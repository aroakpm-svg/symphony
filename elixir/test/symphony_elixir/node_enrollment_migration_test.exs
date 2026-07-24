defmodule SymphonyElixir.NodeEnrollmentMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260724090000_aro_169_node_enrollment.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260724090000_aro_169_node_enrollment.down.sql",
              __DIR__
            )

  test "entrypoints are private, fixed-path, and least privilege" do
    sql = File.read!(@migration)
    assert sql =~ "security definer"
    assert sql =~ "set search_path = pg_catalog, symphony_staging, extensions"
    assert sql =~ "from public, anon, authenticated, service_role"
    assert sql =~ "to symphony_staging_provisioner"
    assert sql =~ "to symphony_staging_runtime"
    refute sql =~ ~r/grant .* to service_role/i
    refute sql =~ "symphony_production."
  end

  test "credentials are hashed and never persisted in audit or operation results" do
    sql = File.read!(@migration)
    assert sql =~ "extensions.digest"
    assert sql =~ "'sha256'"
    assert sql =~ "credential_verifier"
    assert sql =~ "constant_time_equal"
    assert sql =~ "get_byte"
    refute sql =~ ~r/jsonb_build_object\([^;]*credential['"]/s
  end

  test "provisioning and startup are atomic and idempotent" do
    sql = File.read!(@migration)
    assert sql =~ "operation id conflict"
    assert sql =~ "request_fingerprint"
    assert sql =~ "node-provisioned"
    assert sql =~ "status='superseded'"
    assert sql =~ "node_instance_authorized"
    assert sql =~ "authentication rejected"
    assert sql =~ "change_node_credential"
    assert sql =~ "'rotate','revoke','reenroll'"
  end

  test "rollback removes only ARO-169 objects" do
    sql = File.read!(@rollback)
    assert sql =~ "node-enrollment-authentication"
    assert sql =~ "drop table symphony_staging.node_instances"
    refute sql =~ "drop table symphony_staging.nodes"
    refute sql =~ "drop schema"
    refute sql =~ "symphony_production"
  end
end
