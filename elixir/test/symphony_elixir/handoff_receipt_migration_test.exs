defmodule SymphonyElixir.HandoffReceiptMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260807000000_aro_166_handoff_receipts.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260807000000_aro_166_handoff_receipts.down.sql",
              __DIR__
            )

  test "receipt is staging-only, append-only, and contains only the V1 fields" do
    sql = File.read!(@migration)

    refute sql =~ "symphony_production."
    assert sql =~ "checkpoint_sequence bigint generated always as identity"
    assert sql =~ "receipt_schema_version integer not null check (receipt_schema_version = 1)"
    assert sql =~ "recorded_at timestamptz not null default clock_timestamp()"
    assert sql =~ "revoke all on table symphony_staging.handoff_receipts"
    refute sql =~ "grant insert on"
    refute sql =~ "grant update on"
    refute sql =~ "workspace"
    refute sql =~ "prompt"
    refute sql =~ "secret"
  end

  test "only the active generation may append and latest ordering is deterministic" do
    sql = File.read!(@migration)

    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "claims.lease_expires_at > clock_timestamp()"
    assert sql =~ "for update of claims"
    assert sql =~ "receipt requires a matching active claim generation"
    assert sql =~ "order by receipts.generation desc, receipts.checkpoint_sequence desc"
    assert length(Regex.scan(~r/returns table \(\s*receipt_schema_version integer,/s, sql)) == 2
    refute sql =~ "returns setof symphony_staging.handoff_receipts"
    refute sql =~ "select receipts.*"
    assert length(Regex.scan(~r/inserted\.checkpoint_sequence|receipts\.checkpoint_sequence/, sql)) >= 3
  end

  test "fixed step and structured test allowlists are enforced in the database" do
    sql = File.read!(@migration)

    for step <- ~w(preflight branch implementation tests commit push pull_request review) do
      assert sql =~ "('#{step}')"
    end

    assert sql =~ "count(distinct value)"
    assert sql =~ "not exists (select 1 from unnest(completed) value where value = any(pending))"
    assert sql =~ "array['name', 'status']::text[]"
    assert sql =~ "jsonb_typeof(result->'name') is distinct from 'string'"
    assert sql =~ "btrim(result->>'name') = ''"
    assert sql =~ "jsonb_typeof(result->'status') is distinct from 'string'"
    assert sql =~ "result->>'status' is null"
    assert sql =~ "('passed', 'failed', 'skipped')"
  end

  test "handoff reads require a new active claim and runtime gets function-only access" do
    sql = File.read!(@migration)

    assert sql =~ "validate_active_claim("
    assert sql =~ "active claim issue mismatch"
    assert sql =~ "grant execute on function"
    assert sql =~ "grant_handoff_api_to_node_login"
    assert sql =~ "select login_role from symphony_staging.node_login_principals"
  end

  test "rollback removes only ARO-166 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'handoff-receipt'"
    assert rollback =~ "drop table if exists symphony_staging.handoff_receipts"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
