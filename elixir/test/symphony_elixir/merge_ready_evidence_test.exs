defmodule SymphonyElixir.MergeReadyEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{MergeReadyEvidence, MergeReadyCandidate}
  alias SymphonyElixir.Linear.Issue

  defmodule ReviewClient do
    def snapshot(repository, branch) do
      send(Process.get(:merge_ready_test_pid), {:github_read, repository, branch})
      Process.get(:merge_ready_snapshot)
    end
  end

  defmodule Tracker do
    def fetch_routed_issues_by_states(states) do
      send(Process.get(:merge_ready_test_pid), {:linear_read, states})
      Process.get(:merge_ready_issues)
    end
  end

  setup do
    Process.put(:merge_ready_test_pid, self())
    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})
    Process.put(:merge_ready_issues, {:ok, [issue()]})
    :ok
  end

  test "re-reads GitHub and Linear before returning normalized evidence" do
    assert {:ok, evidence, snapshot} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    assert_receive {:github_read, "aroakpm-svg/symphony", "agent/aro-246"}
    assert_receive {:linear_read, ["In Review", "In Progress"]}
    assert evidence.evaluated_head_sha == sha("a")
    assert evidence.linear_revision == "2026-08-18T00:00:00Z"
    assert snapshot.current_head_sha == sha("a")

    assert snapshot.required_checks == [
             %{name: "make-all", status: :completed, conclusion: :success}
           ]

    assert {:ok, _candidate} =
             MergeReadyCandidate.derive(evidence, snapshot, landing_mode: :human)
  end

  test "fails closed when either authority is unavailable or identity changes" do
    Process.put(:merge_ready_snapshot, {:error, :timeout})

    assert {:error, :github_readback_unavailable} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})
    Process.put(:merge_ready_issues, {:ok, [%{issue() | identifier: "ARO-OTHER"}]})

    assert {:error, :linear_mapping_unverified} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
  end

  test "rejects malformed landing evidence instead of manufacturing defaults" do
    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(issue(), %{}, settings(), dependencies())
  end

  defp dependencies do
    [
      review_client: ReviewClient,
      tracker: Tracker,
      required_compatibility_receipts: [:aro_143, :aro_170, :aro_171, :aro_167, :aro_135],
      now: fn -> ~U[2026-08-18 00:00:00Z] end
    ]
  end

  defp settings do
    %{
      repository: "aroakpm-svg/symphony",
      review_state: "In Review",
      in_progress_state: "In Progress"
    }
  end

  defp issue do
    %Issue{
      id: "issue-246",
      identifier: "ARO-246",
      state: "In Review",
      branch_name: "agent/aro-246",
      updated_at: ~U[2026-08-18 00:00:00Z],
      assigned_to_worker: true
    }
  end

  defp github_snapshot do
    %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 42,
      current_head_sha: sha("a"),
      reviewed_head_sha: sha("a"),
      review_result: :no_major_issues,
      base_ref_oid: sha("b"),
      pull_request_state: :open,
      draft?: false,
      mergeable?: true,
      conflict?: false,
      required_checks: [%{name: "make-all", state: :success}],
      threads: []
    }
  end

  defp landing_evidence do
    %{
      repository: "aroakpm-svg/symphony",
      pull_request_number: 42,
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
      settled_findings: [
        %{finding_key_digest: digest("finding-1"), status: :settled}
      ],
      pending_effects: [],
      unknown_effects: [],
      blocked_findings: [],
      stale_evidence: [],
      conflicts: [],
      safety_stops: [],
      acceptance: %{status: :complete, evidence_refs: ["test:merge-ready"]},
      evidence_refs: ["receipt:design4"]
    }
  end

  defp receipt(owner), do: %{owner: owner, status: :verified, contract_version: 1}
  defp sha(character), do: String.duplicate(character, 40)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
