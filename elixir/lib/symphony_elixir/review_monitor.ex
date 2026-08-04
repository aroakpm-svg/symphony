defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc "Poll-cycle integration for latest-head review convergence."

  require Logger

  alias SymphonyElixir.{Config, FindingRouter, GitHubReviewClient, ReviewConvergence, Tracker}
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
    monitored_states = [settings.review_state, settings.in_progress_state] |> Enum.uniq()

    case tracker.fetch_routed_issues_by_states(monitored_states) do
      {:ok, issues} ->
        routed_issues =
          Enum.filter(issues, &Issue.routable?(&1, Config.settings!().tracker.required_labels))

        active_issue_ids = MapSet.new(routed_issues, & &1.id)
        active_state = Map.take(state, MapSet.to_list(active_issue_ids))

        Enum.reduce(routed_issues, active_state, &reconcile_issue(&1, &2, settings, review_client, tracker))

      {:error, reason} ->
        Logger.warning("Review monitor failed to fetch review-state issues: #{inspect(reason)}")
        clear_known_successes(state, settings, review_client)
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
        fetch_failed: false,
        last_finding_fingerprint: nil
      })

    entry = Map.put(entry, :fetch_failed, false)

    case tracker.review_history(issue.id) do
      {:ok, history} ->
        entry = %{
          entry
          | dedup: MapSet.union(entry.dedup, history.dedup),
            fix_rounds: max(entry.fix_rounds, history.rework_count),
            head_sha: entry.head_sha || history[:last_head_sha]
        }

        pending_transitions = history[:pending_transitions] || %{}
        entry = Map.put(entry, :pending_transitions, pending_transitions)

        cond do
          map_size(pending_transitions) > 0 ->
            recover_pending_transitions(
              issue,
              entry,
              state,
              settings,
              tracker,
              pending_transitions
            )

          issue.state == settings.review_state ->
            reconcile_snapshot(issue, entry, state, settings, review_client, tracker)

          true ->
            Map.delete(state, issue.id)
        end

      {:error, reason} ->
        handle_history_error(issue, entry, state, settings, review_client, tracker, reason)
    end
  end

  defp reconcile_issue(_issue, state, _settings, _review_client, _tracker), do: state

  defp handle_history_error(issue, entry, state, settings, review_client, tracker, reason) do
    pending? = map_size(entry[:pending_transitions] || %{}) > 0

    if issue.state == settings.review_state or pending? do
      wait_for_history_error(issue, entry, state, settings, review_client, tracker, reason)
    else
      Map.delete(state, issue.id)
    end
  end

  defp clear_known_successes(state, settings, review_client) do
    Map.new(state, fn {issue_id, entry} ->
      {issue_id, clear_known_success(entry, settings, review_client)}
    end)
  end

  defp clear_known_success(%{fetch_failed: true} = entry, _settings, _review_client), do: entry

  defp clear_known_success(%{head_sha: head_sha} = entry, settings, review_client)
       when is_binary(head_sha) and head_sha != "" do
    snapshot = %{current_head_sha: head_sha}

    case publish_status(
           review_client,
           settings.repository,
           snapshot,
           :error,
           "Review issue evidence unavailable; human judgment required"
         ) do
      :ok ->
        entry
        |> Map.put(:fetch_failed, true)
        |> mark_published_status(snapshot, :error)

      {:error, _reason} ->
        entry
    end
  end

  defp clear_known_success(entry, _settings, _review_client), do: entry

  defp reconcile_snapshot(issue, entry, state, settings, review_client, tracker) do
    with branch when is_binary(branch) and branch != "" <- issue.branch_name,
         {:ok, snapshot} <- review_client.snapshot(settings.repository, branch) do
      entry = invalidate_old_head(entry, snapshot.current_head_sha)

      case finding_router_plan(settings, review_client, snapshot, issue) do
        {:ok, :legacy} ->
          apply_legacy_decision(issue, entry, state, settings, review_client, tracker, snapshot)

        {:ok, {:shadow, plan}} ->
          Logger.info("Finding Router shadow decision for issue_id=#{issue.id} issue_identifier=#{issue.identifier} PR ##{snapshot.pull_request_number}: #{inspect(plan)}")

          apply_legacy_decision(issue, entry, state, settings, review_client, tracker, snapshot)

        {:ok, {:enforce, plan, receipt}} ->
          context = %{
            issue: issue,
            entry: entry,
            state: state,
            settings: settings,
            review_client: review_client,
            tracker: tracker,
            snapshot: snapshot
          }

          apply_finding_router_plan(plan, receipt, context)

        {:error, reason} ->
          wait_for_human(issue, entry, settings, review_client, tracker, reason, state)
      end
    else
      nil -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      "" -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      {:error, reason} -> wait_for_human(issue, entry, settings, review_client, tracker, inspect(reason), state)
    end
  end

  defp apply_legacy_decision(issue, entry, state, settings, review_client, tracker, snapshot) do
    decision = ReviewConvergence.evaluate(snapshot, entry.fix_rounds, settings.max_fix_rounds)
    {updated_entry, _outcome} = apply_decision(decision, issue, entry, settings, review_client, tracker, snapshot)
    Map.put(state, issue.id, updated_entry)
  end

  defp finding_router_plan(settings, review_client, snapshot, issue) do
    case Map.get(settings, :finding_router_mode, "disabled") do
      "disabled" ->
        {:ok, :legacy}

      "shadow" ->
        shadow_finding_router_plan(settings, review_client, snapshot, issue)

      "enforce" ->
        enforce_finding_router_plan(settings, review_client, snapshot)
    end
  end

  defp shadow_finding_router_plan(settings, review_client, snapshot, issue) do
    case review_client.finding_router_receipt(settings.repository, snapshot) do
      {:ok, receipt} ->
        {:ok, {:shadow, route_receipt(receipt, snapshot)}}

      {:error, reason} ->
        Logger.warning("Finding Router shadow evidence unavailable for issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        {:ok, {:shadow, {:hold, :finding_router_evidence_unavailable}}}
    end
  end

  defp enforce_finding_router_plan(settings, review_client, snapshot) do
    case review_client.finding_router_receipt(settings.repository, snapshot) do
      {:ok, receipt} -> {:ok, {:enforce, route_receipt(receipt, snapshot), receipt}}
      {:error, reason} -> {:error, {:finding_router_evidence_unavailable, reason}}
    end
  end

  defp route_receipt(receipt, snapshot) do
    FindingRouter.plan(receipt, snapshot[:threads] || [], snapshot[:issue_comments] || [])
  end

  defp apply_finding_router_plan({:hold, reason}, _receipt, context) do
    {updated, _outcome} =
      apply_decision(
        {:wait, %{reason: reason}},
        context.issue,
        context.entry,
        context.settings,
        context.review_client,
        context.tracker,
        context.snapshot
      )

    Map.put(context.state, context.issue.id, updated)
  end

  defp apply_finding_router_plan({:rework, findings}, receipt, context) do
    case verify_current_router_rework(receipt, findings, context) do
      {:ok, fresh_findings, fresh_snapshot} ->
        apply_verified_router_rework(
          fresh_findings,
          %{context | snapshot: fresh_snapshot}
        )

      {:error, reason} ->
        wait_for_human(
          context.issue,
          context.entry,
          context.settings,
          context.review_client,
          context.tracker,
          reason,
          context.state
        )
    end
  end

  defp apply_finding_router_plan({:settle, actions}, receipt, context) do
    description = "Finding routing actions pending; waiting for fresh evidence"

    case publish_status(
           context.review_client,
           context.settings.repository,
           context.snapshot,
           :pending,
           description
         ) do
      :ok ->
        updated_entry = mark_published_status(context.entry, context.snapshot, :pending)

        case execute_router_actions(
               actions,
               receipt,
               context.settings,
               context.review_client,
               context.snapshot
             ) do
          :ok ->
            Map.put(context.state, context.issue.id, %{updated_entry | waiting: true})

          {:error, reason} ->
            wait_for_human(
              context.issue,
              updated_entry,
              context.settings,
              context.review_client,
              context.tracker,
              reason,
              context.state
            )
        end

      {:error, reason} ->
        wait_for_human(
          context.issue,
          context.entry,
          context.settings,
          context.review_client,
          context.tracker,
          {:finding_router_pending_status_failed, reason},
          context.state
        )
    end
  end

  defp apply_finding_router_plan(:pass, _receipt, context) do
    apply_legacy_decision(
      context.issue,
      context.entry,
      context.state,
      context.settings,
      context.review_client,
      context.tracker,
      context.snapshot
    )
  end

  defp apply_verified_router_rework(findings, context) do
    decision =
      if ReviewConvergence.escalation_required?(
           context.snapshot,
           context.entry.fix_rounds,
           context.settings.max_fix_rounds
         ) do
        {:escalate, %{reason: :review_not_converging, actionable_threads: findings}}
      else
        {:rework, %{actionable_threads: findings}}
      end

    {updated, _outcome} =
      apply_decision(
        decision,
        context.issue,
        context.entry,
        context.settings,
        context.review_client,
        context.tracker,
        context.snapshot
      )

    Map.put(context.state, context.issue.id, updated)
  end

  defp execute_router_actions(actions, receipt, settings, review_client, snapshot) do
    Enum.reduce_while(actions, :ok, fn
      {:comment_then_resolve, disposition}, :ok ->
        body =
          FindingRouter.follow_up_comment(
            disposition,
            receipt["headSha"],
            receipt["receiptDigest"]
          )

        with :ok <-
               verify_current_settlement_receipt(
                 review_client,
                 settings.repository,
                 snapshot.pull_request_number,
                 receipt,
                 snapshot
               ),
             :ok <-
               review_client.verify_review_thread_binding(
                 settings.repository,
                 disposition["findingId"],
                 disposition["findingCommentId"],
                 disposition["findingCommentDigest"]
               ),
             :ok <-
               review_client.create_follow_up_comment(
                 settings.repository,
                 snapshot.pull_request_number,
                 body
               ),
             :ok <-
               verify_current_settlement_receipt(
                 review_client,
                 settings.repository,
                 snapshot.pull_request_number,
                 receipt,
                 snapshot
               ),
             :ok <-
               review_client.resolve_review_thread(
                 settings.repository,
                 disposition["findingId"],
                 disposition["findingCommentId"],
                 disposition["findingCommentDigest"]
               ) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:resolve, disposition}, :ok ->
        with :ok <-
               verify_current_settlement_receipt(
                 review_client,
                 settings.repository,
                 snapshot.pull_request_number,
                 receipt,
                 snapshot
               ),
             :ok <-
               review_client.resolve_review_thread(
                 settings.repository,
                 disposition["findingId"],
                 disposition["findingCommentId"],
                 disposition["findingCommentDigest"]
               ) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp verify_settlement_identity(review_client, repository, number, receipt) do
    expected = %{base_sha: receipt["baseSha"], head_sha: receipt["headSha"]}

    case review_client.current_pull_request_identity(repository, number) do
      {:ok, ^expected} -> :ok
      {:ok, _changed_identity} -> {:error, :finding_router_pr_changed_before_settlement}
      {:error, reason} -> {:error, {:finding_router_pr_unverified_before_settlement, reason}}
    end
  end

  defp verify_current_settlement_receipt(review_client, repository, number, receipt, snapshot) do
    with {:ok, current} <- review_client.finding_router_receipt(repository, snapshot),
         true <- routing_receipt_identity(current) == routing_receipt_identity(receipt),
         :ok <- verify_settlement_identity(review_client, repository, number, receipt) do
      :ok
    else
      false -> {:error, :finding_router_receipt_changed_before_settlement}
      {:error, _reason} -> {:error, :finding_router_receipt_unverified_before_settlement}
    end
  end

  defp verify_current_router_rework(receipt, findings, context) do
    with {:ok, fresh_snapshot} <-
           context.review_client.snapshot(
             context.settings.repository,
             context.issue.branch_name
           ),
         {:ok, current} <-
           context.review_client.finding_router_receipt(
             context.settings.repository,
             fresh_snapshot
           ),
         true <- routing_receipt_identity(current) == routing_receipt_identity(receipt),
         :ok <-
           verify_settlement_identity(
             context.review_client,
             context.settings.repository,
             fresh_snapshot.pull_request_number,
             receipt
           ),
         {:rework, fresh_findings} <- route_receipt(current, fresh_snapshot),
         :ok <- verify_current_rework_bindings(findings, fresh_findings) do
      {:ok, fresh_findings, fresh_snapshot}
    else
      false ->
        {:error, :finding_router_receipt_changed_before_rework}

      {:hold, reason} ->
        {:error, {:finding_router_rework_plan_changed, reason}}

      {:settle, _actions} ->
        {:error, :finding_router_rework_plan_changed}

      :pass ->
        {:error, :finding_router_rework_plan_changed}

      {:error, :finding_router_rework_binding_changed} ->
        {:error, :finding_router_rework_binding_changed}

      {:error, reason} ->
        {:error, {:finding_router_receipt_unverified_before_rework, reason}}
    end
  end

  defp verify_current_rework_bindings(expected, current)
       when is_list(expected) and is_list(current) do
    bindings = fn findings ->
      Enum.map(findings, fn finding ->
        {
          finding[:finding_id],
          finding[:finding_comment_id],
          finding[:finding_comment_digest],
          finding[:router_action]
        }
      end)
    end

    if Enum.all?(current, &(&1[:resolved] == false)) and
         bindings.(current) == bindings.(expected) do
      :ok
    else
      {:error, :finding_router_rework_binding_changed}
    end
  end

  defp verify_current_rework_bindings(_expected, _current),
    do: {:error, :finding_router_rework_binding_changed}

  defp routing_receipt_identity(receipt) do
    Map.take(receipt, [
      "schemaVersion",
      "repository",
      "pullRequestNumber",
      "baseSha",
      "headSha",
      "receiptDigest"
    ])
  end

  defp wait_for_history_error(issue, entry, state, settings, review_client, tracker, reason) do
    entry =
      case issue.branch_name do
        branch when is_binary(branch) and branch != "" ->
          case review_client.snapshot(settings.repository, branch) do
            {:ok, snapshot} -> invalidate_old_head(entry, snapshot.current_head_sha)
            {:error, _snapshot_reason} -> entry
          end

        _missing_branch ->
          entry
      end

    wait_for_human(issue, entry, settings, review_client, tracker, inspect(reason), state)
  end

  defp invalidate_old_head(%{head_sha: head_sha} = entry, current_head) when head_sha != current_head do
    %{entry | head_sha: current_head, review_requested: false, waiting: false}
  end

  defp invalidate_old_head(entry, current_head), do: Map.put(entry, :head_sha, current_head)

  defp apply_decision({:request_review, _evidence}, issue, entry, settings, review_client, _tracker, snapshot) do
    digest = ReviewConvergence.dedup_key(:review_request, issue.id, snapshot.current_head_sha, :codex)
    key = "review-request:#{issue.id}:#{snapshot.current_head_sha}:#{digest}"

    with {entry, :ok} <-
           ensure_published_status(
             entry,
             review_client,
             settings.repository,
             snapshot,
             :pending,
             "Waiting for a formal latest-head review"
           ) do
      dedup_action(entry, key, fn ->
        ensure_review_requested(review_client, settings.repository, snapshot, key)
      end)
    end
    |> then(fn {updated, result} -> {%{updated | review_requested: result == :ok}, result} end)
  end

  defp apply_decision({:rework, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    findings = evidence.actionable_threads
    fingerprint = finding_fingerprint(findings)
    key = ReviewConvergence.dedup_key(:rework, issue.id, snapshot.current_head_sha, fingerprint)

    case ensure_published_status(
           entry,
           review_client,
           settings.repository,
           snapshot,
           :failure,
           "Unresolved actionable P1-P4 review findings"
         ) do
      {entry, :ok} ->
        apply_rework(issue, entry, settings, tracker, snapshot, findings, fingerprint, key)

      {entry, {:error, reason}} ->
        {entry, {:error, reason}}
    end
  end

  defp apply_decision({:wait, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    reason = evidence[:reason] || :external_or_human_validation
    key = ReviewConvergence.dedup_key(:wait, issue.id, snapshot.current_head_sha, reason)

    with {entry, :ok} <-
           ensure_published_status(
             entry,
             review_client,
             settings.repository,
             snapshot,
             :pending,
             "Waiting for required evidence or human judgment"
           ) do
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key))
      end)
    end
    |> then(fn {updated, result} ->
      {%{updated | waiting: result == :ok}, result}
    end)
  end

  defp apply_decision({:escalate, evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:escalate, issue.id, snapshot.current_head_sha, evidence[:reason])

    with {entry, :ok} <-
           ensure_published_status(
             entry,
             review_client,
             settings.repository,
             snapshot,
             :failure,
             "Review did not converge; human decision required"
           ) do
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, human_comment(settings, snapshot, :review_not_converging, key))
      end)
    end
    |> then(fn {updated, result} ->
      {%{updated | waiting: result == :ok}, result}
    end)
  end

  defp apply_decision({:converged, _evidence}, issue, entry, settings, review_client, tracker, snapshot) do
    key = ReviewConvergence.dedup_key(:converged, issue.id, snapshot.current_head_sha, :technical)

    status_result =
      if entry[:last_published_status] == {snapshot.current_head_sha, :success} do
        :ok
      else
        publish_status(
          review_client,
          settings.repository,
          snapshot,
          :success,
          "Latest head technically converged; human merge required"
        )
      end

    case status_result do
      :ok ->
        entry
        |> mark_published_status(snapshot, :success)
        |> dedup_action(key, fn -> tracker.create_comment(issue.id, converged_comment(snapshot, key)) end)

      {:error, reason} ->
        {entry, {:error, reason}}
    end
  end

  defp ensure_review_requested(review_client, repository, snapshot, key) do
    case review_client.review_request_exists?(repository, snapshot.pull_request_number, key) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        review_client.request_review(repository, snapshot.pull_request_number, key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_rework(issue, entry, settings, tracker, snapshot, findings, fingerprint, key) do
    {updated, comment_result} =
      dedup_action(entry, key, fn ->
        tracker.create_comment(issue.id, rework_comment(snapshot, findings, key))
      end)

    transition_key =
      ReviewConvergence.dedup_key(:state_transition, issue.id, snapshot.current_head_sha, fingerprint)

    {updated, result, moved?} =
      cond do
        comment_result not in [:ok, :deduplicated] ->
          {updated, comment_result, false}

        MapSet.member?(updated.dedup, transition_key) ->
          {updated, :deduplicated, false}

        true ->
          transition_to_rework(issue, updated, settings, tracker, snapshot, transition_key)
      end

    rounds = if(moved?, do: entry.fix_rounds + 1, else: entry.fix_rounds)
    {%{updated | fix_rounds: rounds, last_finding_fingerprint: fingerprint}, result}
  end

  defp transition_to_rework(issue, entry, settings, tracker, snapshot, transition_key) do
    intent_key = "transition-intent:#{transition_key}"

    {entry, intent_result} =
      dedup_action(entry, intent_key, fn ->
        tracker.create_comment(
          issue.id,
          transition_intent_comment(snapshot, settings.in_progress_state, transition_key, intent_key)
        )
      end)

    if intent_result in [:ok, :deduplicated] do
      move_and_complete_transition(
        issue,
        entry,
        tracker,
        snapshot,
        transition_key,
        settings.in_progress_state
      )
    else
      {entry, intent_result, false}
    end
  end

  defp recover_pending_transitions(issue, entry, state, settings, tracker, pending_transitions) do
    {entry, completed_count, remaining} =
      Enum.reduce(pending_transitions, {entry, 0, %{}}, fn {operation_id, intent}, {current, count, remaining} ->
        {updated, _outcome, completed?} =
          recover_pending_transition(issue, current, settings, tracker, operation_id, intent)

        if completed? do
          {updated, count + 1, remaining}
        else
          {updated, count, Map.put(remaining, operation_id, intent)}
        end
      end)

    entry =
      entry
      |> Map.put(:fix_rounds, entry.fix_rounds + completed_count)
      |> Map.put(:pending_transitions, remaining)

    Map.put(state, issue.id, entry)
  end

  defp recover_pending_transition(issue, entry, settings, tracker, operation_id, intent) do
    snapshot = %{current_head_sha: intent.head_sha}
    target_state = intent.target_state || settings.in_progress_state

    if issue.state == target_state do
      complete_transition(issue, entry, tracker, snapshot, operation_id)
    else
      move_and_complete_transition(issue, entry, tracker, snapshot, operation_id, target_state)
    end
  end

  defp move_and_complete_transition(issue, entry, tracker, snapshot, operation_id, target_state) do
    with :ok <- tracker.update_issue_state(issue.id, target_state),
         :ok <- verify_issue_state(tracker, issue.id, target_state) do
      complete_transition(issue, entry, tracker, snapshot, operation_id)
    else
      {:error, reason} -> {entry, {:error, reason}, false}
    end
  end

  defp verify_issue_state(tracker, issue_id, target_state) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{id: ^issue_id, state: ^target_state}]} -> :ok
      {:ok, issues} -> {:error, {:state_transition_unverified, target_state, issues}}
      {:error, reason} -> {:error, {:state_transition_verification_failed, reason}}
    end
  end

  defp complete_transition(issue, entry, tracker, snapshot, operation_id) do
    {persisted, result} =
      dedup_action(entry, operation_id, fn ->
        tracker.create_comment(issue.id, state_transition_comment(snapshot, operation_id))
      end)

    # A deduplicated completion is already represented by this entry's durable
    # history. Only a completion newly persisted in this pass consumes a round.
    {persisted, result, result == :ok}
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

  defp wait_for_human(issue, entry, settings, review_client, tracker, reason, state) do
    head_sha = entry.head_sha
    snapshot = %{current_head_sha: head_sha, pull_request_number: nil, required_checks: [], threads: []}
    key = ReviewConvergence.dedup_key(:wait, issue.id, head_sha, reason)

    {entry, status_result} =
      ensure_published_status(
        entry,
        review_client,
        settings.repository,
        snapshot,
        :error,
        "Review evidence unavailable; human judgment required"
      )

    {updated, _result} =
      if status_result == :ok do
        dedup_action(entry, key, fn ->
          tracker.create_comment(issue.id, human_comment(settings, snapshot, reason, key))
        end)
      else
        {entry, status_result}
      end

    Map.put(state, issue.id, %{updated | waiting: true})
  end

  defp finding_fingerprint(findings) do
    findings
    |> Enum.map(fn finding ->
      case finding[:router_action] do
        nil ->
          {finding[:priority], finding[:path], finding[:body]}

        action ->
          {
            finding[:finding_id],
            finding[:finding_comment_id],
            finding[:priority],
            finding[:path],
            finding[:body],
            action
          }
      end
    end)
    |> Enum.sort()
  end

  defp publish_status(_review_client, _repository, %{current_head_sha: head}, _state, _description)
       when head in [nil, ""],
       do: :ok

  defp publish_status(review_client, repository, snapshot, state, description) do
    review_client.publish_status(repository, snapshot.current_head_sha, state, description, nil)
  end

  defp mark_published_status(entry, snapshot, state) do
    Map.put(entry, :last_published_status, {snapshot.current_head_sha, state})
  end

  defp ensure_published_status(entry, review_client, repository, snapshot, state, description) do
    if entry[:last_published_status] == {snapshot.current_head_sha, state} do
      {entry, :ok}
    else
      case publish_status(review_client, repository, snapshot, state, description) do
        :ok -> {mark_published_status(entry, snapshot, state), :ok}
        {:error, reason} -> {entry, {:error, reason}}
      end
    end
  end

  defp rework_comment(snapshot, findings, key) do
    routed? = Enum.any?(findings, &(&1[:router_action] != nil))
    details = Enum.map_join(findings, "\n", &rework_detail/1)
    instruction = rework_instruction(routed?)

    """
    Review Convergence Gate found actionable latest-head findings.

    - PR: ##{snapshot.pull_request_number}
    - currentHeadSha: `#{snapshot.current_head_sha}`
    #{details}

    #{instruction}
    dedup-key: `#{key}`
    """
  end

  defp rework_detail(finding) do
    summary = "- P#{finding.priority}: #{finding.url || finding.path || finding.body}"

    case finding[:router_action] do
      :remove_out_of_scope_change ->
        "#{summary}\n  - 移除越界實作；不要擴大本票範圍。原 thread 會等 exact-head 移除證明後再 Resolve。"

      :fix_in_current_pr ->
        "#{summary}\n  - 留在目前 PR 治本修正。"

      _ ->
        summary
    end
  end

  defp rework_instruction(true),
    do: "Symphony should reuse the same branch/PR and perform only the routed action shown above."

  defp rework_instruction(false),
    do: "Symphony should reuse the same branch/PR and fix only these scoped findings."

  defp state_transition_comment(snapshot, key) do
    """
    Review Convergence Gate returned this issue to In Progress for latest-head repair.

    - currentHeadSha: `#{snapshot.current_head_sha}`
    - transition-operation: `completed`
    - transition-operation-id: `#{key}`
    - dedup-key: `#{key}`
    """
  end

  defp transition_intent_comment(snapshot, target_state, operation_id, key) do
    """
    Review Convergence Gate recorded a durable rework transition intent.

    - currentHeadSha: `#{snapshot.current_head_sha}`
    - target-state: `#{target_state}`
    - transition-operation: `intent`
    - transition-operation-id: `#{operation_id}`
    - dedup-key: `#{key}`

    This operation is safe to resume after timeout or process restart; completion is recorded separately.
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
