defmodule SymphonyElixir.NodeCapacityContractMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.down.sql",
              __DIR__
            )

  test "capacity API is function-only, session-bound, and staging-only" do
    sql = @migration |> File.read!() |> executable_sql()

    assert sql =~ "function symphony_staging.current_node_claim_capacity()"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "principals.revoked_at is null"
    assert sql =~ "nodes.status = 'active'"
    assert sql =~ "select count(*), min(nodes.claim_capacity)"
    assert sql =~ "into matching_nodes, capacity"
    assert sql =~ "if matching_nodes <> 1 then"
    assert sql =~ "errcode = '28000', message = 'node capacity identity rejected'"
    assert sql =~ "grant_claim_api_to_node_login"
    assert sql =~ "'symphony_staging.current_node_claim_capacity() to %I'"
    assert sql =~ "where revoked_at is null"
    assert sql =~ "'grant execute on function symphony_staging.current_node_claim_capacity() to %I'"

    assert sql =~
             "revoke all on function symphony_staging.current_node_claim_capacity()\n" <>
               "  from public, anon, authenticated, service_role,\n" <>
               "       symphony_staging_runtime, symphony_staging_provisioner;"

    assert sql =~ "'node-capacity-contract', 1"
    refute sql =~ "symphony_production."
    refute sql =~ "grant select on symphony_staging.nodes"
    refute File.read!(@migration) =~ "-- select nodes.claim_capacity"
  end

  test "rollback removes only ARO-288 objects and restores the claim grant helper" do
    sql = @rollback |> File.read!() |> executable_sql()

    assert sql =~ "where contract_name = 'node-capacity-contract'"
    assert sql =~ "drop function if exists symphony_staging.current_node_claim_capacity()"
    assert sql =~ "create or replace function symphony_staging.grant_claim_api_to_node_login()"

    assert sql =~
             "'symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer), '\n" <>
               "    'symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer), '\n" <>
               "    'symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid), '\n" <>
               "    'symphony_staging.release_claim(uuid, bigint, uuid, uuid), '\n" <>
               "    'symphony_staging.complete_claim(uuid, bigint, uuid, uuid), '\n" <>
               "    'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer) to %I'"

    refute sql =~ "'symphony_staging.current_node_claim_capacity() to %I'"
    refute sql =~ "drop table"
    refute sql =~ "symphony_production."
  end

  defp executable_sql(sql) do
    sql
    |> String.replace(~r/--[^\r\n]*/, "")
    |> String.replace(~r{/\*.*?\*/}s, "")
  end
end
