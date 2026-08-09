defmodule SymphonyElixir.HandoffReceiptMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql",
              __DIR__
            )

  test "migration is staging-only and persists the exact V1 contract" do
    sql = File.read!(@migration)

    refute sql =~ "symphony_production."
    assert sql =~ "create table symphony_staging.handoff_receipts"
    assert sql =~ "checkpoint_kind in ('pushed', 'pull_request', 'reviewed')"
    assert sql =~ "tested_head_sha = head_sha"
    assert sql =~ "jsonb_array_length(test_results) > 0"
    assert sql =~ "create or replace function symphony_staging.append_handoff_receipt("
    assert sql =~ "create or replace function symphony_staging.latest_handoff_receipt("
    refute sql =~ "current_phase"
    refute sql =~ "completed_step_ids"
    refute sql =~ "pending_step_ids"
  end

  test "append fences the exact active owner and derives the complete effect snapshot" do
    sql = File.read!(@migration)

    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "claims.node_id = requested_node_id"
    assert sql =~ "claims.node_instance_id = requested_node_instance_id"
    assert sql =~ "claims.lease_expires_at > clock_timestamp()"
    assert sql =~ "for update of claims"
    assert sql =~ "from symphony_staging.effect_operations operations"
    assert sql =~ "operations.issue_id = requested_issue_id"
    assert sql =~ "array_agg(operations.operation_id order by operations.operation_id)"
  end

  test "test result names and statuses are JSON strings and non-null, and identity access is revoked" do
    sql = File.read!(@migration)

    assert sql =~ "jsonb_typeof(item -> 'name') <> 'string'"
    assert sql =~ "jsonb_typeof(item -> 'status') <> 'string'"
    assert sql =~ "item ->> 'name' is null"
    assert sql =~ "item ->> 'status' is null"

    assert Regex.match?(
             ~r/revoke all on sequence symphony_staging\.handoff_receipts_checkpoint_sequence_seq\s+from public, anon, authenticated, service_role,\s+symphony_staging_runtime, symphony_staging_provisioner;/,
             sql
           )

    refute Regex.match?(
             ~r/^revoke all on sequence symphony_staging\.handoff_receipts_checkpoint_sequence$/m,
             sql
           )
  end

  test "runtime access is function-only and follows enrolled node roles" do
    sql = File.read!(@migration)

    assert sql =~ "revoke all on table symphony_staging.handoff_receipts"
    assert sql =~ "grant execute on function"
    assert sql =~ "to symphony_staging_runtime"
    assert sql =~ "grant_handoff_receipt_api_to_node_login"
    assert sql =~ "select login_role from symphony_staging.node_login_principals"
    assert sql =~ "set search_path = pg_catalog, pg_temp"
  end

  test "latest requires a fresh same-issue claim and returns newest generation then sequence" do
    sql = File.read!(@migration)

    assert length(Regex.scan(~r/claims.issue_id = requested_issue_id/, sql)) >= 2
    assert sql =~ "order by receipts.generation desc, receipts.checkpoint_sequence desc"
    assert sql =~ "limit 1"
  end

  test "rollback removes only ARO-166 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'handoff-receipts'"
    assert rollback =~ "drop table if exists symphony_staging.handoff_receipts"
    refute rollback =~ "effect_operations"
    refute rollback =~ "issue_claims"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
