defmodule SymphonyElixir.ReadinessGate do
  @moduledoc """
  Proves an issue workspace is safe to dispatch without repairing existing work branches.
  """

  alias SymphonyElixir.GitBranchResolver
  alias SymphonyElixir.GitBranchResolver.Receipt, as: GitReceipt
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Linear.Issue.StackedBase
  alias SymphonyElixir.Workspace

  defmodule Receipt do
    @moduledoc "Typed pre-dispatch branch readiness evidence."

    @enforce_keys [:classification, :issue_branch, :head_sha, :canonical]
    defstruct [:classification, :issue_branch, :head_sha, :canonical, :upstream]

    @type t :: %__MODULE__{
            classification: :continuation | :independent_new | :explicit_stack,
            issue_branch: String.t(),
            head_sha: String.t(),
            canonical: GitBranchResolver.Receipt.t(),
            upstream: GitBranchResolver.Receipt.t() | nil
          }
  end

  defmodule Failure do
    @moduledoc "Fail-closed readiness result with the smallest operator action."

    @enforce_keys [:code, :detail, :operator_action]
    defstruct [:code, :command, :detail, :operator_action]

    @type t :: %__MODULE__{
            code: atom(),
            command: String.t() | nil,
            detail: String.t(),
            operator_action: String.t()
          }
  end

  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  @spec check(Path.t(), Issue.t(), keyword()) :: {:ok, Receipt.t()} | {:error, Failure.t()}
  def check(workspace, %Issue{} = issue, opts \\ [])
      when is_binary(workspace) and is_list(opts) do
    with {:ok, created_now?} <- workspace_created_now(opts),
         {:ok, issue_branch} <- issue_branch(issue),
         {:ok, canonical} <- resolve_canonical(workspace, opts),
         :ok <- validate_issue_branch_not_canonical(issue_branch, canonical),
         {:ok, state} <- inspect_workspace(workspace, issue_branch, opts),
         {:ok, remote_issue_branch} <- lookup_branch(workspace, issue_branch, opts) do
      classify(
        workspace,
        issue,
        issue_branch,
        created_now?,
        canonical,
        state,
        remote_issue_branch,
        opts
      )
    end
  end

  defp classify(
         workspace,
         _issue,
         issue_branch,
         false,
         canonical,
         %{current_branch: issue_branch, head_sha: head_sha} = state,
         remote_issue_branch,
         opts
       ) do
    runner = command_runner(workspace, opts)

    with :ok <-
           verify_continuation_remote(
             runner,
             remote_issue_branch,
             issue_branch,
             head_sha
           ) do
      finish_continuation(runner, issue_branch, state, canonical)
    end
  end

  defp classify(
         workspace,
         _issue,
         issue_branch,
         true,
         canonical,
         %{current_branch: issue_branch, head_sha: head_sha} = state,
         %GitReceipt{fetched_sha: head_sha},
         opts
       ) do
    workspace
    |> command_runner(opts)
    |> finish_continuation(issue_branch, state, canonical)
  end

  defp classify(
         _workspace,
         _issue,
         issue_branch,
         true,
         _canonical,
         %{current_branch: issue_branch, head_sha: local_sha},
         :missing,
         _opts
       ) do
    failure(
      :new_issue_branch_already_exists,
      "new workspace already has local branch #{issue_branch} at #{local_sha}",
      "Preserve the branch for inspection and recreate a clean issue workspace from the live default head."
    )
  end

  defp classify(
         _workspace,
         _issue,
         issue_branch,
         true,
         _canonical,
         %{current_branch: issue_branch, head_sha: local_sha},
         %GitReceipt{fetched_sha: remote_sha},
         _opts
       ) do
    failure(
      :new_issue_branch_remote_mismatch,
      "fresh local branch #{issue_branch} is #{local_sha}, but origin advertises #{remote_sha}",
      "Preserve the local branch and reconcile it manually with the exact remote branch before retrying."
    )
  end

  defp classify(
         _workspace,
         _issue,
         issue_branch,
         _created_now?,
         _canonical,
         %{local_issue_branch?: true, current_branch: current_branch},
         _remote_issue_branch,
         _opts
       ) do
    failure(
      :continuation_branch_not_checked_out,
      "issue branch #{issue_branch} exists locally, but the workspace is on #{current_branch}",
      "Check out the matching issue branch manually without resetting or rebasing it, then retry."
    )
  end

  defp classify(
         workspace,
         _issue,
         issue_branch,
         _created_now?,
         canonical,
         %{dirty: false},
         %GitReceipt{} = remote_issue_branch,
         opts
       ) do
    create_and_verify_branch(
      workspace,
      issue_branch,
      remote_issue_branch.fetched_sha,
      :continuation,
      canonical,
      remote_issue_branch,
      opts
    )
  end

  defp classify(
         _workspace,
         _issue,
         issue_branch,
         _created_now?,
         _canonical,
         %{dirty: true, status: status},
         %GitReceipt{},
         _opts
       ) do
    failure(
      :continuation_workspace_dirty,
      "cannot materialize remote issue branch #{issue_branch} while workspace has changes: #{status}",
      "Preserve or remove the current workspace changes manually, then retry."
    )
  end

  defp classify(
         _workspace,
         _issue,
         issue_branch,
         _created_now?,
         _canonical,
         %{dirty: true, status: status},
         :missing,
         _opts
       ) do
    failure(
      :independent_workspace_dirty,
      "cannot create #{issue_branch} while workspace has changes: #{status}",
      "Preserve or remove the workspace changes manually, then retry."
    )
  end

  defp classify(
         workspace,
         %Issue{readiness_base: :canonical},
         issue_branch,
         _created_now?,
         canonical,
         %{dirty: false},
         :missing,
         opts
       ) do
    create_and_verify_branch(
      workspace,
      issue_branch,
      canonical.fetched_sha,
      :independent_new,
      canonical,
      nil,
      opts
    )
  end

  defp classify(
         workspace,
         %Issue{readiness_base: {:stacked, candidates}},
         issue_branch,
         _created_now?,
         canonical,
         %{dirty: false},
         :missing,
         opts
       ) do
    with {:ok, evidence} <- one_stacked_evidence(candidates, issue_branch),
         {:ok, upstream} <- lookup_stacked_branch(workspace, evidence, opts) do
      create_and_verify_branch(
        workspace,
        issue_branch,
        upstream.fetched_sha,
        :explicit_stack,
        canonical,
        upstream,
        opts
      )
    end
  end

  defp classify(
         _workspace,
         %Issue{readiness_base: readiness_base},
         _issue_branch,
         _created_now?,
         _canonical,
         _state,
         :missing,
         _opts
       ) do
    failure(
      :readiness_base_invalid,
      "unsupported typed readiness base: #{inspect(readiness_base)}",
      "Set readiness_base to :canonical or one exact typed stacked evidence entry."
    )
  end

  defp inspect_workspace(workspace, issue_branch, opts) do
    runner = command_runner(workspace, opts)

    with {:ok, current_output} <- run(runner, ["branch", "--show-current"]),
         {:ok, current_branch} <- parse_current_branch(current_output),
         {:ok, head_output} <- run(runner, ["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, head_sha} <- parse_sha(head_output, :workspace_head_invalid),
         {:ok, refs_output} <-
           run(runner, ["for-each-ref", "--format=%(refname)", "refs/heads/#{issue_branch}"]),
         {:ok, status} <- run(runner, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok,
       %{
         current_branch: current_branch,
         head_sha: head_sha,
         local_issue_branch?: local_branch?(refs_output, issue_branch),
         dirty: String.trim(status) != "",
         status: sanitize(String.trim(status))
       }}
    end
  end

  defp validate_issue_branch_not_canonical(
         issue_branch,
         %GitReceipt{branch: issue_branch}
       ) do
    failure(
      :issue_branch_is_canonical_default,
      "tracker issue branch #{issue_branch} is the live canonical default branch",
      "Set a distinct tracker issue branch before dispatch; preserve the canonical default branch."
    )
  end

  defp validate_issue_branch_not_canonical(_issue_branch, %GitReceipt{}), do: :ok

  defp verify_continuation_remote(_runner, :missing, _issue_branch, _local_sha), do: :ok

  defp verify_continuation_remote(
         _runner,
         %GitReceipt{fetched_sha: sha},
         _issue_branch,
         sha
       ),
       do: :ok

  defp verify_continuation_remote(
         runner,
         %GitReceipt{fetched_sha: remote_sha},
         issue_branch,
         local_sha
       ) do
    args = ["merge-base", "--is-ancestor", remote_sha, local_sha]
    command = Enum.join(["git" | args], " ")

    call_runner(runner, args, command, fn
      {:ok, output} when is_binary(output) ->
        :ok

      {:error, {:git_command_failed, _failed_command, 1, _output}} ->
        failure(
          :continuation_remote_not_ancestor,
          "origin/#{issue_branch} at #{remote_sha} is not an ancestor of local HEAD #{local_sha}",
          "Preserve both branch heads and reconcile the behind, diverged, or unrelated continuation manually before retrying.",
          command
        )

      result ->
        normalize_run_result(result, command)
    end)
  end

  defp finish_continuation(runner, issue_branch, initial_state, canonical) do
    with {:ok, final_state} <- reread_branch_and_head(runner),
         :ok <- verify_workspace_unchanged(initial_state, final_state) do
      ready(:continuation, issue_branch, final_state.head_sha, canonical)
    end
  end

  defp reread_branch_and_head(runner) do
    with {:ok, branch_output} <- run(runner, ["branch", "--show-current"]),
         {:ok, current_branch} <- parse_current_branch(branch_output),
         {:ok, head_output} <- run(runner, ["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, head_sha} <- parse_sha(head_output, :workspace_head_invalid) do
      {:ok, %{current_branch: current_branch, head_sha: head_sha}}
    end
  end

  defp verify_workspace_unchanged(
         %{current_branch: branch, head_sha: sha},
         %{current_branch: branch, head_sha: sha}
       ),
       do: :ok

  defp verify_workspace_unchanged(initial_state, final_state) do
    failure(
      :workspace_changed_during_readiness,
      "workspace changed from #{initial_state.current_branch}@#{initial_state.head_sha} to #{final_state.current_branch}@#{final_state.head_sha} during readiness",
      "Preserve the workspace and inspect the concurrent Git change before retrying."
    )
  end

  defp parse_current_branch(output) do
    case lines(output) do
      [] ->
        failure(
          :detached_head,
          "workspace HEAD is detached",
          "Attach HEAD to the exact issue branch or recreate a clean workspace, then retry."
        )

      [branch] ->
        if GitBranchResolver.valid_branch?(branch) do
          {:ok, branch}
        else
          failure(
            :workspace_branch_invalid,
            "workspace reported invalid branch #{inspect(branch)}",
            "Repair the workspace branch name without resetting work, then retry."
          )
        end

      branches ->
        failure(
          :workspace_branch_ambiguous,
          "workspace reported multiple current branches: #{Enum.join(branches, ", ")}",
          "Repair the workspace symbolic HEAD, then retry."
        )
    end
  end

  defp local_branch?(output, issue_branch) do
    Enum.member?(lines(output), "refs/heads/#{issue_branch}")
  end

  defp one_stacked_evidence([], _issue_branch) do
    failure(
      :stacked_evidence_missing,
      "explicit stacked readiness has no upstream evidence",
      "Provide exactly one typed upstream branch and full head SHA, then retry."
    )
  end

  defp one_stacked_evidence([%StackedBase{} = evidence], issue_branch) do
    with branch when is_binary(branch) <- evidence.branch,
         true <- GitBranchResolver.valid_branch?(branch),
         false <- branch == issue_branch,
         head_sha when is_binary(head_sha) <- evidence.head_sha,
         true <- Regex.match?(@sha_pattern, head_sha) do
      {:ok, %{branch: branch, head_sha: String.downcase(head_sha)}}
    else
      _ ->
        failure(
          :stacked_evidence_invalid,
          "typed stacked evidence must contain a distinct valid branch and one full head SHA",
          "Correct the typed upstream branch and SHA; do not infer them from issue or PR prose."
        )
    end
  end

  defp one_stacked_evidence([_invalid], _issue_branch) do
    failure(
      :stacked_evidence_invalid,
      "explicit stacked readiness evidence has an invalid type",
      "Provide one StackedBase value with an exact branch and head SHA."
    )
  end

  defp one_stacked_evidence(_candidates, _issue_branch) do
    failure(
      :stacked_evidence_ambiguous,
      "explicit stacked readiness has multiple upstream candidates",
      "Choose exactly one typed upstream branch and head SHA, then retry."
    )
  end

  defp lookup_stacked_branch(workspace, evidence, opts) do
    case lookup_branch(workspace, evidence.branch, opts) do
      {:ok, :missing} ->
        failure(
          :stacked_branch_missing,
          "origin does not advertise typed upstream branch #{evidence.branch}",
          "Publish the exact upstream branch or correct the typed evidence, then retry."
        )

      {:ok, %GitReceipt{fetched_sha: fetched_sha} = receipt}
      when fetched_sha == evidence.head_sha ->
        {:ok, receipt}

      {:ok, %GitReceipt{fetched_sha: fetched_sha}} ->
        failure(
          :stacked_head_mismatch,
          "typed upstream #{evidence.branch} expects #{evidence.head_sha}, but origin is #{fetched_sha}",
          "Update the typed evidence to the intended exact upstream head or restore that remote head."
        )

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp create_and_verify_branch(
         workspace,
         issue_branch,
         base_sha,
         classification,
         canonical,
         upstream,
         opts
       ) do
    runner = command_runner(workspace, opts)

    with {:ok, _output} <- run(runner, ["switch", "-c", issue_branch, base_sha]),
         {:ok, final_state} <- inspect_materialized_workspace(runner) do
      verify_created_branch(
        final_state,
        issue_branch,
        base_sha,
        classification,
        canonical,
        upstream
      )
    end
  end

  defp inspect_materialized_workspace(runner) do
    with {:ok, state} <- reread_branch_and_head(runner),
         {:ok, status} <- run(runner, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      normalized_status = String.trim(status)

      {:ok,
       Map.merge(state, %{
         dirty: normalized_status != "",
         status: sanitize(normalized_status)
       })}
    end
  end

  defp verify_created_branch(
         %{current_branch: actual_branch},
         issue_branch,
         _base_sha,
         _classification,
         _canonical,
         _upstream
       )
       when actual_branch != issue_branch do
    failure(
      :created_branch_mismatch,
      "created branch re-read as #{actual_branch}, expected #{issue_branch}",
      "Preserve the workspace and inspect the concurrent Git change before retrying."
    )
  end

  defp verify_created_branch(
         %{head_sha: actual_sha},
         _issue_branch,
         base_sha,
         _classification,
         _canonical,
         _upstream
       )
       when actual_sha != base_sha do
    failure(
      :created_branch_head_mismatch,
      "created branch re-read at #{actual_sha}, expected #{base_sha}",
      "Preserve the workspace and inspect the concurrent Git change before retrying."
    )
  end

  defp verify_created_branch(
         %{dirty: true, status: status},
         _issue_branch,
         _base_sha,
         _classification,
         _canonical,
         _upstream
       ) do
    failure(
      :workspace_changed_during_readiness,
      "materialized issue branch became dirty during readiness: #{status}",
      "Preserve the workspace changes and inspect the concurrent writer before retrying."
    )
  end

  defp verify_created_branch(
         %{head_sha: actual_sha},
         issue_branch,
         _base_sha,
         classification,
         canonical,
         upstream
       ) do
    ready(classification, issue_branch, actual_sha, canonical, upstream)
  end

  defp resolve_canonical(workspace, opts) do
    case GitBranchResolver.resolve(workspace, resolver_opts(opts)) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, resolver_failure} -> from_resolver_failure(resolver_failure)
    end
  end

  defp lookup_branch(workspace, branch, opts) do
    case GitBranchResolver.lookup_branch(workspace, branch, resolver_opts(opts)) do
      {:ok, result} -> {:ok, result}
      {:error, resolver_failure} -> from_resolver_failure(resolver_failure)
    end
  end

  defp from_resolver_failure(%GitBranchResolver.Failure{} = resolver_failure) do
    {:error,
     %Failure{
       code: resolver_failure.code,
       command: resolver_failure.command,
       detail: resolver_failure.detail,
       operator_action: resolver_failure.operator_action
     }}
  end

  defp workspace_created_now(opts) do
    case Keyword.fetch(opts, :workspace_created_now) do
      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      _ ->
        failure(
          :workspace_provenance_missing,
          "readiness requires created_now evidence from Workspace",
          "Retry through AgentRunner so workspace creation/reuse provenance is supplied."
        )
    end
  end

  defp issue_branch(%Issue{branch_name: branch}) when is_binary(branch) do
    normalized = String.trim(branch)

    if normalized == branch and GitBranchResolver.valid_branch?(normalized) do
      {:ok, normalized}
    else
      invalid_issue_branch(branch)
    end
  end

  defp issue_branch(%Issue{branch_name: branch}), do: invalid_issue_branch(branch)

  defp invalid_issue_branch(branch) do
    failure(
      :issue_branch_missing_or_invalid,
      "issue branch evidence is missing or invalid: #{inspect(branch)}",
      "Set one exact typed tracker branch name before dispatch."
    )
  end

  defp command_runner(workspace, opts) do
    case Keyword.get(opts, :command_runner) do
      runner when is_function(runner, 1) -> runner
      nil -> fn args -> Workspace.run_git_command(workspace, args, Keyword.get(opts, :worker_host)) end
    end
  end

  defp resolver_opts(opts) do
    opts
    |> Keyword.take([:command_runner, :worker_host])
  end

  defp run(runner, args) do
    command = Enum.join(["git" | args], " ")

    call_runner(runner, args, command, &normalize_run_result(&1, command))
  end

  defp call_runner(runner, args, command, result_handler) do
    runner.(args)
    |> result_handler.()
  rescue
    error ->
      failure(
        :command_failed,
        Exception.message(error),
        "Verify the readiness Git command runner, then retry.",
        command
      )
  catch
    kind, reason ->
      failure(
        :command_failed,
        inspect({kind, reason}),
        "Verify the readiness Git command runner, then retry.",
        command
      )
  end

  defp normalize_run_result(result, command) do
    case result do
      {:ok, output} when is_binary(output) ->
        {:ok, output}

      {:error, {:workspace_hook_timeout, _timed_command, timeout_ms}} ->
        failure(
          :command_timeout,
          "#{command} timed out after #{timeout_ms}ms",
          "Verify the worker and Git command responsiveness, then retry.",
          command
        )

      {:error, {:git_command_failed, failed_command, status, output}} ->
        failure(
          :command_failed,
          "status=#{status} output=#{sanitize(output)}",
          "Inspect the Git error without changing existing branches, then retry.",
          failed_command
        )

      {:error, {:git_command_failed, failed_command, detail}} ->
        failure(
          :command_failed,
          sanitize(detail),
          "Inspect the Git error without changing existing branches, then retry.",
          failed_command
        )

      other ->
        failure(
          :command_failed,
          "unexpected command result: #{inspect(other)}",
          "Verify the readiness Git command runner, then retry.",
          command
        )
    end
  end

  defp parse_sha(output, error_code) do
    case lines(output) do
      [sha] when is_binary(sha) ->
        if Regex.match?(@sha_pattern, sha) do
          {:ok, String.downcase(sha)}
        else
          invalid_workspace_sha(error_code, sha)
        end

      values ->
        invalid_workspace_sha(error_code, Enum.join(values, ", "))
    end
  end

  defp invalid_workspace_sha(error_code, value) do
    failure(
      error_code,
      "workspace did not report one full commit SHA: #{sanitize(value)}",
      "Preserve the workspace and repair its Git HEAD manually before retrying."
    )
  end

  defp ready(classification, issue_branch, head_sha, canonical, upstream \\ nil) do
    {:ok,
     %Receipt{
       classification: classification,
       issue_branch: issue_branch,
       head_sha: head_sha,
       canonical: canonical,
       upstream: upstream
     }}
  end

  defp failure(code, detail, operator_action, command \\ nil) do
    {:error,
     %Failure{
       code: code,
       command: command,
       detail: sanitize(detail),
       operator_action: operator_action
     }}
  end

  defp lines(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sanitize(value) when is_binary(value), do: Workspace.sanitize_command_output(value)
  defp sanitize(value), do: value |> inspect() |> Workspace.sanitize_command_output()
end
