defmodule SymphonyElixir.ClaimConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "claim service is disabled by default" do
    assert {:ok, settings} = Schema.parse(%{})
    refute settings.claim.enabled
  end

  test "enabled claim service requires identity and a database URL" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"claim" => %{"enabled" => true}})

    assert message =~ "claim.database_url"
    assert message =~ "claim.node_id"
    assert message =~ "claim.node_instance_id"
  end

  test "heartbeat must be shorter than the lease" do
    config = %{
      "claim" => %{
        "enabled" => true,
        "database_url" => "postgresql://localhost/symphony",
        "node_id" => "00000000-0000-4000-8000-000000000001",
        "node_instance_id" => "00000000-0000-4000-8000-000000000002",
        "lease_ms" => 1_000,
        "heartbeat_ms" => 1_000
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "claim.heartbeat_ms must be less than lease_ms"
  end
end
