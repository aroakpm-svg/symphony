defmodule SymphonyElixir.PatchAuthorization do
  @moduledoc """
  Design 3's single authorization boundary.

  The module is intentionally fail-closed while the Design 2 owner contract is unavailable. It
  does not recreate Design 2 identity, ledger, or publish behavior.
  """

  @type authorization_input :: map()
  @type authorization_evidence :: map()
  @type effect_scope :: map()
  @type authorization_dependencies :: map()
  @type slot_kind :: :automatic_initial_v1 | :automatic_correction_v1 | tuple()
  @type slot_state ::
          :available
          | :reserved_unresolved
          | :consumed
          | :reserved_failed_no_effect
          | :blocked_conflict

  @automatic_slots [:automatic_initial_v1, :automatic_correction_v1]
  @slot_states [
    :available,
    :reserved_unresolved,
    :consumed,
    :reserved_failed_no_effect,
    :blocked_conflict
  ]

  @spec authorize(
          authorization_input(),
          [term()],
          authorization_evidence(),
          effect_scope(),
          authorization_dependencies()
        ) :: {:blocked, term()} | {:ok, map()} | {:authorization_required, map()} | {:reconcile, map()}
  def authorize(input, ledger_entries, evidence, effect_scope, dependencies)
      when is_map(input) and is_list(ledger_entries) and is_map(evidence) and is_map(effect_scope) and
             is_map(dependencies) do
    with :ok <- validate_design2_contract(dependencies),
         :ok <- validate_input(input, effect_scope),
         {:ok, finding_keys} <- finding_keys(input),
         {:ok, finding_set_digest} <- validate_design2_digest(dependencies.design2, finding_keys) do
      project_authorization_result =
        project_authorization(input, finding_keys, ledger_entries, evidence, dependencies)

      route_human_authorization(
        project_authorization_result,
        input,
        finding_keys,
        finding_set_digest,
        evidence,
        effect_scope,
        dependencies
      )
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  def authorize(_input, _ledger_entries, _evidence, _effect_scope, _dependencies),
    do: {:blocked, :invalid_authorization_input}

  defp validate_design2_contract(%{design2: design2}) when is_atom(design2) do
    if Code.ensure_loaded?(design2) and function_exported?(design2, :finding_set_digest, 1) do
      :ok
    else
      {:error, :design2_contract_unavailable}
    end
  end

  defp validate_design2_contract(_dependencies), do: {:error, :design2_contract_unavailable}

  defp validate_input(input, effect_scope) do
    with :ok <- validate_profile(input),
         :ok <- validate_repository(input),
         :ok <- validate_pull_request_number(input),
         :ok <- validate_evaluated_head(input),
         :ok <- validate_claim_scope(input, effect_scope),
         :ok <- validate_findings(input) do
      validate_human_summary(input)
    end
  end

  defp validate_profile(%{profile: :aroak_autonomous_v1}), do: :ok
  defp validate_profile(%{profile: profile}), do: {:error, {:invalid_profile, profile}}
  defp validate_profile(_input), do: {:error, :missing_profile}

  defp validate_repository(%{repository: repository})
       when is_binary(repository) and byte_size(repository) > 0,
       do: :ok

  defp validate_repository(_input), do: {:error, :invalid_repository}

  defp validate_pull_request_number(%{pull_request_number: number})
       when is_integer(number) and number > 0,
       do: :ok

  defp validate_pull_request_number(_input), do: {:error, :invalid_pull_request_number}

  defp validate_evaluated_head(%{evaluated_head_sha: head}) when is_binary(head) do
    if valid_head_sha?(head), do: :ok, else: {:error, :invalid_evaluated_head_sha}
  end

  defp validate_evaluated_head(_input), do: {:error, :invalid_evaluated_head_sha}

  defp validate_claim_scope(input, %{claim_context: claim_context}) when is_map(claim_context) do
    repository_matches? = claim_context[:repository] == input[:repository]
    pull_request_matches? = claim_context[:pull_request_number] == input[:pull_request_number]

    if repository_matches? and pull_request_matches?, do: :ok, else: {:error, :claim_scope_mismatch}
  end

  defp validate_claim_scope(_input, _effect_scope), do: {:error, :claim_scope_unavailable}

  defp validate_findings(%{eligible_findings: findings, evaluated_head_sha: evaluated_head})
       when is_list(findings) and findings != [] do
    Enum.reduce_while(findings, MapSet.new(), fn finding, finding_keys ->
      case validate_finding(finding, evaluated_head) do
        {:ok, finding_key} ->
          add_finding_key(finding_keys, finding_key)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_findings(_input), do: {:error, :missing_eligible_findings}

  defp validate_human_summary(%{human_summary: summary}) when is_binary(summary) do
    if String.trim(summary) == "", do: {:error, :invalid_human_summary}, else: :ok
  end

  defp validate_human_summary(_input), do: {:error, :invalid_human_summary}

  defp validate_finding(finding, evaluated_head) when is_map(finding) do
    with {:ok, finding_key} <- Map.fetch(finding, :finding_key),
         :ok <- validate_finding_disposition(finding),
         :ok <- validate_finding_head(finding, evaluated_head) do
      {:ok, finding_key}
    else
      :error -> {:error, :missing_finding_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_finding(_finding, _evaluated_head), do: {:error, :invalid_finding_shape}

  defp add_finding_key(finding_keys, finding_key) do
    if MapSet.member?(finding_keys, finding_key),
      do: {:halt, {:error, :duplicate_finding_key}},
      else: {:cont, MapSet.put(finding_keys, finding_key)}
  end

  defp validate_finding_disposition(%{disposition: :fix_in_current_pr}), do: :ok

  defp validate_finding_disposition(%{disposition: disposition}),
    do: {:error, {:invalid_finding_disposition, disposition}}

  defp validate_finding_disposition(_finding), do: {:error, :missing_finding_disposition}

  defp validate_finding_head(
         %{evaluated_head_sha: finding_head, source_head_sha: source_head},
         evaluated_head
       )
       when is_binary(finding_head) and is_binary(source_head) and is_binary(evaluated_head) do
    cond do
      finding_head != evaluated_head -> {:error, :finding_evaluated_head_mismatch}
      not valid_head_sha?(finding_head) -> {:error, :invalid_finding_evaluated_head_sha}
      not valid_head_sha?(source_head) -> {:error, :invalid_finding_source_head_sha}
      finding_head != source_head -> {:error, :finding_source_head_mismatch}
      true -> :ok
    end
  end

  defp validate_finding_head(_finding, _evaluated_head), do: {:error, :invalid_finding_head_evidence}

  defp finding_keys(%{eligible_findings: findings}) do
    {:ok, Enum.map(findings, & &1[:finding_key])}
  end

  defp validate_design2_digest(design2, finding_keys) do
    case design2.finding_set_digest(finding_keys) do
      {:ok, digest} when is_binary(digest) and byte_size(digest) > 0 -> {:ok, digest}
      _ -> {:error, :design2_finding_set_digest_unavailable}
    end
  rescue
    _error -> {:error, :design2_finding_set_digest_unavailable}
  end

  defp project_authorization(input, finding_keys, ledger_entries, evidence, dependencies) do
    design2 = dependencies.design2

    with :ok <- validate_projection_contract(design2),
         {:ok, classified} <- classify_ledger_entries(design2, ledger_entries, evidence),
         {:ok, projection} <- index_slots(classified),
         :ok <- validate_slot_relationships(projection),
         :ok <- reject_conflicts(projection),
         {:ok, reconciliation} <- pending_reconciliation(projection) do
      case reconciliation do
        {:some, evidence} ->
          {:reconcile, evidence}

        :none ->
          route_available_slot(
            input,
            finding_keys,
            projection.automatic,
            projection.human,
            ledger_entries,
            evidence,
            design2,
            dependencies
          )
      end
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp validate_projection_contract(design2) do
    callbacks = [
      {:classify_managed_publish, 2},
      {:managed_publish_identity, 1},
      {:verify_correction, 4}
    ]

    if Enum.all?(callbacks, &function_exported?(design2, elem(&1, 0), elem(&1, 1))) do
      :ok
    else
      {:error, :design2_projection_contract_unavailable}
    end
  end

  defp classify_ledger_entries(design2, ledger_entries, evidence) do
    native = Map.get(evidence, :native, %{})

    Enum.reduce_while(ledger_entries, {:ok, []}, fn entry, {:ok, classified} ->
      case classify_ledger_entry(design2, entry, native) do
        :not_managed -> {:cont, {:ok, classified}}
        {:ok, record} -> {:cont, {:ok, [record | classified]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_ledger_entry(design2, entry, native) do
    case safe_callback(design2, :classify_managed_publish, [entry, native]) do
      :not_managed -> :not_managed
      {:ok, record} -> validate_classified_record(record)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :design2_projection_invalid}
    end
  end

  defp validate_classified_record(record) do
    case validate_slot_record(record) do
      :ok -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_slot_record(%{slot: slot, state: state, identity: identity, reconciliation: reconciliation}) do
    cond do
      not valid_slot?(slot) -> {:error, :design2_projection_invalid_slot}
      state not in @slot_states -> {:error, :design2_projection_invalid_state}
      not is_map(identity) -> {:error, :design2_projection_invalid_identity}
      not is_map(reconciliation) -> {:error, :design2_projection_invalid_reconciliation}
      true -> :ok
    end
  end

  defp validate_slot_record(_record), do: {:error, :design2_projection_invalid}

  defp valid_slot?(slot), do: slot in @automatic_slots or valid_human_slot?(slot)

  defp valid_human_slot?({:human, request_id, comment_id, actor_id}) do
    Enum.all?([request_id, comment_id, actor_id], &(is_binary(&1) and byte_size(&1) > 0))
  end

  defp valid_human_slot?(_slot), do: false

  defp index_slots(records) do
    Enum.reduce_while(records, {:ok, %{automatic: %{}, human: []}}, fn
      %{slot: slot} = record, {:ok, %{automatic: automatic} = projection} when slot in @automatic_slots ->
        if Map.has_key?(automatic, slot) do
          {:halt, {:error, :duplicate_managed_slot}}
        else
          {:cont, {:ok, %{projection | automatic: Map.put(automatic, slot, record)}}}
        end

      %{slot: {:human, _request_id, comment_id, _actor_id}} = record, {:ok, %{human: human} = projection} ->
        duplicate? =
          Enum.any?(human, fn %{slot: {:human, _existing_request, existing_comment, _existing_actor}} ->
            existing_comment == comment_id
          end)

        if duplicate? do
          {:halt, {:error, :duplicate_managed_slot}}
        else
          {:cont, {:ok, %{projection | human: human ++ [record]}}}
        end
    end)
  end

  defp validate_slot_relationships(%{automatic: automatic, human: human}) do
    initial = Map.get(automatic, :automatic_initial_v1)
    correction = Map.get(automatic, :automatic_correction_v1)

    cond do
      not is_nil(correction) and not consumed_slot?(initial) ->
        {:error, :design3_slot_transition_conflict}

      human != [] and not consumed_slot?(initial) ->
        {:error, :design3_slot_transition_conflict}

      human != [] and not human_correction_history_allowed?(correction) ->
        {:error, :design3_slot_transition_conflict}

      true ->
        :ok
    end
  end

  defp consumed_slot?(%{state: :consumed}), do: true
  defp consumed_slot?(_slot), do: false

  defp human_correction_history_allowed?(nil), do: true

  defp human_correction_history_allowed?(%{state: state}) when state in [:available, :consumed],
    do: true

  defp human_correction_history_allowed?(_slot), do: false

  defp reject_conflicts(%{automatic: automatic, human: human}) do
    if Enum.any?(Map.values(automatic) ++ human, &(&1.state == :blocked_conflict)) do
      {:error, :managed_publish_conflict}
    else
      :ok
    end
  end

  defp pending_reconciliation(%{automatic: automatic, human: human}) do
    candidates =
      Enum.map([:automatic_initial_v1, :automatic_correction_v1], &Map.get(automatic, &1)) ++ human

    case Enum.find(candidates, fn
           %{state: state} when state in [:reserved_unresolved, :reserved_failed_no_effect] -> true
           _record -> false
         end) do
      nil -> {:ok, :none}
      %{slot: slot} = record -> {:ok, {:some, reconciliation_evidence(record, slot)}}
    end
  end

  defp reconciliation_evidence(%{state: state, reconciliation: reconciliation}, slot) do
    reconciliation
    |> Map.put(:slot, slot)
    |> Map.put(:slot_state, state)
  end

  defp route_available_slot(
         input,
         finding_keys,
         records,
         human_slots,
         ledger_entries,
         evidence,
         design2,
         dependencies
       ) do
    case Map.get(records, :automatic_initial_v1) do
      nil ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, evidence, design2, dependencies)

      %{state: :available} ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, evidence, design2, dependencies)

      %{state: :consumed} ->
        route_correction_slot(input, records, human_slots, ledger_entries, evidence, design2, dependencies)
    end
  end

  defp route_correction_slot(input, records, human_slots, ledger_entries, evidence, design2, dependencies) do
    with {:ok, correction_keys} <- verified_correction_keys(input, design2, evidence, ledger_entries),
         true <- correction_keys != [] do
      case Map.get(records, :automatic_correction_v1) do
        nil ->
          issue_automatic_grant(input, correction_keys, :automatic_correction_v1, evidence, design2, dependencies)

        %{state: :available} ->
          issue_automatic_grant(input, correction_keys, :automatic_correction_v1, evidence, design2, dependencies)

        %{state: :consumed} ->
          {:blocked, {:human_authorization_required, human_slots}}
      end
    else
      false -> {:blocked, {:human_authorization_required, human_slots}}
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp verified_correction_keys(input, design2, evidence, ledger_entries) do
    native = Map.get(evidence, :native, %{})

    Enum.reduce_while(input[:eligible_findings], {:ok, []}, fn finding, {:ok, keys} ->
      case verify_correction_finding(finding, design2, native, ledger_entries) do
        :not_candidate -> {:cont, {:ok, keys}}
        {:ok, finding_key} -> {:cont, {:ok, [finding_key | keys]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_correction_finding(%{correction_evidence: nil}, _design2, _native, _ledger_entries),
    do: :not_candidate

  defp verify_correction_finding(
         %{correction_evidence: correction_evidence} = finding,
         design2,
         native,
         ledger_entries
       )
       when is_map(correction_evidence) do
    case safe_callback(design2, :verify_correction, [finding, correction_evidence, native, ledger_entries]) do
      :ok -> {:ok, finding.finding_key}
      {:error, {:conflict, reason}} -> {:error, reason}
      {:error, :correction_conflict} -> {:error, :correction_conflict}
      {:error, :not_candidate} -> :not_candidate
      {:error, {:not_candidate, _reason}} -> :not_candidate
      {:error, reason} -> {:error, {:design2_correction_verification_failed, reason}}
      _other -> {:error, :design2_correction_verification_invalid}
    end
  end

  defp verify_correction_finding(_finding, _design2, _native, _ledger_entries),
    do: {:error, :invalid_correction_evidence}

  defp issue_automatic_grant(input, finding_keys, slot, evidence, design2, dependencies) do
    case current_native_head_matches?(input, evidence, dependencies) do
      :ok -> build_automatic_grant(input, finding_keys, slot, design2)
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp build_automatic_grant(input, finding_keys, slot, design2) do
    context = %{
      repository: input.repository,
      pull_request_number: input.pull_request_number,
      evaluated_head_sha: input.evaluated_head_sha,
      finding_keys: finding_keys,
      slot: slot,
      authorization_identity: Atom.to_string(slot)
    }

    case safe_callback(design2, :managed_publish_identity, [context]) do
      {:ok, identity} when is_map(identity) ->
        case Map.fetch(identity, :expected_transition) do
          {:ok, expected_transition} when is_map(expected_transition) ->
            {:ok,
             %{
               slot: slot,
               finding_keys: finding_keys,
               managed_publish_identity: identity,
               expected_transition: expected_transition
             }}

          _missing ->
            {:blocked, :design2_managed_publish_identity_unavailable}
        end

      {:error, reason} ->
        {:blocked, reason}

      _other ->
        {:blocked, :design2_managed_publish_identity_unavailable}
    end
  end

  defp safe_callback(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _error -> {:error, :design2_callback_failed}
  end

  defp route_human_authorization(
         {:blocked, {:human_authorization_required, human_slots}},
         input,
         finding_keys,
         finding_set_digest,
         evidence,
         effect_scope,
         dependencies
       ) do
    authority_policy = Map.get(dependencies, :authority_policy)

    with {:ok, evidence} <- prune_historical_human_evidence(evidence, human_slots),
         {:ok, policy_version} <- authority_policy_version(authority_policy),
         {:ok, active_request} <-
           active_request(
             evidence,
             input,
             finding_set_digest,
             policy_version,
             Map.get(dependencies, :managed_request_provenance)
           ) do
      case active_request do
        nil ->
          create_authorization_request(
            input,
            finding_keys,
            finding_set_digest,
            policy_version,
            evidence,
            effect_scope,
            dependencies
          )

        request ->
          bind_human_approval(
            request,
            input,
            finding_keys,
            finding_set_digest,
            policy_version,
            evidence,
            dependencies
          )
      end
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp route_human_authorization(result, _input, _finding_keys, _digest, _evidence, _scope, _dependencies),
    do: result

  defp authority_policy_version(policy) when is_atom(policy) do
    if Code.ensure_loaded?(policy) and function_exported?(policy, :version, 0) and
         function_exported?(policy, :authorize_human_actor, 1) do
      case safe_external_callback(policy, :version, []) do
        {:ok, version} when is_binary(version) and byte_size(version) > 0 -> {:ok, version}
        _other -> {:error, :authorization_policy_unavailable}
      end
    else
      {:error, :authorization_policy_unavailable}
    end
  end

  defp authority_policy_version(_policy), do: {:error, :authorization_policy_unavailable}

  defp active_request(
         %{active_requests: requests},
         input,
         finding_set_digest,
         policy_version,
         provenance_policy
       )
       when is_list(requests) do
    with {:ok, current_requests} <-
           current_requests(
             requests,
             input,
             finding_set_digest,
             policy_version,
             provenance_policy
           ) do
      case current_requests do
        [] -> {:ok, nil}
        [request] -> {:ok, request}
        [_ | _] -> {:error, :ambiguous_active_request}
      end
    end
  end

  defp current_requests(requests, input, finding_set_digest, policy_version, provenance_policy) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, current} ->
      case active_request_status(request, input, finding_set_digest, policy_version, provenance_policy) do
        :stale -> {:cont, {:ok, current}}
        {:current, request} -> {:cont, {:ok, [request | current]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, current} -> {:ok, Enum.reverse(current)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_request_status(request, input, finding_set_digest, policy_version, provenance_policy)
       when is_map(request) do
    with :ok <- verify_managed_request_provenance(provenance_policy, request) do
      current_snapshot? =
        request[:repository] == input.repository and
          request[:pull_request_number] == input.pull_request_number and
          request[:evaluated_head_sha] == input.evaluated_head_sha and
          request[:eligible_finding_set_digest] == finding_set_digest and
          request[:policy_version] == policy_version

      cond do
        not current_snapshot? ->
          :stale

        not valid_request_shape?(request) ->
          {:error, :invalid_authorization_request}

        not canonical_request_identity?(request) ->
          {:error, :authorization_request_identity_mismatch}

        true ->
          {:current, request}
      end
    end
  end

  defp verify_managed_request_provenance(policy, request) when is_atom(policy) do
    if Code.ensure_loaded?(policy) and function_exported?(policy, :verify_managed_request, 1) do
      case safe_external_callback(policy, :verify_managed_request, [request]) do
        :verified -> :ok
        :unverified -> {:error, :authorization_request_provenance_unverified}
        _other -> {:error, :authorization_request_provenance_unavailable}
      end
    else
      {:error, :authorization_request_provenance_unavailable}
    end
  end

  defp verify_managed_request_provenance(_policy, _request),
    do: {:error, :authorization_request_provenance_unavailable}

  defp prune_historical_human_evidence(evidence, human_slots) do
    with {:ok, active_requests} <- fetch_active_requests(evidence),
         {:ok, used_approval_comment_ids} <- fetch_used_approval_ids(evidence) do
      historical_request_ids =
        human_slots
        |> Enum.map(fn %{slot: {:human, request_id, _comment_id, _actor_id}} -> request_id end)
        |> MapSet.new()

      used_comment_ids =
        Enum.reduce(human_slots, MapSet.new(), fn
          %{slot: {:human, _request_id, comment_id, _actor_id}}, used_ids ->
            MapSet.put(used_ids, comment_id)
        end)

      with {:ok, active_requests} <-
             remove_historical_requests(active_requests, historical_request_ids) do
        {:ok,
         evidence
         |> Map.put(:active_requests, active_requests)
         |> Map.put(:used_approval_comment_ids, MapSet.union(used_approval_comment_ids, used_comment_ids))}
      end
    end
  end

  defp remove_historical_requests(active_requests, historical_request_ids) do
    Enum.reduce_while(active_requests, {:ok, []}, fn request, {:ok, kept} ->
      case retain_active_request(request, historical_request_ids, kept) do
        {:ok, kept} -> {:cont, {:ok, kept}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retain_active_request(request, historical_request_ids, kept) when is_map(request) do
    if MapSet.member?(historical_request_ids, request[:request_id]),
      do: {:ok, kept},
      else: {:ok, [request | kept]}
  end

  defp retain_active_request(_request, _historical_request_ids, _kept),
    do: {:error, :invalid_authorization_request}

  defp fetch_active_requests(%{active_requests: requests}) when is_list(requests), do: {:ok, requests}
  defp fetch_active_requests(_evidence), do: {:error, :authorization_evidence_unavailable}

  defp fetch_used_approval_ids(%{used_approval_comment_ids: ids}) when is_struct(ids, MapSet), do: {:ok, ids}
  defp fetch_used_approval_ids(_evidence), do: {:error, :authorization_evidence_unavailable}

  defp create_authorization_request(
         input,
         finding_keys,
         finding_set_digest,
         policy_version,
         evidence,
         effect_scope,
         dependencies
       ) do
    request = build_authorization_request(input, finding_keys, finding_set_digest, policy_version)

    with :ok <- current_native_head_matches?(input, evidence, dependencies),
         :ok <- execute_authorization_request_effect(request, effect_scope, dependencies) do
      {:authorization_required, request}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp build_authorization_request(input, finding_keys, finding_set_digest, policy_version) do
    request_id =
      stable_digest({
        :symphony_authorization_request_v1,
        input.repository,
        input.pull_request_number,
        input.evaluated_head_sha,
        finding_set_digest,
        policy_version
      })

    request_without_fingerprint = %{
      request_id: request_id,
      repository: input.repository,
      pull_request_number: input.pull_request_number,
      evaluated_head_sha: input.evaluated_head_sha,
      eligible_finding_set_digest: finding_set_digest,
      eligible_finding_keys: finding_keys,
      policy_version: policy_version,
      human_summary: input.human_summary,
      expected_transition: %{head_sha: input.evaluated_head_sha}
    }

    Map.put(
      request_without_fingerprint,
      :request_fingerprint,
      stable_digest({
        :symphony_authorization_request_fingerprint_v1,
        request_fingerprint_payload(request_without_fingerprint)
      })
    )
  end

  defp request_fingerprint_payload(request) do
    Map.drop(request, [
      :request_fingerprint,
      :created_at,
      :eligible_finding_keys,
      :authorization_request_author,
      :authorization_request_comment_id,
      :authorization_request_created_at
    ])
  end

  defp current_native_head_matches?(input, %{native: %{current_head_sha: evidence_head}}, dependencies)
       when is_binary(evidence_head) do
    with :ok <- validate_native_head(evidence_head),
         {:ok, current_head} <- read_current_native_head(input, dependencies) do
      cond do
        current_head != input.evaluated_head_sha -> {:error, :authorization_request_stale}
        evidence_head != input.evaluated_head_sha -> {:error, :authorization_request_stale}
        true -> :ok
      end
    end
  end

  defp current_native_head_matches?(_input, _evidence, _dependencies),
    do: {:error, :authorization_current_head_unavailable}

  defp validate_native_head(head) when is_binary(head) do
    if valid_head_sha?(head), do: :ok, else: {:error, :authorization_current_head_unavailable}
  end

  defp validate_native_head(_head), do: {:error, :authorization_current_head_unavailable}

  defp read_current_native_head(input, %{native_head_reader: reader}) when is_atom(reader) do
    with :ok <- validate_native_head_reader(reader),
         {:ok, head} <- safe_external_callback(reader, :current_head, [input.repository, input.pull_request_number]),
         :ok <- validate_native_head(head) do
      {:ok, head}
    else
      _error -> {:error, :authorization_current_head_unavailable}
    end
  end

  defp read_current_native_head(_input, _dependencies),
    do: {:error, :authorization_current_head_unavailable}

  defp validate_native_head_reader(reader) do
    if Code.ensure_loaded?(reader) and function_exported?(reader, :current_head, 2),
      do: :ok,
      else: {:error, :authorization_current_head_unavailable}
  end

  defp execute_authorization_request_effect(request, effect_scope, dependencies) do
    with {:ok, context} <- authorization_effect_context(request, effect_scope),
         :ok <- validate_effect_dependencies(dependencies) do
      effect_ledger = dependencies.effect_ledger
      github = dependencies.github
      connection = effect_scope.connection
      managed_request_provenance = Map.get(dependencies, :managed_request_provenance)

      result =
        safe_external_callback(effect_ledger, :execute, [
          connection,
          :github_comment,
          context,
          fn ->
            github
            |> safe_external_callback(
              :create_authorization_request,
              [request.repository, request.pull_request_number, request]
            )
            |> normalize_effect_adapter_result()
          end,
          fn ->
            github
            |> safe_external_callback(
              :find_authorization_request,
              [request.repository, request.pull_request_number, request]
            )
            |> normalize_effect_reconciler_result(managed_request_provenance)
          end
        ])

      case result do
        {:ok, _resource} ->
          :ok

        {:error, :operation_fingerprint_conflict} ->
          {:error, :operation_fingerprint_conflict}

        {:error, {:operation_fingerprint_conflict, _details}} ->
          {:error, :operation_fingerprint_conflict}

        {:error, reason} ->
          {:error, {:authorization_request_effect_failed, reason}}

        _other ->
          {:error, :authorization_request_effect_invalid}
      end
    end
  end

  defp authorization_effect_context(request, %{connection: _connection, claim_context: claim_context})
       when is_map(claim_context) do
    required = [:issue_id, :claim_id, :generation, :node_id, :node_instance_id]

    if Enum.all?(required, &Map.has_key?(claim_context, &1)) do
      {:ok,
       %{
         operation_id: "symphony_authorization_request_v1:" <> request.request_id,
         request_fingerprint: request.request_fingerprint,
         issue_id: claim_context.issue_id,
         claim_id: claim_context.claim_id,
         generation: claim_context.generation,
         node_id: claim_context.node_id,
         node_instance_id: claim_context.node_instance_id
       }}
    else
      {:error, :authorization_claim_context_unavailable}
    end
  end

  defp validate_effect_dependencies(%{effect_ledger: effect_ledger, github: github}) do
    if is_atom(effect_ledger) and is_atom(github) and
         Code.ensure_loaded?(effect_ledger) and Code.ensure_loaded?(github) and
         function_exported?(effect_ledger, :execute, 5) and
         function_exported?(github, :create_authorization_request, 3) and
         function_exported?(github, :find_authorization_request, 3) do
      :ok
    else
      {:error, :authorization_effect_unavailable}
    end
  end

  defp validate_effect_dependencies(_dependencies), do: {:error, :authorization_effect_unavailable}

  defp normalize_effect_adapter_result({:ok, resource}), do: {:ok, resource}
  defp normalize_effect_adapter_result({:error, :no_effect, reason}), do: {:error, :no_effect, reason}
  defp normalize_effect_adapter_result({:error, :unknown, reason}), do: {:error, :unknown, reason}
  defp normalize_effect_adapter_result({:error, reason}), do: {:error, :unknown, reason}
  defp normalize_effect_adapter_result(other), do: {:error, :unknown, {:invalid_adapter_result, other}}

  defp normalize_effect_reconciler_result(:not_found, _provenance_policy), do: :not_found

  defp normalize_effect_reconciler_result({:found, resource}, provenance_policy) do
    case verify_managed_request_provenance(provenance_policy, resource) do
      :ok -> {:found, resource}
      {:error, reason} -> {:unknown, reason}
    end
  end

  defp normalize_effect_reconciler_result({:unknown, reason}, _provenance_policy),
    do: {:unknown, reason}

  defp normalize_effect_reconciler_result({:error, reason}, _provenance_policy),
    do: {:unknown, reason}

  defp normalize_effect_reconciler_result(other, _provenance_policy),
    do: {:unknown, {:invalid_reconciler_result, other}}

  defp bind_human_approval(
         request,
         input,
         finding_keys,
         finding_set_digest,
         policy_version,
         evidence,
         dependencies
       ) do
    with :ok <- validate_request_binding(request, input, finding_keys, finding_set_digest, policy_version),
         :ok <- current_native_head_matches?(input, evidence, dependencies),
         {:ok, approval} <-
           find_approval(evidence, request, Map.get(dependencies, :authority_policy)),
         :ok <- validate_approval_command(approval),
         {:ok, actor_id} <- approval_actor_id(approval),
         :ok <- validate_unused_approval(evidence, approval),
         :ok <- authorize_human_actor(Map.get(dependencies, :authority_policy), request, approval, actor_id),
         {:ok, identity} <-
           request_human_identity(
             request,
             approval,
             actor_id,
             input,
             finding_keys,
             dependencies.design2
           ),
         :ok <- validate_expected_transition(request, identity) do
      slot = {:human, request.request_id, approval.comment_id, actor_id}
      expected_transition = Map.fetch!(identity, :expected_transition)

      {:ok,
       %{
         slot: slot,
         request: request,
         finding_keys: finding_keys,
         managed_publish_identity: identity,
         expected_transition: expected_transition
       }}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp validate_expected_transition(%{expected_transition: expected}, %{expected_transition: expected}),
    do: :ok

  defp validate_expected_transition(_request, _identity),
    do: {:error, :authorization_transition_mismatch}

  defp validate_request_binding(request, input, finding_keys, finding_set_digest, policy_version)
       when is_map(request) do
    with :ok <- validate_request_scope(request, input),
         :ok <- validate_request_head(request, input),
         :ok <- validate_request_finding_set(request, finding_keys, finding_set_digest),
         :ok <- validate_request_policy(request, policy_version),
         :ok <- validate_request_shape(request) do
      validate_canonical_request_identity(request)
    end
  end

  defp validate_request_scope(request, input) do
    if request[:repository] == input.repository and
         request[:pull_request_number] == input.pull_request_number do
      :ok
    else
      {:error, :authorization_request_scope_mismatch}
    end
  end

  defp validate_request_head(request, input) do
    if request[:evaluated_head_sha] == input.evaluated_head_sha,
      do: :ok,
      else: {:error, :authorization_request_stale}
  end

  defp validate_request_finding_set(request, _finding_keys, finding_set_digest) do
    if request[:eligible_finding_set_digest] == finding_set_digest do
      :ok
    else
      {:error, :authorization_finding_set_changed}
    end
  end

  defp validate_request_policy(request, policy_version) do
    if request[:policy_version] == policy_version,
      do: :ok,
      else: {:error, :authorization_policy_unavailable}
  end

  defp validate_request_shape(request) do
    if valid_request_shape?(request),
      do: :ok,
      else: {:error, :invalid_authorization_request}
  end

  defp valid_request_shape?(request) do
    Enum.all?(
      [:request_id, :request_fingerprint, :policy_version, :eligible_finding_keys],
      &(is_binary(request[&1]) or (is_list(request[&1]) and request[&1] != []))
    )
  end

  defp validate_canonical_request_identity(request) do
    if canonical_request_identity?(request),
      do: :ok,
      else: {:error, :authorization_request_identity_mismatch}
  end

  defp canonical_request_identity?(request) do
    expected_request_id =
      stable_digest({
        :symphony_authorization_request_v1,
        request[:repository],
        request[:pull_request_number],
        request[:evaluated_head_sha],
        request[:eligible_finding_set_digest],
        request[:policy_version]
      })

    expected_fingerprint =
      stable_digest({
        :symphony_authorization_request_fingerprint_v1,
        request_fingerprint_payload(request)
      })

    request.request_id == expected_request_id and request.request_fingerprint == expected_fingerprint
  end

  defp find_approval(%{comments: comments, used_approval_comment_ids: used_ids}, request, policy)
       when is_list(comments) and is_struct(used_ids, MapSet) do
    with {:ok, request_created_at} <- request_created_at(request),
         {:ok, candidates} <- approvals_after_request(comments, request_created_at) do
      case candidates do
        [] ->
          {:error, :authorization_approval_pending}

        candidates ->
          select_eligible_approval(candidates, used_ids, policy, request)
      end
    end
  end

  defp find_approval(_evidence, _request, _policy), do: {:error, :authorization_evidence_unavailable}

  defp select_eligible_approval(candidates, used_ids, policy, request) do
    candidates
    |> Enum.reduce_while({:ok, false}, fn approval, state ->
      reduce_approval_candidate(approval, state, used_ids, policy, request)
    end)
    |> finalize_approval_selection()
  end

  defp reduce_approval_candidate(approval, state, used_ids, policy, request) do
    case evaluate_approval_candidate(approval, used_ids, policy, request) do
      :used -> {:cont, state}
      :unauthorized -> {:cont, mark_unauthorized(state)}
      {:selected, selected} -> {:halt, {:selected, selected}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_approval_selection(result) do
    case result do
      {:selected, approval} -> {:ok, approval}
      {:error, reason} -> {:error, reason}
      {:ok, true} -> {:error, :unauthorized_actor}
      {:ok, false} -> {:error, :approval_comment_already_used}
    end
  end

  defp evaluate_approval_candidate(approval, used_ids, policy, request) do
    if unused_approval?(approval, used_ids),
      do: authorize_approval_candidate(approval, policy, request),
      else: :used
  end

  defp authorize_approval_candidate(approval, policy, request) do
    case approval_actor_id(approval) do
      {:ok, actor_id} ->
        case authorize_human_actor(policy, request, approval, actor_id) do
          :ok -> {:selected, approval}
          {:error, :unauthorized_actor} -> :unauthorized
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :authorization_actor_unknown}
    end
  end

  defp mark_unauthorized({:ok, _unauthorized_seen?}), do: {:ok, true}

  defp unused_approval?(%{comment_id: comment_id}, used_ids) when is_binary(comment_id),
    do: not MapSet.member?(used_ids, comment_id)

  defp unused_approval?(_approval, _used_ids), do: true

  defp request_created_at(%{authorization_request_created_at: created_at}),
    do: parse_timestamp(created_at, :authorization_request_provenance_unavailable)

  defp request_created_at(%{created_at: created_at}),
    do: parse_timestamp(created_at, :authorization_request_provenance_unavailable)

  defp request_created_at(_request),
    do: {:error, :authorization_request_provenance_unavailable}

  defp approvals_after_request(comments, request_created_at) do
    Enum.reduce_while(comments, {:ok, []}, fn approval, {:ok, candidates} ->
      with :ok <- validate_approval_shape(approval),
           {:ok, candidates} <- approval_candidate(approval, request_created_at, candidates) do
        {:cont, {:ok, candidates}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approval_candidate(%{created_at: created_at} = approval, request_created_at, candidates) do
    with {:ok, approval_created_at} <- parse_timestamp(created_at, :invalid_authorization_approval) do
      if DateTime.compare(approval_created_at, request_created_at) == :gt,
        do: {:ok, [approval | candidates]},
        else: {:ok, candidates}
    end
  end

  defp approval_candidate(approval, _request_created_at, candidates),
    do: {:ok, [approval | candidates]}

  defp validate_approval_shape(%{body: body, actor: actor})
       when is_binary(body) and is_map(actor),
       do: :ok

  defp validate_approval_shape(_approval), do: {:error, :invalid_authorization_approval}

  defp parse_timestamp(value, error) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _other -> {:error, error}
    end
  end

  defp parse_timestamp(_value, error), do: {:error, error}

  defp validate_approval_command(%{body: body}) when is_binary(body) do
    if String.trim(body) == "批准再修一輪",
      do: :ok,
      else: {:error, :invalid_authorization_command}
  end

  defp approval_actor_id(%{actor: %{id: actor_id}}) when is_binary(actor_id) and byte_size(actor_id) > 0,
    do: {:ok, actor_id}

  defp approval_actor_id(_approval), do: {:error, :authorization_actor_unknown}

  defp validate_unused_approval(%{used_approval_comment_ids: used_ids}, %{comment_id: comment_id})
       when is_struct(used_ids, MapSet) and is_binary(comment_id) do
    if MapSet.member?(used_ids, comment_id),
      do: {:error, :approval_comment_already_used},
      else: :ok
  end

  defp validate_unused_approval(_evidence, _approval),
    do: {:error, :authorization_approval_identity_unavailable}

  defp authorize_human_actor(policy, request, approval, actor_id) do
    case safe_external_callback(policy, :authorize_human_actor, [
           %{request: request, approval: approval, actor_id: actor_id}
         ]) do
      :authorized -> :ok
      :unauthorized -> {:error, :unauthorized_actor}
      _other -> {:error, :authorization_policy_unavailable}
    end
  end

  defp request_human_identity(request, approval, actor_id, input, finding_keys, design2) do
    authorization_identity =
      stable_digest({:symphony_human_authorization_v1, request.request_id, approval.comment_id, actor_id})

    context = %{
      repository: input.repository,
      pull_request_number: input.pull_request_number,
      evaluated_head_sha: input.evaluated_head_sha,
      finding_keys: finding_keys,
      slot: {:human, request.request_id, approval.comment_id, actor_id},
      authorization_identity: authorization_identity,
      request_id: request.request_id,
      approval_comment_id: approval.comment_id,
      actor_id: actor_id
    }

    case safe_callback(design2, :managed_publish_identity, [context]) do
      {:ok, identity} when is_map(identity) ->
        if is_map(identity[:expected_transition]),
          do: {:ok, identity},
          else: {:error, :design2_managed_publish_identity_unavailable}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :design2_managed_publish_identity_unavailable}
    end
  end

  defp safe_external_callback(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _error -> {:error, :external_callback_failed}
  end

  defp stable_digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp valid_head_sha?(head), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, head)
end
