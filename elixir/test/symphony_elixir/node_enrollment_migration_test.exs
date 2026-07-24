defmodule SymphonyElixir.NodeEnrollmentMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260724010000_aro_169_node_enrollment.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260724010000_aro_169_node_enrollment.down.sql",
              __DIR__
            )

  test "requires contract v2 and publishes contract v3" do
    sql = File.read!(@migration)

    assert sql =~ "contract_version = 2"
    assert sql =~ "ARO-169 requires the reconciled ARO-168 contract v2"
    assert sql =~ "'node-identity-routing-foundation',\n  3"
  end

  test "uses independent login credentials and stores only a verifier" do
    sql = File.read!(@migration)

    assert sql =~ "extensions.gen_random_bytes(32)"
    assert sql =~ "extensions.digest(generated_credential, 'sha256')"
    assert sql =~ "create role %I login password %L"
    refute sql =~ "github"
    refute sql =~ "linear"
  end

  test "authentication binds the database principal and rejects duplicates" do
    sql = File.read!(@migration)

    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "active_node_instances"
    assert sql =~ "pg_stat_activity"
    assert sql =~ "activity.backend_start"
    assert sql =~ "node instance reuse rejected"
    assert sql =~ "duplicate node session rejected"
    assert sql =~ "requested_node_instance_id"
    refute sql =~ "pg_try_advisory_lock"
    refute sql =~ "in role symphony_staging_runtime"
  end

  test "removes public and API execution paths" do
    sql = File.read!(@migration)

    assert sql =~
             "from public, anon, authenticated, service_role,\n       symphony_staging_runtime"

    assert sql =~
             "'symphony_staging.authenticate_node(uuid, uuid) to %I'"
  end

  test "rotation and revocation invalidate credentials without a termination race" do
    sql = File.read!(@migration)

    assert sql =~ "alter role %I password %L"
    assert sql =~ "alter role %I nologin"
    refute sql =~ "pg_terminate_backend"

    assert sql =~
             "'symphony_staging.authenticate_node(uuid, uuid) from %I'"

    assert sql =~ "'node_credential_rotated'"
    assert sql =~ "'node_revoked'"
  end

  test "rollback refuses to orphan provisioned identities" do
    sql = File.read!(@rollback)

    assert sql =~ "rollback refused while provisioned node principals exist"
    assert sql =~ "contract_version = 2"
  end
end
