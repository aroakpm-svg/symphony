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
    gate_end = byte_offset!(sql, "$aro_168_gate$;")
    first_change = byte_offset!(sql, "alter role symphony_staging_runtime reset search_path;")

    assert gate_end < first_change
    assert sql =~ "unexpected staging table state"
    assert sql =~ "unexpected staging function state"
    assert sql =~ "unexpected foundation data state"
    assert sql =~ "unsafe role attributes"
    assert sql =~ "unsafe managed membership state"
    assert sql =~ "unexpected legacy policy state"
    assert sql =~ "production must remain empty"
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
    assert sql =~ ") <> 2"
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

  test "rollback preserves roles and foundation objects" do
    sql = File.read!(@rollback)

    refute sql =~ ~r/drop role/i
    refute sql =~ ~r/drop table/i
    refute sql =~ ~r/drop schema/i
    assert sql =~ "rollback refused unexpected v2 state"
    assert sql =~ "contract_version = 1"
    assert sql =~ "20260723000000_aro_163_staging_foundation"
    assert sql =~ "set search_path = pg_catalog, symphony_staging"
  end

  defp byte_offset!(haystack, needle) do
    {offset, _length} = :binary.match(haystack, needle)
    offset
  end
end
