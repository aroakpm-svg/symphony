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
         :ok <- validate_claim_scope(input, effect_scope) do
      validate_findings(input)
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
            design2
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

      %{slot: {:human, request_id, comment_id, actor_id}} = record, {:ok, %{human: human} = projection} ->
        duplicate? =
          Enum.any?(human, fn %{slot: {:human, existing_request, existing_comment, existing_actor}} ->
            {existing_request, existing_comment, existing_actor} == {request_id, comment_id, actor_id}
          end)

        if duplicate? do
          {:halt, {:error, :duplicate_managed_slot}}
        else
          {:cont, {:ok, %{projection | human: human ++ [record]}}}
        end
    end)
  end

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

  defp route_available_slot(input, finding_keys, records, human_slots, ledger_entries, evidence, design2) do
    case Map.get(records, :automatic_initial_v1) do
      nil ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, design2)

      %{state: :available} ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, design2)

      %{state: :consumed} ->
        route_correction_slot(input, records, human_slots, ledger_entries, evidence, design2)
    end
  end

  defp route_correction_slot(input, records, human_slots, ledger_entries, evidence, design2) do
    with {:ok, correction_keys} <- verified_correction_keys(input, design2, evidence, ledger_entries),
         true <- correction_keys != [] do
      case Map.get(records, :automatic_correction_v1) do
        nil -> issue_automatic_grant(input, correction_keys, :automatic_correction_v1, design2)
        %{state: :available} -> issue_automatic_grant(input, correction_keys, :automatic_correction_v1, design2)
        %{state: :consumed} -> {:blocked, {:human_authorization_required, human_slots}}
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
      {:error, _reason} -> :not_candidate
      _other -> {:error, :design2_correction_verification_invalid}
    end
  end

  defp verify_correction_finding(_finding, _design2, _native, _ledger_entries),
    do: {:error, :invalid_correction_evidence}

  defp issue_automatic_grant(input, finding_keys, slot, design2) do
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
    with {:ok, evidence} <- prune_historical_human_evidence(evidence, human_slots),
         {:ok, policy_version} <- authority_policy_version(dependencies.authority_policy),
         {:ok, active_request} <- active_request(evidence) do
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

  defp active_request(%{active_requests: requests}) when is_list(requests) do
    case requests do
      [] -> {:ok, nil}
      [request] when is_map(request) -> {:ok, request}
      [_ | _] -> {:error, :ambiguous_active_request}
    end
  end

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

      {:ok,
       evidence
       |> Map.put(:active_requests, Enum.reject(active_requests, &MapSet.member?(historical_request_ids, &1[:request_id])))
       |> Map.put(:used_approval_comment_ids, MapSet.union(used_approval_comment_ids, used_comment_ids))}
    end
  end

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

    with :ok <- current_native_head_matches?(input, evidence),
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
        finding_keys,
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
      stable_digest({:symphony_authorization_request_fingerprint_v1, request_without_fingerprint})
    )
  end

  defp current_native_head_matches?(input, %{native: %{current_head_sha: head_sha}})
       when is_binary(head_sha) do
    cond do
      not valid_head_sha?(head_sha) -> {:error, :authorization_current_head_unavailable}
      head_sha != input.evaluated_head_sha -> {:error, :authorization_request_stale}
      true -> :ok
    end
  end

  defp current_native_head_matches?(_input, _evidence),
    do: {:error, :authorization_current_head_unavailable}

  defp execute_authorization_request_effect(request, effect_scope, dependencies) do
    with {:ok, context} <- authorization_effect_context(request, effect_scope),
         :ok <- validate_effect_dependencies(dependencies) do
      effect_ledger = dependencies.effect_ledger
      github = dependencies.github
      connection = effect_scope.connection

      result =
        safe_external_callback(effect_ledger, :execute, [
          connection,
          :github_comment,
          context,
          fn ->
            safe_external_callback(
              github,
              :create_authorization_request,
              [request.repository, request.pull_request_number, request]
            )
          end,
          fn ->
            safe_external_callback(
              github,
              :find_authorization_request,
              [request.repository, request.pull_request_number, request]
            )
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
         {:ok, approval} <- find_approval(evidence),
         :ok <- validate_approval_command(approval),
         {:ok, actor_id} <- approval_actor_id(approval),
         :ok <- validate_unused_approval(evidence, approval),
         :ok <- authorize_human_actor(dependencies.authority_policy, request, approval, actor_id),
         {:ok, identity} <-
           request_human_identity(
             request,
             approval,
             actor_id,
             input,
             finding_keys,
             dependencies.design2
           ) do
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

  defp validate_request_binding(request, input, finding_keys, finding_set_digest, policy_version)
       when is_map(request) do
    cond do
      request[:repository] != input.repository or
          request[:pull_request_number] != input.pull_request_number ->
        {:error, :authorization_request_scope_mismatch}

      request[:evaluated_head_sha] != input.evaluated_head_sha ->
        {:error, :authorization_request_stale}

      request[:eligible_finding_set_digest] != finding_set_digest or
          request[:eligible_finding_keys] != finding_keys ->
        {:error, :authorization_finding_set_changed}

      request[:policy_version] != policy_version ->
        {:error, :authorization_policy_unavailable}

      not valid_request_shape?(request) ->
        {:error, :invalid_authorization_request}

      true ->
        :ok
    end
  end

  defp valid_request_shape?(request) do
    Enum.all?(
      [:request_id, :request_fingerprint, :policy_version, :eligible_finding_keys],
      &(is_binary(request[&1]) or (is_list(request[&1]) and request[&1] != []))
    )
  end

  defp find_approval(%{comments: comments}) when is_list(comments) do
    case comments do
      [] -> {:error, :authorization_approval_pending}
      [approval | _] when is_map(approval) -> {:ok, approval}
      _comments -> {:error, :invalid_authorization_approval}
    end
  end

  defp find_approval(_evidence), do: {:error, :authorization_evidence_unavailable}

  defp validate_approval_command(%{body: body}) when is_binary(body) do
    if String.trim(body) == "批准再修一輪",
      do: :ok,
      else: {:error, :invalid_authorization_command}
  end

  defp validate_approval_command(_approval), do: {:error, :invalid_authorization_command}

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
