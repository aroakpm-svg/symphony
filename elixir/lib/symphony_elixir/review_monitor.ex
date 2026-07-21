defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc "Poll-cycle integration for latest-head review convergence."

  require Logger

  alias SymphonyElixir.{Config, GitHubReviewClient, ReviewConvergence, Tracker}
  alias SymphonyElixir.Linear.Issue

  @type state :: %{optional(String.t()) => map()}

  @spec run(state()) :: state()
  def run(state) when is_map(state) do
    settings = Config.settings!().review_convergence

    if settings.enabled do
      run_with(state, settings, GitHubReviewClient, Tracker)
    else
      state
    end
  end

  @doc false
  @spec run_with(state(), struct() | map(), module(), module()) :: state()
  def run_with(state, settings, review_client, tracker) do
    case tracker.fetch_issues_by_states([settings.review_state]) do
      {:ok, issues} ->
        Enum.reduce(issues, state, &reconcile_issue(&1, &2, settings, review_client, tracker))

      {:error, reason} ->
        Logger.warning("Review monitor failed to fetch review-state issues: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_issue(%Issue{} = issue, state, settings, review_client, tracker) do
    entry =
      Map.get(state, issue.id, %{
        dedup: MapSet.new(),
        fix_rounds: 0,
        head_sha: nil,
        review_requested: false,
        waiting: false,
        last_finding_fingerprint: nil
      })

    with branch when is_binary(branch) and branch != "" <- issue.branch_name,
         {:ok, snapshot} <- review_client.snapshot(settings.repository, branch) do
      entry = invalidate_old_head(entry, snapshot.current_head_sha)
      decision = ReviewConvergence.evaluate(snapshot, entry.fix_rounds, settings.max_fix_rounds)
      {updated_entry, _outcome} = apply_decision(decision, issue, entry, settings, review_client, tracker, snapshot)
      Map.put(state, issue.id, updated_entry)
    else
      nil -> wait_for_human(issue, entry, settings, tracker, :missing_branch_name, nil, state)
      "" -> wait_for_human(issue, entry, settings, tracker, :missing_branch_name, nil, state)
      {:error, reason} -> wait_for_human(issue, entry, settings, tracker, inspect(reason), nil, state)
    end
  end

  defp reconcile_issue(_issue, state, _settings, _review_client, _tracker), do: state

  defp invalidate_old_head(%{head_sha: head_sha} = entry, current_head) when head_sha != current_head do
    %{entry | head_sha: current_head, review_requested: false, waiting: false}
  end

  defp invalidate_old_head(entry, current_head), do: Map.put(entry, :head_sha, current_head)

  defp apply_decision({:request_review, _evidence}, issue, entry, settings, review_client, _tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:review_request, issue.id, snapshot.current_head_sha, :codex)

    dedup_action(entry, key, fn ->
      with {:ok, requested?} <-
             review_client.review_request_exists?(settings.repository, snapshot.pull_request_number, key) do
        if requested? do
          :ok
        else
          status_then(review_client, settings.repository, snapshot, :pending, "Waiting for a formal latest-head review", fn ->
            review_client.request_review(settings.repository, snapshot.pull_request_number, key)
          end)
        end
      end
    end)
    |> then(fn {updated, result} -> {%{updated | review_requested: result == :ok}, result} end)
  end

  defp apply_decision({:rework, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    findings = evidence.actionable_threads
    fingerprint = finding_fingerprint(findings)
    key = ReviewConvergence.dedup_key(:rework, issue.id, snapshot.current_head_sha, fingerprint)

    dedup_action(entry, key, fn ->
      case publish_status(review_client, settings.repository, snapshot, :failure, "Unresolved actionable P1-P4 review findings") do
        :ok -> write_rework(tracker, issue, settings, snapshot, findings, key)
        {:error, reason} -> {:error, reason}
      end
    end)
    |> then(fn {updated, result} ->
      rounds = if(result == :ok, do: entry.fix_rounds + 1, else: entry.fix_rounds)
      {%{updated | fix_rounds: rounds, last_finding_fingerprint: fingerprint}, result}
    end)
  end

  defp apply_decision({:wait, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    reason = evidence[:reason] || :external_or_human_validation
    key = ReviewConvergence.dedup_key(:wait, issue.id, snapshot.current_head_sha, reason)

    dedup_action(entry, key, fn ->
      status_then(review_client, settings.repository, snapshot, :pending, "Waiting for required evidence or human judgment", fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key))
      end)
    end)
    |> then(fn {updated, result} -> {%{updated | waiting: result == :ok}, result} end)
  end

  defp apply_decision({:escalate, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:escalate, issue.id, snapshot.current_head_sha, evidence[:reason])

    dedup_action(entry, key, fn ->
      status_then(review_client, settings.repository, snapshot, :failure, "Review did not converge; human decision required", fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, :review_not_converging, key))
      end)
    end)
    |> then(fn {updated, result} -> {%{updated | waiting: result == :ok}, result} end)
  end

  defp apply_decision({:converged, _evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:converged, issue.id, snapshot.current_head_sha, :technical)

    dedup_action(entry, key, fn ->
      status_then(review_client, settings.repository, snapshot, :success, "Latest head technically converged; human merge required", fn ->
        tracker.create_comment(issue.id, converged_comment(snapshot, key))
      end)
    end)
  end

  defp dedup_action(entry, key, action) do
    if MapSet.member?(entry.dedup, key) do
      {entry, :deduplicated}
    else
      case action.() do
        :ok -> {%{entry | dedup: MapSet.put(entry.dedup, key)}, :ok}
        {:error, reason} -> {entry, {:error, reason}}
      end
    end
  end

  defp wait_for_human(issue, entry, settings, tracker, reason, head_sha, state) do
    snapshot = %{current_head_sha: head_sha, pull_request_number: nil, required_checks: [], threads: []}
    key = ReviewConvergence.dedup_key(:wait, issue.id, head_sha, reason)
    {updated, _result} = dedup_action(entry, key, fn -> tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key)) end)
    Map.put(state, issue.id, %{updated | waiting: true})
  end

  defp finding_fingerprint(findings) do
    Enum.map(findings, &{&1[:priority], &1[:path], &1[:body]})
  end

  defp write_rework(tracker, issue, settings, snapshot, findings, key) do
    case tracker.create_comment(issue.id, rework_comment(snapshot, findings, key)) do
      :ok -> tracker.update_issue_state(issue.id, settings.in_progress_state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_status(_review_client, _repository, %{current_head_sha: head}, _state, _description)
       when head in [nil, ""],
       do: :ok

  defp publish_status(review_client, repository, snapshot, state, description) do
    review_client.publish_status(repository, snapshot.current_head_sha, state, description, nil)
  end

  defp status_then(review_client, repository, snapshot, state, description, next) do
    case publish_status(review_client, repository, snapshot, state, description) do
      :ok -> next.()
      {:error, reason} -> {:error, reason}
    end
  end

  defp rework_comment(snapshot, findings, key) do
    details = Enum.map_join(findings, "\n", fn finding -> "- P#{finding.priority}: #{finding.url || finding.path || finding.body}" end)

    """
    Review Convergence Gate found actionable latest-head findings.

    - PR: ##{snapshot.pull_request_number}
    - currentHeadSha: `#{snapshot.current_head_sha}`
    #{details}

    Symphony should reuse the same branch/PR and fix only these scoped findings.
    dedup-key: `#{key}`
    """
  end

  defp human_comment(settings, snapshot, reason, key) do
    owner = settings.human_owner || "team owner"

    """
    Review Convergence Gate is waiting for team human judgment (owner: #{owner}).

    - Decision: `#{reason}`
    - Option A: provide the missing evidence/approval and keep this head.
    - Option B: revise the scope or implementation, accepting another full latest-head review.
    - Impact/risk: Symphony retry is paused; technical convergence is not claimed.
    - PR/head: ##{snapshot.pull_request_number || "unknown"} / `#{snapshot.current_head_sha || "unknown"}`

    The issue remains In Review. No merge, deployment, production, permission, or secret action is authorized.
    dedup-key: `#{key}`
    """
  end

  defp converged_comment(snapshot, key) do
    """
    Review Convergence Gate reports technical convergence for PR ##{snapshot.pull_request_number}.

    - currentHeadSha = reviewedHeadSha = `#{snapshot.current_head_sha}`
    - review: `No major issues found`
    - required checks: passed
    - unresolved actionable P1-P4 threads: 0

    This is ready for human merge review; it is not merge authorization.
    dedup-key: `#{key}`
    """
  end
end
