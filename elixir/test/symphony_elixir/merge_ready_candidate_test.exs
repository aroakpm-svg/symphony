defmodule SymphonyElixir.MergeReadyCandidateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MergeReadyCandidate

  test "derives one deterministic human merge-ready candidate" do
    assert {:ok, candidate} =
             MergeReadyCandidate.derive(valid_evidence(), valid_snapshot(), landing_mode: :human)

    assert candidate.candidate_schema_version == 1
    assert candidate.repository == "aroakpm-svg/symphony"
    assert candidate.pull_request_number == 42
    assert candidate.linear_issue_id == "issue-246"
    assert candidate.head_sha == sha("a")
    assert candidate.required_checks == ["make-all", "validate-pr-description"]
    assert candidate.settled_finding_digests == [digest("finding-1")]
    assert candidate.candidate_digest =~ ~r/^[0-9a-f]{64}$/

    reordered =
      valid_evidence()
      |> Map.put(:evidence_refs, ["receipt:design4"] |> Enum.reverse())
      |> Map.put(:settled_findings, Enum.reverse(valid_evidence().settled_findings))

    snapshot = Map.put(valid_snapshot(), :required_checks, Enum.reverse(valid_snapshot().required_checks))

    assert {:ok, retried} = MergeReadyCandidate.derive(reordered, snapshot, landing_mode: :human)
    assert retried.candidate_digest == candidate.candidate_digest
  end

  test "fails closed with canonically ordered blockers" do
    evidence =
      valid_evidence()
      |> Map.put(:unknown_effects, ["operation-1"])
      |> Map.put(:safety_stops, [:operator_stop])

    snapshot =
      valid_snapshot()
      |> Map.put(:current_head_sha, sha("c"))
      |> Map.put(:draft?, true)
      |> Map.put(:trusted_actionable_threads, ["thread-1"])

    assert {:blocked, blockers} =
             MergeReadyCandidate.derive(evidence, snapshot, landing_mode: :human)

    assert Enum.map(blockers, & &1.code) == [
             :head_changed,
             :pull_request_draft,
             :review_stale,
             :actionable_review_remaining,
             :effect_unknown,
             :safety_stop_present
           ]
  end

  test "rejects unsupported modes and incomplete evidence" do
    assert {:blocked, [%{code: :unsupported_landing_mode} | _]} =
             MergeReadyCandidate.derive(valid_evidence(), valid_snapshot(), landing_mode: :automatic)

    for {path, value, reason} <- [
          {[:handoff_receipt, :status], :unknown, :handoff_receipt_unverified},
          {[:acceptance, :status], :incomplete, :acceptance_incomplete},
          {[:review_policy, :status], :unknown, :review_stale}
        ] do
      evidence = put_in(valid_evidence(), path, value)

      assert {:blocked, blockers} =
               MergeReadyCandidate.derive(evidence, valid_snapshot(), landing_mode: :human)

      assert reason in Enum.map(blockers, & &1.code)
    end
  end

  test "malformed nested collections block instead of raising" do
    for evidence <- [
          Map.put(valid_evidence(), :settled_findings, [true]),
          Map.put(valid_evidence(), :compatibility_receipts, []),
          Map.put(valid_evidence(), :pending_effects, nil)
        ] do
      assert {:blocked, _blockers} =
               MergeReadyCandidate.derive(evidence, valid_snapshot(), landing_mode: :human)
    end

    assert {:blocked, blockers} =
             MergeReadyCandidate.derive(
               valid_evidence(),
               Map.put(valid_snapshot(), :required_checks, [true]),
               landing_mode: :human
             )

    assert :required_check_unsettled in Enum.map(blockers, & &1.code)
  end

  test "invalidates a candidate after any live identity or policy drift" do
    assert {:ok, candidate} =
             MergeReadyCandidate.derive(valid_evidence(), valid_snapshot(), landing_mode: :human)

    assert MergeReadyCandidate.matches_live_snapshot?(candidate, valid_snapshot())

    refute MergeReadyCandidate.matches_live_snapshot?(
             candidate,
             Map.put(valid_snapshot(), :current_head_sha, sha("c"))
           )

    refute MergeReadyCandidate.matches_live_snapshot?(
             candidate,
             put_in(valid_snapshot(), [:trusted_actionable_threads], ["thread-2"])
           )

    refute MergeReadyCandidate.matches_live_snapshot?(
             candidate,
             put_in(valid_snapshot(), [:required_checks, Access.at(0), :conclusion], :failure)
           )
  end

  test "rejects every unsafe terminal collection and PR state" do
    for {field, value, reason} <- [
          {:pending_effects, [:pending], :effect_pending},
          {:blocked_findings, [:blocked], :finding_blocked},
          {:stale_evidence, [:stale], :evidence_stale},
          {:conflicts, [:conflict], :evidence_conflict}
        ] do
      assert_blocked(Map.put(valid_evidence(), field, value), valid_snapshot(), reason)
    end

    for {field, value, reason} <- [
          {:state, :closed, :pull_request_not_open},
          {:mergeable?, false, :merge_conflict},
          {:conflict?, true, :merge_conflict}
        ] do
      assert_blocked(valid_evidence(), Map.put(valid_snapshot(), field, value), reason)
    end
  end

  test "rejects malformed identities, receipts, checks, settlements, and acceptance" do
    assert {:blocked, [%{code: :evidence_incompatible}]} =
             MergeReadyCandidate.derive(nil, valid_snapshot(), [])

    assert_blocked(Map.delete(valid_evidence(), :repository), valid_snapshot(), :evidence_incompatible)
    assert_blocked(valid_evidence(), Map.delete(valid_snapshot(), :state), :evidence_incompatible)
    assert_blocked(Map.put(valid_evidence(), :repository, " "), valid_snapshot(), :evidence_incompatible)

    assert_blocked(
      put_in(valid_evidence(), [:handoff_receipt, :head_sha], sha("c")),
      valid_snapshot(),
      :handoff_receipt_unverified
    )

    assert_blocked(
      put_in(valid_evidence(), [:compatibility_receipts, :aro_143, :owner], :other),
      valid_snapshot(),
      :compatibility_receipt_unverified
    )

    duplicate_checks = [hd(valid_snapshot().required_checks), hd(valid_snapshot().required_checks)]

    assert_blocked(
      valid_evidence(),
      Map.put(valid_snapshot(), :required_checks, duplicate_checks),
      :required_check_unsettled
    )

    duplicate_settlements = List.duplicate(hd(valid_evidence().settled_findings), 2)

    assert_blocked(
      Map.put(valid_evidence(), :settled_findings, duplicate_settlements),
      valid_snapshot(),
      :finding_unsettled
    )

    assert {:ok, candidate} =
             valid_evidence()
             |> Map.put(:settled_findings, [])
             |> MergeReadyCandidate.derive(valid_snapshot(), landing_mode: :human)

    assert candidate.settled_finding_digests == []

    assert_blocked(
      Map.put(valid_evidence(), :settled_findings, nil),
      valid_snapshot(),
      :finding_unsettled
    )

    assert_blocked(
      put_in(valid_evidence(), [:acceptance, :evidence_refs], []),
      valid_snapshot(),
      :acceptance_incomplete
    )
  end

  test "compatibility receipts are bound to the exact candidate identity" do
    for {field, value} <- [
          {:repository, "other/repo"},
          {:pull_request_number, 99},
          {:linear_issue_id, "other-issue"},
          {:linear_issue_identifier, "ARO-999"},
          {:base_sha, sha("c")},
          {:head_sha, sha("c")}
        ] do
      evidence = put_in(valid_evidence(), [:compatibility_receipts, :aro_143, field], value)
      assert_blocked(evidence, valid_snapshot(), :compatibility_receipt_unverified)
    end
  end

  test "live revalidation rejects all identity, PR, check, and review drift" do
    {:ok, candidate} = MergeReadyCandidate.derive(valid_evidence(), valid_snapshot(), landing_mode: :human)

    drifts = [
      {:repository, "other/repo"},
      {:pull_request_number, 99},
      {:linear_issue_id, "other"},
      {:linear_issue_identifier, "ARO-999"},
      {:linear_revision, "later"},
      {:base_sha, sha("c")},
      {:state, :closed},
      {:draft?, true},
      {:mergeable?, false},
      {:conflict?, true}
    ]

    for {field, value} <- drifts do
      refute MergeReadyCandidate.matches_live_snapshot?(candidate, Map.put(valid_snapshot(), field, value))
    end

    refute MergeReadyCandidate.matches_live_snapshot?(candidate, Map.put(valid_snapshot(), :required_checks, []))
    refute MergeReadyCandidate.matches_live_snapshot?(candidate, Map.put(valid_snapshot(), :exact_head_review, nil))

    refute MergeReadyCandidate.matches_live_snapshot?(
             candidate,
             put_in(valid_snapshot(), [:exact_head_review, :status], :missing)
           )

    refute MergeReadyCandidate.matches_live_snapshot?(nil, valid_snapshot())
  end

  test "live revalidation rejects tampered candidate and exact-head review fields" do
    {:ok, candidate} = MergeReadyCandidate.derive(valid_evidence(), valid_snapshot(), landing_mode: :human)

    for {field, value} <- [
          {:candidate_schema_version, 2},
          {:repository, "other/repo"},
          {:required_checks, ["other-check"]}
        ] do
      refute MergeReadyCandidate.matches_live_snapshot?(Map.put(candidate, field, value), valid_snapshot())
    end

    refute MergeReadyCandidate.matches_live_snapshot?(
             candidate,
             put_in(valid_snapshot(), [:exact_head_review, :head_sha], sha("c"))
           )
  end

  defp assert_blocked(evidence, snapshot, reason) do
    assert {:blocked, blockers} =
             MergeReadyCandidate.derive(evidence, snapshot, landing_mode: :human)

    assert reason in Enum.map(blockers, & &1.code)
  end

  defp valid_evidence do
    %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 42,
      linear_issue_id: "issue-246",
      linear_issue_identifier: "ARO-246",
      linear_revision: "2026-08-18T00:00:00Z",
      base_sha: sha("b"),
      evaluated_head_sha: sha("a"),
      tested_head_sha: sha("a"),
      handoff_receipt: %{status: :verified, head_sha: sha("a"), contract_version: 2},
      compatibility_receipts: %{
        aro_143: receipt(:aro_143),
        aro_170: receipt(:aro_170),
        aro_171: receipt(:aro_171),
        aro_167: receipt(:aro_167),
        aro_135: receipt(:aro_135)
      },
      settled_findings: [%{finding_key_digest: digest("finding-1"), status: :settled}],
      pending_effects: [],
      unknown_effects: [],
      blocked_findings: [],
      stale_evidence: [],
      conflicts: [],
      safety_stops: [],
      acceptance: %{status: :complete, evidence_refs: ["test:merge-ready"]},
      review_policy: %{status: :satisfied, reviewed_head_sha: sha("a")},
      evidence_refs: ["receipt:design4"],
      derived_at: ~U[2026-08-18 00:00:00Z]
    }
  end

  defp valid_snapshot do
    %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 42,
      linear_issue_id: "issue-246",
      linear_issue_identifier: "ARO-246",
      linear_revision: "2026-08-18T00:00:00Z",
      state: :open,
      draft?: false,
      mergeable?: true,
      conflict?: false,
      base_sha: sha("b"),
      current_head_sha: sha("a"),
      required_checks: [
        %{name: "validate-pr-description", status: :completed, conclusion: :success},
        %{name: "make-all", status: :completed, conclusion: :success}
      ],
      exact_head_review: %{status: :accepted, head_sha: sha("a")},
      trusted_actionable_threads: []
    }
  end

  defp receipt(owner) do
    %{
      owner: owner,
      status: :verified,
      contract_version: 1,
      repository: "aroakpm-svg/symphony",
      pull_request_number: 42,
      linear_issue_id: "issue-246",
      linear_issue_identifier: "ARO-246",
      base_sha: sha("b"),
      head_sha: sha("a")
    }
  end

  defp sha(character), do: String.duplicate(character, 40)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
