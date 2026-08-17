defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc "Poll-cycle integration for latest-head review convergence."

  require Logger

  alias SymphonyElixir.{
    ClaimService,
    Config,
    EffectLedger,
    FindingDisposition,
    GitHubReviewClient,
    PatchAuthorization,
    ReviewConvergence,
    ReviewSettlement,
    ReviewSettlementReceipt,
    ScopeContract,
    Tracker
  }

  @owner_finding_fact_keys [
    :introduced_by_pr?,
    :invariant_violation?,
    :still_applies?,
    :in_scope?,
    :root_cause_bounded?,
    :requires_new_decision?,
    :safe_follow_up?,
    :follow_up_destination,
    :evidence_conflict?,
    :root_cause_receipt
  ]

  alias SymphonyElixir.Linear.Issue

  @type state :: %{optional(String.t()) => map()}

  @spec run(state()) :: state()
  def run(state) when is_map(state) do
    settings = Config.settings!().review_convergence

    if settings.enabled do
      run_with(state, settings, GitHubReviewClient, Tracker, production_options(settings))
    else
      state
    end
  end

  defp production_options(%{profile: :aroak_autonomous_v1}) do
    %{
      profile: :aroak_autonomous_v1,
      claim_service: ClaimService,
      effect_ledger: EffectLedger,
      patch_authorization: PatchAuthorization,
      review_settlement: ReviewSettlement,
      settlement_receipt: ReviewSettlementReceipt,
      owner_runtime: configured_owner_runtime(Config.settings!().review_convergence.owner_runtime_module)
    }
  end

  defp production_options(_settings), do: %{profile: :legacy}

  defp configured_owner_runtime(name) when is_binary(name) and name != "" do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp configured_owner_runtime(_name), do: nil

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

  defp retain_uncertain_inactive_claims(state, active_issue_ids, options) do
    state
    |> Enum.reject(fn {issue_id, _entry} -> MapSet.member?(active_issue_ids, issue_id) end)
    |> Enum.reduce(%{}, fn {issue_id, entry}, retained ->
      retain_uncertain_inactive_claim(retained, issue_id, entry, options)
    end)
  end

  defp retain_uncertain_inactive_claim(retained, issue_id, entry, options) do
    with {:ok, identity} <- retained_claim_identity(entry),
         :uncertain <- release_outcome(release_claim_if_owned(options, issue_id, identity)) do
      Map.put(retained, issue_id, clear_grant_if_present(entry, :preserve_claim))
    else
      _definitive_or_invalid -> retained
    end
  end

  @doc false
  @spec run_with(state(), struct() | map(), module(), module(), map()) :: state()
  def run_with(state, settings, review_client, tracker, options) when is_map(options) do
    case Map.get(options, :profile, :legacy) do
      :aroak_autonomous_v1 ->
        run_autonomous(state, settings, review_client, tracker, options)

      _legacy_profile ->
        run_with(state, settings, review_client, tracker)
    end
  end

  defp run_autonomous(state, settings, review_client, tracker, options) do
    monitored_states = [settings.review_state, settings.in_progress_state] |> Enum.uniq()

    case tracker.fetch_routed_issues_by_states(monitored_states) do
      {:ok, issues} ->
        routed_issues =
          Enum.filter(issues, &Issue.routable?(&1, Config.settings!().tracker.required_labels))

        active_issue_ids = MapSet.new(routed_issues, & &1.id)
        uncertain_inactive = retain_uncertain_inactive_claims(state, active_issue_ids, options)

        active_state =
          state
          |> Map.take(MapSet.to_list(active_issue_ids))
          |> Map.merge(uncertain_inactive)

        Enum.reduce(
          routed_issues,
          active_state,
          &reconcile_autonomous_issue(&1, &2, settings, review_client, options)
        )

      {:error, _reason} ->
        invalidate_state_grants(state)
    end
  end

  defp reconcile_autonomous_issue(%Issue{} = issue, state, settings, review_client, options) do
    entry = autonomous_entry(Map.get(state, issue.id, %{}))

    {result, acquisition} =
      with branch when is_binary(branch) and branch != "" <- issue.branch_name,
           {:ok, snapshot} <- review_client.snapshot(settings.repository, branch),
           {:ok, claim, claim_acquisition} <- claim_for(options, issue) do
        reconcile_acquired_claim(
          claim_acquisition,
          entry,
          issue,
          snapshot,
          claim,
          settings,
          review_client,
          options
        )
      else
        nil -> {{:blocked, :missing_branch_name}, :none}
        "" -> {{:blocked, :missing_branch_name}, :none}
        {:error, reason} -> {{:blocked, reason}, :none}
      end

    grant_invalid? = releasable_result?(result)
    release? = acquisition in [:new, :retained] and grant_invalid?
    release_result = if release?, do: release_reconciled_claim(options, issue.id, acquisition, entry), else: :not_released

    result =
      if grant_invalid?,
        do: invalidate_stale_grant(result, entry, release_retention(acquisition, release_result)),
        else: result

    case result do
      {:ok, updated_entry} -> Map.put(state, issue.id, updated_entry)
      {:blocked, reason, blocked_entry} -> Map.put(state, issue.id, autonomous_blocker(blocked_entry, reason))
      {:blocked, reason} -> Map.put(state, issue.id, autonomous_blocker(entry, reason))
    end
  end

  defp reconcile_acquired_claim(:new, entry, issue, snapshot, claim, settings, review_client, options) do
    {reconcile_new_claim(entry, issue, snapshot, claim, settings, review_client, options, :bind), :new}
  end

  defp reconcile_acquired_claim(:existing, entry, issue, snapshot, claim, settings, review_client, options) do
    if retained_claim?(entry, claim) do
      {reconcile_new_claim(entry, issue, snapshot, claim, settings, review_client, options, :preserve), :retained}
    else
      {{:blocked, :claim_already_owned}, :existing}
    end
  end

  # Only an unconsumed grant keeps its claim. Pending effects remain visible to a
  # later claim generation through durable readback, so they must release capacity.
  defp releasable_result?({:ok, %{terminal_result: {:grant, _grants}}}), do: false
  defp releasable_result?(_result), do: true

  defp invalidate_stale_grant({:ok, updated}, entry, retention),
    do: {:ok, invalidate_entry_grant(updated, entry, retention)}

  defp invalidate_stale_grant({:blocked, reason, blocked}, entry, retention),
    do: {:blocked, reason, invalidate_entry_grant(blocked, entry, retention)}

  defp invalidate_stale_grant({:blocked, reason}, entry, retention),
    do: {:blocked, reason, clear_grant_if_present(entry, retention)}

  defp invalidate_entry_grant(updated, original, :preserve_claim) do
    retained_claim = recoverable_grant_claim_identity(original)

    updated
    |> clear_grant_if_present(:preserve_claim)
    |> Map.put(:retained_claim, retained_claim)
  end

  defp invalidate_entry_grant(updated, _original, :drop_claim),
    do: clear_grant_if_present(updated, :drop_claim)

  defp clear_grant_if_present(%{terminal_result: {:grant, _grants}} = entry, :drop_claim),
    do: %{entry | terminal_result: nil, retained_claim: nil, authorization_required: false}

  defp clear_grant_if_present(%{terminal_result: {:grant, _grants}} = entry, :preserve_claim),
    do: %{
      entry
      | terminal_result: nil,
        retained_claim: recoverable_grant_claim_identity(entry),
        authorization_required: false
    }

  defp clear_grant_if_present(entry, _retention), do: entry

  defp invalidate_state_grants(state) do
    Map.new(state, fn {issue_id, entry} ->
      {issue_id, clear_grant_if_present(entry, :preserve_claim)}
    end)
  end

  defp recoverable_grant_claim_identity(entry) do
    case retained_claim_identity(entry) do
      {:ok, identity} -> identity
      :error -> entry[:retained_claim]
    end
  end

  defp retained_claim?(%{retained_claim: %{claim_id: claim_id, generation: generation}}, claim)
       when is_binary(claim_id) and claim_id != "" and is_integer(generation) do
    claim[:owner] == self() and claim[:worker] in [nil, self()] and claim[:claim_id] == claim_id and
      claim[:generation] == generation
  end

  defp retained_claim?(%{terminal_result: {:grant, grants}}, claim) when is_map(grants) do
    claim[:owner] == self() and claim[:worker] in [nil, self()] and
      Enum.any?(grants, fn {_digest, grant} ->
        grant[:claim_id] == claim[:claim_id] and grant[:generation] == claim[:generation]
      end)
  end

  defp retained_claim?(_entry, _claim), do: false

  defp valid_claim_identity?(%{claim_id: claim_id, generation: generation}),
    do: is_binary(claim_id) and claim_id != "" and is_integer(generation) and generation > 0

  defp valid_claim_identity?(_identity), do: false

  defp retained_claim_identity(%{retained_claim: nil} = entry) do
    retained_grant_claim_identity(entry)
  end

  defp retained_claim_identity(%{retained_claim: retained}) do
    if valid_claim_identity?(retained), do: {:ok, retained}, else: :error
  end

  defp retained_claim_identity(entry), do: retained_grant_claim_identity(entry)

  defp retained_grant_claim_identity(%{terminal_result: {:grant, grants}}) when is_map(grants) do
    identities =
      grants
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:claim_id, :generation]))
      |> Enum.uniq()

    case identities do
      [identity] -> if valid_claim_identity?(identity), do: {:ok, identity}, else: :error
      _identities -> :error
    end
  end

  defp retained_grant_claim_identity(_entry), do: :error

  defp claim_identity(claim_context) do
    %{claim_id: claim_context[:claim_id], generation: claim_context[:generation]}
  end

  defp reconcile_new_claim(entry, issue, snapshot, claim, settings, review_client, options, binding) do
    with {:ok, connection, claim_context} <- claimed_context(options, issue, claim, binding),
         {:ok, operations} <- list_effect_operations(options, connection, claim_context),
         {:ok, operations} <-
           reconcile_pending_settlement_receipts(options, connection, claim_context, operations),
         :ok <- reconcile_operation_locks(operations),
         {:ok, options} <- hydrate_owner_runtime(options, snapshot, operations, claim_context),
         {:ok, summary} <- finding_summary(snapshot, settings, entry, operations, options),
         :ok <- verify_live_head(review_client, settings, snapshot) do
      autonomous_claimed_result(
        connection,
        entry,
        snapshot,
        summary,
        operations,
        claim_context,
        options
      )
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp hydrate_owner_runtime(options, snapshot, operations, claim_context) do
    cond do
      complete_owner_evidence?(options) ->
        {:ok, options}

      owner_runtime_available?(options) ->
        owner_runtime = options.owner_runtime

        owner_runtime.readback(
          snapshot,
          %{review_events: snapshot[:review_events] || []},
          operations,
          claim_context
        )
        |> owner_runtime_result(options)

      Map.has_key?(options, :owner_runtime) ->
        {:error, :owner_runtime_unavailable}

      true ->
        {:ok, options}
    end
  end

  defp complete_owner_evidence?(options),
    do:
      is_map(options[:settlement_contexts]) and is_map(options[:root_cause_receipts]) and
        is_map(options[:authorization_runtime])

  defp owner_runtime_available?(options),
    do:
      Map.has_key?(options, :owner_runtime) and
        loaded_function_exported?(options[:owner_runtime], :readback, 4)

  defp owner_runtime_result(
         {:ok,
          %{
            settlement_contexts: contexts,
            root_cause_receipts: receipts,
            authorization_runtime: runtime,
            finding_facts: finding_facts
          }},
         options
       )
       when is_map(contexts) and is_map(receipts) and is_map(runtime) and is_map(finding_facts) do
    {:ok,
     Map.merge(options, %{
       settlement_contexts: contexts,
       root_cause_receipts: receipts,
       authorization_runtime: runtime,
       finding_facts: finding_facts
     })}
  end

  defp owner_runtime_result({:error, reason}, _options),
    do: {:error, {:owner_runtime_unavailable, reason}}

  defp owner_runtime_result(_invalid, _options), do: {:error, :invalid_owner_runtime_readback}

  defp verify_live_head(review_client, settings, snapshot) do
    with true <- loaded_function_exported?(review_client, :current_head_sha, 2),
         {:ok, live_head_sha} <- review_client.current_head_sha(settings.repository, snapshot[:pull_request_number]),
         true <- live_head_sha == snapshot[:current_head_sha] do
      :ok
    else
      false -> {:error, :head_changed_during_reconciliation}
      {:error, reason} -> {:error, reason}
      _unavailable -> {:error, :head_verification_unavailable}
    end
  end

  defp autonomous_entry(entry) do
    Map.merge(
      %{
        evaluated_head_sha: nil,
        decisions: %{},
        pending_effect_ids: [],
        local_blocked_finding_keys: [],
        authorization_required: false,
        authorization_attempts: %{},
        authorization_results: %{},
        settlement_attempts: %{},
        settlement_results: %{},
        causal_attempts: [],
        pending_causal_attempts: [],
        global_blocker: nil,
        retained_claim: nil,
        terminal_result: nil
      },
      entry
    )
  end

  defp autonomous_blocker(entry, reason) do
    %{entry | global_blocker: reason, authorization_required: false}
  end

  defp claim_for(options, issue) do
    claim_service = Map.get(options, :claim_service, ClaimService)

    case claim_service.claim(issue, self()) do
      {:ok, %{acquisition: acquisition} = claim} when acquisition in [:new, :existing] ->
        {:ok, claim, acquisition}

      {:error, reason} ->
        {:error, reason}

      {:ok, nil} ->
        {:error, :claim_service_unavailable}

      {:ok, claim} when is_map(claim) ->
        {:error, :claim_ownership_unverified}

      other ->
        {:error, {:invalid_claim_result, other}}
    end
  end

  defp claimed_context(options, issue, _claim, :bind) do
    claim_service = Map.get(options, :claim_service, ClaimService)

    with :ok <- claim_service.bind_worker(issue.id, self()) do
      claim_service.effect_context(issue.id)
    end
  end

  defp claimed_context(options, issue, _claim, :preserve) do
    claim_service = Map.get(options, :claim_service, ClaimService)
    claim_service.effect_context(issue.id)
  end

  defp release_claim(options, issue_id) do
    claim_service = Map.get(options, :claim_service, ClaimService)

    if function_exported?(claim_service, :release, 1) do
      _ = claim_service.release(issue_id)
    end

    :ok
  end

  defp release_reconciled_claim(options, issue_id, :retained, entry) do
    case retained_claim_identity(entry) do
      {:ok, identity} -> release_claim_if_owned(options, issue_id, identity)
      :error -> :ok
    end
  end

  defp release_reconciled_claim(options, issue_id, :new, _entry),
    do: release_claim(options, issue_id)

  defp release_retention(:retained, result) do
    if release_outcome(result) == :uncertain, do: :preserve_claim, else: :drop_claim
  end

  defp release_retention(_acquisition, :not_released), do: :preserve_claim
  defp release_retention(_acquisition, _result), do: :drop_claim

  defp release_outcome(:ok), do: :released
  defp release_outcome({:error, :claim_ownership_changed}), do: :ownership_changed
  defp release_outcome({:error, :claim_not_owned}), do: :ownership_changed
  defp release_outcome(_result), do: :uncertain

  defp release_claim_if_owned(options, issue_id, identity) do
    claim_service = Map.get(options, :claim_service, ClaimService)

    if function_exported?(claim_service, :release_if_owned, 2) do
      claim_service.release_if_owned(issue_id, identity)
    else
      {:error, :conditional_release_unavailable}
    end
  end

  defp list_effect_operations(options, connection, claim_context) do
    ledger = Map.get(options, :effect_ledger, EffectLedger)

    if loaded_function_exported?(ledger, :list_operations, 2) do
      ledger.list_operations(connection, claim_context)
    else
      {:error, :effect_ledger_readback_unavailable}
    end
  end

  defp reconcile_pending_settlement_receipts(options, connection, claim_context, operations) do
    recorder = Map.get(options, :settlement_receipt, ReviewSettlementReceipt)
    ledger = Map.get(options, :effect_ledger, EffectLedger)

    pending? =
      Enum.any?(
        operations,
        &(&1[:effect_type] == :review_settlement_receipt and &1[:status] in [:pending, :unknown])
      )

    if pending? and loaded_function_exported?(recorder, :reconcile_pending, 4) do
      with :ok <- recorder.reconcile_pending(connection, ledger, claim_context, operations) do
        list_effect_operations(options, connection, claim_context)
      end
    else
      {:ok, operations}
    end
  end

  defp reconcile_operation_locks(operations) do
    entries =
      operations
      |> Enum.filter(&String.starts_with?(&1.request_fingerprint, "symphony_request_fingerprint_v1:"))
      |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
        case FindingDisposition.decode_request_fingerprint(operation.request_fingerprint) do
          {:ok, intent} ->
            {:cont,
             {:ok,
              [
                %{
                  finding_key: intent.finding_key,
                  disposition: intent.disposition,
                  ledger_record: operation
                }
                | acc
              ]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_effect_fingerprint, reason}}}
        end
      end)

    with {:ok, entries} <- entries,
         {:ok, _locks} <- FindingDisposition.reconcile_locks(entries) do
      :ok
    end
  end

  defp finding_summary(%{finding_summary: summary}, _settings, _entry, _operations, _options)
       when is_map(summary) do
    if is_list(summary[:decisions]), do: {:ok, summary}, else: {:error, :finding_summary_invalid}
  end

  defp finding_summary(snapshot, settings, entry, operations, options) do
    with {:ok, scope_contract} <- parse_scope_contract(snapshot),
         {:ok, events} <- review_events(snapshot),
         {:ok, findings} <-
           selected_findings(
             snapshot,
             events,
             settings,
             settled_threads(entry, operations, snapshot),
             options[:finding_facts] || %{}
           ),
         {:ok, plan} <-
           FindingDisposition.classify_all(findings, %{
             verified?: true,
             valid?: true,
             current_head_sha: snapshot[:current_head_sha]
           }) do
      {:ok,
       Map.merge(plan, %{
         requires_lifecycle?: plan.decisions != [],
         scope_contract: scope_contract
       })}
    end
  end

  defp parse_scope_contract(%{pull_request_body: body}) when is_binary(body),
    do: ScopeContract.parse_pr_body(body)

  defp parse_scope_contract(_snapshot), do: {:error, :scope_contract_unavailable}

  defp review_events(%{review_events: events}) when is_list(events), do: {:ok, events}
  defp review_events(_snapshot), do: {:error, :review_events_unavailable}

  defp selected_findings(snapshot, events, settings, settled, finding_facts) do
    repository = snapshot[:repository] || settings.repository
    pull_request_number = snapshot[:pull_request_number]
    head_sha = snapshot[:current_head_sha]

    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      case review_comment_for_evaluation(event, settled, head_sha) do
        {:ok, comment, revalidation_required?} ->
          facts = %{
            repository: repository,
            pull_request_number: pull_request_number,
            source_head_sha: head_sha,
            selected_review_comment_head_sha: comment[:commit_sha],
            review_thread_id: event[:review_thread_id],
            selected_review_comment_id: comment[:id],
            body: comment[:body],
            prior_settlement_revalidation_required?: revalidation_required?,
            introduced_by_pr?: :unknown,
            invariant_violation?: :unknown,
            still_applies?: :unknown,
            in_scope?: :unknown,
            root_cause_bounded?: :unknown,
            requires_new_decision?: :unknown,
            safe_follow_up?: :unknown,
            follow_up_destination: nil
          }

          owner_facts =
            Map.get(finding_facts, comment[:id]) ||
              Map.get(finding_facts, event[:review_thread_id]) || %{}

          facts = Map.merge(facts, Map.take(owner_facts, @owner_finding_fact_keys))

          {:cont, {:ok, [facts | acc]}}

        :no_fresh_evidence ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp review_comment_for_evaluation(event, settled, head_sha) do
    selection = %{resolved?: event[:resolved?], settled: settled}

    case FindingDisposition.select_review_comment(event, selection) do
      {:ok, comment} ->
        {:ok, comment, false}

      {:error, :resolved_thread_settlement_unverified} = unresolved ->
        review_resolved_comment_for_evaluation(event, selection, head_sha, unresolved)

      other ->
        other
    end
  end

  defp review_resolved_comment_for_evaluation(event, selection, head_sha, unresolved) do
    if (event[:resolved?] || event["resolved?"]) == true do
      event
      |> Map.put(:resolved?, false)
      |> Map.put("resolved?", false)
      |> FindingDisposition.select_review_comment(%{selection | resolved?: false})
      |> revalidate_resolved_comment_head(head_sha, unresolved)
    else
      unresolved
    end
  end

  defp revalidate_resolved_comment_head({:ok, comment}, head_sha, unresolved) do
    if comment[:commit_sha] != head_sha, do: {:ok, comment, true}, else: unresolved
  end

  defp revalidate_resolved_comment_head(other, _head_sha, _unresolved), do: other

  defp settled_threads(entry, operations, snapshot) do
    local =
      entry.settlement_results
      |> Map.values()
      |> Enum.reduce(%{}, fn
        {:settled, %{finding_key: finding_key}}, settled when is_map(finding_key) ->
          if settlement_snapshot_identity?(snapshot, finding_key),
            do: put_settled_thread(settled, finding_key),
            else: settled

        _unsettled, settled ->
          settled
      end)

    Map.merge(durable_settled_threads(operations, snapshot), local)
  end

  defp durable_settled_threads(operations, snapshot) do
    operations
    |> Enum.filter(&(&1[:status] == :succeeded))
    |> Enum.group_by(& &1[:request_fingerprint])
    |> Enum.reduce(%{}, fn {_fingerprint, entries}, settled ->
      case durable_settlement_finding(entries, snapshot) do
        {:ok, finding_key} -> put_settled_thread(settled, finding_key)
        :error -> settled
      end
    end)
  end

  defp durable_settlement_finding(entries, snapshot) do
    fingerprint = entries |> List.first() |> Map.get(:request_fingerprint)

    with {:ok, intent} <- FindingDisposition.decode_request_fingerprint(fingerprint),
         disposition when disposition in [:fix_in_current_pr, :follow_up_required, :rejected] <-
           intent[:disposition],
         finding_key when is_map(finding_key) <- intent[:finding_key],
         true <- durable_receipt?(entries, finding_key, disposition),
         true <- settlement_snapshot_identity?(snapshot, finding_key) do
      {:ok, finding_key}
    else
      _invalid -> :error
    end
  end

  defp durable_receipt?(entries, finding_key, disposition) do
    case Enum.filter(entries, &(&1[:effect_type] == :review_settlement_receipt)) do
      [%{native_resource: resource}] when is_map(resource) ->
        receipt_identity(resource) == expected_receipt_identity(finding_key, disposition) and
          valid_evidence_digest?(resource_value(resource, [:evidence_sha256]))

      _ ->
        false
    end
  end

  defp receipt_identity(resource) do
    Map.new(receipt_identity_fields(), fn field -> {field, resource_value(resource, [field])} end)
  end

  defp expected_receipt_identity(finding_key, disposition) do
    %{
      verified: true,
      disposition: Atom.to_string(disposition),
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      finding_key_digest: finding_key.digest,
      review_thread_id: finding_key.review_thread_id,
      selected_review_comment_id: finding_key.selected_review_comment_id,
      body_sha256: finding_key.body_sha256,
      exact_head_sha: finding_key.source_head_sha
    }
  end

  defp receipt_identity_fields do
    [
      :verified,
      :disposition,
      :repository,
      :pull_request_number,
      :finding_key_digest,
      :review_thread_id,
      :selected_review_comment_id,
      :body_sha256,
      :exact_head_sha
    ]
  end

  defp valid_evidence_digest?(digest) when is_binary(digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_evidence_digest?(_digest), do: false

  defp settlement_snapshot_identity?(snapshot, finding_key) do
    finding_key.repository == snapshot[:repository] and
      finding_key.pull_request_number == snapshot[:pull_request_number] and
      finding_key.source_head_sha == snapshot[:current_head_sha]
  end

  defp resource_value(resource, keys) when is_map(resource) do
    Enum.find_value(keys, fn key -> Map.get(resource, key) || Map.get(resource, Atom.to_string(key)) end)
  end

  defp put_settled_thread(settled, finding_key) do
    Map.put(settled, finding_key.review_thread_id, %{
      comment_id: finding_key.selected_review_comment_id,
      body_sha256: finding_key.body_sha256
    })
  end

  defp autonomous_claimed_result(
         connection,
         entry,
         snapshot,
         summary,
         operations,
         claim_context,
         options
       ) do
    pending_effect_ids =
      operations
      |> Enum.filter(&(&1[:status] in [:pending, :unknown] and &1[:effect_type] != :review_settlement_receipt))
      |> Enum.map(& &1[:operation_id])

    updated =
      entry
      |> Map.put(:evaluated_head_sha, snapshot[:current_head_sha])
      |> Map.put(:decisions, decisions_by_digest(summary[:decisions] || []))
      |> Map.put(:pending_effect_ids, pending_effect_ids)
      |> Map.put(:global_blocker, nil)
      |> Map.put(:retained_claim, nil)

    cond do
      pending_effect_ids != [] ->
        {:blocked, :pending_effects, Map.put(updated, :retained_claim, claim_identity(claim_context))}

      summary[:decisions] == [] ->
        {:ok,
         %{
           updated
           | authorization_required: false,
             authorization_results: %{},
             terminal_result: nil
         }}

      not owner_apis_available?(options) ->
        {:blocked, :owner_api_unavailable, updated}

      true ->
        runtime = %{
          connection: connection,
          operations: operations,
          snapshot: snapshot,
          claim_context: claim_context,
          options: options
        }

        settle_or_authorize(updated, summary[:decisions], runtime)
    end
  end

  defp decisions_by_digest(decisions),
    do: Map.new(decisions, &{&1.finding_key_digest, &1})

  defp owner_apis_available?(options) do
    authorization = Map.get(options, :patch_authorization, PatchAuthorization)
    settlement = Map.get(options, :review_settlement)

    loaded_function_exported?(authorization, :authorize, 5) and
      loaded_function_exported?(settlement, :settle, 2)
  end

  defp settle_or_authorize(entry, decisions, runtime) do
    contexts = Map.get(runtime.options, :settlement_contexts, %{})

    if is_map(contexts) do
      {settlement_decisions, remaining_decisions} =
        Enum.split_with(decisions, &Map.has_key?(contexts, &1.finding_key_digest))

      {authorization_decisions, missing_settlement_decisions} =
        Enum.split_with(remaining_decisions, &(&1.disposition == :fix_in_current_pr))

      if missing_settlement_decisions == [] do
        runtime = Map.put(runtime, :contexts, contexts)
        settle_then_authorize(entry, settlement_decisions, authorization_decisions, runtime)
      else
        {:blocked, :settlement_context_unavailable, entry}
      end
    else
      {:blocked, :invalid_settlement_contexts, entry}
    end
  end

  defp settle_then_authorize(entry, [], authorization_decisions, runtime) do
    authorize_causal_patches(
      entry,
      authorization_decisions,
      runtime.operations,
      runtime.snapshot,
      runtime.claim_context,
      runtime.options
    )
  end

  defp settle_then_authorize(entry, settlement_decisions, [], runtime) do
    settle_decisions(entry, settlement_decisions, runtime)
  end

  defp settle_then_authorize(entry, settlement_decisions, authorization_decisions, runtime) do
    with {:ok, settled_entry} <- reduce_settlements(entry, settlement_decisions, runtime) do
      authorize_causal_patches(
        settled_entry,
        authorization_decisions,
        runtime.operations,
        runtime.snapshot,
        runtime.claim_context,
        runtime.options
      )
    end
  end

  defp settle_decisions(entry, decisions, runtime) do
    decisions
    |> then(&reduce_settlements(entry, &1, runtime))
    |> settlement_result(MapSet.new(decisions, & &1.finding_key_digest))
  end

  defp reduce_settlements(entry, decisions, runtime) do
    settlement = Map.fetch!(runtime.options, :review_settlement)
    sorted = FindingDisposition.sort_decisions(decisions)

    sorted
    |> Enum.reduce_while({:ok, entry}, fn decision, {:ok, acc} ->
      settle_decision(acc, decision, settlement, runtime)
    end)
  end

  defp settle_decision(entry, decision, settlement, runtime) do
    digest = decision.finding_key_digest

    case runtime.contexts[digest] do
      context when is_map(context) ->
        authoritative = %{
          current_head_sha: runtime.snapshot[:current_head_sha],
          claim:
            runtime.claim_context
            |> Map.take([:issue_id, :claim_id, :generation])
            |> Map.put(:active?, true),
          operations: runtime.operations
        }

        context = Map.merge(context, authoritative)
        key = :crypto.hash(:sha256, :erlang.term_to_binary({decision, context}))
        result = Map.get(entry.settlement_attempts, key) || settlement.settle(decision, context)

        attempted = put_in(entry, [:settlement_attempts, key], result)
        commit_settlement_result(attempted, decision, result, runtime)

      _missing ->
        {:halt, {:blocked, :settlement_context_unavailable, entry}}
    end
  end

  defp commit_settlement_result(entry, decision, {:settled, evidence} = result, runtime) do
    recorder = Map.get(runtime.options, :settlement_receipt, ReviewSettlementReceipt)
    ledger = Map.get(runtime.options, :effect_ledger, EffectLedger)

    case recorder.record(
           runtime.connection,
           ledger,
           runtime.claim_context,
           decision,
           evidence,
           runtime.operations
         ) do
      {:ok, _receipt} ->
        committed = put_in(entry, [:settlement_results, decision.finding_key_digest], result)
        {:cont, {:ok, committed}}

      {:error, reason} ->
        {:halt, {:blocked, {:settlement_receipt_failed, reason}, entry}}
    end
  end

  defp commit_settlement_result(entry, decision, {:blocked, reason} = result, _runtime) do
    blocked = put_in(entry, [:settlement_results, decision.finding_key_digest], result)
    {:halt, {:blocked, reason, blocked}}
  end

  defp commit_settlement_result(entry, _decision, _invalid, _runtime),
    do: {:halt, {:blocked, :invalid_review_settlement_result, entry}}

  defp settlement_result({:ok, entry}, current_digests) do
    evidence =
      entry.settlement_results
      |> Map.take(MapSet.to_list(current_digests))
      |> Enum.reduce(%{}, fn
        {digest, {:settled, item}}, acc -> Map.put(acc, digest, item)
        {_digest, _unsettled}, acc -> acc
      end)

    {:ok,
     %{
       entry
       | authorization_required: false,
         authorization_results: %{},
         terminal_result: {:settled, evidence},
         global_blocker: nil
     }}
  end

  defp settlement_result({:blocked, reason, entry}, _current_digests) do
    {:blocked, reason,
     %{
       entry
       | authorization_required: false,
         terminal_result: {:blocked, reason}
     }}
  end

  defp authorize_causal_patches(entry, decisions, operations, snapshot, claim_context, options) do
    authorization = Map.get(options, :patch_authorization, PatchAuthorization)
    receipts = Map.get(options, :root_cause_receipts)
    runtime = Map.get(options, :authorization_runtime)

    case is_map(receipts) and is_map(runtime) do
      true ->
        reduce_authorizations(
          entry,
          decisions,
          operations,
          snapshot,
          claim_context,
          authorization,
          receipts,
          runtime
        )

      false ->
        {:blocked, :root_cause_receipt_unavailable, entry}
    end
  end

  defp reduce_authorizations(entry, decisions, operations, snapshot, claim_context, authorization, receipts, runtime) do
    sorted_decisions = FindingDisposition.sort_decisions(decisions)
    current_digests = MapSet.new(sorted_decisions, & &1.finding_key_digest)
    entry = %{entry | authorization_results: %{}}

    sorted_decisions
    |> Enum.reduce_while({:ok, entry}, fn decision, {:ok, acc} ->
      authorize_decision(acc, decision, operations, snapshot, claim_context, authorization, receipts, runtime)
    end)
    |> authorization_result(current_digests)
  end

  defp authorize_decision(entry, decision, operations, snapshot, claim_context, authorization, receipts, runtime) do
    digest = decision[:finding_key_digest]
    receipt = receipts[digest]

    key = authorization_transition_key(decision, receipt, operations, snapshot, claim_context, runtime)

    authorize_decision_once(
      Map.get(entry.authorization_attempts, key),
      entry,
      key,
      digest,
      decision,
      receipt,
      operations,
      snapshot,
      claim_context,
      authorization,
      runtime
    )
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp authorize_decision_once(nil, entry, key, digest, decision, receipt, operations, snapshot, claim_context, authorization, runtime) do
    result =
      authorization.authorize(
        decision,
        receipt || %{},
        authorization_claim(claim_context),
        operations,
        authorization_runtime(runtime, snapshot, claim_context, entry)
      )

    updated =
      entry
      |> put_in([:authorization_attempts, key], result)
      |> put_in([:authorization_results, digest], result)

    authorization_reduction(result, updated)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp authorize_decision_once(
         cached_result,
         entry,
         _key,
         digest,
         _decision,
         _receipt,
         _operations,
         _snapshot,
         _claim_context,
         _authorization,
         _runtime
       ) do
    updated = put_in(entry, [:authorization_results, digest], cached_result)
    authorization_reduction(cached_result, updated)
  end

  defp authorization_transition_key(decision, receipt, operations, snapshot, claim_context, runtime) do
    payload = {
      decision,
      receipt,
      operations,
      snapshot[:current_head_sha],
      claim_context[:claim_id],
      claim_context[:generation],
      runtime
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
  end

  defp authorization_claim(claim_context) do
    %{
      active?: true,
      claim_id: claim_context[:claim_id],
      generation: claim_context[:generation]
    }
  end

  defp authorization_runtime(runtime, snapshot, claim_context, entry) do
    prior_attempts = merge_prior_attempts(runtime[:prior_attempts], entry.causal_attempts)

    Map.merge(runtime, %{
      current_head_sha: snapshot[:current_head_sha],
      active_claim_id: claim_context[:claim_id],
      active_generation: claim_context[:generation],
      prior_attempts: prior_attempts
    })
  end

  defp merge_prior_attempts(nil, local), do: local

  defp merge_prior_attempts(external, local) when is_list(external) do
    if Enum.all?(external, &is_map/1) do
      Enum.uniq_by(external ++ local, &causal_attempt_identity/1)
    else
      external
    end
  end

  defp merge_prior_attempts(external, _local), do: external

  defp authorization_reduction({:ok, grant}, entry) do
    attempt = %{
      finding_lineage_digest: grant.finding_lineage_key.digest,
      causal_attempt_fingerprint: grant.causal_attempt_fingerprint,
      causal_evidence_digest: grant.causal_evidence_digest,
      generation: grant.generation
    }

    pending = Enum.uniq_by([attempt | entry.pending_causal_attempts], &causal_attempt_identity/1)
    {:cont, {:ok, %{entry | pending_causal_attempts: pending}}}
  end

  defp authorization_reduction({:reconcile, evidence}, entry),
    do: {:halt, {:reconcile, evidence, entry}}

  defp authorization_reduction({:blocked, reason}, entry),
    do: {:halt, {:blocked, reason, entry}}

  defp authorization_reduction(_invalid, entry),
    do: {:halt, {:blocked, :invalid_patch_authorization_result, entry}}

  defp causal_attempt_identity(attempt) do
    {
      attempt[:finding_lineage_digest],
      attempt[:causal_attempt_fingerprint],
      attempt[:causal_evidence_digest]
    }
  end

  defp authorization_result({:ok, entry}, current_digests) do
    current_results = Map.take(entry.authorization_results, MapSet.to_list(current_digests))
    grants = Map.new(current_results, fn {digest, {:ok, grant}} -> {digest, grant} end)

    attempts =
      Enum.uniq_by(entry.pending_causal_attempts ++ entry.causal_attempts, &causal_attempt_identity/1)

    {:ok,
     %{
       entry
       | authorization_required: true,
         authorization_results: current_results,
         causal_attempts: attempts,
         pending_causal_attempts: [],
         terminal_result: {:grant, grants},
         global_blocker: nil
     }}
  end

  defp authorization_result({:reconcile, evidence, entry}, _current_digests) do
    updated = %{
      entry
      | authorization_required: false,
        pending_causal_attempts: [],
        terminal_result: {:reconcile, evidence}
    }

    {:blocked, :authorization_reconciliation_required, updated}
  end

  defp authorization_result({:blocked, reason, entry}, _current_digests) do
    {:blocked, reason,
     %{
       entry
       | authorization_required: false,
         pending_causal_attempts: [],
         terminal_result: {:blocked, reason}
     }}
  end

  defp loaded_function_exported?(module, function, arity) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, function, arity)
      _ -> false
    end
  end

  defp loaded_function_exported?(_module, _function, _arity), do: false

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
      decision = ReviewConvergence.evaluate(snapshot, entry.fix_rounds, settings.max_fix_rounds)
      {updated_entry, _outcome} = apply_decision(decision, issue, entry, settings, review_client, tracker, snapshot)
      Map.put(state, issue.id, updated_entry)
    else
      nil -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      "" -> wait_for_human(issue, entry, settings, review_client, tracker, :missing_branch_name, state)
      {:error, reason} -> wait_for_human(issue, entry, settings, review_client, tracker, inspect(reason), state)
    end
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
    Enum.map(findings, &{&1[:priority], &1[:path], &1[:body]})
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
