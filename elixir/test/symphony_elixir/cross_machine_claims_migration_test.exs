defmodule SymphonyElixir.CrossMachineClaimsMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260804000000_aro_164_cross_machine_claims.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260804000000_aro_164_cross_machine_claims.down.sql",
              __DIR__
            )

  test "migration stays inside staging and provides the complete claim interface" do
    sql = File.read!(@migration)

    refute sql =~ "symphony_production."

    for function <- [
          "claim_issue",
          "renew_claim",
          "release_claim",
          "complete_claim",
          "takeover_claim",
          "validate_active_claim"
        ] do
      assert sql =~ "function symphony_staging.#{function}("
    end

    assert sql =~ "set search_path = pg_catalog, pg_temp"
    assert sql =~ "to symphony_staging_runtime"
    assert sql =~ "grant_claim_api_to_node_login"
    assert sql =~ "select login_role from symphony_staging.node_login_principals"
    assert sql =~ "from public, anon, authenticated, service_role"
  end

  test "claim transaction locks node capacity and fences stale generations" do
    sql = File.read!(@migration)

    assert sql =~ "for update of nodes"
    assert sql =~ "active_count >= node_capacity"
    assert sql =~ "next_generation := last_generation + 1"
    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "claims.lease_expires_at > db_now"
    assert sql =~ "clock_timestamp()"
    refute sql =~ "current_timestamp"
  end

  test "claim states come from configuration and renewals revalidate routing" do
    sql = File.read!(@migration)

    assert sql =~ "requested_active_states text[]"
    assert sql =~ "requested_issue_state = any(requested_active_states)"
    refute sql =~ "requested_issue_state not in ('todo', 'in progress')"
    assert sql =~ "assignments.routing_policy = claims.routing_policy"
    assert sql =~ "assignments.target_node_id is not distinct from claims.target_node_id"
    assert sql =~ "assignments.routing_revision = claims.routing_revision"
  end

  test "routing distinguishes never-claimed fallback from expired-owner takeover" do
    sql = File.read!(@migration)

    assert sql =~ "route.routing_policy = 'preferred-with-fallback'"
    assert sql =~ "current_claim.issue_id is null"
    assert sql =~ "route.updated_at + make_interval"
    assert sql =~ "current_claim.lease_expires_at"
    assert sql =~ "route.routing_policy = 'exclusive'"
    assert sql =~ "In Progress requires an expired claim takeover"
  end

  test "rollback removes only ARO-164 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'cross-machine-claims'"
    assert rollback =~ "drop table if exists symphony_staging.issue_claims"
    assert rollback =~ "alter table symphony_staging.nodes drop column if exists claim_capacity"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
