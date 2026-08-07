defmodule SymphonyElixir.FindingDispositionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FindingDisposition

  @head "0123456789abcdef0123456789abcdef01234567"
  @next_head "89abcdef0123456789abcdef0123456789abcdef"

  test "only an explicitly approved in-scope root cause permits current-pr rework" do
    assertion =
      assertion(%{
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    assert %{decision: :fix_in_current_pr, finding_ids: ["finding-1"], handoff: nil} =
             FindingDisposition.evaluate(["finding-1"], [assertion], @head)
  end

  test "fix disposition without causality, scope, or maintainer approval blocks" do
    for overrides <- [
          %{cause: :root_cause_out_of_scope},
          %{scope: :out_of_scope},
          %{maintainer_approved: false}
        ] do
      assertion = assertion(Map.merge(%{disposition: :fix_in_current_pr}, overrides))

      assert %{decision: :blocked_unverified} =
               FindingDisposition.evaluate(["finding-1"], [assertion], @head)
    end
  end

  test "out-of-scope root-cause work produces a manual follow-up handoff" do
    assertion =
      assertion(%{
        disposition: :follow_up_required,
        cause: :root_cause_out_of_scope,
        scope: :out_of_scope
      })

    assert %{decision: :follow_up_required, handoff: handoff} =
             FindingDisposition.evaluate(["finding-1"], [assertion], @head)

    assert handoff == FindingDisposition.handoff_text("finding-1")
    assert handoff =~ "Finding IDs: finding-1"
    assert handoff =~ "no agent patch was applied"
  end

  test "unknown causality or scope blocks instead of inferring ownership" do
    for overrides <- [
          %{disposition: :follow_up_required, cause: :insufficient_evidence, scope: :unknown},
          %{disposition: :follow_up_required, cause: :root_cause_out_of_scope, scope: :unknown},
          %{disposition: :blocked_unverified, cause: :insufficient_evidence, scope: :unknown}
        ] do
      assert %{decision: :blocked_unverified} =
               FindingDisposition.evaluate(["finding-1"], [assertion(overrides)], @head)
    end
  end

  test "a new head invalidates a prior fix authorization" do
    assertion =
      assertion(%{
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    assert %{decision: :blocked_unverified, reason: :stale_head} =
             FindingDisposition.evaluate(["finding-1"], [assertion], @next_head)
  end

  test "missing, duplicate, unknown, malformed, and ambiguous assertions block" do
    valid =
      assertion(%{
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    assert %{decision: :blocked_unverified, reason: :missing_assertion} =
             FindingDisposition.evaluate(["finding-1"], [], @head)

    assert %{decision: :blocked_unverified, reason: :duplicate_finding_id} =
             FindingDisposition.evaluate(["finding-1", "finding-1"], [valid], @head)

    unknown =
      assertion(%{
        finding_id: "finding-2",
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    assert %{decision: :blocked_unverified, reason: :unknown_finding} =
             FindingDisposition.evaluate(["finding-1"], [unknown], @head)

    assert %{decision: :blocked_unverified, reason: :malformed_assertion} =
             FindingDisposition.evaluate(["finding-1"], [%{finding_id: "finding-1"}], @head)

    assert %{decision: :blocked_unverified, reason: :ambiguous_assertion} =
             FindingDisposition.evaluate(["finding-1"], [valid, valid], @head)

    malformed = %FindingDisposition{
      finding_id: valid.finding_id,
      head_sha: valid.head_sha,
      disposition: valid.disposition,
      cause: :invalid_cause,
      scope: valid.scope,
      maintainer_approved: valid.maintainer_approved
    }

    assert %{decision: :blocked_unverified, reason: :malformed_assertion} =
             FindingDisposition.evaluate(["finding-1"], [malformed], @head)
  end

  test "batch precedence is blocked, then follow-up, then fix" do
    fix =
      assertion(%{
        finding_id: "fix",
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    follow_up =
      assertion(%{
        finding_id: "follow-up",
        disposition: :follow_up_required,
        cause: :root_cause_out_of_scope,
        scope: :out_of_scope
      })

    blocked =
      assertion(%{
        finding_id: "blocked",
        disposition: :blocked_unverified,
        cause: :insufficient_evidence,
        scope: :unknown
      })

    assert %{decision: :follow_up_required} =
             FindingDisposition.evaluate(["fix", "follow-up"], [fix, follow_up], @head)

    assert %{decision: :blocked_unverified} =
             FindingDisposition.evaluate(["fix", "follow-up", "blocked"], [fix, follow_up, blocked], @head)

    assert %{handoff: handoff} =
             FindingDisposition.evaluate(["fix", "follow-up", "blocked"], [fix, follow_up, blocked], @head)

    assert handoff =~ "Finding IDs: follow-up"
  end

  test "the pure contract does not use severity, path, or prose" do
    assertion =
      assertion(%{
        disposition: :fix_in_current_pr,
        cause: :introduced_by_pr,
        scope: :accepted,
        maintainer_approved: true
      })

    assert %{decision: :fix_in_current_pr} =
             FindingDisposition.evaluate(["finding-1"], [assertion], @head)
  end

  test "assertion constructor rejects unknown fields and non-full heads" do
    attrs = %{
      finding_id: "finding-1",
      head_sha: @head,
      disposition: :fix_in_current_pr,
      cause: :introduced_by_pr,
      scope: :accepted,
      maintainer_approved: true
    }

    assert {:ok, %FindingDisposition{}} = FindingDisposition.new_assertion(attrs)
    assert {:error, :malformed_assertion} = FindingDisposition.new_assertion(:not_a_map)
    assert {:error, :invalid_head_sha} = FindingDisposition.new_assertion(%{attrs | head_sha: "head"})
    assert {:error, :malformed_assertion} = FindingDisposition.new_assertion(Map.put(attrs, :path, "lib/example.ex"))
  end

  test "no actionable findings has no triage decision" do
    assert %{decision: :no_actionable_findings, finding_ids: [], handoff: nil} =
             FindingDisposition.evaluate([], [], @head)
  end

  defp assertion(overrides) do
    Map.merge(
      %{
        finding_id: "finding-1",
        head_sha: @head,
        disposition: :blocked_unverified,
        cause: :insufficient_evidence,
        scope: :unknown,
        maintainer_approved: false
      },
      overrides
    )
    |> FindingDisposition.new_assertion()
    |> elem(1)
  end
end
