defmodule SymphonyElixir.StagingFoundationMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260723000000_aro_163_staging_foundation.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260723000000_aro_163_staging_foundation.down.sql",
              __DIR__
            )

  test "migration keeps all writes inside symphony_staging" do
    sql = File.read!(@migration)

    assert sql =~ "create schema if not exists symphony_staging"
    assert sql =~ "revoke all on schema symphony_production"
    assert length(Regex.scan(~r/nspname = 'symphony_production'/, sql)) == 2
    refute sql =~ ~r/(create|alter|drop|insert into|update|delete from)\s+.*symphony_production/i
  end

  test "migration defines the reviewed foundation contract" do
    sql = File.read!(@migration)

    for required <- [
          "symphony_staging.contract_versions",
          "symphony_staging.nodes",
          "symphony_staging.node_bindings",
          "symphony_staging.routing_assignments",
          "symphony_staging.foundation_audit_events",
          "'pending', 'active', 'rotating', 'revoked', 'retired'",
          "'unassigned', 'preferred-with-fallback', 'exclusive'",
          "node_bindings_one_active_per_node",
          "routing_assignments_target_node_id_idx",
          "credential_verifier",
          "enable row level security",
          "enforce_node_transition",
          "enforce_node_binding_transition",
          "enforce_routing_revision",
          "security invoker"
        ] do
      assert sql =~ required
    end
  end

  test "staging roles are non-admin permission roles" do
    sql = File.read!(@migration)

    for role <- ["symphony_staging_runtime", "symphony_staging_provisioner"] do
      assert sql =~ "create role #{role}"
    end

    for restriction <- [
          "nologin",
          "nosuperuser",
          "nocreatedb",
          "nocreaterole",
          "noinherit",
          "noreplication",
          "nobypassrls"
        ] do
      assert sql =~ restriction
    end

    assert sql =~
             "grant symphony_staging_runtime, symphony_staging_provisioner to postgres"
  end

  test "rollback preserves both environment schemas" do
    sql = File.read!(@rollback)

    for table <- [
          "foundation_audit_events",
          "routing_assignments",
          "node_bindings",
          "nodes",
          "contract_versions"
        ] do
      assert sql =~ "drop table if exists symphony_staging.#{table}"
    end

    refute sql =~ ~r/drop schema/i
    refute sql =~ ~r/(drop|alter|truncate|insert|update|delete).*symphony_production/i

    for function <- [
          "enforce_node_transition",
          "enforce_node_binding_transition",
          "enforce_routing_revision"
        ] do
      assert sql =~ "drop function if exists symphony_staging.#{function}()"
    end
  end
end
