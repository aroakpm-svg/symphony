defmodule SymphonyElixir.ClaimServiceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaimService
  alias SymphonyElixir.Linear.Issue

  @current_node_id "00000000-0000-4000-8000-000000000001"
  @other_node_id "00000000-0000-4000-8000-000000000002"

  test "exclusive routing accepts only the current node and returns its revision" do
    assert {:ok, %{routing_revision: 7}} = exclusive_route("exclusive", @current_node_id, 7)
    assert {:ineligible, :wrong_node} = exclusive_route("exclusive", @other_node_id, 7)
    assert {:ineligible, :missing_routing} = exclusive_route(nil, nil, nil)
    assert {:ineligible, :non_exclusive_routing} = exclusive_route("unassigned", nil, 3)

    assert {:ineligible, :non_exclusive_routing} =
             exclusive_route("preferred-with-fallback", @current_node_id, 4)
  end

  test "exclusive routing reads the assignment by issue id without exposing query errors" do
    parent = self()

    query = fn sql, params ->
      send(parent, {:routing_query, sql, params})
      {:error, RuntimeError.exception("postgresql://secret@database.internal/symphony")}
    end

    assert {:error, :routing_lookup_failed} = route_with_query(query)
    assert_receive {:routing_query, sql, ["issue-1"]}
    assert sql =~ "from symphony_staging.routing_assignments"
    assert sql =~ "where issue_id = $1::text::uuid"
    assert String.trim_leading(sql) =~ ~r/^select\b/i
    refute sql =~ ~r/\b(insert|update|delete|call)\b/i

    result = ClaimService.exclusive_route(%Issue{id: "issue-1"})

    assert result == {:error, :claim_service_unavailable}
    refute inspect(result) =~ "database.internal"
  end

  test "multi-project claim locks and revalidates the exclusive routing receipt before acquisition" do
    parent = self()

    query = fn sql, params ->
      send(parent, {:query, String.trim(sql), params})

      cond do
        sql =~ "routing_assignments" ->
          {:ok, %Postgrex.Result{rows: [["exclusive", @current_node_id, 7]], num_rows: 1}}

        sql =~ "claim_issue" ->
          {:ok, %Postgrex.Result{rows: [["claim-1", 1]], num_rows: 1}}
      end
    end

    assert {:ok, claim} = claim_with_query(query, 7, transaction_seam(parent))
    assert claim.claim_id == "claim-1"
    assert_receive :transaction_checked_out
    assert_receive {:query, route_sql, ["issue-1", @current_node_id, 7]}
    assert route_sql =~ "for share"
    assert_receive {:query, claim_sql, _params}
    assert claim_sql =~ "claim_issue"
  end

  test "multi-project claim rejects a changed routing revision, policy, or node before acquisition" do
    cases = [
      {"exclusive", @current_node_id, 8},
      {"unassigned", nil, 7},
      {"preferred-with-fallback", @current_node_id, 7},
      {"exclusive", @other_node_id, 7}
    ]

    for {policy, target_node_id, revision} <- cases do
      parent = self()

      query = fn sql, params ->
        send(parent, {:query, String.trim(sql), params})

        cond do
          sql =~ "routing_assignments" ->
            {:ok, %Postgrex.Result{rows: [[policy, target_node_id, revision]], num_rows: 1}}

          sql =~ "claim_issue" ->
            flunk("stale routing must be rejected before claim acquisition")
        end
      end

      assert {:error, :routing_changed} = claim_with_query(query, 7, transaction_seam(parent))
      assert_receive :transaction_checked_out
      assert_receive {:query, _route_sql, ["issue-1", @current_node_id, 7]}
    end
  end

  test "uncertain transaction outcome stops the claim service and discards local claim state" do
    owner = self()
    existing_claim = %{owner: owner, worker: nil, lease_deadline_ms: 1}
    transaction = fn _connection, _callback -> {:uncertain, :commit_connection_lost} end

    query = fn _sql, _params ->
      flunk("uncertain transaction must own query execution")
    end

    state = claim_state(query, transaction)
    state = %{state | claims: %{"existing" => existing_claim}}

    assert {
             :stop,
             {:claim_transaction_uncertain, :commit_connection_lost},
             {:error, :claim_outcome_uncertain},
             %{claims: %{}}
           } =
             ClaimService.handle_call(
               {:claim, claim_issue(7), self()},
               self(),
               state
             )

    assert_receive {:claim_lost, "existing", {:claim_transaction_uncertain, :commit_connection_lost}}
  end

  test "legacy claim without a routing receipt retains the existing claim acquisition behavior" do
    parent = self()

    query = fn sql, params ->
      send(parent, {:query, String.trim(sql), params})
      {:ok, %Postgrex.Result{rows: [["legacy-claim", 2]], num_rows: 1}}
    end

    assert {:ok, %{claim_id: "legacy-claim"}} = claim_with_query(query, nil, nil)
    assert_receive {:query, claim_sql, _params}
    assert claim_sql =~ "claim_issue"
    refute_receive {:query, "begin", []}
  end

  test "database calls bind textual UUIDs through text before UUID casts" do
    source = File.read!(Path.expand("../../lib/symphony_elixir/claim_service.ex", __DIR__))

    assert length(Regex.scan(~r/::text::uuid/, source)) == 14
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

  defp exclusive_route(nil, nil, nil) do
    route_with_query(fn _sql, _params ->
      {:ok, %Postgrex.Result{rows: [], num_rows: 0}}
    end)
  end

  defp exclusive_route(policy, target_node_id, routing_revision) do
    route_with_query(fn _sql, _params ->
      {:ok,
       %Postgrex.Result{
         rows: [[policy, target_node_id, routing_revision]],
         num_rows: 1
       }}
    end)
  end

  defp route_with_query(query) do
    issue = %Issue{id: "issue-1"}
    state = %ClaimService{connection: query, settings: %{node_id: @current_node_id}}

    assert {:reply, result, ^state} =
             ClaimService.handle_call({:exclusive_route, issue}, self(), state)

    result
  end

  defp claim_with_query(query, routing_revision, transaction) do
    state = claim_state(query, transaction)

    assert {:reply, result, _state} =
             ClaimService.handle_call({:claim, claim_issue(routing_revision), self()}, self(), state)

    result
  end

  defp claim_issue(routing_revision) do
    %Issue{
      id: "issue-1",
      state: "In Progress",
      updated_at: DateTime.utc_now(),
      routing_revision: routing_revision
    }
  end

  defp claim_state(query, transaction) do
    settings = %{
      node_id: @current_node_id,
      node_instance_id: "00000000-0000-4000-8000-000000000003",
      lease_ms: 60_000,
      fallback_grace_ms: 30_000
    }

    %ClaimService{connection: query, settings: settings, transaction_fun: transaction}
  end

  defp transaction_seam(parent) do
    fn connection, callback ->
      send(parent, :transaction_checked_out)

      case callback.(connection) do
        {:commit, value} -> {:ok, value}
        {:rollback, reason} -> {:error, reason}
      end
    end
  end
end
