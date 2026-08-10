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
  @retry_migration Path.expand(
                     "../../priv/symphony_migrations/20260810000000_aro_166_handoff_retry_semantics.sql",
                     __DIR__
                   )
  @retry_rollback Path.expand(
                    "../../priv/symphony_migrations/20260810000000_aro_166_handoff_retry_semantics.down.sql",
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
    assert sql =~ "create index handoff_receipts_latest_lookup_idx"
    assert sql =~ "on symphony_staging.handoff_receipts (issue_id, generation desc, checkpoint_sequence desc)"
    assert sql =~ "order by receipts.generation desc, receipts.checkpoint_sequence desc"
    assert sql =~ "limit 1"
  end

  test "rollback removes only ARO-166 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'handoff-receipts'"
    assert rollback =~ "drop index if exists symphony_staging.handoff_receipts_latest_lookup_idx"
    assert rollback =~ "drop table if exists symphony_staging.handoff_receipts"
    refute rollback =~ "effect_operations"
    refute rollback =~ "issue_claims"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end

  test "retry migration binds a generation, deduplicates identities, and preserves rank" do
    sql = File.read!(@retry_migration)

    assert sql =~ "handoff retry migration requires unique checkpoint identities"
    assert sql =~ "current_setting('symphony.handoff_v1_writes_drained', true)"
    assert sql =~ "requires stopped and fully drained V1 receipt writers"
    assert sql =~ "legacy duplicate checkpoint identities"
    assert sql =~ "malformed legacy receipt content"
    assert sql =~ "legacy generation bindings"
    claim_lock = "lock table symphony_staging.issue_claims in exclusive mode"
    receipt_lock = "lock table symphony_staging.handoff_receipts in share row exclusive mode"

    assert sql =~ claim_lock
    assert sql =~ receipt_lock
    drain_guard = "current_setting('symphony.handoff_v1_writes_drained', true)"
    content_helper = "create or replace function symphony_staging.handoff_receipt_content_present"

    assert :binary.match(sql, drain_guard) < :binary.match(sql, content_helper)
    assert :binary.match(sql, content_helper) < :binary.match(sql, claim_lock)
    assert :binary.match(sql, claim_lock) < :binary.match(sql, receipt_lock)

    assert :binary.match(sql, receipt_lock) <
             :binary.match(sql, "handoff retry migration requires valid receipt content")

    assert sql =~ "create or replace function symphony_staging.enforce_handoff_receipt_v2_insert()"
    assert sql =~ "create trigger enforce_handoff_receipt_v2_insert"
    assert sql =~ "before insert on symphony_staging.handoff_receipts"
    assert sql =~ "handoff receipt checkpoint rank cannot regress"

    [preflight, trigger_and_rest] =
      String.split(
        sql,
        "create or replace function symphony_staging.enforce_handoff_receipt_v2_insert()",
        parts: 2
      )

    [trigger_body, _rest] =
      String.split(trigger_and_rest, "create trigger enforce_handoff_receipt_v2_insert", parts: 2)

    refute preflight =~ "new."
    assert sql =~ "create or replace function symphony_staging.handoff_receipt_content_present"
    assert sql =~ "chr(160)"
    assert sql =~ "chr(8239)"
    assert preflight =~ "handoff_receipt_content_present(receipts.issue_id)"
    assert preflight =~ "handoff_receipt_content_present(receipts.branch)"
    assert preflight =~ "handoff_receipt_content_present(item ->> 'name')"
    assert trigger_body =~ "handoff_receipt_content_present(new.issue_id)"
    assert trigger_body =~ "handoff_receipt_content_present(new.branch)"
    assert trigger_body =~ "handoff_receipt_content_present(item ->> 'name')"
    assert sql =~ "legacy checkpoint rank regressions"
    assert sql =~ "prior_checkpoint_rank > ranked_receipts.checkpoint_rank"
    assert sql =~ "count(distinct receipts.repository)"
    assert sql =~ "count(distinct receipts.head_sha)"
    assert sql =~ "count(distinct receipts.pr_number)"
    assert sql =~ "create unique index handoff_receipts_checkpoint_identity_idx"
    assert sql =~ "create index effect_operations_issue_operation_idx"
    assert sql =~ "on symphony_staging.effect_operations (issue_id, operation_id)"
    assert sql =~ "coalesce(pr_number, 0)"
    assert sql =~ "handoff receipt generation is bound to another repository, branch, or head"
    assert sql =~ "handoff receipt generation is bound to another pull request"
    assert sql =~ "handoff_receipt_content_present(requested_branch)"
    assert sql =~ "handoff_receipt_content_present(requested_issue_id)"
    assert sql =~ "latest_checkpoint_rank > requested_checkpoint_rank"
    assert sql =~ "handoff receipt retry identity has conflicting test results"
    assert sql =~ "'handoff-receipts', 2"
    refute sql =~ "symphony_production."
  end

  test "retry rollback removes only the retry contract and restores V1 registration" do
    rollback = File.read!(@retry_rollback)

    assert rollback =~ "delete from symphony_staging.contract_versions"
    assert rollback =~ "'handoff-receipts', 1"
    assert rollback =~ "drop index if exists symphony_staging.handoff_receipts_checkpoint_identity_idx"
    assert rollback =~ "drop index if exists symphony_staging.effect_operations_issue_operation_idx"
    assert rollback =~ "drop trigger if exists enforce_handoff_receipt_v2_insert"
    assert rollback =~ "drop function if exists symphony_staging.enforce_handoff_receipt_v2_insert()"
    assert rollback =~ "drop function if exists symphony_staging.handoff_receipt_content_present(text)"
    refute rollback =~ "drop table"
    refute rollback =~ "drop function symphony_staging.begin_effect"
    refute rollback =~ "drop table symphony_staging.effect_operations"
    refute rollback =~ "drop table symphony_staging.issue_claims"
    refute rollback =~ "symphony_production"
  end
end
