defmodule SymphonyElixir.GitBranchResolver do
  @moduledoc """
  Resolves and verifies live remote Git branch authority without mutating work branches.
  """

  alias SymphonyElixir.Workspace

  defmodule Receipt do
    @moduledoc "Verified remote branch evidence captured during readiness checks."

    @enforce_keys [:source, :ref, :branch, :advertised_sha, :fetched_sha]
    defstruct [:source, :ref, :branch, :advertised_sha, :fetched_sha]

    @type t :: %__MODULE__{
            source: :canonical_default | :explicit_branch,
            ref: String.t(),
            branch: String.t(),
            advertised_sha: String.t(),
            fetched_sha: String.t()
          }
  end

  defmodule Failure do
    @moduledoc "Fail-closed Git authority result with one operator action."

    @enforce_keys [:code, :detail, :operator_action]
    defstruct [:code, :command, :detail, :operator_action]

    @type t :: %__MODULE__{
            code: atom(),
            command: String.t() | nil,
            detail: String.t(),
            operator_action: String.t()
          }
  end

  @type command_runner :: ([String.t()] -> {:ok, String.t()} | {:error, term()})

  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  @spec resolve(Path.t(), keyword()) :: {:ok, Receipt.t()} | {:error, Failure.t()}
  def resolve(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    runner = command_runner(workspace, opts)
    args = ["ls-remote", "--symref", "origin", "HEAD"]

    with {:ok, output} <- run(runner, args),
         {:ok, ref, branch, advertised_sha} <- parse_canonical_head(output),
         {:ok, fetched_sha} <- fetch_and_verify(runner, ref, advertised_sha, :canonical_head_moved) do
      {:ok,
       %Receipt{
         source: :canonical_default,
         ref: ref,
         branch: branch,
         advertised_sha: advertised_sha,
         fetched_sha: fetched_sha
       }}
    end
  end

  @spec lookup_branch(Path.t(), String.t(), keyword()) ::
          {:ok, Receipt.t() | :missing} | {:error, Failure.t()}
  def lookup_branch(workspace, branch, opts \\ [])
      when is_binary(workspace) and is_binary(branch) and is_list(opts) do
    runner = command_runner(workspace, opts)

    with :ok <- validate_branch(branch, :branch_ref_invalid),
         ref = "refs/heads/#{branch}",
         args = ["ls-remote", "--heads", "origin", ref],
         {:ok, output} <- run(runner, args),
         {:ok, advertised_sha} <- parse_explicit_head(output, ref) do
      resolve_explicit_branch(runner, ref, branch, advertised_sha)
    end
  end

  @spec valid_branch?(String.t()) :: boolean()
  def valid_branch?(branch) when is_binary(branch) do
    branch != "" and
      branch != "@" and
      not String.starts_with?(branch, ["-", ".", "/"]) and
      not String.ends_with?(branch, ["/", ".", ".lock"]) and
      not String.contains?(branch, ["..", "@{", "//", "\\"]) and
      not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[]/, branch) and
      Enum.all?(String.split(branch, "/"), fn component ->
        component != "" and not String.starts_with?(component, ".") and
          not String.ends_with?(component, ".lock")
      end)
  end

  def valid_branch?(_branch), do: false

  defp command_runner(workspace, opts) do
    case Keyword.get(opts, :command_runner) do
      runner when is_function(runner, 1) ->
        runner

      nil ->
        worker_host = Keyword.get(opts, :worker_host)
        fn args -> Workspace.run_git_command(workspace, args, worker_host) end
    end
  end

  defp run(runner, args) do
    command = Enum.join(["git" | args], " ")

    try do
      case runner.(args) do
        {:ok, output} when is_binary(output) ->
          {:ok, output}

        {:error, %Failure{} = failure} ->
          {:error, failure}

        {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
          failure(
            :command_timeout,
            command,
            "#{command} timed out after #{timeout_ms}ms",
            "Verify remote connectivity, then retry the readiness check."
          )

        {:error, {:git_command_failed, failed_command, status, output}} ->
          failure(
            :command_failed,
            failed_command,
            "status=#{status} output=#{sanitize(output)}",
            "Verify origin access and credentials, then retry the readiness check."
          )

        {:error, {:git_command_failed, failed_command, detail}} ->
          failure(
            :command_failed,
            failed_command,
            sanitize(detail),
            "Verify origin access and credentials, then retry the readiness check."
          )

        {:error, reason} ->
          failure(
            :command_failed,
            command,
            sanitize(inspect(reason)),
            "Verify origin access and credentials, then retry the readiness check."
          )

        other ->
          failure(
            :command_failed,
            command,
            "unexpected command result: #{sanitize(inspect(other))}",
            "Verify the Git command runner contract, then retry the readiness check."
          )
      end
    rescue
      error ->
        failure(
          :command_failed,
          command,
          sanitize(Exception.message(error)),
          "Verify the Git command runner contract, then retry the readiness check."
        )
    catch
      kind, reason ->
        failure(
          :command_failed,
          command,
          sanitize(inspect({kind, reason})),
          "Verify the Git command runner contract, then retry the readiness check."
        )
    end
  end

  defp parse_canonical_head(output) do
    lines = output_lines(output)
    symref_lines = Enum.filter(lines, &String.starts_with?(&1, "ref:"))

    with {:ok, ref} <- one_canonical_symref(symref_lines),
         "refs/heads/" <> branch <- ref,
         :ok <- validate_branch(branch, :canonical_ref_invalid),
         {:ok, advertised_sha} <- one_canonical_sha(lines),
         :ok <- validate_canonical_evidence(lines) do
      {:ok, ref, branch, advertised_sha}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> invalid_canonical_ref(output)
    end
  end

  defp one_canonical_symref([]) do
    failure(
      :canonical_symref_missing,
      "git ls-remote --symref origin HEAD",
      "origin HEAD did not advertise a symbolic default branch",
      "Set origin HEAD to one canonical branch, then retry the readiness check."
    )
  end

  defp one_canonical_symref([line]) do
    case Regex.run(~r/\Aref:\s+(\S+)\s+HEAD\z/, line, capture: :all_but_first) do
      [ref] -> {:ok, ref}
      _ -> invalid_canonical_ref(line)
    end
  end

  defp one_canonical_symref(_lines) do
    failure(
      :canonical_symref_ambiguous,
      "git ls-remote --symref origin HEAD",
      "origin HEAD advertised multiple symbolic default branches",
      "Repair origin HEAD so it advertises exactly one branch, then retry."
    )
  end

  defp one_canonical_sha(lines) do
    head_lines =
      Enum.filter(lines, fn line ->
        not String.starts_with?(line, "ref:") and Regex.match?(~r/\sHEAD\z/, line)
      end)

    case head_lines do
      [] ->
        failure(
          :canonical_head_invalid,
          "git ls-remote --symref origin HEAD",
          "origin HEAD did not advertise a valid commit SHA",
          "Repair origin HEAD so it resolves to one commit, then retry."
        )

      [line] ->
        case String.split(line, ~r/\s+/, trim: true) do
          [sha, "HEAD"] -> validate_sha(sha, :canonical_head_invalid)
          _ -> invalid_canonical_sha(line)
        end

      _ ->
        failure(
          :canonical_head_ambiguous,
          "git ls-remote --symref origin HEAD",
          "origin HEAD advertised multiple commit SHAs",
          "Retry after origin HEAD has one stable commit."
        )
    end
  end

  defp validate_canonical_evidence([_symref_line, _head_line]), do: :ok

  defp validate_canonical_evidence(_lines) do
    failure(
      :canonical_evidence_malformed,
      "git ls-remote --symref origin HEAD",
      "origin HEAD returned unexpected output in addition to its symref and commit SHA",
      "Remove the unexpected remote or SSH output, then retry the readiness check."
    )
  end

  defp parse_explicit_head(output, ref) do
    lines = output_lines(output)

    case lines do
      [] ->
        {:ok, nil}

      [line] ->
        case String.split(line, ~r/\s+/, trim: true) do
          [sha, ^ref] -> validate_sha(sha, :branch_head_invalid)
          _ -> invalid_branch_head(ref, line)
        end

      _ ->
        failure(
          :branch_head_ambiguous,
          "git ls-remote --heads origin #{ref}",
          "origin advertised multiple heads for #{ref}",
          "Repair the remote ref ambiguity, then retry."
        )
    end
  end

  defp resolve_explicit_branch(_runner, _ref, _branch, nil), do: {:ok, :missing}

  defp resolve_explicit_branch(runner, ref, branch, advertised_sha) do
    with {:ok, fetched_sha} <-
           fetch_and_verify(runner, ref, advertised_sha, :branch_head_moved) do
      {:ok,
       %Receipt{
         source: :explicit_branch,
         ref: ref,
         branch: branch,
         advertised_sha: advertised_sha,
         fetched_sha: fetched_sha
       }}
    end
  end

  defp fetch_and_verify(runner, ref, advertised_sha, moved_code) do
    with {:ok, _output} <- run(runner, ["fetch", "--no-tags", "origin", ref]),
         {:ok, fetched_output} <- run(runner, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"]),
         {:ok, fetched_sha} <- parse_fetched_sha(fetched_output),
         :ok <- verify_fetched_sha(ref, advertised_sha, fetched_sha, moved_code) do
      {:ok, fetched_sha}
    end
  end

  defp parse_fetched_sha(output) do
    case output_lines(output) do
      [sha] ->
        validate_sha(sha, :fetched_head_invalid)

      _ ->
        failure(
          :fetched_head_invalid,
          "git rev-parse --verify FETCH_HEAD^{commit}",
          "FETCH_HEAD did not resolve to exactly one commit SHA",
          "Retry after verifying the remote branch resolves to one commit."
        )
    end
  end

  defp verify_fetched_sha(_ref, advertised_sha, fetched_sha, _moved_code)
       when advertised_sha == fetched_sha,
       do: :ok

  defp verify_fetched_sha(ref, advertised_sha, fetched_sha, moved_code) do
    failure(
      moved_code,
      "git fetch --no-tags origin #{ref}",
      "#{ref} moved from advertised #{advertised_sha} to fetched #{fetched_sha}",
      "Retry the readiness check after the remote ref is stable."
    )
  end

  defp validate_branch(branch, error_code) do
    if valid_branch?(branch) do
      :ok
    else
      failure(
        error_code,
        nil,
        "invalid branch name: #{sanitize(branch)}",
        "Provide one valid refs/heads branch name, then retry."
      )
    end
  end

  defp validate_sha(sha, error_code) do
    if Regex.match?(@sha_pattern, sha) do
      {:ok, String.downcase(sha)}
    else
      failure(
        error_code,
        nil,
        "invalid commit SHA: #{sanitize(sha)}",
        "Provide one full 40- or 64-character commit SHA, then retry."
      )
    end
  end

  defp invalid_canonical_ref(detail) do
    failure(
      :canonical_ref_invalid,
      "git ls-remote --symref origin HEAD",
      "invalid canonical symref evidence: #{sanitize(detail)}",
      "Set origin HEAD to one valid refs/heads branch, then retry."
    )
  end

  defp invalid_canonical_sha(detail) do
    failure(
      :canonical_head_invalid,
      "git ls-remote --symref origin HEAD",
      "invalid canonical HEAD evidence: #{sanitize(detail)}",
      "Repair origin HEAD so it resolves to one full commit SHA, then retry."
    )
  end

  defp invalid_branch_head(ref, detail) do
    failure(
      :branch_head_invalid,
      "git ls-remote --heads origin #{ref}",
      "invalid remote branch evidence: #{sanitize(detail)}",
      "Repair the remote branch ref, then retry."
    )
  end

  defp failure(code, command, detail, operator_action) do
    {:error,
     %Failure{
       code: code,
       command: command,
       detail: sanitize(detail),
       operator_action: operator_action
     }}
  end

  defp output_lines(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sanitize(value) when is_binary(value), do: Workspace.sanitize_command_output(value)
  defp sanitize(value), do: value |> inspect() |> Workspace.sanitize_command_output()
end
