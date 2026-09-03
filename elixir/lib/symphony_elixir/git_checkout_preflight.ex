defmodule SymphonyElixir.GitCheckoutPreflight do
  @moduledoc """
  Validates that a project worker is operating in the checkout authorized before claim.

  The credential is call-local and is supplied only to the worker-aware command boundary. Public
  results are deliberately bounded to non-secret checkout identity.
  """

  alias SymphonyElixir.{Config, PathSafety, ProjectExecutionContext, Workspace}
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @probe_prefix ".symphony-write-probe-"

  @type receipt :: %{repository: String.t(), branch: String.t(), head: String.t()}
  @type reason ::
          :git_checkout_invalid
          | :git_checkout_mismatch
          | :git_remote_mismatch
          | :git_branch_mismatch
          | :github_remote_head_changed
          | :git_metadata_missing
          | :git_metadata_unsafe
          | :git_metadata_unwritable

  @spec check(ProjectExecutionContext.t(), Path.t(), Credential.t(), keyword()) ::
          {:ok, receipt()} | {:error, reason()}
  def check(%ProjectExecutionContext{} = context, workspace, %Credential{} = credential, opts)
      when is_binary(workspace) and is_list(opts) do
    with :ok <- credential_matches(context, credential),
         :ok <- exact_workspace(context, workspace, opts),
         {:ok, expected_head} <- expected_head(opts),
         {:ok, runner} <- command_runner(workspace, context, opts),
         {:ok, origin} <- run(runner, ["remote", "get-url", "origin"], credential, opts),
         {:ok, repository} <- canonical_repository(origin),
         :ok <- equal(repository, context.repository, :git_remote_mismatch),
         {:ok, branch} <- run_text(runner, ["branch", "--show-current"], credential, opts),
         :ok <- equal(branch, context.canonical_branch, :git_branch_mismatch),
         {:ok, local_head} <- run_text(runner, ["rev-parse", "--verify", "HEAD^{commit}"], credential, opts),
         :ok <- valid_bound_head(local_head, expected_head, :git_checkout_mismatch),
         {:ok, remote_head} <- remote_head(runner, context, credential, opts),
         :ok <- valid_bound_head(remote_head, expected_head, :github_remote_head_changed),
         :ok <- metadata_capability(workspace, opts) do
      {:ok, %{repository: repository, branch: branch, head: expected_head}}
    else
      {:error, reason}
      when reason in [
             :git_checkout_invalid,
             :git_checkout_mismatch,
             :git_remote_mismatch,
             :git_branch_mismatch,
             :github_remote_head_changed,
             :git_metadata_missing,
             :git_metadata_unsafe,
             :git_metadata_unwritable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :git_checkout_invalid}
    end
  rescue
    _exception -> {:error, :git_checkout_invalid}
  catch
    _kind, _reason -> {:error, :git_checkout_invalid}
  end

  def check(_context, _workspace, _credential, _opts), do: {:error, :git_checkout_invalid}

  defp credential_matches(
         %ProjectExecutionContext{credential_ref: ref},
         %Credential{credential_ref: ref, token: token}
       )
       when is_binary(token) and byte_size(token) > 0,
       do: :ok

  defp credential_matches(_context, _credential), do: {:error, :git_checkout_invalid}

  defp exact_workspace(context, workspace, opts) do
    root = Keyword.get(opts, :workspace_root, Config.settings!().workspace.root)

    expected =
      Path.join([root, context.workspace_namespace, safe_identifier(context.issue_identifier)])
      |> normalize_path()

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_expected} <- PathSafety.canonicalize(expected),
         true <- normalize_path(workspace) == expected,
         true <- normalize_path(canonical_workspace) == normalize_path(canonical_expected) do
      :ok
    else
      _failure -> {:error, :git_checkout_mismatch}
    end
  end

  defp normalize_path(path), do: path |> Path.expand() |> String.replace("\\", "/")

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp expected_head(opts) do
    case Keyword.get(opts, :expected_head_sha) do
      head when is_binary(head) ->
        head = String.downcase(String.trim(head))
        if valid_sha?(head), do: {:ok, head}, else: {:error, :git_checkout_invalid}

      _head ->
        {:error, :git_checkout_invalid}
    end
  end

  defp command_runner(workspace, context, opts) do
    case {Keyword.get(opts, :command_runner), Keyword.get(opts, :worker_host)} do
      {runner, _worker_host} when is_function(runner, 3) ->
        {:ok, runner}

      {nil, nil} ->
        {:ok,
         fn args, %Credential{token: token}, runtime ->
           workspace_opts =
             runtime
             |> Keyword.take([:workspace_attestation])
             |> Keyword.put(:execution_context, context)
             |> Keyword.put(:env, %{"GH_TOKEN" => token})

           Workspace.run_git_command(workspace, args, nil, workspace_opts)
         end}

      {nil, _worker_host} ->
        # Remote credentials must not be embedded in an SSH command line. Host packaging supplies
        # a worker-local runner that receives the credential as a call-local value.
        {:error, :git_checkout_invalid}

      {_runner, _worker_host} ->
        {:error, :git_checkout_invalid}
    end
  end

  defp run(runner, args, credential, opts) do
    case runner.(args, credential, worker_runtime(opts)) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      _failure -> {:error, :git_checkout_invalid}
    end
  rescue
    _exception -> {:error, :git_checkout_invalid}
  catch
    _kind, _reason -> {:error, :git_checkout_invalid}
  end

  defp run_text(runner, args, credential, opts) do
    with {:ok, output} <- run(runner, args, credential, opts),
         value <- String.trim(output),
         true <- value != "" and not String.contains?(value, ["\n", "\r", <<0>>]) do
      {:ok, value}
    else
      _failure -> {:error, :git_checkout_invalid}
    end
  end

  defp worker_runtime(opts), do: Keyword.take(opts, [:worker_host, :workspace_attestation])

  defp canonical_repository(output) do
    origin = String.trim(output)

    repository =
      cond do
        Regex.match?(~r/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/i, origin) ->
          String.replace_prefix(origin, "https://github.com/", "")

        Regex.match?(~r/\Agit@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/i, origin) ->
          String.replace_prefix(origin, "git@github.com:", "")

        Regex.match?(~r/\Assh:\/\/git@github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/i, origin) ->
          String.replace_prefix(origin, "ssh://git@github.com/", "")

        true ->
          nil
      end

    case repository do
      value when is_binary(value) -> {:ok, String.trim_trailing(value, ".git")}
      _invalid -> {:error, :git_remote_mismatch}
    end
  end

  defp equal(value, value, _reason), do: :ok
  defp equal(_actual, _expected, reason), do: {:error, reason}

  defp valid_bound_head(head, expected, reason) do
    normalized = String.downcase(String.trim(head))
    if valid_sha?(normalized) and normalized == expected, do: :ok, else: {:error, reason}
  end

  defp valid_sha?(sha), do: Regex.match?(@sha_pattern, sha)

  defp remote_head(runner, context, credential, opts) do
    ref = "refs/heads/" <> context.canonical_branch

    with {:ok, output} <- run(runner, ["ls-remote", "--heads", "origin", ref], credential, opts) do
      case String.split(String.trim(output), ~r/\s+/, trim: true) do
        [sha, ^ref] when is_binary(sha) -> {:ok, sha}
        _invalid -> {:error, :github_remote_head_changed}
      end
    end
  end

  defp metadata_capability(workspace, opts) do
    git_dir = Path.join(workspace, ".git")

    with {:ok, :directory} <- inspect_metadata(git_dir, opts),
         :ok <- probe_metadata(git_dir, opts) do
      :ok
    else
      {:error, :enoent} -> {:error, :git_metadata_missing}
      {:ok, type} when type in [:symlink, :reparse] -> {:error, :git_metadata_unsafe}
      _failure -> {:error, :git_metadata_unwritable}
    end
  end

  defp inspect_metadata(path, opts) do
    case Keyword.get(opts, :metadata_inspector) do
      inspector when is_function(inspector, 1) -> inspector.(path)
      nil -> local_metadata_type(path)
      _invalid -> {:error, :invalid_inspector}
    end
  rescue
    _exception -> {:error, :invalid_inspector}
  end

  defp local_metadata_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, :directory}
      {:ok, %File.Stat{type: :symlink}} -> {:ok, :symlink}
      {:ok, _stat} -> {:ok, :other}
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_metadata(git_dir, opts) do
    probe_path = Path.join(git_dir, @probe_prefix <> random_suffix())

    try do
      case Keyword.get(opts, :metadata_probe) do
        probe when is_function(probe, 1) -> normalize_probe(probe.(probe_path))
        nil -> exclusive_probe(probe_path)
        _invalid -> {:error, :invalid_probe}
      end
    rescue
      _exception -> {:error, :probe_failed}
    catch
      _kind, _reason -> {:error, :probe_failed}
    after
      _ = File.rm(probe_path)
    end
  end

  defp normalize_probe(:ok), do: :ok
  defp normalize_probe(_failure), do: {:error, :probe_failed}

  defp exclusive_probe(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, device} -> File.close(device)
      {:error, reason} -> {:error, reason}
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end
end
