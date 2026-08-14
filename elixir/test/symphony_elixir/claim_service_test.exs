defmodule SymphonyElixir.ClaimServiceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaimService

  test "database calls bind textual UUIDs through text before UUID casts" do
    source = File.read!(Path.expand("../../lib/symphony_elixir/claim_service.ex", __DIR__))

    assert length(Regex.scan(~r/::text::uuid/, source)) == 11
    refute source =~ "DateTime.to_iso8601(updated_at)"
  end

  test "lease deadlines remain anchored before a slow database grant returns" do
    grant_started_ms = System.monotonic_time(:millisecond)
    Process.sleep(5)

    deadline_ms = ClaimService.lease_deadline_for_test(grant_started_ms, 60_000)

    assert deadline_ms == grant_started_ms + 60_000
    assert deadline_ms < System.monotonic_time(:millisecond) + 60_000
  end

  test "claim calls fail closed when the coordinator is absent or exits" do
    assert ClaimService.call_for_test(:claim) == {:error, :claim_service_unavailable}

    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), ClaimService)
        send(parent, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(:coordinator_failed)
        end
      end)

    assert_receive :registered

    assert {:error, {:claim_service_unavailable, reason}} =
             ClaimService.call_for_test(:claim)

    assert inspect(reason) =~ "coordinator_failed"
    refute Process.alive?(pid)
  end

  test "connection exits notify every claim owner before the service stops" do
    connection = self()

    state = %ClaimService{
      connection: connection,
      claims: %{
        "issue-1" => %{owner: self(), lease_deadline_ms: 1},
        "issue-2" => %{owner: self(), lease_deadline_ms: 1}
      }
    }

    assert {:stop, {:connection_lost, :closed}, %{claims: claims}} =
             ClaimService.handle_info({:EXIT, connection, :closed}, state)

    assert claims == %{}
    assert_receive {:claim_lost, "issue-1", {:connection_lost, :closed}}
    assert_receive {:claim_lost, "issue-2", {:connection_lost, :closed}}
  end

  test "claim loss kills a bound worker before notifying its owner" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    state = %ClaimService{
      claims: %{"issue-1" => %{owner: self(), worker: worker, lease_deadline_ms: 1}}
    }

    assert {:stop, :normal, %{claims: %{}}} = ClaimService.handle_info(:heartbeat, state)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:claim_lost, "issue-1", :claim_service_disabled}
  end

  test "claimed, running, blocked, terminal, and restart lifecycle table fails closed" do
    lifecycle = [
      %{state: :claimed, event: :service_restart, retained_claims: 0, fence_worker: false},
      %{state: :running, event: :claim_lost, retained_claims: 0, fence_worker: true},
      %{state: :blocked, event: :worker_blocked, retained_claims: 0, fence_worker: false},
      %{state: :terminal, event: :release_or_complete, retained_claims: 0, fence_worker: false},
      %{state: :running, event: :orchestrator_restart, retained_claims: 0, fence_worker: true}
    ]

    assert Enum.all?(lifecycle, &(&1.retained_claims == 0))

    connection = self()
    claimed_state = %ClaimService{connection: connection, claims: %{"claimed" => %{owner: self()}}}

    assert {:stop, {:connection_lost, :restart}, %{claims: %{}}} =
             ClaimService.handle_info({:EXIT, connection, :restart}, claimed_state)

    assert_receive {:claim_lost, "claimed", {:connection_lost, :restart}}

    running_worker = spawn(fn -> Process.sleep(:infinity) end)
    running_ref = Process.monitor(running_worker)
    running_claim = %{owner: self(), lease_deadline_ms: 1}
    running_state = %ClaimService{claims: %{"running" => running_claim}}

    assert {:reply, :ok, bound_state} =
             ClaimService.handle_call({:bind_worker, "running", running_worker}, self(), running_state)

    assert {:stop, :normal, %{claims: %{}}} = ClaimService.handle_info(:heartbeat, bound_state)
    assert_receive {:DOWN, ^running_ref, :process, ^running_worker, :killed}
    assert_receive {:claim_lost, "running", :claim_service_disabled}

    assert Enum.find(lifecycle, &(&1.event == :worker_blocked)).retained_claims == 0
    assert Enum.find(lifecycle, &(&1.event == :release_or_complete)).retained_claims == 0
    assert Enum.find(lifecycle, &(&1.event == :orchestrator_restart)).fence_worker
  end

  test "disabling coordination drains claims instead of renewing them" do
    state = %ClaimService{claims: %{"issue-1" => %{owner: self()}}}

    assert {:stop, :normal, %{claims: %{}}} = ClaimService.handle_info(:heartbeat, state)
    assert_receive {:claim_lost, "issue-1", :claim_service_disabled}
  end

  test "conditional release preserves claims transferred to another worker" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    claim = %{
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 3,
      owner: self(),
      worker: worker
    }

    state = %ClaimService{claims: %{"issue-1" => claim}}
    identity = Map.take(claim, [:claim_id, :generation])

    assert {:reply, {:error, :claim_ownership_changed}, unchanged} =
             ClaimService.handle_call(
               {:release_if_owned, "issue-1", identity},
               {self(), make_ref()},
               state
             )

    assert unchanged.claims == state.claims
  end

  test "supervisor shutdown drains claims and stops immediately" do
    state = %ClaimService{connection: make_ref(), claims: %{"issue-1" => %{owner: self()}}}

    assert {:stop, :shutdown, %{claims: %{}}} =
             ClaimService.handle_info({:EXIT, self(), :shutdown}, state)

    assert_receive {:claim_lost, "issue-1", {:coordinator_stopping, :shutdown}}
  end

  test "core supervisor couples orchestrator and worker lifecycles" do
    application_supervisor_state = :sys.get_state(SymphonyElixir.Supervisor)
    supervisor_state = :sys.get_state(SymphonyElixir.CoreSupervisor)

    assert elem(application_supervisor_state, 2) == :one_for_one
    assert elem(supervisor_state, 2) == :one_for_all
  end
end
