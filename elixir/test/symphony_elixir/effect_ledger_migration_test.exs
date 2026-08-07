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
  @effect_ledger Path.expand("../../lib/symphony_elixir/effect_ledger.ex", __DIR__)
  @dynamic_tool Path.expand("../../lib/symphony_elixir/codex/dynamic_tool.ex", __DIR__)
  @agent_runner Path.expand("../../lib/symphony_elixir/agent_runner.ex", __DIR__)
  @claim_service Path.expand("../../lib/symphony_elixir/claim_service.ex", __DIR__)

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
    assert sql =~ "attempt_id uuid"
    assert sql =~ "attempt_expires_at timestamptz"
    assert sql =~ "set search_path = pg_catalog, pg_temp"
  end

  test "begin intent fences stale generations and fingerprint drift" do
    sql = File.read!(@migration)

    assert sql =~ "requested_generation"
    assert sql =~ "claims.issue_id = requested_issue_id"
    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "claims.node_instance_id = requested_node_instance_id"
    assert sql =~ "claims.lease_expires_at > clock_timestamp()"
    assert sql =~ "for update of claims"
    assert sql =~ "effect requires a matching active claim generation"
    assert sql =~ "existing.attempt_expires_at > clock_timestamp()"
    assert sql =~ "'in-flight'::text"
    assert sql =~ "operations.attempt_id = requested_attempt_id"
    assert sql =~ "for update"
    assert sql =~ "request fingerprint mismatch"
    assert sql =~ "operation_id text primary key"
  end

  test "only pending effects can be finalized and unknown effects require reconciliation" do
    sql = File.read!(@migration)

    assert sql =~ "operations.status = 'pending'"
    assert sql =~ "operations.status in ('pending', 'unknown')"
    assert sql =~ "existing.status = 'failed-no-effect'"
    assert sql =~ "existing.status = 'unknown'"
    assert sql =~ "set claim_id = requested_claim_id"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "operations.attempt_id = requested_attempt_id"
    assert sql =~ "reconciliation must produce a definite result"
    assert sql =~ "relinquish_effect"
    assert sql =~ "set attempt_id = null"
    refute sql =~ "exactly-once"
  end

  test "comment reconciliation binds exact payload to the authenticated Linear viewer" do
    source = File.read!(@dynamic_tool)

    assert source =~ "viewer { id }"
    assert source =~ "nodes { id body user { id } }"
    assert source =~ ~s(comment["body"] == expected_body)
    assert source =~ ~S|get_in(comment, ["user", "id"]) == viewer_id|
  end

  test "state lookup failures remain in the definite no-effect retry path" do
    source = File.read!(@dynamic_tool)

    assert source =~ "lookup_linear_state"
    assert source =~ "{:error, reason} -> {:error, :no_effect, reason}"
    assert source =~ "{:error, reason} -> {:error, :unknown, reason}"
  end

  test "managed sessions require the installed effect ledger contract" do
    runner = File.read!(@agent_runner)
    claims = File.read!(@claim_service)

    assert runner =~ "effect_ledger_contract_unavailable"
    assert runner =~ "ClaimService.effect_ledger_ready?"
    assert claims =~ "select symphony_staging.effect_ledger_ready()"
    assert File.read!(@migration) =~ "create or replace function symphony_staging.effect_ledger_ready()"
  end

  test "runtime selects granted attempts and namespaces operation IDs by issue" do
    source = File.read!(@effect_ledger)

    assert source =~ "select status, native_resource, attempt_id::text"

    assert SymphonyElixir.EffectLedger.operation_id("ARO-166", "comment-1") ==
             "ARO-166:comment-1"

    assert SymphonyElixir.EffectLedger.operation_id("ARO-166", "ARO-166:comment-1") ==
             "ARO-166:comment-1"

    assert SymphonyElixir.EffectLedger.operation_id("ARO-166", "ARO-16:comment-1") ==
             "ARO-166:ARO-16:comment-1"

    assert source =~ "defp encode_resource(resource) when is_map(resource), do: resource"
    refute source =~ "Jason.encode!(resource)"

    assert File.read!(@migration) =~
             "left(requested_operation_id, length(requested_issue_id) + 1) <> requested_issue_id || ':'"
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
    assert rollback =~ "finish_effect(text, text, uuid, text, jsonb, text)"
    assert rollback =~ "relinquish_effect(text, text, uuid)"
    assert rollback =~ "effect_ledger_ready()"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
