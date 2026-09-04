defmodule SymphonyElixir.GitCheckoutPreflight do
  @moduledoc """
  Validates that a project worker is operating in the checkout authorized before claim.

  The credential is call-local and is supplied only to the worker-aware command boundary. Public
  results are deliberately bounded to non-secret checkout identity.
  """

  alias SymphonyElixir.{Config, GitCredentialEnvironment, PathSafety, ProjectExecutionContext, Workspace}
  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.GitPreflightCommand

  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @probe_prefix ".symphony-write-probe-"

  @type receipt :: %{repository: String.t(), branch: String.t(), head: String.t()}
  @type reason ::
          :git_checkout_invalid
          | :git_checkout_mismatch
          | :git_remote_mismatch
          | :git_branch_mismatch
          | :github_remote_head_changed
          | :github_unavailable
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
         :ok <- validate_origin(runner, context.repository, credential, opts),
         {:ok, branch} <- run_text(runner, ["branch", "--show-current"], credential, opts),
         :ok <- validate_push_selection(runner, branch, credential, opts),
         {:ok, local_head} <- run_text(runner, ["rev-parse", "--verify", "HEAD^{commit}"], credential, opts),
         :ok <- validate_local_checkout(branch, local_head, expected_head, context, opts),
         {:ok, remote_head} <- remote_head(runner, context, credential, opts),
         :ok <- valid_bound_head(remote_head, expected_head, :github_remote_head_changed),
         :ok <- metadata_capability(workspace, opts) do
      {:ok, %{repository: context.repository, branch: branch, head: expected_head}}
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

    expected = Path.join([root, context.workspace_namespace, safe_identifier(context.issue_identifier)])

    case Keyword.get(opts, :worker_host) do
      nil -> exact_local_workspace(context, workspace, root, opts)
      worker_host when is_binary(worker_host) -> exact_remote_workspace(context, workspace, expected, worker_host, opts)
      _invalid -> {:error, :git_checkout_mismatch}
    end
  end

  defp exact_local_workspace(context, workspace, root, opts) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         # Resolve only the root: namespace/issue links must not redefine the authorized checkout.
         expected = Path.join([canonical_root, context.workspace_namespace, safe_identifier(context.issue_identifier)]),
         true <- normalize_path(canonical_workspace) == normalize_path(expected),
         :ok <- validate_local_attestation(context, workspace, opts) do
      :ok
    else
      _failure -> {:error, :git_checkout_mismatch}
    end
  end

  defp validate_local_attestation(context, workspace, opts) do
    case Keyword.get(opts, :workspace_attestation) do
      nil -> :ok
      attestation -> Workspace.validate_execution_workspace(workspace, nil, context, attestation)
    end
  end

  defp exact_remote_workspace(context, workspace, expected, worker_host, opts) do
    expected_attestation = Keyword.get(opts, :workspace_attestation)

    with true <- normalize_path_lexical(workspace) == normalize_path_lexical(expected),
         {:ok, attestor} <- workspace_attestor(opts),
         {:ok, current_attestation} <- attest(attestor, context, worker_host),
         true <- current_attestation == expected_attestation,
         {:ok, guard} <- workspace_guard(opts),
         :ok <- guard.(workspace, worker_host, context, current_attestation) do
      :ok
    else
      _failure -> {:error, :git_checkout_mismatch}
    end
  end

  defp workspace_attestor(opts) do
    case Keyword.get(opts, :workspace_attestor) do
      attestor when is_function(attestor, 3) -> {:ok, attestor}
      nil -> {:ok, &Workspace.attest_existing_issue_workspace/3}
      _invalid -> {:error, :git_checkout_mismatch}
    end
  end

  defp workspace_guard(opts) do
    case Keyword.get(opts, :workspace_guard, &Workspace.validate_execution_workspace/4) do
      guard when is_function(guard, 4) -> {:ok, guard}
      _invalid -> {:error, :git_checkout_mismatch}
    end
  end

  defp attest(attestor, context, worker_host) do
    attestor.(context.issue_identifier, worker_host, context)
  rescue
    _exception -> {:error, :git_checkout_mismatch}
  catch
    _kind, _reason -> {:error, :git_checkout_mismatch}
  end

  defp normalize_path(path), do: path |> Path.expand() |> String.replace("\\", "/")
  defp normalize_path_lexical(path), do: String.replace(path, "\\", "/")

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
         fn args, %Credential{} = credential, runtime ->
           with {:ok, environment} <- GitCredentialEnvironment.build(credential) do
             workspace_opts =
               runtime
               |> Keyword.take([:workspace_attestation])
               |> Keyword.put(:execution_context, context)
               |> Keyword.put(:env, environment)

             Workspace.run_git_command(workspace, args, nil, workspace_opts)
           end
         end}

      {nil, _worker_host} ->
        # Remote credentials must not be embedded in an SSH command line. Host packaging supplies
        # a worker-local runner that receives the credential as a call-local value.
        {:error, :git_checkout_invalid}

      {_runner, _worker_host} ->
        {:error, :git_checkout_invalid}
    end
  end

  defp run(runner, args, credential, opts, operation \\ :local) do
    case GitPreflightCommand.run(runner, args, credential, worker_runtime(opts), operation) do
      {:error, :command_failed} -> {:error, :git_checkout_invalid}
      result -> result
    end
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

    if Regex.match?(~r/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/, origin) do
      {:ok, origin |> String.replace_prefix("https://github.com/", "") |> String.trim_trailing(".git")}
    else
      {:error, :git_remote_mismatch}
    end
  end

  defp validate_origin(runner, repository, credential, opts) do
    # Git resolves insteadOf/pushInsteadOf here. A fetch URL cannot attest a push
    # destination, and Git may push to every configured pushurl.
    with {:ok, fetch_urls} <- run(runner, ["remote", "get-url", "--all", "origin"], credential, opts),
         :ok <- validate_remote_urls(fetch_urls, repository),
         {:ok, push_urls} <- run(runner, ["remote", "get-url", "--push", "--all", "origin"], credential, opts) do
      validate_remote_urls(push_urls, repository)
    end
  end

  defp validate_push_selection(runner, branch, credential, opts) do
    # Plain push can select a different remote at any of these three levels.
    # Reject competing configuration even when another setting currently overrides it:
    # the checkout contract authorizes origin, not a separate publishing remote.
    keys = ["remote.pushDefault", "branch.#{branch}.pushRemote", "branch.#{branch}.remote"]

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case run(runner, ["config", "--get", "--default", "origin", key], credential, opts) do
        {:ok, origin} when origin in ["origin", "origin\n", "origin\r\n"] -> {:cont, :ok}
        {:ok, _other} -> {:halt, {:error, :git_remote_mismatch}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_remote_urls(output, repository) do
    urls = output |> String.trim() |> String.split(~r/\r?\n/)

    if Enum.all?(urls, &(canonical_repository(&1) == {:ok, repository})),
      do: :ok,
      else: {:error, :git_remote_mismatch}
  end

  defp valid_bound_head(head, expected, reason) do
    normalized = String.downcase(String.trim(head))
    if valid_sha?(normalized) and normalized == expected, do: :ok, else: {:error, reason}
  end

  defp validate_local_checkout(branch, local_head, expected_head, context, opts) do
    created_now = Keyword.get(opts, :created_now, true)
    issue_branch = Keyword.get(opts, :expected_issue_branch)

    cond do
      branch == context.canonical_branch ->
        valid_bound_head(local_head, expected_head, :git_checkout_mismatch)

      created_now == false and is_binary(issue_branch) and issue_branch != "" and branch == issue_branch ->
        if valid_sha?(String.downcase(String.trim(local_head))),
          do: :ok,
          else: {:error, :git_checkout_mismatch}

      true ->
        {:error, :git_branch_mismatch}
    end
  end

  defp valid_sha?(sha), do: Regex.match?(@sha_pattern, sha)

  defp remote_head(runner, context, credential, opts) do
    ref = "refs/heads/" <> context.canonical_branch

    with {:ok, output} <- run(runner, ["ls-remote", "--heads", "origin", ref], credential, opts, :remote) do
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
    worker_host = Keyword.get(opts, :worker_host)

    case {worker_host, Keyword.get(opts, :metadata_inspector)} do
      {nil, inspector} when is_function(inspector, 1) ->
        inspector.(path)

      {nil, nil} ->
        local_metadata_type(path)

      {host, inspector} when is_binary(host) and is_function(inspector, 2) ->
        inspector.(path, worker_runtime(opts))

      _invalid ->
        {:error, :invalid_inspector}
    end
  rescue
    _exception -> {:error, :invalid_inspector}
  end

  defp local_metadata_type(path) do
    case Workspace.validate_non_reparse_directory_for_worker(path) do
      :ok -> {:ok, :directory}
      {:error, :enoent} -> {:error, :enoent}
      {:error, _unsafe} -> {:ok, :reparse}
    end
  end

  defp probe_metadata(git_dir, opts) do
    probe_path = Path.join(git_dir, @probe_prefix <> random_suffix())

    if is_binary(Keyword.get(opts, :worker_host)) do
      remote_probe_metadata(probe_path, opts)
    else
      local_probe_metadata(probe_path, opts)
    end
  end

  defp remote_probe_metadata(probe_path, opts) do
    case Keyword.get(opts, :metadata_probe) do
      probe when is_function(probe, 2) -> normalize_probe(probe.(probe_path, worker_runtime(opts)))
      _missing_or_invalid -> {:error, :probe_failed}
    end
  rescue
    _exception -> {:error, :probe_failed}
  catch
    _kind, _reason -> {:error, :probe_failed}
  end

  defp local_probe_metadata(probe_path, opts) do
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
