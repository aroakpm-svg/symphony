defmodule SymphonyElixir.ReviewSettlementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingDisposition, ReviewIdentity, ReviewSettlement}

  test "FindingKey stays stable from H1 to H2 while EvaluationKey changes" do
    {decision, context} = fixture(:follow_up_required)
    {:ok, h2} = FindingDisposition.build_finding_key(Map.put(decision.facts, :source_head_sha, sha("b")))

    assert h2.digest == decision.finding_key.digest
    refute Map.has_key?(decision.finding_key, :source_head_sha)

    assert {:blocked, :evaluated_head_mismatch} =
             ReviewSettlement.settle(decision, %{context | current_head_sha: sha("b")})
  end

  test "follow-up settles only after durable effects and native readback" do
    {decision, context} = fixture(:follow_up_required)

    assert {:settled, evidence} = ReviewSettlement.settle(decision, context)
    assert evidence.status == :follow_up_settled
    assert evidence.merge_authorized? == false
    assert evidence.receipt.finding_key.digest == decision.finding_key.digest
    assert evidence.receipt.native_resources == evidence.receipt.native_readbacks
  end

  test "fix settlement requires publish regression and accepted exact-head review" do
    {decision, context} = fixture(:fix_in_current_pr)

    assert {:settled, %{status: :fix_settled, receipt: receipt}} = ReviewSettlement.settle(decision, context)
    assert receipt.published_head_sha == sha("a")

    assert {:blocked, :fix_settlement_evidence_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:path_evidence, :regression_status], :fail))

    without_publish = Enum.reject(context.operations, &(&1.effect_type == :github_pr_update))

    assert {:blocked, {:settlement_effect_missing, :publish}} =
             ReviewSettlement.settle(decision, %{context | operations: without_publish})
  end

  test "rejected settles after proof revalidation reply and resolve" do
    {decision, context} = fixture(:rejected)
    assert {:settled, %{status: :rejected_settled}} = ReviewSettlement.settle(decision, context)
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

  test "resolve operation identity comes from ResolveAttemptKey" do
    {decision, context} = fixture(:follow_up_required)
    {:ok, expected} = ReviewIdentity.resolve_operation_identity(context.resolve_attempt_key)
    assert get_in(context, [:operation_ids, :resolve]) == expected

    invented = Map.put(context.operation_ids, :resolve, String.duplicate("e", 64))

    assert {:blocked, {:settlement_operation_identity_mismatch, :resolve}} =
             ReviewSettlement.settle(decision, %{context | operation_ids: invented})
  end

  test "head drift reopen and newer trusted evidence block resolve" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, :review_thread_reopened} =
             ReviewSettlement.settle(decision, put_in(context, [:native_readback, :reopened?], true))

    assert {:blocked, :newer_trusted_actionable_finding} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :newer_trusted_actionable?], true)
             )

    assert {:blocked, :review_thread_reopen_status_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:native_readback, :reopened?], nil))
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

  test "claim and identity mismatches fail before effects" do
    {decision, context} = fixture(:follow_up_required)

    assert {:blocked, :settlement_claim_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:claim, :active?], false))

    assert {:blocked, :invalid_settlement_identity} =
             ReviewSettlement.settle(%{decision | finding_key_digest: sha256("wrong")}, context)

    assert {:blocked, :invalid_settlement_input} = ReviewSettlement.settle(nil, context)

    assert {:blocked, :settlement_operations_unavailable} =
             ReviewSettlement.settle(decision, %{context | operations: nil})

    assert {:blocked, :unsupported_settlement_disposition} =
             ReviewSettlement.settle(%{decision | disposition: :unsupported}, context)

    assert {:blocked, :settlement_issue_identity_unverified} =
             ReviewSettlement.settle(decision, put_in(context, [:claim, :issue_id], nil))

    assert {:blocked, {:settlement_native_resource_mismatch, :follow_up_issue}} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :follow_up, :id], "other")
             )

    assert {:blocked, {:settlement_native_resource_mismatch, :resolve}} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:native_readback, :resolve, :review_thread_id], "other-thread")
             )

    assert {:blocked, :settlement_operation_ids_unverified} =
             ReviewSettlement.settle(
               decision,
               put_in(context, [:operation_ids, :receipt], "not-a-digest")
             )

    [first | rest] = context.operations

    assert {:blocked, {:settlement_effect_invalid, :follow_up_issue}} =
             ReviewSettlement.settle(decision, %{context | operations: [%{first | status: :bogus} | rest]})

    assert {:blocked, :invalid_settlement_fingerprint} =
             ReviewSettlement.settle(
               decision,
               %{context | operations: [%{first | request_fingerprint: "nope"} | rest]}
             )

    resolve_native =
      Enum.map(context.operations, fn
        %{effect_type: :github_review_thread_resolve} = operation ->
          %{operation | native_resource: %{id: decision.finding_key.review_thread_id}}

        operation ->
          operation
      end)

    assert {:settled, _} = ReviewSettlement.settle(decision, %{context | operations: resolve_native})

    {rejected, rejected_context} = fixture(:rejected)

    assert {:blocked, :rejection_proof_unverified} =
             ReviewSettlement.settle(put_in(rejected, [:facts, :root_cause_receipt], :no), rejected_context)
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

    {:ok, resolve_attempt_key} =
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
        message_kind: message_kind(disposition),
        effect_type: :github_comment
      })

    {:ok, resolve_id} = ReviewIdentity.resolve_operation_identity(resolve_attempt_key)

    finding_set_digest = sha256(finding_key.digest)
    authorization_identity = "authorization-245"

    {:ok, publish_id} =
      FindingDisposition.operation_id(:github_pr_update, %{
        repository: finding_key.repository,
        pull_request_number: finding_key.pull_request_number,
        evaluated_head_sha: sha("a"),
        finding_set_digest: finding_set_digest,
        authorization_identity: authorization_identity,
        effect_type: :github_pr_update
      })

    fingerprint = fingerprint(decision)
    issue_id = "ARO-245"

    operations = [
      operation(issue_id, linear_id, :linear_issue_create, fingerprint, %{id: "ARO-999"}),
      operation(issue_id, reply_id, :github_comment, fingerprint, %{comment_id: "reply-1"}),
      operation(issue_id, publish_id, :github_pr_update, fingerprint, %{
        commit_sha: sha("a"),
        tree_sha: sha("c")
      }),
      operation(issue_id, resolve_id, :github_review_thread_resolve, fingerprint, %{
        review_thread_id: finding_key.review_thread_id,
        resolved?: true
      })
    ]

    context = %{
      current_head_sha: sha("a"),
      source_head_sha: sha("a"),
      evaluated_head_sha: sha("a"),
      claim: %{active?: true, issue_id: issue_id, claim_id: "claim-1", generation: 1},
      operation_ids: %{
        follow_up_issue: linear_id,
        reply: reply_id,
        resolve: resolve_id,
        publish: publish_id
      },
      operations: operations,
      reply_body: "settled by Symphony",
      resolve_attempt_key: resolve_attempt_key,
      path_evidence: %{
        managed_publish_confirmed?: true,
        regression_status: :pass,
        accepted_review_head_sha: sha("a"),
        finding_set_digest: finding_set_digest,
        authorization_identity: authorization_identity
      },
      native_readback: %{
        publish: %{commit_sha: sha("a"), tree_sha: sha("c")},
        follow_up: %{
          id: "ARO-999",
          identifier: "ARO-999",
          url: "https://linear.app/issue/ARO-999",
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
        evaluated_head_sha: sha("a"),
        policy_version: "design-4-v1",
        target: %{
          repository: decision.finding_key.repository,
          pull_request_number: decision.finding_key.pull_request_number
        },
        payload: %{settlement: true},
        resulting_tree_or_commit: sha("a"),
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
      current_head_sha: sha("a"),
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
        evaluated_head_sha: sha("a"),
        current_head_sha: sha("a"),
        native_readback: native
      }
    })
  end

  defp sha(char), do: String.duplicate(char, 40)

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
