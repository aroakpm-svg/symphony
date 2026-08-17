defmodule SymphonyElixir.ReviewSettlementReceiptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingDisposition, ReviewIdentity, ReviewSettlement, ReviewSettlementReceipt}

  defmodule Ledger do
    def execute(_connection, :review_settlement_receipt, _context, adapter, _reconciler) do
      adapter.()
    end
  end

  defmodule MismatchLedger do
    def execute(_connection, :review_settlement_receipt, _context, _adapter, _reconciler),
      do: {:ok, %{other: true}}
  end

  defmodule BoomLedger do
    def execute(_connection, :review_settlement_receipt, _context, _adapter, _reconciler),
      do: {:error, :boom}
  end

  defmodule FoundLedger do
    def execute(_connection, :review_settlement_receipt, _context, _adapter, reconciler),
      do: reconciler.()
  end

  test "record persists the rebuilt ReviewIdentity receipt" do
    {decision, context} = settle_fixture()
    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)

    assert {:ok, receipt} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, evidence, context.operations)

    assert {:ok, ^receipt} = ReviewIdentity.reconcile_receipt(%{original_receipt: receipt})
  end

  test "pending reconcile requires the original immutable receipt" do
    {decision, context} = settle_fixture()
    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)

    operations = [
      %{
        effect_type: :review_settlement_receipt,
        status: :pending,
        operation_id: "ARO-245:receipt",
        request_fingerprint: hd(context.operations).request_fingerprint,
        native_resource: evidence.receipt
      }
    ]

    assert :ok = ReviewSettlementReceipt.reconcile_pending(:conn, Ledger, context.claim, operations)

    assert {:error, :terminal_receipt_evidence_unavailable} =
             ReviewSettlementReceipt.reconcile_pending(:conn, Ledger, context.claim, [
               %{
                 effect_type: :review_settlement_receipt,
                 status: :pending,
                 operation_id: "ARO-245:receipt",
                 request_fingerprint: hd(context.operations).request_fingerprint,
                 native_resource: %{recovered_from_pending_receipt?: true}
               }
             ])
  end

  test "synthetic or mismatched stored receipts fail closed" do
    {decision, context} = settle_fixture()
    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)

    assert {:error, :settlement_receipt_mismatch} =
             ReviewSettlementReceipt.record(
               :conn,
               MismatchLedger,
               context.claim,
               decision,
               evidence,
               context.operations
             )

    assert {:error, :invalid_pending_settlement_operations} =
             ReviewSettlementReceipt.reconcile_pending(:conn, Ledger, context.claim, :no)

    pending = [
      %{
        effect_type: :review_settlement_receipt,
        status: :pending,
        operation_id: "receipt",
        request_fingerprint: hd(context.operations).request_fingerprint,
        native_resource: evidence.receipt
      }
    ]

    assert {:error, :invalid_pending_settlement_receipt} =
             ReviewSettlementReceipt.reconcile_pending(:conn, BoomLedger, context.claim, pending)

    assert {:error, :invalid_pending_settlement_receipt} =
             ReviewSettlementReceipt.reconcile_pending(:conn, FoundLedger, context.claim, pending)

    assert {:error, :invalid_settlement_receipt} =
             ReviewSettlementReceipt.record(:conn, FoundLedger, context.claim, decision, evidence, context.operations)

    assert :ok =
             ReviewSettlementReceipt.reconcile_pending(:conn, Ledger, %{context.claim | issue_id: nil}, [
               %{
                 effect_type: :review_settlement_receipt,
                 status: :pending,
                 operation_id: 1,
                 native_resource: evidence.receipt
               }
             ])

    assert {:error, :settlement_receipt_mismatch} =
             ReviewSettlementReceipt.reconcile_pending(:conn, MismatchLedger, context.claim, [
               %{
                 effect_type: :review_settlement_receipt,
                 status: :pending,
                 operation_id: "receipt",
                 native_resource: evidence.receipt
               }
             ])

    assert {:error, :invalid_settlement_receipt} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, :no, context.operations)

    assert {:error, :settlement_fingerprint_unavailable} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, evidence, :no)

    assert {:error, :settlement_fingerprint_unavailable} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, evidence, [
               %{request_fingerprint: "nope"}
             ])

    assert {:ok, _} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, evidence.receipt, context.operations)

    assert {:error, {:missing_field, :repository}} =
             ReviewSettlementReceipt.record(:conn, Ledger, context.claim, decision, %{status: :fix_settled}, context.operations)
  end

  defp settle_fixture do
    facts = %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 38,
      source_head_sha: sha("a"),
      review_thread_id: "thread-245",
      selected_review_comment_id: "comment-245",
      body: "finding"
    }

    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :follow_up_required,
      follow_up_destination: "Backlog",
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest,
      facts: facts
    }

    {:ok, evaluation_key} =
      ReviewIdentity.build_evaluation_key(%{
        finding_key: finding_key,
        source_head_sha: sha("a"),
        evaluated_head_sha: sha("a"),
        current_head_sha: sha("a"),
        claim_id: "claim-1",
        generation: 1
      })

    {:ok, attempt} =
      ReviewIdentity.build_resolve_attempt_key(%{
        evaluation_key: evaluation_key,
        thread_state: :unresolved,
        native_thread: %{
          repository: finding_key.repository,
          pull_request_number: finding_key.pull_request_number,
          review_thread_id: finding_key.review_thread_id,
          thread_state: :unresolved,
          observed_head_sha: sha("a")
        }
      })

    {:ok, linear_id} =
      FindingDisposition.operation_id(:linear_issue_create, %{
        repository: finding_key.repository,
        pull_request_number: finding_key.pull_request_number,
        finding_lineage_key: lineage_key,
        destination: "Backlog",
        effect_type: :linear_issue_create
      })

    {:ok, reply_id} =
      FindingDisposition.operation_id(:github_comment, %{
        repository: finding_key.repository,
        pull_request_number: finding_key.pull_request_number,
        review_thread_id: finding_key.review_thread_id,
        finding_key: finding_key,
        message_kind: :follow_up,
        effect_type: :github_comment
      })

    {:ok, resolve_id} = ReviewIdentity.resolve_operation_identity(attempt)

    {:ok, fingerprint} =
      FindingDisposition.request_fingerprint(%{
        disposition: :follow_up_required,
        finding_key: finding_key,
        finding_lineage_key: lineage_key,
        evaluated_head_sha: sha("a"),
        policy_version: "design-4-v1",
        target: %{repository: finding_key.repository, pull_request_number: finding_key.pull_request_number},
        payload: %{settlement: true},
        resulting_tree_or_commit: sha("a"),
        expected_transition: :settled
      })

    issue_id = "ARO-245"

    operations = [
      %{
        operation_id: issue_id <> ":" <> linear_id,
        effect_type: :linear_issue_create,
        request_fingerprint: fingerprint,
        status: :succeeded,
        native_resource: %{id: "ARO-999"},
        issue_id: issue_id
      },
      %{
        operation_id: issue_id <> ":" <> reply_id,
        effect_type: :github_comment,
        request_fingerprint: fingerprint,
        status: :succeeded,
        native_resource: %{comment_id: "reply-1"},
        issue_id: issue_id
      },
      %{
        operation_id: issue_id <> ":" <> resolve_id,
        effect_type: :github_review_thread_resolve,
        request_fingerprint: fingerprint,
        status: :succeeded,
        native_resource: %{review_thread_id: finding_key.review_thread_id, resolved?: true},
        issue_id: issue_id
      }
    ]

    context = %{
      current_head_sha: sha("a"),
      claim: %{active?: true, issue_id: issue_id, claim_id: "claim-1", generation: 1},
      operation_ids: %{follow_up_issue: linear_id, reply: reply_id, resolve: resolve_id},
      operations: operations,
      reply_body: "settled by Symphony",
      native_readback: %{
        follow_up: %{
          id: "ARO-999",
          identifier: "ARO-999",
          destination: "Backlog",
          state: "Backlog",
          finding_lineage_key_digest: lineage_key.digest
        },
        reply: %{
          id: "reply-1",
          body: "settled by Symphony",
          finding_key_digest: finding_key.digest,
          head_sha: sha("a")
        },
        resolve: %{
          repository: finding_key.repository,
          pull_request_number: finding_key.pull_request_number,
          review_thread_id: finding_key.review_thread_id,
          resolved?: true,
          head_sha: sha("a")
        },
        reopened?: false,
        newer_trusted_actionable?: false
      }
    }

    {decision, context}
  end

  defp sha(char), do: String.duplicate(char, 40)
end
