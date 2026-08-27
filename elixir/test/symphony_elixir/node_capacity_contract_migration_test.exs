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
    sql = File.read!(@migration)

    assert sql =~ "function symphony_staging.current_node_claim_capacity()"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "principals.revoked_at is null"
    assert sql =~ "nodes.status = 'active'"
    assert sql =~ "select nodes.claim_capacity"
    assert sql =~ "grant_claim_api_to_node_login"
    assert sql =~ "'node-capacity-contract', 1"
    refute sql =~ "symphony_production."
    refute sql =~ "grant select on symphony_staging.nodes"
  end

  test "rollback removes only ARO-288 objects and restores the claim grant helper" do
    sql = File.read!(@rollback)

    assert sql =~ "where contract_name = 'node-capacity-contract'"
    assert sql =~ "drop function if exists symphony_staging.current_node_claim_capacity()"
    assert sql =~ "create or replace function symphony_staging.grant_claim_api_to_node_login()"
    refute sql =~ "drop table"
    refute sql =~ "symphony_production."
  end
end
