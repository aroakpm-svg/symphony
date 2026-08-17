defmodule SymphonyElixir.ReviewSettlementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingDisposition, ReviewSettlement}

  test "follow-up settles only after durable effects and native readback" do
    {decision, context} = fixture(:follow_up_required)

    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)
    assert evidence.status == :follow_up_settled
    assert evidence.merge_authorized? == false
    assert evidence.finding_lineage_key == decision.finding_lineage_key
  end

  test "blocked findings never produce settlement effects" do
    {decision, context} = fixture(:blocked_unverified)
    assert {:blocked, :blocked_unverified} = ReviewSettlement.settle(decision, context)
  end

  test "pending unknown and conflicting ledger effects fail closed" do
    {decision, context} = fixture(:follow_up_required)

    for status <- [:pending, :unknown] do
      operations = [Map.put(hd(context.operations), :status, status) | tl(context.operations)]

      assert {:blocked, :settlement_reconciliation_required} =
               ReviewSettlement.settle(decision, %{context | operations: operations})
    end

    [first | rest] = context.operations
    conflicting = [%{first | request_fingerprint: "other"}, first | rest]

    assert {:blocked, :settlement_operation_conflict} =
             ReviewSettlement.settle(decision, %{context | operations: conflicting})
  end

  test "response loss and failed resolve remain unresolved" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, {:settlement_native_resource_mismatch, :reply}} =
             ReviewSettlement.settle(decision, put_in(context, [:native_readback, :reply], nil))

    operations =
      Enum.map(context.operations, fn
        %{effect_type: :github_review_thread_resolve} = operation ->
          %{operation | status: :failed_no_effect, native_resource: nil}

        operation ->
          operation
      end)

    assert {:blocked, {:settlement_effect_failed, :resolve}} =
             ReviewSettlement.settle(decision, %{context | operations: operations})
  end

  test "head drift reopen and newer trusted evidence block resolve" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, :settlement_head_drift} =
             ReviewSettlement.settle(decision, %{context | current_head_sha: sha("b")})

    assert {:blocked, :review_thread_reopened} =
             ReviewSettlement.settle(decision, put_in(context, [:native_readback, :reopened?], true))

    assert {:blocked, :newer_trusted_actionable_finding} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :newer_trusted_actionable?], true)
             )
  end

  test "fix settlement requires publish regression and accepted exact-head review" do
    {decision, context} = fixture(:fix_in_current_pr)

    assert {:settled, %{status: :fix_settled}} = ReviewSettlement.settle(decision, context)

    assert {:blocked, :fix_settlement_evidence_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:path_evidence, :regression_status], :fail))
  end

  test "rejected reaches rejected_settled only with canonical proof and final readback" do
    {decision, context} = fixture(:rejected)

    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)
    assert evidence.status == :rejected_settled
    assert evidence.disposition == :rejected

    bad = put_in(decision, [:facts, :root_cause_receipt, :evidence_conflict?], true)
    assert {:blocked, :rejection_proof_unverified} = ReviewSettlement.settle(bad, context)
  end

  test "claim and identity mismatches fail before effects" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, :settlement_claim_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:claim, :active?], false))

    assert {:blocked, :invalid_settlement_identity} =
             ReviewSettlement.settle(%{decision | finding_key_digest: sha256("wrong")}, context)
  end

  test "ledger operation IDs must use the claim issue namespace" do
    {decision, context} = fixture(:follow_up_required)
    [first | rest] = context.operations
    bare_id = get_in(context, [:operation_ids, :follow_up_issue])

    assert {:blocked, {:settlement_effect_missing, :follow_up_issue}} =
             ReviewSettlement.settle(decision, %{context | operations: [%{first | operation_id: bare_id} | rest]})

    assert {:blocked, :settlement_issue_identity_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:claim, :issue_id], nil))
  end

  test "ledger native resources must identify the same objects as native readback" do
    {decision, context} = fixture(:follow_up_required)

    for {effect_type, role} <- [
          {:linear_issue_create, :follow_up_issue},
          {:github_comment, :reply},
          {:github_review_thread_resolve, :resolve}
        ] do
      operations =
        Enum.map(context.operations, fn
          %{effect_type: ^effect_type} = operation -> %{operation | native_resource: %{id: "different"}}
          operation -> operation
        end)

      assert {:blocked, {:settlement_native_resource_mismatch, ^role}} =
               ReviewSettlement.settle(decision, %{context | operations: operations})
    end
  end

  test "non-canonical operation IDs and fingerprints fail closed" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, {:settlement_operation_identity_mismatch, :follow_up_issue}} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:operation_ids, :follow_up_issue], "invented-operation")
             )

    [first | rest] = context.operations

    assert {:blocked, :invalid_settlement_fingerprint} =
             ReviewSettlement.settle(
               decision,
               %{context | operations: [%{first | request_fingerprint: "not-a-fingerprint"} | rest]}
             )
  end

  test "all malformed settlement and readback shapes fail closed" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, :invalid_settlement_input} = ReviewSettlement.settle(nil, context)

    assert {:blocked, :settlement_operations_unavailable} =
             ReviewSettlement.settle(decision, %{context | operations: nil})

    assert {:blocked, :unsupported_settlement_disposition} =
             ReviewSettlement.settle(%{decision | disposition: :unsupported}, context)

    [first | rest] = context.operations

    assert {:blocked, {:settlement_effect_invalid, :follow_up_issue}} =
             ReviewSettlement.settle(decision, %{context | operations: [%{first | status: :invalid} | rest]})

    assert {:blocked, :follow_up_readback_unverified} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :follow_up, :url], "")
             )

    assert {:blocked, :reply_readback_unverified} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :reply, :body], "wrong reply")
             )

    assert {:blocked, :resolve_readback_unverified} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :thread, :resolved?], false)
             )
  end

  defp fixture(disposition) do
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

    facts = if disposition == :rejected, do: rejected_facts(facts, finding_key, lineage_key), else: facts

    decision = %{
      disposition: disposition,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      finding_key_digest: finding_key.digest,
      facts: facts
    }

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
        message_kind: message_kind(disposition),
        effect_type: :github_comment
      })

    {:ok, resolve_id} =
      FindingDisposition.operation_id(:github_review_thread_resolve, %{
        repository: finding_key.repository,
        pull_request_number: finding_key.pull_request_number,
        review_thread_id: finding_key.review_thread_id,
        finding_lineage_key: lineage_key,
        effect_type: :github_review_thread_resolve
      })

    operation_ids = %{follow_up_issue: linear_id, reply: reply_id, resolve: resolve_id}

    fingerprint = fingerprint(decision)

    issue_id = "ARO-245"

    operations = [
      operation(issue_id, linear_id, :linear_issue_create, fingerprint, %{id: "ARO-999"}),
      operation(issue_id, reply_id, :github_comment, fingerprint, %{comment_id: "reply-1"}),
      operation(issue_id, resolve_id, :github_review_thread_resolve, fingerprint, %{
        review_thread_id: finding_key.review_thread_id,
        resolved?: true
      })
    ]

    context = %{
      current_head_sha: finding_key.source_head_sha,
      claim: %{active?: true, issue_id: issue_id, claim_id: "claim-1", generation: 1},
      operation_ids: operation_ids,
      operations: operations,
      reply_body: "settled by Symphony",
      path_evidence: %{
        managed_publish_confirmed?: true,
        regression_status: :pass,
        accepted_review_head_sha: finding_key.source_head_sha
      },
      native_readback: %{
        follow_up: %{
          id: "ARO-999",
          url: "https://linear.app/issue/ARO-999",
          destination: "Backlog",
          state: "Backlog",
          finding_lineage_key_digest: lineage_key.digest
        },
        reply: %{
          id: "reply-1",
          body: "settled by Symphony",
          finding_key_digest: finding_key.digest,
          head_sha: finding_key.source_head_sha
        },
        thread: %{
          repository: finding_key.repository,
          pull_request_number: finding_key.pull_request_number,
          review_thread_id: finding_key.review_thread_id,
          resolved?: true,
          head_sha: finding_key.source_head_sha
        },
        reopened?: false,
        newer_trusted_actionable?: false
      }
    }

    {decision, context}
  end

  defp operation(issue_id, id, type, fingerprint, native_resource) do
    %{
      operation_id: issue_id <> ":" <> id,
      effect_type: type,
      request_fingerprint: fingerprint,
      status: :succeeded,
      native_resource: native_resource,
      issue_id: issue_id
    }
  end

  defp fingerprint(decision) do
    {:ok, fingerprint} =
      FindingDisposition.request_fingerprint(%{
        disposition: decision.disposition,
        finding_key: decision.finding_key,
        finding_lineage_key: decision.finding_lineage_key,
        evaluated_head_sha: decision.finding_key.source_head_sha,
        policy_version: "design-4-v1",
        target: %{
          repository: decision.finding_key.repository,
          pull_request_number: decision.finding_key.pull_request_number
        },
        payload: %{settlement: true},
        resulting_tree_or_commit: decision.finding_key.source_head_sha,
        expected_transition: :settled
      })

    fingerprint
  end

  defp message_kind(:fix_in_current_pr), do: :fix
  defp message_kind(:follow_up_required), do: :follow_up
  defp message_kind(:rejected), do: :rejected
  defp message_kind(:blocked_unverified), do: :follow_up

  defp rejected_facts(facts, finding_key, lineage_key) do
    native = %{
      verified?: true,
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      current_head_sha: finding_key.source_head_sha,
      finding_key_digest: finding_key.digest,
      finding_lineage_key_digest: lineage_key.digest
    }

    Map.merge(facts, %{
      evidence_conflict?: false,
      root_cause_receipt: %{
        disposition: :reject,
        verified?: true,
        valid?: true,
        evidence_conflict?: false,
        rejection_basis: "canonical evidence contradicts finding",
        evidence_references: ["spec:design-4"],
        review_action: :unresolved_with_reason,
        validation_receipt_status: "PASS",
        hypothesis_rejected?: false,
        finding_key: finding_key,
        finding_lineage_key: lineage_key,
        evaluated_head_sha: finding_key.source_head_sha,
        current_head_sha: finding_key.source_head_sha,
        native_readback: native
      }
    })
  end

  defp sha(char), do: String.duplicate(char, 40)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
