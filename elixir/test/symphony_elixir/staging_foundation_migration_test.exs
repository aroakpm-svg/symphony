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
    refute sql =~ "symphony_production"
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
      assert sql =~ "alter role #{role} with"
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

    assert sql =~ "unsafe pre-existing role state"
    assert sql =~ "incompatible pre-existing schema grants"
    assert sql =~ "role_record.rolconfig is not null"
    assert sql =~ "pg_auth_members"
    assert sql =~ "has_schema_privilege"
    refute sql =~ ~r/alter role .* set search_path/i
  end

  test "migration preserves shared schema ACLs and default privileges" do
    sql = File.read!(@migration)

    refute sql =~
             ~r/revoke all on schema symphony_staging from public, anon, authenticated, service_role/i

    refute sql =~ ~r/alter default privileges/i
  end

  test "migration revokes object privileges only from ARO-163-owned objects" do
    sql = File.read!(@migration)

    refute sql =~ ~r/on all (tables|sequences|functions) in schema symphony_staging/i

    for object <- [
          "symphony_staging.contract_versions",
          "symphony_staging.nodes",
          "symphony_staging.node_bindings",
          "symphony_staging.routing_assignments",
          "symphony_staging.foundation_audit_events",
          "symphony_staging.foundation_audit_events_audit_id_seq",
          "symphony_staging.enforce_node_transition()",
          "symphony_staging.enforce_node_binding_transition()",
          "symphony_staging.enforce_routing_revision()"
        ] do
      assert sql =~ object
    end
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
    assert sql =~ "aro_163_roles_to_drop"
    assert sql =~ "'aro-163-created-role:symphony_staging_runtime'"
    assert sql =~ "'aro-163-created-role:symphony_staging_provisioner'"

    refute sql =~
             ~r/revoke all on schema symphony_staging\s+from symphony_staging_runtime/i

    for function <- [
          "enforce_node_transition",
          "enforce_node_binding_transition",
          "enforce_routing_revision"
        ] do
      assert sql =~ "drop function if exists symphony_staging.#{function}()"
    end
  end
end
