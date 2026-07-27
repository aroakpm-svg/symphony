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
  @lifecycle_script Path.expand(
                      "../../../.github/scripts/test-node-enrollment.sh",
                      __DIR__
                    )

  test "requires contract v2 and publishes contract v3" do
    sql = File.read!(@migration)
    lifecycle_script = File.read!(@lifecycle_script)

    assert sql =~ "contract_version = 2"
    assert sql =~ "ARO-169 requires the reconciled ARO-168 contract v2"
    assert sql =~ "unsafe ARO-168 membership graph"
    assert sql =~ "unsafe ARO-168 direct object ACL state"
    assert sql =~ "unsafe ARO-168 direct column ACL state"
    assert sql =~ "unsafe ARO-168 ACL or default-ACL state"
    assert sql =~ "unsafe ARO-168 function or schema ACL state"
    assert sql =~ "unsafe ARO-168 ownership or row-security state"
    assert sql =~ "unsafe ARO-168 relation inventory"
    assert sql =~ "unsafe ARO-168 function inventory or definition"
    assert sql =~ "unsafe ARO-168 trigger state"
    assert sql =~ "unsafe ARO-168 index state"
    assert sql =~ "unsafe ARO-168 column/default/identity state"
    assert sql =~ "unsafe ARO-168 constraint state"
    assert sql =~ "pg_get_triggerdef(trigger_row.oid, true)"
    assert sql =~ "procedure.oid::regprocedure::text"
    assert sql =~ "pg_get_indexdef(index_relation.oid)"
    assert sql =~ "unsafe ARO-168 sequence configuration"
    assert sql =~ "unsafe ARO-168 RLS policy state"
    assert sql =~ ~r/'node-identity-routing-foundation',\r?\n  3/

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted drifted v2 authorization state"
  end

  test "uses independent login credentials and stores only a verifier" do
    sql = File.read!(@migration)

    assert sql =~ "extensions.gen_random_bytes(32)"
    assert sql =~ "extensions.digest(generated_credential, 'sha256')"
    assert sql =~ "create role %I login password %L"
    refute sql =~ "github"
    refute sql =~ "linear"
  end

  test "lifecycle operations are stable, atomic, and do not replay credentials" do
    sql = File.read!(@migration)
    lifecycle_script = File.read!(@lifecycle_script)

    assert sql =~ "create table symphony_staging.node_lifecycle_operations"
    assert sql =~ "operation_id uuid primary key"
    assert sql =~ "request_fingerprint text not null"
    assert sql =~ "jsonb_build_array("
    assert sql =~ "credential_returned boolean"
    assert sql =~ "null::text"
    assert sql =~ "insert into symphony_staging.routing_assignments"
    assert sql =~ "create or replace function symphony_staging.reenroll_node"

    assert lifecycle_script =~ "concurrent-node"
    assert lifecycle_script =~ "routing conflict unexpectedly provisioned a partial node"
    assert lifecycle_script =~ "replayed_reenroll_credential"
    assert lifecycle_script =~ "node_principal_history"
  end

  test "authentication binds the database principal and rejects duplicates" do
    sql = File.read!(@migration)

    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "active_node_instances"
    refute sql =~ "pg_stat_activity"
    assert sql =~ "on conflict on constraint active_node_instances_pkey do nothing"
    assert sql =~ "retire_node_instance"
    assert sql =~ "node instance reuse rejected"
    assert sql =~ "duplicate node session rejected"
    assert sql =~ "requested_node_instance_id"
    assert sql =~ "for update of nodes, principals, bindings"
    refute sql =~ "pg_try_advisory_lock"
    refute sql =~ "in role symphony_staging_runtime"
  end

  test "SET-only provisioner membership is an accepted caller boundary" do
    sql = File.read!(@migration)
    lifecycle_script = File.read!(@lifecycle_script)

    assert sql =~ "'SET'"
    refute sql =~ "'MEMBER'"
    refute sql =~ "\n       'USAGE'\n"

    assert lifecycle_script =~
             "grant symphony_staging_provisioner to aro169_disposable_bootstrap"

    assert lifecycle_script =~ "set role symphony_staging_provisioner"
    assert lifecycle_script =~ "with inherit true, set false"
    assert lifecycle_script =~ "inherit-only provisioner member bypassed SET capability"

    assert lifecycle_script =~
             "inherit-only provisioner member bypassed lifecycle table boundary"

    assert lifecycle_script =~
             "inherit-only provisioner member bypassed foundation table boundary"

    refute sql =~ "grant select, insert, update on symphony_staging.node_login_principals"
    refute sql =~ "create policy provisioner_manage_node_login_principals"
    assert sql =~ "drop policy if exists provisioner_manage_nodes"
    assert sql =~ "revoke all on table"
    assert File.read!(@rollback) =~ "create policy provisioner_manage_nodes"
  end

  test "removes public and API execution paths" do
    sql = File.read!(@migration)

    assert sql =~
             ~r/from public, anon, authenticated, service_role,\r?\n       symphony_staging_runtime/

    assert sql =~
             "'symphony_staging.authenticate_node(uuid, uuid) to %I'"
  end

  test "rotation and revocation invalidate credentials without a termination race" do
    sql = File.read!(@migration)
    lifecycle_script = File.read!(@lifecycle_script)

    assert sql =~ "replacement_role"
    assert sql =~ "create role %I login password %L"
    assert sql =~ "alter role %I nologin"
    refute sql =~ "pg_terminate_backend"
    assert sql =~ "delete from symphony_staging.active_node_instances"

    assert sql =~
             "'symphony_staging.authenticate_node(uuid, uuid) from %I'"

    assert sql =~ "'node_credential_rotated'"
    assert sql =~ "'node_revoked'"
    assert sql =~ "node_principal_history"
    assert sql =~ "'node_reenrolled'"

    assert lifecycle_script =~
             "-c \"select * from symphony_staging.authenticate_node('$node_id', '$instance_four');\""

    assert lifecycle_script =~
             "-c \"select * from symphony_staging.authenticate_node('$node_id', '$instance_five');\""

    assert lifecycle_script =~
             "rotation did not serialize with in-flight authentication"

    assert lifecycle_script =~
             "retired login role reconnected after choosing its own password"
  end

  test "rollback refuses to orphan provisioned identities" do
    sql = File.read!(@rollback)

    assert sql =~ "rollback refused while provisioned node principals exist"
    assert sql =~ "rollback requires the exact contract v3 marker"
    assert sql =~ "contract objects or ACLs drifted"
    assert sql =~ "contract downgrade did not update exactly one row"
    assert sql =~ "in access exclusive mode"
    assert sql =~ "pg_advisory_xact_lock"
    assert sql =~ "contract_version = 2"
    assert sql =~ "node_principal_history"
    assert sql =~ "node_lifecycle_operations"
  end

  test "behavior suite covers rollback marker, object, index, and ACL drift" do
    lifecycle_script = File.read!(@lifecycle_script)

    assert lifecycle_script =~ "rollback unexpectedly accepted a future contract"
    assert lifecycle_script =~ "rollback unexpectedly accepted object drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted index drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted ACL drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted column ACL drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted trigger drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted membership drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted sequence drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted managed-role attribute drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted schema ACL drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted FORCE RLS drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted extra staging object"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted drifted trigger function namespace"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted drifted index access method"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted drifted foundation constraint"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted drifted foundation column default"

    assert lifecycle_script =~
             "rollback unexpectedly accepted auxiliary catalog object drift"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted nonempty v2 foundation data"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted an extra v2 contract row"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted disabled internal FK triggers"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted unlogged foundation audit data"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted replica identity drift"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted rewrite-rule drift"

    assert lifecycle_script =~
             "v3 apply unexpectedly accepted production auxiliary objects"

    assert lifecycle_script =~ "rollback unexpectedly accepted identity-mode drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted rewrite-rule drift"
    assert lifecycle_script =~ "rollback unexpectedly accepted internal-trigger drift"

    assert File.read!(@migration) =~ "'index:'"
    assert File.read!(@rollback) =~ "'index:'"
    assert File.read!(@migration) =~ "'trigger:'"
    assert File.read!(@rollback) =~ "'trigger:'"
    assert File.read!(@migration) =~ "'membership:'"
    assert File.read!(@rollback) =~ "'membership:'"
    assert File.read!(@migration) =~ "sequence_state.seqincrement"
    assert File.read!(@rollback) =~ "sequence_state.seqincrement"
    assert File.read!(@migration) =~ "attribute.attacl::text"
    assert File.read!(@rollback) =~ "attribute.attacl::text"
    assert File.read!(@migration) =~ "'role:'"
    assert File.read!(@rollback) =~ "'role:'"
    assert File.read!(@migration) =~ "'schema:'"
    assert File.read!(@rollback) =~ "'schema:'"
    assert File.read!(@migration) =~ "'default-acl:'"
    assert File.read!(@rollback) =~ "'default-acl:'"
    assert File.read!(@migration) =~ "relation.relforcerowsecurity::text"
    assert File.read!(@rollback) =~ "relation.relforcerowsecurity::text"
    assert File.read!(@migration) =~ "relation.relpersistence::text"
    assert File.read!(@rollback) =~ "relation.relpersistence::text"
    assert File.read!(@migration) =~ "relation.relreplident::text"
    assert File.read!(@rollback) =~ "relation.relreplident::text"
    assert File.read!(@migration) =~ "index_state.indisreplident::text"
    assert File.read!(@rollback) =~ "index_state.indisreplident::text"
    assert File.read!(@migration) =~ "attribute.attidentity::text"
    assert File.read!(@rollback) =~ "attribute.attidentity::text"
    assert File.read!(@migration) =~ "attribute.attgenerated::text"
    assert File.read!(@rollback) =~ "attribute.attgenerated::text"
    assert File.read!(@migration) =~ "'rewrite:'"
    assert File.read!(@rollback) =~ "'rewrite:'"
    assert File.read!(@migration) =~ "trigger_row.tgisinternal::text"
    assert File.read!(@rollback) =~ "trigger_row.tgisinternal::text"
    assert File.read!(@migration) =~ "'inventory-relation:'"
    assert File.read!(@rollback) =~ "'inventory-relation:'"
    assert File.read!(@migration) =~ "'inventory-function:'"
    assert File.read!(@rollback) =~ "'inventory-function:'"
    assert File.read!(@migration) =~ "'inventory-conversion:'"
    assert File.read!(@rollback) =~ "'inventory-conversion:'"
    assert File.read!(@migration) =~ "'inventory-opclass:'"
    assert File.read!(@rollback) =~ "'inventory-opclass:'"
    assert File.read!(@migration) =~ "'inventory-opfamily:'"
    assert File.read!(@rollback) =~ "'inventory-opfamily:'"
    assert File.read!(@migration) =~ "'inventory-ts-config:'"
    assert File.read!(@rollback) =~ "'inventory-ts-config:'"
    assert File.read!(@migration) =~ "'inventory-ts-dict:'"
    assert File.read!(@rollback) =~ "'inventory-ts-dict:'"

    assert lifecycle_script =~
             "rollback did not serialize with concurrent contract DDL"
  end
end
