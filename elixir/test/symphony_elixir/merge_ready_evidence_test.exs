defmodule SymphonyElixir.MergeReadyEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeReadyCandidate
  alias SymphonyElixir.MergeReadyEvidence

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

  defmodule RaisingReviewClient do
    def snapshot(_repository, _branch), do: raise("unavailable")
  end

  defmodule RaisingTracker do
    def fetch_routed_issues_by_states(_states), do: raise("unavailable")
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

  test "reads completed evidence from the per-issue production handoff" do
    evidence = landing_evidence()

    assert {:ok, ^evidence} = MergeReadyEvidence.completed_landing_evidence(%{landing_evidence: evidence})

    assert {:ok, ^evidence} =
             MergeReadyEvidence.completed_landing_evidence(%{
               terminal_result: {:finding_complete, evidence}
             })

    assert {:error, :landing_evidence_unavailable} =
             MergeReadyEvidence.completed_landing_evidence(%{})
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

  test "fails closed for invalid calls, issue identity, and dependency contracts" do
    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(nil, landing_evidence(), settings(), dependencies())

    assert {:error, :linear_mapping_unverified} =
             MergeReadyEvidence.read(%{issue() | branch_name: ""}, landing_evidence(), settings(), dependencies())

    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(
               issue(),
               landing_evidence(),
               settings(),
               Keyword.put(dependencies(), :required_compatibility_receipts, [])
             )
  end

  test "fails closed when authoritative clients raise or return malformed data" do
    assert {:error, :github_readback_unavailable} =
             MergeReadyEvidence.read(
               issue(),
               landing_evidence(),
               settings(),
               Keyword.put(dependencies(), :review_client, RaisingReviewClient)
             )

    assert {:error, :linear_readback_unavailable} =
             MergeReadyEvidence.read(
               issue(),
               landing_evidence(),
               settings(),
               Keyword.put(dependencies(), :tracker, RaisingTracker)
             )

    Process.put(:merge_ready_issues, {:error, :timeout})

    assert {:error, :linear_readback_unavailable} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
  end

  test "rejects ambiguous Linear mappings and changed native GitHub identity" do
    Process.put(:merge_ready_issues, {:ok, [issue(), issue()]})

    assert {:error, :linear_mapping_unverified} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_issues, {:ok, [issue()]})
    changed = Map.put(github_snapshot(), :pull_request_number, 99)
    Process.put(:merge_ready_snapshot, {:ok, changed})

    assert {:error, :landing_evidence_identity_stale} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    stale_linear = Map.put(landing_evidence(), :linear_revision, "2026-08-17T00:00:00Z")

    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})

    assert {:error, :landing_evidence_identity_stale} =
             MergeReadyEvidence.read(issue(), stale_linear, settings(), dependencies())
  end

  test "rejects malformed canonical landing and native identity fields" do
    for {field, value} <- [
          {:linear_issue_id, nil},
          {:linear_issue_identifier, " "},
          {:linear_revision, 42},
          {:repository, ""},
          {:pull_request_number, 0},
          {:base_sha, "invalid"},
          {:evaluated_head_sha, nil}
        ] do
      assert {:error, :landing_evidence_incompatible} =
               MergeReadyEvidence.read(
                 issue(),
                 Map.put(landing_evidence(), field, value),
                 settings(),
                 dependencies()
               )
    end

    for {field, value} <- [
          {:repository, ""},
          {:pull_request_number, nil},
          {:base_ref_oid, "invalid"},
          {:current_head_sha, nil}
        ] do
      Process.put(:merge_ready_snapshot, {:ok, Map.put(github_snapshot(), field, value)})

      assert {:error, :landing_evidence_incompatible} =
               MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
    end
  end

  test "rejects malformed GitHub checks, threads, state, and clock" do
    invalid_snapshots = [
      Map.put(github_snapshot(), :required_checks, []),
      Map.put(github_snapshot(), :required_checks, [true]),
      Map.put(github_snapshot(), :threads, nil),
      Map.put(github_snapshot(), :threads, [true]),
      Map.put(github_snapshot(), :pull_request_state, :unknown)
    ]

    for snapshot <- invalid_snapshots do
      Process.put(:merge_ready_snapshot, {:ok, snapshot})

      assert {:error, :github_readback_incompatible} =
               MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
    end

    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})
    deps = Keyword.put(dependencies(), :now, fn -> :invalid end)

    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), deps)
  end

  test "normalizes pending checks, missing review, and actionable thread identities" do
    snapshot =
      github_snapshot()
      |> Map.put(:review_result, :unknown)
      |> Map.put(:reviewed_head_sha, nil)
      |> Map.put(:required_checks, [%{name: "make-all", state: :pending}])
      |> Map.put(:threads, [
        %{resolved: true, url: "resolved"},
        %{resolved: false, url: "thread-url"},
        %{resolved: false, body: "thread-body"},
        %{resolved: false}
      ])

    Process.put(:merge_ready_snapshot, {:ok, snapshot})

    assert {:ok, evidence, native} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    assert native.required_checks == [
             %{name: "make-all", status: :pending, conclusion: :pending}
           ]

    assert native.exact_head_review.status == :missing
    assert native.trusted_actionable_threads == ["thread-url", "thread-body", "unidentified-actionable-thread"]
    assert evidence.review_policy.status == :unsatisfied
  end

  test "rejects wrong successful response shapes and missing current issue" do
    Process.put(:merge_ready_snapshot, {:ok, []})

    assert {:error, :github_readback_unavailable} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})
    Process.put(:merge_ready_issues, {:ok, %{}})

    assert {:error, :linear_readback_unavailable} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_issues, {:ok, [true]})

    assert {:error, :linear_mapping_unverified} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
  end

  test "rejects malformed nested receipts, native state fields, and a raising clock" do
    malformed = Map.put(landing_evidence(), :compatibility_receipts, nil)

    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(issue(), malformed, settings(), dependencies())

    Process.put(
      :merge_ready_snapshot,
      {:ok, Map.put(github_snapshot(), :reviewed_head_sha, 42)}
    )

    assert {:error, :github_readback_incompatible} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_snapshot, {:ok, github_snapshot()})
    deps = Keyword.put(dependencies(), :now, fn -> raise("clock unavailable") end)

    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), deps)
  end

  test "fails closed when required client dependencies are absent" do
    assert {:error, :github_readback_unavailable} =
             MergeReadyEvidence.read(
               issue(),
               landing_evidence(),
               settings(),
               Keyword.delete(dependencies(), :review_client)
             )

    assert {:error, :linear_readback_unavailable} =
             MergeReadyEvidence.read(
               issue(),
               landing_evidence(),
               settings(),
               Keyword.delete(dependencies(), :tracker)
             )
  end

  test "rejects an unassigned current issue and normalizes failed checks" do
    Process.put(:merge_ready_issues, {:ok, [%{issue() | assigned_to_worker: false}]})

    assert {:error, :linear_mapping_unverified} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    Process.put(:merge_ready_issues, {:ok, [issue()]})

    snapshot =
      github_snapshot()
      |> Map.put(:reviewed_head_sha, sha("c"))
      |> Map.put(:required_checks, [%{name: "make-all", state: :failure}])

    Process.put(:merge_ready_snapshot, {:ok, snapshot})

    assert {:ok, evidence, native} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())

    assert native.required_checks == [
             %{name: "make-all", status: :completed, conclusion: :failure}
           ]

    assert native.exact_head_review.status == :missing
    assert evidence.review_policy.status == :unsatisfied
  end

  test "validates every issue, native identity, and GitHub state field" do
    for invalid_issue <- [
          %{issue() | id: ""},
          %{issue() | identifier: ""},
          %{issue() | updated_at: nil}
        ] do
      assert {:error, :linear_mapping_unverified} =
               MergeReadyEvidence.read(invalid_issue, landing_evidence(), settings(), dependencies())
    end

    for {field, value} <- [
          {:repository, "other/repo"},
          {:base_ref_oid, sha("c")},
          {:current_head_sha, sha("c")}
        ] do
      Process.put(:merge_ready_snapshot, {:ok, Map.put(github_snapshot(), field, value)})

      assert {:error, :landing_evidence_identity_stale} =
               MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
    end

    for {field, value} <- [
          {:draft?, nil},
          {:mergeable?, nil},
          {:conflict?, nil}
        ] do
      Process.put(:merge_ready_snapshot, {:ok, Map.put(github_snapshot(), field, value)})

      assert {:error, :github_readback_incompatible} =
               MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
    end

    Process.put(
      :merge_ready_snapshot,
      {:ok, Map.put(github_snapshot(), :current_head_sha, nil)}
    )

    assert {:error, :landing_evidence_incompatible} =
             MergeReadyEvidence.read(issue(), landing_evidence(), settings(), dependencies())
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
      linear_issue_id: "issue-246",
      linear_issue_identifier: "ARO-246",
      linear_revision: "2026-08-18T00:00:00Z",
      base_sha: sha("b"),
      evaluated_head_sha: sha("a"),
      tested_head_sha: sha("a"),
      handoff_receipt: %{
        status: :verified,
        contract_version: 2,
        repository: "aroakpm-svg/symphony",
        pull_request_number: 42,
        linear_issue_id: "issue-246",
        linear_issue_identifier: "ARO-246",
        linear_revision: "2026-08-18T00:00:00Z",
        base_sha: sha("b"),
        head_sha: sha("a"),
        canonical_finding_inventory_digest: "076140d9f460db81519f311e346867e0d2fa4b1a1bf2eb0de09be0dc971abe42",
        canonical_settlement_digest: "7d2d29ce284ad21fa5d43c2e5e95885113384971bb7fbe71719873b2a7e02494"
      },
      compatibility_receipts: %{
        aro_143: receipt(:aro_143),
        aro_170: receipt(:aro_170),
        aro_171: receipt(:aro_171),
        aro_167: receipt(:aro_167),
        aro_135: receipt(:aro_135)
      },
      canonical_finding_digests: [digest("finding-1")],
      settled_findings: [
        %{finding_key_digest: digest("finding-1"), status: :settled}
      ],
      pending_effects: [],
      unknown_effects: [],
      blocked_findings: [],
      stale_evidence: [],
      conflicts: [],
      safety_stops: [],
      acceptance: %{
        status: :complete,
        evidence_refs: ["test:merge-ready"],
        repository: "aroakpm-svg/symphony",
        pull_request_number: 42,
        linear_issue_id: "issue-246",
        linear_issue_identifier: "ARO-246",
        linear_revision: "2026-08-18T00:00:00Z",
        base_sha: sha("b"),
        head_sha: sha("a")
      },
      evidence_refs: ["receipt:design4"]
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
      linear_revision: "2026-08-18T00:00:00Z",
      base_sha: sha("b"),
      head_sha: sha("a")
    }
  end

  defp sha(character), do: String.duplicate(character, 40)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
