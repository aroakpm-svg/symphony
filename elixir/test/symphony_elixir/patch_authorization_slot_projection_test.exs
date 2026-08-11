defmodule SymphonyElixir.PatchAuthorization.SlotProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PatchAuthorization.SlotProjection

  @automatic_initial :automatic_initial_v1
  @automatic_correction :automatic_correction_v1

  test "reconstructs deterministic automatic and human slot projections" do
    records = [
      record({:human, "request-2", "comment-2", "actor-2"}, :consumed),
      record(@automatic_correction, :available),
      record(@automatic_initial, :consumed),
      record({:human, "request-1", "comment-1", "actor-1"}, :consumed)
    ]

    assert {:ok, projection} = SlotProjection.project(records)

    assert Map.keys(projection.automatic) |> MapSet.new() ==
             MapSet.new([@automatic_correction, @automatic_initial])

    assert Enum.map(projection.human, & &1.slot) == [
             {:human, "request-1", "comment-1", "actor-1"},
             {:human, "request-2", "comment-2", "actor-2"}
           ]

    assert projection.pending == :none
  end

  test "selects the first deterministic unresolved slot for reconciliation" do
    records = [
      record(@automatic_initial, :reserved_failed_no_effect)
    ]

    assert {:ok, %{pending: {:some, pending}}} = SlotProjection.project(records)
    assert pending.slot == @automatic_initial
    assert pending.slot_state == :reserved_failed_no_effect
  end

  test "accepts every bounded slot state" do
    states = [:available, :reserved_unresolved, :consumed, :reserved_failed_no_effect]

    for state <- states do
      result = SlotProjection.project([record(@automatic_initial, state)])

      assert {:ok, %{automatic: %{@automatic_initial => %{state: ^state}}}} = result
    end

    assert {:error, :slot_conflict} = SlotProjection.project([record(@automatic_initial, :blocked_conflict)])
  end

  test "blocks correction or human history without a consumed initial predecessor" do
    assert {:error, :slot_transition_conflict} =
             SlotProjection.project([record(@automatic_correction, :consumed)])

    assert {:error, :slot_transition_conflict} =
             SlotProjection.project([record({:human, "request-1", "comment-1", "actor-1"}, :consumed)])
  end

  test "blocks human history while correction remains unresolved" do
    records = [
      record(@automatic_initial, :consumed),
      record(@automatic_correction, :reserved_unresolved),
      record({:human, "request-1", "comment-1", "actor-1"}, :consumed)
    ]

    assert {:error, :slot_transition_conflict} = SlotProjection.project(records)
  end

  test "allows human history when correction was absent or available" do
    human = record({:human, "request-1", "comment-1", "actor-1"}, :consumed)
    initial = record(@automatic_initial, :consumed)

    assert {:ok, _projection} = SlotProjection.project([human, initial])

    assert {:ok, _projection} =
             SlotProjection.project([human, initial, record(@automatic_correction, :available)])
  end

  test "blocks duplicate slots, duplicate human approval IDs, and conflicts" do
    assert {:error, :duplicate_slot} =
             SlotProjection.project([record(@automatic_initial, :available), record(@automatic_initial, :consumed)])

    duplicate_comment = {:human, "request-2", "comment-1", "actor-2"}

    assert {:error, :duplicate_slot} =
             SlotProjection.project([
               record({:human, "request-1", "comment-1", "actor-1"}, :consumed),
               record(duplicate_comment, :consumed),
               record(@automatic_initial, :consumed)
             ])

    assert {:error, :slot_conflict} = SlotProjection.project([record(@automatic_initial, :blocked_conflict)])
  end

  test "rejects malformed records and slot identities" do
    assert {:error, :invalid_projection_records} = SlotProjection.project(:not_a_list)
    assert {:error, :invalid_projection_record} = SlotProjection.project([:not_a_record])
    assert {:error, :invalid_slot} = SlotProjection.project([record(:unknown, :available)])
    assert {:error, :invalid_slot} = SlotProjection.project([record({:human, 1, "comment-1", "actor-1"}, :available)])
    assert {:error, :invalid_slot_state} = SlotProjection.project([record(@automatic_initial, :unknown)])
    assert {:error, :invalid_slot_identity} = SlotProjection.project([record({:human, "", "comment-1", "actor-1"}, :available)])
    assert {:error, :invalid_slot_identity} = SlotProjection.project([record({:human, "request-1", "", "actor-1"}, :available)])

    assert {:error, :invalid_slot_identity} =
             SlotProjection.project([record({:human, "request-1", "comment-1", ""}, :available)])

    assert {:error, :invalid_projection_identity} =
             SlotProjection.project([%{slot: @automatic_initial, state: :available}])

    assert {:error, :invalid_projection_reconciliation} =
             SlotProjection.project([%{slot: @automatic_initial, state: :available, identity: %{}}])
  end

  defp record(slot, state) do
    %{slot: slot, state: state, identity: %{opaque: slot}, reconciliation: %{operation_id: inspect(slot)}}
  end
end
