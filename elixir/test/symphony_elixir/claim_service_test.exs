defmodule SymphonyElixir.ClaimServiceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaimService

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
        "issue-1" => %{owner: self()},
        "issue-2" => %{owner: self()}
      }
    }

    assert {:stop, {:connection_lost, :closed}, %{claims: claims}} =
             ClaimService.handle_info({:EXIT, connection, :closed}, state)

    assert claims == %{}
    assert_receive {:claim_lost, "issue-1", {:connection_lost, :closed}}
    assert_receive {:claim_lost, "issue-2", {:connection_lost, :closed}}
  end
end
