defmodule SymphonyElixir.ReviewIdentityContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewIdentity

  test "FindingKey digest excludes head and stays stable across H1 to H2" do
    {:ok, h1} = ReviewIdentity.build_finding_key(finding_input())
    {:ok, h2} = ReviewIdentity.build_finding_key(Map.put(finding_input(), :source_head_sha, sha("b")))

    refute Map.has_key?(h1, :source_head_sha)
    assert h1.digest == h2.digest
  end

  test "FindingLineageKey is stable across comment body and head changes" do
    {:ok, first} = ReviewIdentity.build_lineage_key(finding_input())

    {:ok, second} =
      ReviewIdentity.build_lineage_key(
        finding_input()
        |> Map.put(:selected_review_comment_id, "comment-2")
        |> Map.put(:body_sha256, digest_char("2"))
        |> Map.put(:source_head_sha, sha("b"))
      )

    assert first.digest == second.digest
  end

  test "H1 finding without H2 revalidation cannot share EvaluationKey or settle on H2" do
    {:ok, evaluation} = ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("a"), sha("a")))

    assert {:error, :current_head_mismatch} =
             ReviewIdentity.exact_head(:current, evaluation, sha("b"))

    assert {:error, :evaluated_head_mismatch} =
             ReviewIdentity.exact_head(:evaluated, evaluation, sha("b"))
  end

  test "verified H2 revalidation creates a new EvaluationKey and can settle on H2" do
    {:ok, finding} = ReviewIdentity.build_finding_key(finding_input())
    {:ok, h1} = ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("a"), sha("a")))
    {:ok, h2} = ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("b"), sha("b")))

    assert h1.finding_key.digest == finding.digest
    assert h2.finding_key.digest == finding.digest
    refute h1.digest == h2.digest
    assert :ok = ReviewIdentity.exact_head(:source, h2, sha("a"))
    assert :ok = ReviewIdentity.exact_head(:evaluated, h2, sha("b"))
    assert :ok = ReviewIdentity.exact_head(:current, h2, sha("b"))
  end

  test "same-head reopen without a new comment creates a new ResolveAttemptKey" do
    {:ok, initial} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:unresolved, nil))
    {:ok, after_resolve} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:resolved, digest_char("1")))
    {:ok, reopened} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:unresolved, digest_char("1")))

    refute initial.digest == after_resolve.digest
    refute after_resolve.digest == reopened.digest
    refute initial.reopen_epoch == reopened.reopen_epoch
  end

  test "reopened resolve operation identity differs so native resolve must run again" do
    {:ok, first} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:resolved, digest_char("1")))
    {:ok, second} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:unresolved, digest_char("1")))
    {:ok, first_op} = ReviewIdentity.resolve_operation_identity(first)
    {:ok, second_op} = ReviewIdentity.resolve_operation_identity(second)

    refute first_op == second_op
  end

  test "reopen epoch is deterministic across process-local restart with the same native proof" do
    input = resolve_input(:unresolved, digest_char("1"))
    {:ok, first} = ReviewIdentity.derive_reopen_epoch(input)
    {:ok, second} = ReviewIdentity.derive_reopen_epoch(input)

    assert first == second
  end

  test "resolved native state without prior succeeded resolve fails closed" do
    assert {:error, :resolved_without_prior_resolve} =
             ReviewIdentity.derive_reopen_epoch(resolve_input(:resolved, nil))
  end

  test "missing native unresolved readback fails closed instead of using a counter" do
    input = Map.delete(resolve_input(:unresolved, digest_char("1")), :native_thread)

    assert {:error, :native_thread_state_unverified} = ReviewIdentity.derive_reopen_epoch(input)
  end

  test "pending receipt retries only the original immutable payload" do
    {:ok, receipt} = ReviewIdentity.build_settlement_receipt(receipt_input())

    assert {:ok, ^receipt} = ReviewIdentity.reconcile_receipt(%{original_receipt: receipt})
  end

  test "pending receipt without original evidence stays blocked and cannot synthesize recovery" do
    assert {:error, :terminal_receipt_evidence_unavailable} =
             ReviewIdentity.reconcile_receipt(%{
               recovered_from_pending_receipt?: true,
               evidence_sha256: String.duplicate("e", 64)
             })

    assert {:error, :synthetic_terminal_evidence} =
             ReviewIdentity.evidence_digest(%{
               status: :fix_settled,
               native_confirmed?: true,
               recovered_from_pending_receipt?: true
             })
  end

  test "supplied synthetic evidence_sha256 is rejected unless it recomputes from evidence" do
    assert {:error, :evidence_digest_mismatch} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :evidence_sha256, String.duplicate("e", 64)))
  end

  test "process restart on the same head with a complete receipt replays the same digest" do
    {:ok, first} = ReviewIdentity.build_settlement_receipt(receipt_input())
    {:ok, second} = ReviewIdentity.build_settlement_receipt(receipt_input())

    assert first.digest == second.digest
    assert {:ok, ^first} = ReviewIdentity.reconcile_receipt(%{original_receipt: second})
  end

  test "old receipt on a different head cannot suppress a new evaluation" do
    {:ok, h1} = ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("a"), sha("a")))
    {:ok, h2} = ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("b"), sha("b")))
    {:ok, receipt} = ReviewIdentity.build_settlement_receipt(receipt_input())

    {:ok, h2_attempt} =
      ReviewIdentity.build_resolve_attempt_key(%{
        evaluation_key: h2,
        thread_state: :unresolved,
        native_thread: %{
          repository: "aroakpm-svg/symphony",
          pull_request_number: 39,
          review_thread_id: "thread-1",
          thread_state: :unresolved,
          observed_head_sha: sha("b")
        }
      })

    assert {:error, :settled_head_not_current_evaluation} =
             ReviewIdentity.build_settlement_receipt(
               receipt_input()
               |> Map.put(:evaluation_key, h2)
               |> Map.put(:resolve_attempt_key, h2_attempt)
               |> Map.put(:settled_head_sha, h1.current_head_sha)
             )

    assert receipt.evaluation_key.digest != h2.digest
  end

  test "component effects without terminal evidence cannot become a settlement receipt" do
    assert {:error, :invalid_settlement_evidence} =
             ReviewIdentity.evidence_digest(%{reply_succeeded?: true, resolve_succeeded?: false})
  end

  test "mixed findings keep independent evaluation and resolve identities" do
    first = finding_input()
    second = Map.put(finding_input(), :selected_review_comment_id, "comment-2")
    {:ok, first_eval} = ReviewIdentity.build_evaluation_key(Map.put(evaluation_input(), :finding_key, elem(ReviewIdentity.build_finding_key(first), 1)))
    {:ok, second_eval} = ReviewIdentity.build_evaluation_key(Map.put(evaluation_input(), :finding_key, elem(ReviewIdentity.build_finding_key(second), 1)))

    refute first_eval.digest == second_eval.digest
    refute first_eval.finding_key.digest == second_eval.finding_key.digest
  end

  test "receipt native resource or repository/PR/head mismatch is blocked" do
    {:ok, other_finding} =
      ReviewIdentity.build_finding_key(Map.put(finding_input(), :repository, "aroakpm-svg/other"))

    assert {:error, :evaluation_finding_mismatch} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :finding_key, other_finding))

    assert {:error, :settled_head_not_current_evaluation} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :settled_head_sha, sha("b")))
  end

  test "malformed nested rejection keys and missing native reopen status are blocked" do
    assert {:error, {:missing_field, :repository}} =
             ReviewIdentity.build_finding_key(%{digest: String.duplicate("f", 64)})

    assert {:error, {:missing_field, :repository}} = ReviewIdentity.derive_reopen_epoch(%{})
  end

  defp receipt_input do
    {:ok, finding} = ReviewIdentity.build_finding_key(finding_input())
    {:ok, lineage} = ReviewIdentity.build_lineage_key(finding_input())
    {:ok, evaluation} = ReviewIdentity.build_evaluation_key(evaluation_input())
    {:ok, attempt} = ReviewIdentity.build_resolve_attempt_key(resolve_input(:unresolved, nil))

    %{
      finding_key: finding,
      finding_lineage_key: lineage,
      evaluation_key: evaluation,
      resolve_attempt_key: attempt,
      disposition: :fix_in_current_pr,
      settled_head_sha: sha("a"),
      published_head_sha: sha("a"),
      operation_ids: %{
        reply: digest_char("1"),
        resolve: digest_char("2"),
        receipt: digest_char("3")
      },
      native_resources: %{
        reply: %{id: "reply-1"},
        resolve: %{thread_id: "thread-1", state: :resolved}
      },
      evidence: %{status: :fix_settled, native_confirmed?: true}
    }
  end

  defp resolve_input(thread_state, prior_resolve_operation_id) do
    {:ok, evaluation} = ReviewIdentity.build_evaluation_key(evaluation_input())

    %{
      evaluation_key: evaluation,
      thread_state: thread_state,
      prior_resolve_operation_id: prior_resolve_operation_id,
      native_thread: %{
        repository: "aroakpm-svg/symphony",
        pull_request_number: 39,
        review_thread_id: "thread-1",
        thread_state: thread_state,
        observed_head_sha: sha("a")
      }
    }
  end

  defp evaluation_input(source \\ sha("a"), evaluated \\ sha("a"), current \\ sha("a")) do
    {:ok, finding} = ReviewIdentity.build_finding_key(finding_input())

    %{
      finding_key: finding,
      source_head_sha: source,
      evaluated_head_sha: evaluated,
      current_head_sha: current,
      claim_id: "claim-1",
      generation: 1
    }
  end

  defp finding_input do
    %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 39,
      review_thread_id: "thread-1",
      selected_review_comment_id: "comment-1",
      body_sha256: digest_char("b")
    }
  end

  defp sha(char), do: String.duplicate(char, 40)
  defp digest_char(char), do: String.duplicate(char, 64)
end
