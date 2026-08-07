defmodule SymphonyElixir.FindingTriageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FindingTriage

  test "exposes exactly the three triage states" do
    assert FindingTriage.states() == [:fix_in_current_pr, :follow_up_required, :blocked_unverified]
  end

  test "missing evidence fails closed" do
    finding = %{priority: 1, path: "lib/example.ex", body: "P1"}

    assert %{blocked_unverified: [%{reason: :missing_triage_evidence}]} =
             FindingTriage.classify([finding], %{})
  end

  test "fix state requires an allowed evidence kind" do
    finding = %{
      priority: 1,
      triage: %{state: :fix_in_current_pr, evidence: :introduced_by_pr}
    }

    assert %{fix_in_current_pr: [%{finding: ^finding, reason: :verified_scope}]} =
             FindingTriage.classify([finding], %{})

    invalid = %{finding | triage: %{state: :fix_in_current_pr, evidence: :severity_only}}

    assert %{blocked_unverified: [%{reason: :invalid_triage_evidence}]} =
             FindingTriage.classify([invalid], %{})
  end

  test "follow-up state requires an out-of-scope reason" do
    finding = %{
      priority: 2,
      triage: %{
        state: :follow_up_required,
        evidence: :root_cause_out_of_scope,
        reason: "belongs to the shared deployment contract"
      }
    }

    assert %{follow_up_required: [%{finding: ^finding, reason: reason}]} =
             FindingTriage.classify([finding], %{})

    assert reason == "belongs to the shared deployment contract"
  end

  test "snapshot triage is matched by stable finding fingerprint" do
    finding = %{priority: 3, path: "lib/example.ex", body: "P3"}

    snapshot = %{
      finding_triage: [
        %{
          fingerprint: FindingTriage.fingerprint(finding),
          state: :fix_in_current_pr,
          evidence: :violates_acceptance_criterion
        }
      ]
    }

    assert %{fix_in_current_pr: [%{finding: ^finding}]} =
             FindingTriage.classify([finding], snapshot)
  end

  test "invalid finding and triage shapes fail closed" do
    assert %{state: :blocked_unverified, reason: :invalid_finding} =
             FindingTriage.classify_finding(:not_a_finding, %{})

    finding = %{priority: 1, triage: %{state: :not_a_state}}

    assert %{blocked_unverified: [%{reason: :missing_triage_evidence}]} =
             FindingTriage.classify([finding], %{})

    invalid_follow_up = %{
      finding
      | triage: %{state: :follow_up_required, evidence: :root_cause_out_of_scope, reason: "  "}
    }

    assert %{blocked_unverified: [%{reason: :invalid_follow_up_reason}]} =
             FindingTriage.classify([invalid_follow_up], %{})

    invalid_shape = %{finding | triage: %{state: :follow_up_required, evidence: :root_cause_out_of_scope}}

    assert %{blocked_unverified: [%{reason: :invalid_triage_evidence}]} =
             FindingTriage.classify([invalid_shape], %{})

    explicit_block = %{finding | triage: %{state: :blocked_unverified, reason: :human_review}}

    assert %{blocked_unverified: [%{reason: :human_review}]} =
             FindingTriage.classify([explicit_block], %{})

    assert %{blocked_unverified: [%{reason: :missing_triage_evidence}]} =
             FindingTriage.classify([%{priority: 1}], %{finding_triage: :invalid})
  end

  test "list triage entries ignore unrelated fingerprints" do
    finding = %{priority: 1, path: "lib/example.ex", body: "P1"}

    snapshot = %{
      finding_triage: [
        %{fingerprint: {4, "other.ex", "P4"}, state: :blocked_unverified, reason: :human_review}
      ]
    }

    assert %{blocked_unverified: [%{reason: :missing_triage_evidence}]} =
             FindingTriage.classify([finding], snapshot)
  end

  test "map triage entries use the same fingerprint key" do
    finding = %{priority: 4, path: "lib/example.ex", body: "P4"}

    snapshot = %{
      finding_triage: %{
        FindingTriage.fingerprint(finding) => %{
          state: :blocked_unverified,
          reason: :human_review
        }
      }
    }

    assert %{blocked_unverified: [%{reason: :human_review}]} =
             FindingTriage.classify([finding], snapshot)
  end
end
