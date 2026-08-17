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

  test "remaining fail-closed clauses stay covered" do
    {:ok, receipt} = ReviewIdentity.build_settlement_receipt(receipt_input())
    {:ok, evaluation} = ReviewIdentity.build_evaluation_key(evaluation_input())
    {:ok, finding} = ReviewIdentity.build_finding_key(finding_input())

    assert {:error, :invalid_finding_key_input} = ReviewIdentity.build_finding_key(:no)
    assert {:error, :invalid_lineage_key_input} = ReviewIdentity.build_lineage_key(:no)
    assert {:error, :invalid_evaluation_key_input} = ReviewIdentity.build_evaluation_key(:no)
    assert {:error, :invalid_reopen_epoch_input} = ReviewIdentity.derive_reopen_epoch(:no)
    assert {:error, :invalid_resolve_attempt_key_input} = ReviewIdentity.build_resolve_attempt_key(:no)
    assert {:error, :invalid_settlement_evidence} = ReviewIdentity.evidence_digest(:no)
    assert {:error, :invalid_settlement_receipt_input} = ReviewIdentity.build_settlement_receipt(:no)
    assert {:error, :terminal_receipt_evidence_unavailable} = ReviewIdentity.reconcile_receipt(:no)
    assert {:error, :invalid_resolve_operation_identity} = ReviewIdentity.resolve_operation_identity(%{})

    assert {:error, :source_head_mismatch} = ReviewIdentity.exact_head(:source, evaluation, sha("b"))
    assert :ok = ReviewIdentity.exact_head(:published, receipt, sha("a"))
    assert {:error, :published_head_mismatch} = ReviewIdentity.exact_head(:published, receipt, sha("b"))
    assert :ok = ReviewIdentity.exact_head(:settled, receipt, sha("a"))
    assert {:error, :settled_head_mismatch} = ReviewIdentity.exact_head(:settled, receipt, sha("b"))
    assert {:error, :exact_head_unverified} = ReviewIdentity.exact_head(:current, evaluation, :bad)

    assert {:error, :non_canonical_finding_key} =
             ReviewIdentity.build_evaluation_key(
               evaluation_input()
               |> Map.put(:finding_key, Map.put(finding, :digest, digest_char("9")))
             )

    other_lineage = %{
      repository: "aroakpm-svg/other",
      pull_request_number: 1,
      review_thread_id: "thread-x"
    }

    assert {:error, :lineage_scope_mismatch} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :finding_lineage_key, other_lineage))

    {:ok, other_eval} =
      ReviewIdentity.build_evaluation_key(evaluation_input(sha("a"), sha("b"), sha("b")))

    {:ok, other_attempt} =
      ReviewIdentity.build_resolve_attempt_key(%{
        evaluation_key: other_eval,
        thread_state: :unresolved,
        native_thread: %{
          repository: "aroakpm-svg/symphony",
          pull_request_number: 39,
          review_thread_id: "thread-1",
          thread_state: :unresolved,
          observed_head_sha: sha("b")
        }
      })

    assert {:error, :resolve_attempt_evaluation_mismatch} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :resolve_attempt_key, other_attempt))

    assert {:error, :settlement_operation_ids_unverified} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :operation_ids, %{}))

    assert {:error, :settlement_native_resources_unverified} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :native_resources, %{}))

    assert {:error, :unsupported_settlement_disposition} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :disposition, :blocked_unverified))

    assert {:error, {:missing_field, :evidence}} =
             ReviewIdentity.build_settlement_receipt(Map.delete(receipt_input(), :evidence))

    assert {:error, {:invalid_sha, :source_head_sha}} =
             ReviewIdentity.build_evaluation_key(Map.put(evaluation_input(), :source_head_sha, "nope"))

    assert {:error, {:invalid_digest, :body_sha256}} =
             ReviewIdentity.build_finding_key(Map.put(finding_input(), :body_sha256, "nope"))

    assert {:ok, without_publish} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :published_head_sha, "nope"))

    assert without_publish.published_head_sha == nil

    assert {:ok, ^receipt} = ReviewIdentity.reconcile_receipt(%{"original_receipt" => receipt})
    assert {:ok, ^receipt} = ReviewIdentity.reconcile_receipt(%{native_resource: receipt})

    assert {:error, :terminal_receipt_evidence_unavailable} =
             ReviewIdentity.reconcile_receipt(%{original_receipt: Map.put(receipt, :extra, true)})

    mismatched_head = put_in(resolve_input(:unresolved, nil), [:native_thread, :observed_head_sha], sha("b"))
    assert {:error, :native_thread_state_unverified} = ReviewIdentity.derive_reopen_epoch(mismatched_head)

    mismatched_state = put_in(resolve_input(:unresolved, nil), [:native_thread, :thread_state], :resolved)
    assert {:error, :native_thread_state_unverified} = ReviewIdentity.derive_reopen_epoch(mismatched_state)

    mismatched_repo = put_in(resolve_input(:unresolved, nil), [:native_thread, :repository], "aroakpm-svg/other")
    assert {:error, :native_thread_state_unverified} = ReviewIdentity.derive_reopen_epoch(mismatched_repo)

    {:ok, epoch} = ReviewIdentity.derive_reopen_epoch(resolve_input(:unresolved, nil))

    {:ok, explicit} =
      ReviewIdentity.build_resolve_attempt_key(Map.put(resolve_input(:unresolved, nil), :reopen_epoch, epoch))

    assert explicit.reopen_epoch == epoch

    with_node = put_in(resolve_input(:unresolved, nil), [:native_thread, :node_id], "PRRT_1")
    assert {:ok, _} = ReviewIdentity.derive_reopen_epoch(with_node)

    assert {:error, :synthetic_terminal_evidence} =
             ReviewIdentity.evidence_digest(%{
               "status" => :fix_settled,
               "native_confirmed?" => true,
               "recovered_from_pending_receipt?" => true
             })

    {:ok, matching} = ReviewIdentity.evidence_digest(%{status: :fix_settled, native_confirmed?: true})

    assert {:ok, _} =
             ReviewIdentity.build_settlement_receipt(Map.put(receipt_input(), :evidence_sha256, matching))

    assert {:ok, _} =
             ReviewIdentity.build_settlement_receipt(
               receipt_input()
               |> Map.delete(:finding_lineage_key)
               |> Map.put(:lineage_key, finding_input())
             )

    assert {:error, :terminal_receipt_evidence_unavailable} =
             ReviewIdentity.reconcile_receipt(%{original_receipt: %{status: :incomplete}})

    assert {:error, {:missing_field, :repository}} =
             ReviewIdentity.build_evaluation_key(%{finding_key: %{digest: digest_char("a")}})

    assert {:error, {:missing_field, :repository}} =
             ReviewIdentity.build_settlement_receipt(Map.delete(receipt_input(), :finding_lineage_key))

    resolve_fields = resolve_input(:unresolved, nil)

    assert {:ok, _} =
             ReviewIdentity.build_settlement_receipt(
               receipt_input()
               |> Map.delete(:resolve_attempt_key)
               |> Map.merge(%{
                 thread_state: :unresolved,
                 native_thread: resolve_fields.native_thread
               })
             )

    bad_sha = put_in(resolve_input(:unresolved, nil), [:native_thread, :observed_head_sha], "bad")
    assert {:error, {:invalid_sha, :observed_head_sha}} = ReviewIdentity.derive_reopen_epoch(bad_sha)

    assert {:error, :native_thread_state_unverified} =
             ReviewIdentity.derive_reopen_epoch(Map.put(resolve_input(:unresolved, nil), :thread_state, :nope))

    assert {:ok, omitted_publish} =
             ReviewIdentity.build_settlement_receipt(Map.delete(receipt_input(), :published_head_sha))

    assert omitted_publish.published_head_sha == nil
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
