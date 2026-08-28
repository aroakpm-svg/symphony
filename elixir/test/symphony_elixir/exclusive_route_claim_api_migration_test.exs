defmodule SymphonyElixir.ExclusiveRouteClaimApiMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260828000000_aro_287_exclusive_route_claim_api.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260828000000_aro_287_exclusive_route_claim_api.down.sql",
              __DIR__
            )

  test "route snapshot and atomic claim are session-bound function-only APIs for text issue ids" do
    sql = File.read!(@migration)

    assert sql =~ "exclusive_route_snapshot(requested_issue_id text)"
    assert sql =~ "claim_exclusive_issue(\n  requested_issue_id text"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "if matching_nodes <> 1 then"
    assert sql =~ "assignments.issue_id = requested_issue_id"
    assert sql =~ "assignments.routing_policy = 'exclusive'"
    assert sql =~ "assignments.target_node_id = requested_node_id"
    assert sql =~ "assignments.routing_revision = expected_routing_revision"
    assert sql =~ "for share of assignments"
    assert sql =~ "select * from symphony_staging.claim_issue("
    assert sql =~ "security definer"
    assert sql =~ "set search_path = pg_catalog, pg_temp"
    assert sql =~ "grant_claim_api_to_node_login"
    assert sql =~ "'exclusive-route-claim-api', 1"
    refute sql =~ "grant select on symphony_staging.routing_assignments"
    refute sql =~ "::uuid"
    refute sql =~ "symphony_production."
  end

  test "rollback removes only the forward APIs and restores the prior grant helper" do
    sql = File.read!(@rollback)

    assert sql =~ "where contract_name = 'exclusive-route-claim-api'"
    assert sql =~ "drop function if exists symphony_staging.claim_exclusive_issue"
    assert sql =~ "drop function if exists symphony_staging.exclusive_route_snapshot(text)"
    assert sql =~ "symphony_staging.current_node_claim_capacity() to %I"
    refute sql =~ "drop table"
    refute sql =~ "drop schema"
  end

  test "disposable PostgreSQL proof executes the real claim, capacity, and route migrations" do
    source = File.read!(Path.expand("claim_service_postgres_test.exs", __DIR__))

    assert source =~ "apply_migration!(claim_connection, \"20260804000000_aro_164_cross_machine_claims.sql\")"
    assert source =~ "apply_migration!(claim_connection, \"20260827000000_aro_288_node_capacity_contract.sql\")"

    assert source =~
             "apply_migration!(claim_connection, \"20260828000000_aro_287_exclusive_route_claim_api.sql\")"

    refute source =~ "create function symphony_staging.claim_exclusive_issue"
    refute source =~ "create function symphony_staging.exclusive_route_snapshot"
    assert source =~ "future_node_role"
    assert source =~ "insufficient_privilege"
    assert source =~ "future/non-uuid"
  end
end
