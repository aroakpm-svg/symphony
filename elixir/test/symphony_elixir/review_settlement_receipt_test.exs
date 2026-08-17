defmodule SymphonyElixir.ReviewSettlementReceiptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingDisposition, ReviewSettlementReceipt}

  defmodule ReconcilingLedger do
    def execute(_connection, :review_settlement_receipt, _context, adapter, reconciler) do
      {:ok, expected} = adapter.()

      case reconciler.() do
        {:found, ^expected} -> {:ok, expected}
        other -> {:error, {:unexpected_reconciliation, other}}
      end
    end
  end

  test "pending or unknown receipt retries reconcile from deterministic terminal proof" do
    head = String.duplicate("a", 40)

    facts = %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 39,
      source_head_sha: head,
      review_thread_id: "thread-1",
      selected_review_comment_id: "comment-1",
      body: "P1 finding"
    }

    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest
    }

    {:ok, fingerprint} =
      FindingDisposition.request_fingerprint(%{
        disposition: decision.disposition,
        finding_key: finding_key,
        finding_lineage_key: lineage_key,
        evaluated_head_sha: head,
        policy_version: "design-4-v1",
        target: %{repository: finding_key.repository, pull_request_number: 39},
        payload: %{settlement: true},
        resulting_tree_or_commit: head,
        expected_transition: :settled
      })

    claim = %{
      issue_id: "ARO-245",
      claim_id: "11111111-1111-4111-8111-111111111111",
      generation: 1,
      node_id: "22222222-2222-4222-8222-222222222222",
      node_instance_id: "33333333-3333-4333-8333-333333333333"
    }

    operations = [%{request_fingerprint: fingerprint}]

    assert {:ok, %{"verified" => true}} =
             ReviewSettlementReceipt.record(
               :connection,
               ReconcilingLedger,
               claim,
               decision,
               %{status: :fix_settled},
               operations
             )
  end
end
