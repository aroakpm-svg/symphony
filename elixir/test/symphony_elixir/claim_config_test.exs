defmodule SymphonyElixir.ClaimConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema

  test "claim service is disabled by default" do
    assert {:ok, settings} = Schema.parse(%{})
    refute settings.claim.enabled
  end

  test "enabled claim service requires identity, a database URL, and a CA" do
    keys = [
      "SYMPHONY_CLAIM_DATABASE_URL",
      "SYMPHONY_CLAIM_CA_CERT_FILE",
      "SYMPHONY_NODE_ID",
      "SYMPHONY_NODE_INSTANCE_ID"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    Enum.each(keys, &System.delete_env/1)

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"claim" => %{"enabled" => true}})

    assert message =~ "claim.database_url"
    assert message =~ "claim.ca_cert_file"
    assert message =~ "claim.node_id"
    assert message =~ "claim.node_instance_id"
  end

  test "enabled claim service validates after environment resolution" do
    env = %{
      "SYMPHONY_CLAIM_DATABASE_URL" => "postgresql://localhost/symphony",
      "SYMPHONY_CLAIM_CA_CERT_FILE" => "/approved/supabase-ca.crt",
      "SYMPHONY_NODE_ID" => "00000000-0000-4000-8000-000000000001",
      "SYMPHONY_NODE_INSTANCE_ID" => "00000000-0000-4000-8000-000000000002"
    }

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    assert {:ok, settings} = Schema.parse(%{"claim" => %{"enabled" => true}})
    assert settings.claim.database_url == env["SYMPHONY_CLAIM_DATABASE_URL"]
    assert settings.claim.ca_cert_file == env["SYMPHONY_CLAIM_CA_CERT_FILE"]
    assert settings.claim.node_id == env["SYMPHONY_NODE_ID"]
    assert settings.claim.node_instance_id == env["SYMPHONY_NODE_INSTANCE_ID"]
  end

  test "heartbeat must be shorter than the lease" do
    config = %{
      "claim" => %{
        "enabled" => true,
        "database_url" => "postgresql://localhost/symphony",
        "ca_cert_file" => "/approved/supabase-ca.crt",
        "node_id" => "00000000-0000-4000-8000-000000000001",
        "node_instance_id" => "00000000-0000-4000-8000-000000000002",
        "lease_ms" => 1_000,
        "heartbeat_ms" => 1_000
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "claim.heartbeat_ms must be less than lease_ms"
  end

  test "heartbeat leaves enough time for a bounded renewal call" do
    config = %{
      "claim" => %{
        "lease_ms" => 30_000,
        "heartbeat_ms" => 20_000
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "claim.heartbeat_ms must leave more than 15000ms before lease expiry"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
