defmodule SymphonyElixir.ProjectRepoPreflight do
  @moduledoc """
  Read-only readiness check for explicitly approved project repositories.

  This is intentionally separate from runtime polling and dispatch. It proves
  that a repository mapping can be resolved and inspected without granting a
  worker permission to pick up issues from that project.
  """

  @mapping %{
    "project-management" => %{
      repository: "aroakpm-svg/aroak-project-management",
      default_branch: "main",
      required_scripts: ["typecheck", "build", "db:test"]
    }
  }
  @command_timeout_ms 10_000
  @github_hostname "github.com"
  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  @type command_runner :: (String.t(), [String.t()] -> {String.t(), non_neg_integer()})
  @type receipt :: %{
          project: String.t(),
          repository: String.t(),
          default_branch: String.t(),
          head_sha: String.t(),
          required_scripts: [String.t()]
        }
  @type blocker :: %{code: atom(), detail: term(), next_step: String.t()}

  @spec check(String.t(), command_runner()) :: {:ok, receipt()} | {:blocked, blocker()}
  def check(project, runner \\ &run_command/2) when is_binary(project) and is_function(runner, 2) do
    case Map.fetch(@mapping, project) do
      {:ok, mapping} -> check_mapping(project, mapping, runner)
      :error -> blocked(:project_mapping_missing, project, "Add an explicitly approved project-to-repository mapping.")
    end
  end

  defp check_mapping(project, mapping, runner) do
    with {:ok, repo} <- repository_metadata(mapping, runner),
         :ok <- verify_repository(mapping, repo),
         {:ok, head_sha} <- default_branch_head(mapping, runner),
         {:ok, scripts} <- package_scripts(mapping, head_sha, runner),
         :ok <- verify_required_scripts(mapping, scripts) do
      {:ok,
       %{
         project: project,
         repository: mapping.repository,
         default_branch: mapping.default_branch,
         head_sha: head_sha,
         required_scripts: mapping.required_scripts
       }}
    end
  end

  defp repository_metadata(mapping, runner) do
    args = ["api", "repos/#{mapping.repository}", "--hostname", @github_hostname]

    case safe_run(runner, "gh", args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{"full_name" => repository, "default_branch" => branch} = metadata}
          when is_binary(repository) and is_binary(branch) ->
            {:ok, metadata}

          _other ->
            blocked(:repository_metadata_invalid, nil, "Retry the read-only preflight; GitHub returned malformed repository metadata.")
        end

      {:error, _reason} ->
        blocked(:repository_unavailable, mapping.repository, "Grant GitHub CLI read access to the mapped repository.")
    end
  end

  defp verify_repository(mapping, metadata) do
    actual_repository = metadata["full_name"]
    actual_branch = metadata["default_branch"]

    cond do
      actual_repository != mapping.repository ->
        blocked(:repository_mismatch, actual_repository, "Correct the approved repository mapping.")

      actual_branch != mapping.default_branch ->
        blocked(:default_branch_mismatch, actual_branch, "Restore the repository default branch to main or update the approved mapping.")

      true ->
        :ok
    end
  end

  defp default_branch_head(mapping, runner) do
    args = ["api", "repos/#{mapping.repository}/git/ref/heads/#{mapping.default_branch}", "--hostname", @github_hostname]

    case safe_run(runner, "gh", args) do
      {:ok, output} ->
        parse_default_branch_head(output, mapping)

      {:error, _reason} ->
        branch_unresolvable(mapping)
    end
  end

  defp parse_default_branch_head(output, mapping) do
    case Jason.decode(output) do
      {:ok, %{"ref" => "refs/heads/" <> branch, "object" => %{"sha" => sha}}}
      when branch == mapping.default_branch and is_binary(sha) ->
        validate_head_sha(sha, mapping)

      _other ->
        branch_unresolvable(mapping)
    end
  end

  defp validate_head_sha(sha, mapping) do
    if Regex.match?(@sha_pattern, sha),
      do: {:ok, String.downcase(sha)},
      else: branch_unresolvable(mapping)
  end

  defp package_scripts(mapping, head_sha, runner) do
    args = [
      "api",
      "repos/#{mapping.repository}/contents/package.json?ref=#{head_sha}",
      "--hostname",
      @github_hostname,
      "-H",
      "Accept: application/vnd.github.raw+json"
    ]

    case safe_run(runner, "gh", args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{"scripts" => scripts}} when is_map(scripts) -> {:ok, scripts}
          _other -> blocked(:required_check_contract_invalid, nil, "Restore a valid package.json scripts contract on main.")
        end

      {:error, _reason} ->
        blocked(:required_check_contract_unreadable, nil, "Ensure package.json exists and is readable at the verified head.")
    end
  end

  defp verify_required_scripts(mapping, scripts) do
    missing =
      Enum.reject(mapping.required_scripts, fn name ->
        case Map.get(scripts, name) do
          command when is_binary(command) -> String.trim(command) != ""
          _other -> false
        end
      end)

    if missing == [] do
      :ok
    else
      blocked(:required_check_contract_missing, missing, "Add the missing quality scripts to package.json before enabling runtime pickup.")
    end
  end

  defp safe_run(runner, command, args) do
    parent = self()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {self(), execute_runner(runner, command, args)}) end)

    receive do
      {^pid, {output, 0}} when is_binary(output) ->
        Process.demonitor(monitor, [:flush])
        {:ok, output}

      {^pid, {_output, status}} when is_integer(status) ->
        Process.demonitor(monitor, [:flush])
        {:error, :command_failed}

      {^pid, :command_exception} ->
        Process.demonitor(monitor, [:flush])
        {:error, :command_exception}

      {^pid, _unexpected} ->
        Process.demonitor(monitor, [:flush])
        {:error, :invalid_command_result}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :command_exception}
    after
      @command_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        {:error, :command_timeout}
    end
  end

  defp execute_runner(runner, command, args) do
    runner.(command, args)
  rescue
    _error -> :command_exception
  catch
    _kind, _reason -> :command_exception
  end

  defp branch_unresolvable(mapping) do
    blocked(:default_branch_unresolvable, mapping.default_branch, "Ensure the mapped default branch exists and is readable.")
  end

  defp blocked(code, detail, next_step), do: {:blocked, %{code: code, detail: detail, next_step: next_step}}

  defp run_command(command, args) do
    System.cmd(command, args,
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}, {"GCM_INTERACTIVE", "Never"}]
    )
  end
end
