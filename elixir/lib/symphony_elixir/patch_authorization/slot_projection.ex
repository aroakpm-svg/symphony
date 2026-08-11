defmodule SymphonyElixir.PatchAuthorization.SlotProjection do
  @moduledoc false

  @automatic_slots [:automatic_initial_v1, :automatic_correction_v1]
  @slot_states [
    :available,
    :reserved_unresolved,
    :consumed,
    :reserved_failed_no_effect,
    :blocked_conflict
  ]
  @unresolved_states [:reserved_unresolved, :reserved_failed_no_effect]

  @type slot ::
          :automatic_initial_v1
          | :automatic_correction_v1
          | {:human, String.t(), String.t(), String.t()}
  @type state ::
          :available
          | :reserved_unresolved
          | :consumed
          | :reserved_failed_no_effect
          | :blocked_conflict
  @type record :: %{slot: slot(), state: state(), identity: map(), reconciliation: map()}
  @type projection :: %{
          automatic: %{optional(slot()) => record()},
          human: [record()],
          pending: :none | {:some, map()}
        }

  @spec project([record()]) :: {:ok, projection()} | {:error, atom()}
  def project(records) when is_list(records) do
    with {:ok, records} <- validate_records(records),
         {:ok, projection} <- index_records(records),
         :ok <- validate_slot_relationships(projection),
         :ok <- reject_conflicts(projection) do
      {:ok, Map.put(projection, :pending, pending_reconciliation(projection))}
    end
  end

  def project(_records), do: {:error, :invalid_projection_records}

  defp validate_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, valid} ->
      case validate_record(record) do
        :ok -> {:cont, {:ok, [record | valid]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.sort_by(valid, &slot_sort_key(&1.slot))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(record) when is_struct(record), do: {:error, :invalid_projection_record}

  defp validate_record(%{slot: slot, state: state} = record) when is_map(record) do
    cond do
      not valid_slot?(slot) -> {:error, :invalid_slot}
      not valid_slot_identity?(slot) -> {:error, :invalid_slot_identity}
      state not in @slot_states -> {:error, :invalid_slot_state}
      not is_map(record[:identity]) -> {:error, :invalid_projection_identity}
      not is_map(record[:reconciliation]) -> {:error, :invalid_projection_reconciliation}
      true -> :ok
    end
  end

  defp validate_record(_record), do: {:error, :invalid_projection_record}

  defp index_records(records) do
    Enum.reduce_while(records, {:ok, %{automatic: %{}, human: []}}, fn record, {:ok, projection} ->
      case record.slot do
        slot when slot in @automatic_slots ->
          add_automatic_record(projection, record, slot)

        {:human, _request_id, comment_id, _actor_id} ->
          add_human_record(projection, record, comment_id)
      end
    end)
  end

  defp add_automatic_record(%{automatic: automatic} = projection, record, slot) do
    if Map.has_key?(automatic, slot) do
      {:halt, {:error, :duplicate_slot}}
    else
      {:cont, {:ok, %{projection | automatic: Map.put(automatic, slot, record)}}}
    end
  end

  defp add_human_record(%{human: human} = projection, record, comment_id) do
    if Enum.any?(human, &(&1.slot |> elem(2) == comment_id)) do
      {:halt, {:error, :duplicate_slot}}
    else
      {:cont, {:ok, %{projection | human: human ++ [record]}}}
    end
  end

  defp validate_slot_relationships(%{automatic: automatic, human: human}) do
    initial = Map.get(automatic, :automatic_initial_v1)
    correction = Map.get(automatic, :automatic_correction_v1)

    cond do
      not is_nil(correction) and not consumed?(initial) ->
        {:error, :slot_transition_conflict}

      human != [] and not consumed?(initial) ->
        {:error, :slot_transition_conflict}

      human != [] and not human_correction_history_allowed?(correction) ->
        {:error, :slot_transition_conflict}

      true ->
        :ok
    end
  end

  defp consumed?(%{state: :consumed}), do: true
  defp consumed?(_record), do: false

  defp human_correction_history_allowed?(nil), do: true
  defp human_correction_history_allowed?(%{state: state}) when state in [:available, :consumed], do: true
  defp human_correction_history_allowed?(_record), do: false

  defp reject_conflicts(%{automatic: automatic, human: human}) do
    if Enum.any?(Map.values(automatic) ++ human, &(&1.state == :blocked_conflict)) do
      {:error, :slot_conflict}
    else
      :ok
    end
  end

  defp pending_reconciliation(%{automatic: automatic, human: human}) do
    candidates =
      Enum.map(@automatic_slots, &Map.get(automatic, &1)) ++ human

    case Enum.find(candidates, &unresolved?/1) do
      nil ->
        :none

      %{slot: slot, state: state, reconciliation: reconciliation} ->
        {:some, Map.merge(reconciliation, %{slot: slot, slot_state: state})}
    end
  end

  defp unresolved?(%{state: state}) when state in @unresolved_states, do: true
  defp unresolved?(_record), do: false

  defp valid_slot?(slot) when slot in @automatic_slots, do: true

  defp valid_slot?({:human, request_id, comment_id, actor_id}) do
    is_binary(request_id) and is_binary(comment_id) and is_binary(actor_id)
  end

  defp valid_slot?(_slot), do: false

  defp valid_slot_identity?(slot) when slot in @automatic_slots, do: true

  defp valid_slot_identity?({:human, request_id, comment_id, actor_id}) do
    Enum.all?([request_id, comment_id, actor_id], &non_empty_string?/1)
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp slot_sort_key(:automatic_initial_v1), do: {0, ""}
  defp slot_sort_key(:automatic_correction_v1), do: {1, ""}

  defp slot_sort_key({:human, request_id, comment_id, actor_id}),
    do: {2, request_id, comment_id, actor_id}
end
