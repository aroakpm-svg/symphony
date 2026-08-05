defmodule SymphonyElixir.EffectLedgerMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260805000000_aro_165_effect_ledger.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260805000000_aro_165_effect_ledger.down.sql",
              __DIR__
            )

  test "migration is staging-only and fixes the allowed effect set" do
    sql = File.read!(@migration)

    refute sql =~ "symphony_production."

    for effect_type <- ~w(
          linear_comment github_comment git_commit git_push github_pr_create
          github_pr_update linear_state
        ) do
      assert sql =~ "'#{effect_type}'"
    end

    assert sql =~ "status in ('pending', 'succeeded', 'failed-no-effect', 'unknown')"
    assert sql =~ "set search_path = pg_catalog, pg_temp"
  end

  test "begin intent fences stale generations and fingerprint drift" do
    sql = File.read!(@migration)

    assert sql =~ "validate_active_claim("
    assert sql =~ "requested_generation"
    assert sql =~ "for update"
    assert sql =~ "request fingerprint mismatch"
    assert sql =~ "operation_id text primary key"
  end

  test "only pending effects can be finalized and unknown effects require reconciliation" do
    sql = File.read!(@migration)

    assert sql =~ "operations.status = 'pending'"
    assert sql =~ "operations.status in ('pending', 'unknown')"
    assert sql =~ "existing.status = 'failed-no-effect'"
    assert sql =~ "reconciliation must produce a definite result"
    refute sql =~ "exactly-once"
  end

  test "runtime access is function-only and existing node logins receive it" do
    sql = File.read!(@migration)

    assert sql =~ "revoke all on table symphony_staging.effect_operations"
    assert sql =~ "grant execute on function"
    assert sql =~ "to symphony_staging_runtime"
    assert sql =~ "grant_effect_api_to_node_login"
    assert sql =~ "select login_role from symphony_staging.node_login_principals"
  end

  test "rollback removes only ARO-165 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'effect-ledger'"
    assert rollback =~ "drop table if exists symphony_staging.effect_operations"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
