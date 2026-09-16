defmodule SymphonyElixir.DispatchPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DispatchPolicy

  @now ~U[2026-09-16 06:00:00Z]

  test "allows an eligible issue with fresh evidence and returns the exact receipt" do
    assert DispatchPolicy.evaluate(issue(), policy(), run_state(), evidence(), @now) ==
             {:allow,
              %{
                issue_id: "issue-1",
                policy_revision: 3,
                workflow_sha: "workflow-sha-3",
                evidence_version: "evidence-v9",
                evidence_valid_until: ~U[2026-09-16 06:03:00Z]
              }}
  end

  test "denies a missing or different Team identity" do
    for team_id <- [nil, "other-team"] do
      assert DispatchPolicy.evaluate(
               issue(%{team_id: team_id}),
               policy(),
               run_state(),
               evidence(),
               @now
             ) == {:deny, [:wrong_team]}
    end
  end

  test "denies a same-name Project with a different immutable ID" do
    assert DispatchPolicy.evaluate(
             issue(%{project_id: "other-project"}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:wrong_project]}
  end

  test "denies a different repository" do
    assert DispatchPolicy.evaluate(
             issue(%{repository: "aroakpm-svg/other"}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:wrong_repository]}
  end

  test "denies an issue without the worker label" do
    assert DispatchPolicy.evaluate(
             issue(%{label_ids: []}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:missing_worker_label]}
  end

  test "denies an issue outside the approved workflow states" do
    assert DispatchPolicy.evaluate(
             issue(%{state_id: "done-state"}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:inactive_state]}
  end

  test "requires an exact active claim for In Progress" do
    in_progress_issue = issue(%{state_id: "in-progress-state"})

    assert DispatchPolicy.evaluate(
             in_progress_issue,
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:unowned_in_progress]}

    assert {:allow, _receipt} =
             DispatchPolicy.evaluate(
               in_progress_issue,
               policy(),
               run_state(%{claim: %{issue_id: "issue-1", generation: 2, active: true}}),
               evidence(),
               @now
             )

    for claim <- [
          %{issue_id: "other-issue", generation: 2, active: true},
          %{issue_id: "issue-1", generation: 0, active: true},
          %{issue_id: "issue-1", generation: -1, active: true},
          %{issue_id: "issue-1", generation: 2, active: false}
        ] do
      assert DispatchPolicy.evaluate(
               in_progress_issue,
               policy(),
               run_state(%{claim: claim}),
               evidence(),
               @now
             ) == {:deny, [:unowned_in_progress]}
    end
  end

  test "requires exact accepted Done evidence for every blocker" do
    for blocker_acceptance <- [
          %{"blocker-1" => %{state: "Canceled", accepted: true}},
          %{"blocker-1" => %{state: "Duplicate", accepted: true}},
          %{"blocker-1" => %{state: "Unknown", accepted: true}},
          %{},
          %{"blocker-1" => %{state: "Done", accepted: false}},
          %{"blocker-1" => %{state: "Done", accepted: true, extra: true}}
        ] do
      assert DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(),
               evidence(%{blocker_acceptance: blocker_acceptance}),
               @now
             ) == {:deny, [:blocker_not_accepted]}
    end

    assert DispatchPolicy.evaluate(
             issue(%{blocked_by: [%{id: ""}]}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:blocker_not_accepted]}
  end

  test "allows an issue with no blockers and an empty acceptance map" do
    assert {:allow, _receipt} =
             DispatchPolicy.evaluate(
               issue(%{blocked_by: []}),
               policy(),
               run_state(),
               evidence(%{blocker_acceptance: %{}}),
               @now
             )
  end

  test "denies unavailable, incomplete, future, expired, or malformed evidence" do
    unavailable_evidence = [
      evidence(%{status: :error}),
      evidence(%{blockers_complete: false}),
      evidence(%{read_at: ~U[2026-09-16 06:01:00Z]}),
      evidence(%{read_at: ~U[2026-09-16 05:54:59Z]}),
      Map.delete(evidence(), :supported_models),
      evidence(%{read_at: "2026-09-16T05:58:00Z"})
    ]

    for unavailable <- unavailable_evidence do
      assert DispatchPolicy.evaluate(issue(), policy(), run_state(), unavailable, @now) ==
               {:deny, [:evidence_unavailable]}
    end
  end

  test "accepts evidence exactly at its deadline" do
    assert {:allow, %{evidence_valid_until: ~U[2026-09-16 06:00:00Z]}} =
             DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(),
               evidence(%{read_at: ~U[2026-09-16 05:55:00Z]}),
               @now
             )
  end

  test "does not derive evidence-dependent reasons from unusable evidence" do
    unusable =
      evidence(%{
        status: :error,
        blocker_acceptance: %{},
        human_gate: %{status: :pending},
        supported_models: []
      })

    assert DispatchPolicy.evaluate(issue(), policy(), run_state(), unusable, @now) ==
             {:deny, [:evidence_unavailable]}
  end

  test "denies a pending required human gate" do
    assert DispatchPolicy.evaluate(
             issue(),
             policy(),
             run_state(),
             evidence(%{human_gate: %{status: :pending}}),
             @now
           ) == {:deny, [:human_gate_pending]}
  end

  test "allows a disabled human gate without approval" do
    assert {:allow, _receipt} =
             DispatchPolicy.evaluate(
               issue(),
               policy(%{human_gate: :disabled}),
               run_state(),
               evidence(%{human_gate: %{status: :pending}}),
               @now
             )
  end

  test "binds approved evidence to the issue, policy, and workflow revisions" do
    for human_gate <- [
          %{
            status: :approved,
            issue_revision: "other-revision",
            policy_revision: 3,
            workflow_sha: "workflow-sha-3"
          },
          %{
            status: :approved,
            issue_revision: "issue-revision-7",
            policy_revision: 4,
            workflow_sha: "workflow-sha-3"
          },
          %{
            status: :approved,
            issue_revision: "issue-revision-7",
            policy_revision: 3,
            workflow_sha: "other-workflow"
          }
        ] do
      assert DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(),
               evidence(%{human_gate: human_gate}),
               @now
             ) == {:deny, [:policy_revision_mismatch]}
    end
  end

  test "binds run state to the issue, policy, and workflow revisions" do
    for state <- [
          run_state(%{approved_issue_revision: "other-revision"}),
          run_state(%{approved_policy_revision: 4}),
          run_state(%{approved_workflow_sha: "other-workflow"})
        ] do
      assert DispatchPolicy.evaluate(issue(), policy(), state, evidence(), @now) ==
               {:deny, [:policy_revision_mismatch]}
    end
  end

  test "denies when a time, turn, failure, or distinct-issue quota is exhausted" do
    for state <- [
          run_state(%{accumulated_minutes: 30}),
          run_state(%{turns: 10}),
          run_state(%{failures: 3}),
          run_state(%{issue_ids_24h: ["one", "two", "three", "four", "five"]})
        ] do
      assert DispatchPolicy.evaluate(issue(), policy(), state, evidence(), @now) ==
               {:deny, [:quota_exhausted]}
    end
  end

  test "counts distinct 24-hour issue IDs and permits an existing issue at the maximum" do
    assert {:allow, _receipt} =
             DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(%{issue_ids_24h: ["older-issue", "older-issue"]}),
               evidence(),
               @now
             )

    assert {:allow, _receipt} =
             DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(%{issue_ids_24h: ["issue-1", "two", "three", "four", "five"]}),
               evidence(),
               @now
             )
  end

  test "fails quota validation closed for malformed counters, maxima, or issue IDs" do
    malformed_pairs = [
      {run_state(%{accumulated_minutes: -1}), policy()},
      {run_state(%{turns: "two"}), policy()},
      {run_state(%{failures: nil}), policy()},
      {run_state(%{issue_ids_24h: ["older-issue", nil]}), policy()},
      {run_state(), policy(%{limits: Map.put(policy().limits, :max_minutes, -1)})},
      {run_state(), policy(%{limits: Map.put(policy().limits, :max_issues_24h, 1.5)})}
    ]

    for {state, quota_policy} <- malformed_pairs do
      assert DispatchPolicy.evaluate(issue(), quota_policy, state, evidence(), @now) ==
               {:deny, [:quota_exhausted]}
    end
  end

  test "denies paused and stopped run states" do
    for pause_state <- [:paused, :stopped] do
      assert DispatchPolicy.evaluate(
               issue(),
               policy(),
               run_state(%{pause_state: pause_state}),
               evidence(),
               @now
             ) == {:deny, [:paused]}
    end
  end

  test "requires exact model support from valid evidence" do
    assert DispatchPolicy.evaluate(
             issue(),
             policy(),
             run_state(),
             evidence(%{supported_models: ["gpt-6-astra"]}),
             @now
           ) == {:deny, [:unsupported_model]}
  end

  test "returns unique denial reasons in the documented order" do
    assert DispatchPolicy.evaluate(
             issue(%{team_id: "other-team", label_ids: []}),
             policy(),
             run_state(%{pause_state: :paused}),
             evidence(),
             @now
           ) == {:deny, [:wrong_team, :missing_worker_label, :paused]}
  end

  test "rejects every non-map top-level input and a non-DateTime clock" do
    invalid_calls = [
      [nil, policy(), run_state(), evidence(), @now],
      [issue(), nil, run_state(), evidence(), @now],
      [issue(), policy(), nil, evidence(), @now],
      [issue(), policy(), run_state(), nil, @now],
      [issue(), policy(), run_state(), evidence(), "2026-09-16T06:00:00Z"]
    ]

    for arguments <- invalid_calls do
      assert apply(DispatchPolicy, :evaluate, arguments) == {:deny, [:invalid_input]}
    end
  end

  test "rejects malformed nested policy input without raising" do
    assert DispatchPolicy.evaluate(
             issue(),
             policy(%{human_gate: :sometimes}),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:invalid_input]}

    assert {:deny, reasons} =
             DispatchPolicy.evaluate(
               issue(),
               policy(%{scope: nil}),
               run_state(),
               evidence(),
               @now
             )

    assert reasons == [
             :invalid_input,
             :wrong_team,
             :wrong_project,
             :wrong_repository
           ]

    assert DispatchPolicy.evaluate(
             issue(%{id: nil}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:invalid_input]}

    assert DispatchPolicy.evaluate(
             issue(%{label_ids: nil}),
             policy(),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:invalid_input, :missing_worker_label]}

    assert DispatchPolicy.evaluate(
             issue(),
             policy(%{limits: nil}),
             run_state(),
             evidence(),
             @now
           ) == {:deny, [:invalid_input, :quota_exhausted]}
  end

  test "keeps the pure policy generic for both existing repositories" do
    for {project_id, repository} <- [
          {"d0acfb71-f68c-4a9f-8a1a-477265d3c3ec", "aroakpm-svg/aroak-central-brain"},
          {"708053e0-f42c-4e93-bec4-7abbb37e74af", "aroakpm-svg/aroak-project-management"}
        ] do
      generic_issue = issue(%{project_id: project_id, repository: repository})

      generic_policy =
        policy(%{
          scope: %{
            team_id: "e057ed6d-08c4-449d-becb-2c1fbc3fcabc",
            project_id: project_id,
            repository: repository
          }
        })

      assert {:allow, _receipt} =
               DispatchPolicy.evaluate(
                 generic_issue,
                 generic_policy,
                 run_state(),
                 evidence(),
                 @now
               )
    end
  end

  defp issue(overrides \\ %{}) do
    Map.merge(
      %{
        id: "issue-1",
        team_id: "e057ed6d-08c4-449d-becb-2c1fbc3fcabc",
        project_id: "6616d485-7a2d-42e4-bc34-b6510e08ff55",
        repository: "aroakpm-svg/Social-Media-Analysis",
        state_id: "todo-state",
        label_ids: ["sma-worker-label"],
        revision: "issue-revision-7",
        blocked_by: [%{id: "blocker-1"}]
      },
      overrides
    )
  end

  defp policy(overrides \\ %{}) do
    Map.merge(
      %{
        revision: 3,
        workflow_sha: "workflow-sha-3",
        scope: %{
          team_id: "e057ed6d-08c4-449d-becb-2c1fbc3fcabc",
          project_id: "6616d485-7a2d-42e4-bc34-b6510e08ff55",
          repository: "aroakpm-svg/Social-Media-Analysis"
        },
        allowed_state_ids: ["todo-state", "in-progress-state"],
        in_progress_state_ids: ["in-progress-state"],
        worker_label_id: "sma-worker-label",
        human_gate: :required,
        model: "gpt-5.6-sol",
        limits: %{max_minutes: 30, max_turns: 10, max_failures: 3, max_issues_24h: 5},
        evidence_ttl_seconds: 300
      },
      overrides
    )
  end

  defp run_state(overrides \\ %{}) do
    Map.merge(
      %{
        claim: nil,
        approved_issue_revision: "issue-revision-7",
        approved_policy_revision: 3,
        approved_workflow_sha: "workflow-sha-3",
        accumulated_minutes: 4,
        turns: 2,
        failures: 0,
        issue_ids_24h: ["older-issue"],
        pause_state: :active
      },
      overrides
    )
  end

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        version: "evidence-v9",
        status: :ok,
        blockers_complete: true,
        read_at: ~U[2026-09-16 05:58:00Z],
        blocker_acceptance: %{"blocker-1" => %{state: "Done", accepted: true}},
        human_gate: %{
          status: :approved,
          issue_revision: "issue-revision-7",
          policy_revision: 3,
          workflow_sha: "workflow-sha-3"
        },
        supported_models: ["gpt-5.6-sol"]
      },
      overrides
    )
  end
end
