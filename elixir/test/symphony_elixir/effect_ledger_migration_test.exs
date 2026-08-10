defmodule SymphonyElixir.EffectLedgerMigrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EffectLedger

  @migration Path.expand(
               "../../priv/symphony_migrations/20260805000000_aro_165_effect_ledger.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260805000000_aro_165_effect_ledger.down.sql",
              __DIR__
            )
  @finding_readback_migration Path.expand(
                                "../../priv/symphony_migrations/20260809000000_finding_effect_readback.sql",
                                __DIR__
                              )
  @finding_readback_rollback Path.expand(
                               "../../priv/symphony_migrations/20260809000000_finding_effect_readback.down.sql",
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
    assert source =~ ~s(context.issue_id <> ":" <> context.operation_id)
    assert source =~ "defp encode_resource(resource) when is_map(resource), do: resource"
    refute source =~ "Jason.encode!(resource)"
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

  test "finding readback is function-only and scoped to the active claim" do
    assert File.exists?(@finding_readback_migration)
    sql = File.read!(@finding_readback_migration)

    assert sql =~ "create or replace function symphony_staging.list_effect_operations"
    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "revoke all on table symphony_staging.effect_operations"
    refute sql =~ "grant select on table symphony_staging.effect_operations"
    refute sql =~ "symphony_production"

    assert File.exists?(@finding_readback_rollback)
    rollback = File.read!(@finding_readback_rollback)
    assert rollback =~ "finding-effect-readback"
    refute rollback =~ "drop table if exists symphony_staging.effect_operations"
    refute rollback =~ "drop function if exists symphony_staging.begin_effect"
  end

  test "EffectLedger exposes only the Design 2 list_operations/2 readback wrapper" do
    source = File.read!(@effect_ledger)

    assert source =~ "def list_operations(connection, claim_context)"
    assert length(Regex.scan(~r/def list_operations\(/, source)) == 1
    refute source =~ "def list(connection, claim_context, effect_type)"
  end

  test "list_operations passes only claim context and strictly decodes operation rows" do
    claim = claim_context()
    test_pid = self()

    connection = fn sql, params ->
      send(test_pid, {:query, sql, params})

      {:ok,
       %Postgrex.Result{
         rows: [
           [
             "operation-1",
             "github_comment",
             "fingerprint-1",
             "succeeded",
             %{"comment_id" => "comment-1"},
             claim.issue_id,
             claim.claim_id,
             claim.generation
           ]
         ],
         num_rows: 1
       }}
    end

    assert {:ok,
            [
              %{
                operation_id: "operation-1",
                effect_type: :github_comment,
                request_fingerprint: "fingerprint-1",
                status: :succeeded,
                native_resource: %{"comment_id" => "comment-1"},
                issue_id: "issue-1",
                claim_id: "11111111-1111-4111-8111-111111111111",
                generation: 2
              }
            ]} = EffectLedger.list_operations(connection, claim)

    assert_receive {
      :query,
      sql,
      [
        "issue-1",
        "11111111-1111-4111-8111-111111111111",
        2,
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333"
      ]
    }

    assert sql =~ "list_effect_operations"
  end

  test "list_operations rejects unknown statuses, effect types, malformed resources, and duplicates" do
    claim = claim_context()

    for row <- [
          ["operation-1", "github_comment", "fingerprint", "started", nil, "issue-1", "11111111-1111-4111-8111-111111111111", 2],
          ["operation-1", "not-an-effect", "fingerprint", "pending", nil, "issue-1", "11111111-1111-4111-8111-111111111111", 2],
          ["operation-1", "github_comment", "fingerprint", "pending", [], "issue-1", "11111111-1111-4111-8111-111111111111", 2],
          ["operation-1", "github_comment", "fingerprint", "pending", nil, "issue-1", "11111111-1111-4111-8111-111111111111", 2],
          ["operation-1", "github_comment", "fingerprint-2", "pending", nil, "issue-1", "11111111-1111-4111-8111-111111111111", 2]
        ] do
      connection = fn _sql, _params ->
        {:ok, %Postgrex.Result{rows: [row, row], num_rows: 2}}
      end

      assert {:error, _reason} = EffectLedger.list_operations(connection, claim)
    end
  end

  test "list_operations rejects rows from another issue, claim, or generation" do
    claim = claim_context()

    for row <- [
          ["operation-1", "github_comment", "fingerprint", "pending", nil, "issue-2", claim.claim_id, claim.generation],
          ["operation-1", "github_comment", "fingerprint", "pending", nil, claim.issue_id, "44444444-4444-4444-8444-444444444444", claim.generation],
          ["operation-1", "github_comment", "fingerprint", "pending", nil, claim.issue_id, claim.claim_id, 3]
        ] do
      connection = fn _sql, _params ->
        {:ok, %Postgrex.Result{rows: [row], num_rows: 1}}
      end

      assert {:error, :effect_operation_context_mismatch} =
               EffectLedger.list_operations(connection, claim)
    end
  end

  defp claim_context do
    %{
      issue_id: "issue-1",
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 2,
      node_id: "22222222-2222-4222-8222-222222222222",
      node_instance_id: "33333333-3333-4333-8333-333333333333"
    }
  end
end
