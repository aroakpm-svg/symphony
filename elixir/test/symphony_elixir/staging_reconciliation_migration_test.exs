defmodule SymphonyElixir.StagingReconciliationMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.down.sql",
              __DIR__
            )

  test "upgrade is fail closed before its first persistent change" do
    sql = File.read!(@migration)
    lock = byte_offset!(sql, "lock table")
    gate_start = byte_offset!(sql, "do $aro_168_gate$")
    gate_end = byte_offset!(sql, "$aro_168_gate$;")
    first_change = byte_offset!(sql, "alter role symphony_staging_runtime reset search_path;")

    assert lock < gate_start
    assert gate_end < first_change
    assert sql =~ "unexpected staging table state"
    assert sql =~ "unexpected staging function state"
    assert sql =~ "unexpected staging index state"
    assert sql =~ "unexpected row-security state"
    assert sql =~ "unexpected trigger attachment state"
    assert sql =~ "unexpected foundation data state"
    assert sql =~ "unsafe role attributes"
    assert sql =~ "unsafe managed membership state"
    assert sql =~ "unexpected legacy policy state"
    assert sql =~ "unexpected foundation ownership state"
    assert sql =~ "unexpected direct object ACL state"
    assert sql =~ "unexpected direct column ACL state"
    assert sql =~ "unexpected ACL or default-ACL state"
    assert sql =~ "unexpected function or schema ACL state"
    assert sql =~ "production must remain empty"
  end

  test "upgrade rejects database role settings and global default ACL drift" do
    sql = File.read!(@migration)

    assert sql =~ "pg_db_role_setting"
    assert sql =~ "setdatabase"
    assert sql =~ "database-scoped role settings"
    assert sql =~ "default_acl.defaclnamespace = 0"
  end

  test "upgrade recognizes the managed PostgreSQL 17 membership tuple" do
    sql = File.read!(@migration)

    assert sql =~ "grantor_role.rolname = 'supabase_admin'"
    assert sql =~ "membership.admin_option"
    assert sql =~ "not membership.inherit_option"
    assert sql =~ "not membership.set_option"
    assert sql =~ "grantor_role.rolname = 'postgres'"
    assert sql =~ "membership.inherit_option"
    assert sql =~ "membership.set_option"
    assert sql =~ "expected_membership_count"
    assert sql =~ "case when current_setting('is_superuser') = 'on' then 1 else 2 end"
  end

  test "upgrade resets only known role settings and installs contract v2 policies" do
    sql = File.read!(@migration)

    assert sql =~ "alter role symphony_staging_runtime reset search_path;"
    assert sql =~ "alter role symphony_staging_provisioner reset search_path;"
    refute sql =~ "reset all"
    refute sql =~ "aro-163-created-role:' ||"
    assert sql =~ "contract_version = 2"
    assert sql =~ "20260724000000_aro_168_staging_reconciliation"

    assert sql =~
             ~r/create policy runtime_read_contract_versions.*contract_name not like 'aro-163-created-role:%'/s

    assert sql =~
             ~r/create policy provisioner_manage_contract_versions.*using \(contract_name not like 'aro-163-created-role:%'\).*with check \(contract_name not like 'aro-163-created-role:%'\)/s
  end

  test "upgrade covers effective RLS, triggers, ACLs, and production namespace catalogs" do
    sql = File.read!(@migration)

    assert sql =~ "object.relrowsecurity"
    assert sql =~ "object.relforcerowsecurity"
    assert sql =~ "permissive"
    assert sql =~ "trigger.tgenabled"
    assert sql =~ "trigger.tgisinternal"
    assert sql =~ "trigger.tgtype"
    assert sql =~ "aclexplode"
    assert sql =~ "column_attribute.attacl"
    assert sql =~ "pg_default_acl"
    assert sql =~ "credential_verifier"

    for catalog <- [
          "pg_class",
          "pg_proc",
          "pg_type",
          "pg_operator",
          "pg_collation",
          "pg_conversion",
          "pg_opclass",
          "pg_opfamily",
          "pg_ts_config",
          "pg_ts_dict",
          "pg_ts_parser",
          "pg_ts_template"
        ] do
      assert sql =~ catalog
    end
  end

  test "rollback preserves roles and foundation objects" do
    sql = File.read!(@rollback)

    refute sql =~ ~r/drop role/i
    refute sql =~ ~r/drop table/i
    refute sql =~ ~r/drop schema/i
    assert sql =~ "rollback refused unexpected v2 state"
    assert sql =~ "rollback refused direct object ACL drift"
    assert sql =~ "rollback refused direct column ACL drift"
    assert sql =~ "rollback refused ACL or default-ACL drift"
    assert sql =~ "rollback refused function or schema ACL drift"
    assert sql =~ "pg_db_role_setting"
    assert sql =~ "contract_version = 1"
    assert sql =~ "20260723000000_aro_163_staging_foundation"
    assert sql =~ "set search_path = pg_catalog, symphony_staging"
  end

  defp byte_offset!(haystack, needle) do
    {offset, _length} = :binary.match(haystack, needle)
    offset
  end
end
