defmodule SymphonyElixir.PatchAuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FindingDisposition, PatchAuthorization}

  test "new causal evidence grants exactly one bounded mutation" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:ok, grant} = PatchAuthorization.authorize(decision, receipt, claim, effects, runtime)
    assert grant.authorization == :bounded_managed_mutation
    assert grant.authorized_head_sha == receipt.authorized_head_sha
    assert grant.claim_id == claim.claim_id
    refute Map.has_key?(grant, :credentials)
    refute Map.has_key?(grant, :merge)
    refute Map.has_key?(grant, :deploy)
  end

  test "non-fix dispositions and malformed receipts fail closed" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:blocked, :follow_up_required} =
             PatchAuthorization.authorize(
               %{decision | disposition: :follow_up_required},
               receipt,
               claim,
               effects,
               runtime
             )

    assert {:blocked, :blocked_unverified} =
             PatchAuthorization.authorize(
               %{decision | disposition: :blocked_unverified},
               receipt,
               claim,
               effects,
               runtime
             )

    for change <- [
          %{verified?: false},
          %{valid?: false},
          %{readback_capable?: false},
          %{earliest_incorrect_boundary: ""},
          %{finding_key: nil},
          %{finding_lineage_key: nil}
        ] do
      assert {:blocked, _reason} =
               PatchAuthorization.authorize(decision, Map.merge(receipt, change), claim, effects, runtime)
    end
  end

  test "only red or bounded reproduced pre-mutation evidence can authorize" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:blocked, :green_pre_mutation_regression} =
             PatchAuthorization.authorize(
               decision,
               put_in(receipt, [:pre_mutation_regression, :status], :pass),
               claim,
               effects,
               runtime
             )

    assert {:blocked, :pre_mutation_regression_unverified} =
             PatchAuthorization.authorize(
               decision,
               put_in(receipt, [:pre_mutation_regression, :status], :not_run),
               claim,
               effects,
               runtime
             )
  end

  test "head, claim, generation, and circuit breaker remain exact and current" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:blocked, :stale_or_conflicting_head} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               claim,
               effects,
               %{runtime | current_head_sha: String.duplicate("b", 40)}
             )

    assert {:blocked, :stale_claim} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               %{claim | claim_id: "old-claim"},
               effects,
               runtime
             )

    assert {:blocked, :stale_generation} =
             PatchAuthorization.authorize(decision, receipt, %{claim | generation: 5}, effects, runtime)

    assert {:blocked, :safety_stopped} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               claim,
               effects,
               %{runtime | circuit_breaker: :open}
             )
  end

  test "pending and unknown effects reconcile, while malformed state blocks" do
    {decision, receipt, claim, _effects, runtime} = valid_inputs()

    for status <- [:pending, :unknown] do
      assert {:reconcile, %{reason: :managed_effect_requires_reconciliation, status: ^status}} =
               PatchAuthorization.authorize(
                 decision,
                 receipt,
                 claim,
                 [%{operation_id: "op", status: status, generation: 6}],
                 runtime
               )
    end

    assert {:blocked, :malformed_effect_readback} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               claim,
               [%{operation_id: "op", status: :surprise, generation: 6}],
               runtime
             )
  end

  test "old-generation terminal readback is allowed but cannot authorize an old claim" do
    {decision, receipt, claim, _effects, runtime} = valid_inputs()

    assert {:ok, _grant} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               claim,
               [%{operation_id: "old", status: :succeeded, generation: 5}],
               runtime
             )

    assert {:blocked, :stale_generation} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               %{claim | generation: 5},
               [],
               runtime
             )
  end

  test "same lineage, root-cause fingerprint, and evidence cannot grant again" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    prior = %{
      finding_lineage_digest: receipt.finding_lineage_key.digest,
      causal_attempt_fingerprint: receipt.causal_attempt_fingerprint,
      causal_evidence_digest: receipt.causal_evidence_digest,
      generation: 5
    }

    assert {:blocked, :non_progress_blocked} =
             PatchAuthorization.authorize(
               decision,
               receipt,
               claim,
               effects,
               %{
                 runtime
                 | prior_attempts: [
                     %{prior | finding_lineage_digest: String.duplicate("f", 64)},
                     prior
                   ]
               }
             )

    assert {:ok, _grant} =
             PatchAuthorization.authorize(
               decision,
               %{receipt | causal_evidence_digest: String.duplicate("e", 64)},
               claim,
               effects,
               %{runtime | prior_attempts: [prior]}
             )
  end

  test "a third bypass in one boundary requires architecture or policy routing" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:blocked, :architecture_escalation_required} =
             PatchAuthorization.authorize(
               decision,
               %{receipt | recurrence_count: 3},
               claim,
               effects,
               runtime
             )

    assert {:blocked, :architecture_escalation} =
             PatchAuthorization.authorize(
               decision,
               Map.merge(receipt, %{recurrence_count: 3, escalation_decision: :architecture_escalation}),
               claim,
               effects,
               runtime
             )
  end

  test "every malformed boundary value fails closed" do
    {decision, receipt, claim, effects, runtime} = valid_inputs()

    assert {:blocked, :invalid_authorization_input} =
             PatchAuthorization.authorize(nil, receipt, claim, effects, runtime)

    assert {:blocked, :invalid_disposition} =
             PatchAuthorization.authorize(%{decision | disposition: :unexpected}, receipt, claim, effects, runtime)

    assert {:blocked, _reason} =
             PatchAuthorization.authorize(
               %{decision | finding_key: %{decision.finding_key | digest: "bad"}},
               receipt,
               claim,
               effects,
               runtime
             )

    assert {:blocked, :invalid_regression_phase} =
             PatchAuthorization.authorize(
               decision,
               put_in(receipt, [:pre_mutation_regression, :phase], :post_mutation),
               claim,
               effects,
               runtime
             )

    assert {:blocked, :missing_pre_mutation_regression} =
             PatchAuthorization.authorize(
               decision,
               Map.delete(receipt, :pre_mutation_regression),
               claim,
               effects,
               runtime
             )

    for invalid_claim <- [
          %{claim | active?: false},
          %{claim | claim_id: nil},
          %{claim | generation: nil}
        ] do
      assert {:blocked, _reason} =
               PatchAuthorization.authorize(decision, receipt, invalid_claim, effects, runtime)
    end

    for invalid_effect <- [
          %{operation_id: "op", status: :succeeded, generation: nil},
          :not_a_readback
        ] do
      assert {:blocked, :malformed_effect_readback} =
               PatchAuthorization.authorize(decision, receipt, claim, [invalid_effect], runtime)
    end

    assert {:blocked, :invalid_digest} =
             PatchAuthorization.authorize(
               decision,
               %{receipt | causal_evidence_digest: nil},
               claim,
               effects,
               runtime
             )

    assert {:blocked, :stale_or_conflicting_head} =
             PatchAuthorization.authorize(
               decision,
               %{receipt | evaluated_head_sha: nil},
               claim,
               effects,
               runtime
             )

    assert {:blocked, :receipt_malformed} =
             PatchAuthorization.authorize(
               decision,
               %{receipt | invariant: nil},
               claim,
               effects,
               runtime
             )
  end

  defp valid_inputs do
    head_sha = String.duplicate("a", 40)

    facts = %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 31,
      source_head_sha: head_sha,
      review_thread_id: "thread-1",
      selected_review_comment_id: "comment-1",
      body: "P1 invariant violation"
    }

    {:ok, finding_key} = FindingDisposition.build_finding_key(facts)
    {:ok, lineage_key} = FindingDisposition.build_lineage_key(facts)

    decision = %{
      disposition: :fix_in_current_pr,
      finding_key: finding_key,
      finding_lineage_key: lineage_key
    }

    receipt = %{
      verified?: true,
      valid?: true,
      readback_capable?: true,
      finding_key: finding_key,
      finding_lineage_key: lineage_key,
      causal_attempt_fingerprint: String.duplicate("c", 64),
      causal_evidence_digest: String.duplicate("d", 64),
      invariant: "managed writes are exactly once",
      causal_hypothesis: "identity validation accepted contradictory values",
      earliest_incorrect_boundary: "PatchAuthorization input validation",
      boundary_group: "managed-effect-identity",
      causal_progress_reference: "regression:patch-authorization:1",
      receipt_provenance: "review-thread:thread-1",
      recurrence_count: 1,
      evaluated_head_sha: head_sha,
      authorized_head_sha: head_sha,
      mutation_intent_reference: "bounded-intent:thread-1",
      pre_mutation_regression: %{
        phase: :pre_mutation,
        status: :fail,
        command_or_source: "mix test test/symphony_elixir/patch_authorization_test.exs",
        observed_output: "expected grant, owner API missing",
        head_sha: head_sha
      }
    }

    claim = %{active?: true, claim_id: "claim-6", generation: 6}
    effects = [%{operation_id: "done", status: :succeeded, generation: 6}]

    runtime = %{
      current_head_sha: head_sha,
      active_claim_id: "claim-6",
      active_generation: 6,
      circuit_breaker: :clear,
      prior_attempts: []
    }

    {decision, receipt, claim, effects, runtime}
  end
end
