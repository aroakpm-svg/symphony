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
      clone_url: "https://github.com/aroakpm-svg/aroak-project-management.git",
      default_branch: "main",
      required_scripts: ["typecheck", "build", "db:test"]
    }
  }

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
    with :ok <- command_ok(runner, "gh", ["auth", "status"], :github_auth_unavailable, "Authenticate GitHub CLI with read access to the repository."),
         {:ok, repo} <- repository_metadata(mapping, runner),
         :ok <- verify_repository(mapping, repo),
         {:ok, head_sha} <- default_branch_head(mapping, runner),
         {:ok, scripts} <- package_scripts(mapping, runner),
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
    args = ["repo", "view", mapping.repository, "--json", "nameWithOwner,defaultBranchRef"]

    case runner.("gh", args) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, metadata} -> {:ok, metadata}
          {:error, _reason} -> blocked(:repository_metadata_invalid, nil, "Retry the read-only preflight; GitHub returned malformed repository metadata.")
        end

      {_output, _status} ->
        blocked(:repository_unavailable, mapping.repository, "Grant GitHub CLI read access to the mapped repository.")
    end
  end

  defp verify_repository(mapping, metadata) do
    actual_repository = metadata["nameWithOwner"]
    actual_branch = get_in(metadata, ["defaultBranchRef", "name"])

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
    args = ["ls-remote", "--exit-code", mapping.clone_url, "refs/heads/#{mapping.default_branch}"]

    case runner.("git", args) do
      {output, 0} ->
        case output |> String.split() |> List.first() do
          nil -> blocked(:default_branch_unresolvable, mapping.default_branch, "Ensure the mapped default branch exists and is readable.")
          sha -> {:ok, String.downcase(sha)}
        end

      {_output, _status} ->
        blocked(:default_branch_unresolvable, mapping.default_branch, "Ensure the mapped default branch exists and is readable.")
    end
  end

  defp package_scripts(mapping, runner) do
    args = ["api", "repos/#{mapping.repository}/contents/package.json", "-H", "Accept: application/vnd.github.raw+json"]

    case runner.("gh", args) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"scripts" => scripts}} when is_map(scripts) -> {:ok, scripts}
          _other -> blocked(:required_check_contract_invalid, nil, "Restore a valid package.json scripts contract on main.")
        end

      {_output, _status} ->
        blocked(:required_check_contract_unreadable, nil, "Grant read access to package.json on the mapped repository.")
    end
  end

  defp verify_required_scripts(mapping, scripts) do
    missing = Enum.reject(mapping.required_scripts, &Map.has_key?(scripts, &1))

    if missing == [] do
      :ok
    else
      blocked(:required_check_contract_missing, missing, "Add the missing quality scripts to package.json before enabling runtime pickup.")
    end
  end

  defp command_ok(runner, command, args, code, next_step) do
    case runner.(command, args) do
      {_output, 0} -> :ok
      {_output, _status} -> blocked(code, nil, next_step)
    end
  end

  defp blocked(code, detail, next_step), do: {:blocked, %{code: code, detail: detail, next_step: next_step}}

  defp run_command(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  end
end
