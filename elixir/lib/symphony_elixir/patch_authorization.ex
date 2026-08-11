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
         :ok <- validate_design2_digest(dependencies.design2, finding_keys) do
      project_authorization(input, finding_keys, ledger_entries, evidence, dependencies)
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
      :ok
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
      if is_map(finding) do
        with {:ok, finding_key} <- Map.fetch(finding, :finding_key),
             :ok <- validate_finding_disposition(finding),
             :ok <- validate_finding_head(finding, evaluated_head) do
          if MapSet.member?(finding_keys, finding_key) do
            {:halt, {:error, :duplicate_finding_key}}
          else
            {:cont, MapSet.put(finding_keys, finding_key)}
          end
        else
          :error -> {:halt, {:error, :missing_finding_key}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:halt, {:error, :invalid_finding_shape}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_findings(_input), do: {:error, :missing_eligible_findings}

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
    {:ok, Enum.map(findings, &Map.fetch!(&1, :finding_key))}
  rescue
    KeyError -> {:error, :missing_finding_key}
  end

  defp validate_design2_digest(design2, finding_keys) do
    case design2.finding_set_digest(finding_keys) do
      {:ok, digest} when is_binary(digest) and byte_size(digest) > 0 -> :ok
      _ -> {:error, :design2_finding_set_digest_unavailable}
    end
  rescue
    _error -> {:error, :design2_finding_set_digest_unavailable}
  end

  defp project_authorization(input, finding_keys, ledger_entries, evidence, dependencies) do
    design2 = dependencies.design2

    with :ok <- validate_projection_contract(design2),
         {:ok, classified} <- classify_ledger_entries(design2, ledger_entries, evidence),
         {:ok, records} <- index_automatic_slots(classified),
         :ok <- reject_conflicts(records),
         {:ok, reconciliation} <- pending_reconciliation(records) do
      case reconciliation do
        {:some, evidence} -> {:reconcile, evidence}
        :none -> route_available_slot(input, finding_keys, records, ledger_entries, evidence, design2)
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
      case safe_callback(design2, :classify_managed_publish, [entry, native]) do
        :not_managed ->
          {:cont, {:ok, classified}}

        {:ok, record} ->
          case validate_slot_record(record) do
            :ok -> {:cont, {:ok, [record | classified]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}

        _other ->
          {:halt, {:error, :design2_projection_invalid}}
      end
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
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

  defp index_automatic_slots(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn
      %{slot: slot} = record, {:ok, slots} when slot in @automatic_slots ->
        if Map.has_key?(slots, slot) do
          {:halt, {:error, :duplicate_managed_slot}}
        else
          {:cont, {:ok, Map.put(slots, slot, record)}}
        end

      _human_record, {:ok, slots} ->
        {:cont, {:ok, slots}}
    end)
  end

  defp reject_conflicts(records) do
    if Enum.any?(Map.values(records), &(&1.state == :blocked_conflict)) do
      {:error, :managed_publish_conflict}
    else
      :ok
    end
  end

  defp pending_reconciliation(records) do
    case Enum.find([:automatic_initial_v1, :automatic_correction_v1], fn slot ->
           case Map.get(records, slot) do
             %{state: state} when state in [:reserved_unresolved, :reserved_failed_no_effect] -> true
             _record -> false
           end
         end) do
      nil -> {:ok, :none}
      slot -> {:ok, {:some, reconciliation_evidence(records[slot], slot)}}
    end
  end

  defp reconciliation_evidence(%{state: state, reconciliation: reconciliation}, slot) do
    reconciliation
    |> Map.put(:slot, slot)
    |> Map.put(:slot_state, state)
  end

  defp route_available_slot(input, finding_keys, records, ledger_entries, evidence, design2) do
    case Map.get(records, :automatic_initial_v1) do
      nil ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, design2)

      %{state: :available} ->
        issue_automatic_grant(input, finding_keys, :automatic_initial_v1, design2)

      %{state: :consumed} ->
        route_correction_slot(input, records, ledger_entries, evidence, design2)

      %{state: state} ->
        {:blocked, {:unsupported_initial_slot_state, state}}
    end
  end

  defp route_correction_slot(input, records, ledger_entries, evidence, design2) do
    with {:ok, correction_keys} <- verified_correction_keys(input, design2, evidence, ledger_entries),
         true <- correction_keys != [] do
      case Map.get(records, :automatic_correction_v1) do
        nil -> issue_automatic_grant(input, correction_keys, :automatic_correction_v1, design2)
        %{state: :available} -> issue_automatic_grant(input, correction_keys, :automatic_correction_v1, design2)
        %{state: :consumed} -> {:blocked, :human_authorization_required}
        %{state: state} -> {:blocked, {:unsupported_correction_slot_state, state}}
      end
    else
      false -> {:blocked, :human_authorization_required}
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp verified_correction_keys(input, design2, evidence, ledger_entries) do
    native = Map.get(evidence, :native, %{})

    Enum.reduce_while(input[:eligible_findings], {:ok, []}, fn finding, {:ok, keys} ->
      case Map.get(finding, :correction_evidence) do
        nil ->
          {:cont, {:ok, keys}}

        correction_evidence when is_map(correction_evidence) ->
          case safe_callback(design2, :verify_correction, [finding, correction_evidence, native, ledger_entries]) do
            :ok -> {:cont, {:ok, [finding.finding_key | keys]}}
            {:error, {:conflict, reason}} -> {:halt, {:error, reason}}
            {:error, :correction_conflict} -> {:halt, {:error, :correction_conflict}}
            {:error, _reason} -> {:cont, {:ok, keys}}
            _other -> {:halt, {:error, :design2_correction_verification_invalid}}
          end

        _malformed ->
          {:halt, {:error, :invalid_correction_evidence}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp valid_head_sha?(head), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, head)
end
