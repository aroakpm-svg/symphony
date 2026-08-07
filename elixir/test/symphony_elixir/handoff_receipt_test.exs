defmodule SymphonyElixir.HandoffReceiptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentRunner, HandoffReceipt, Workspace}

  test "raw Git evidence retains bytes beyond the log sanitization limit" do
    workspace =
      Path.join(System.tmp_dir!(), "handoff-raw-diff-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "large.txt"), String.duplicate("evidence-tail\n", 400))

      assert {:ok, 1, evidence} =
               Workspace.run_git_command_with_status(
                 workspace,
                 ["diff", "--no-index", "--binary", "--no-prefix", "--", "/dev/null", "large.txt"]
               )

      assert byte_size(evidence) > 2_048
      assert evidence =~ "evidence-tail"
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff verification is based on freshly fetched tracker and workspace evidence" do
    source = File.read!(Path.expand("../../lib/symphony_elixir/agent_runner.ex", __DIR__))

    assert source =~ "fetch_handoff_issue(issue.id, issue_fetcher)"
    assert source =~ "run_codex_turns(\n                workspace,\n                current_issue"
    assert source =~ "handoff_issue_runnable?(fresh_issue)"
    assert source =~ "checkpoint_effects"
    assert source =~ "HandoffReceipt.resume(checkpoint"
    assert source =~ "Postgrex.transaction(connection"
    assert source =~ "run_locked_handoff("
    assert source =~ "handoff_commit_sha(previous, git_evidence.head_sha)"
    refute source =~ "handoff_commit_sha(previous, readiness.head_sha)"
    assert source =~ "workspace_evidence(workspace, readiness.issue_branch, repository, worker_host)"
    assert source =~ "Known canonical managed effect IDs"
    assert source =~ "Reuse the exact existing ID for the same intended effect"
  end

  test "PR readiness is bound to the locally and remotely verified head" do
    sha = String.duplicate("a", 40)
    evidence = %{head_sha: sha, remote_branch_sha: sha}

    assert AgentRunner.handoff_pr_ready_for_test(
             %{number: 19, head_sha: sha, ready?: true},
             evidence
           )

    refute AgentRunner.handoff_pr_ready_for_test(
             %{number: 19, head_sha: String.duplicate("b", 40), ready?: true},
             evidence
           )

    refute AgentRunner.handoff_pr_ready_for_test(
             %{number: 19, head_sha: sha, ready?: true},
             %{evidence | remote_branch_sha: nil}
           )
  end

  test "handoff evidence requires the expected checked-out symbolic branch" do
    assert HandoffReceipt.validate_checked_out_branch_for_test(
             "codex/aro-166-handoff-receipts",
             "codex/aro-166-handoff-receipts"
           ) == {:ok, "codex/aro-166-handoff-receipts"}

    assert HandoffReceipt.validate_checked_out_branch_for_test(
             "other-branch",
             "codex/aro-166-handoff-receipts"
           ) == {:error, :handoff_branch_mismatch}

    assert HandoffReceipt.validate_checked_out_branch_for_test(
             "HEAD",
             "codex/aro-166-handoff-receipts"
           ) == {:error, :handoff_branch_mismatch}
  end

  test "canonical origin parsing accepts GitHub transports without accepting lookalike hosts" do
    assert HandoffReceipt.github_repository_from_remote_for_test("https://github.com/aroakpm-svg/symphony.git") == {:ok, "aroakpm-svg/symphony"}

    assert HandoffReceipt.github_repository_from_remote_for_test("git@github.com:aroakpm-svg/symphony.git") == {:ok, "aroakpm-svg/symphony"}

    assert HandoffReceipt.github_repository_from_remote_for_test("ssh://git@github.com/aroakpm-svg/symphony") == {:ok, "aroakpm-svg/symphony"}

    assert HandoffReceipt.github_repository_from_remote_for_test("ssh://git@github.com:22/aroakpm-svg/symphony.git") ==
             {:ok, "aroakpm-svg/symphony"}

    assert HandoffReceipt.github_repository_from_remote_for_test("https://github.com:443/aroakpm-svg/symphony.git") ==
             {:ok, "aroakpm-svg/symphony"}

    assert HandoffReceipt.github_repository_from_remote_for_test("https://github.com.example/aroakpm-svg/symphony.git") == {:error, :handoff_origin_invalid}
  end

  @receipt %{
    receipt_schema_version: 1,
    issue_id: "ARO-166",
    canonical_owner: "aroakpm-svg",
    canonical_repository: "symphony",
    claim_id: "00000000-0000-0000-0000-000000000001",
    generation: 2,
    checkpoint_sequence: 7,
    recorded_at: ~U[2026-08-07 00:00:00Z],
    linear_updated_at: ~U[2026-08-06 23:59:00Z],
    branch: "codex/aro-166-handoff-receipts",
    worktree_fingerprint: String.duplicate("f", 64),
    remote_branch_sha: nil,
    commit_sha: String.duplicate("a", 40),
    pr_number: nil,
    current_phase: :delivery,
    completed_step_ids: [:preflight, :branch, :implementation, :tests, :commit],
    pending_step_ids: [:push, :pull_request, :review],
    test_results: [%{name: "make all", status: :passed}],
    effect_operation_ids: ["ARO-166:git-commit:1"]
  }

  @truth %{
    issue_id: "ARO-166",
    canonical_owner: "aroakpm-svg",
    canonical_repository: "symphony",
    branch: "codex/aro-166-handoff-receipts",
    worktree_fingerprint: String.duplicate("f", 64),
    remote_branch_sha: nil,
    commit_sha: String.duplicate("a", 40),
    pr_number: nil,
    pr_ready?: false,
    linear_updated_at: ~U[2026-08-06 23:59:00Z],
    active_claim?: true,
    effect_operations: %{"ARO-166:git-commit:1" => :succeeded}
  }

  @claim %{
    issue_id: "ARO-166",
    claim_id: "00000000-0000-0000-0000-000000000001",
    generation: 2,
    node_id: "00000000-0000-0000-0000-000000000002",
    node_instance_id: "00000000-0000-0000-0000-000000000003"
  }

  test "a compatible receipt plus freshly verified truths selects the next step" do
    assert HandoffReceipt.resume(@receipt, @truth) == {:ok, :push}
  end

  test "a verified pre-PR checkpoint resumes without requiring PR readiness" do
    assert HandoffReceipt.resume(@receipt, @truth) == {:ok, :push}
  end

  test "missing or future receipts safely require a full recheck" do
    assert HandoffReceipt.resume(nil, @truth) == {:safe_recheck, :receipt_missing}

    assert HandoffReceipt.resume(%{@receipt | receipt_schema_version: 2}, @truth) ==
             {:safe_recheck, :receipt_incompatible}
  end

  test "receipts missing any V1 field fail closed before verification" do
    for key <- Map.keys(@receipt) do
      assert @receipt
             |> Map.delete(key)
             |> HandoffReceipt.resume(@truth) == {:safe_recheck, :receipt_incompatible}
    end
  end

  test "receipts with invalid persisted metadata fail closed" do
    invalid_values = [
      {:issue_id, " "},
      {:claim_id, nil},
      {:claim_id, "not-a-uuid"},
      {:generation, 0},
      {:checkpoint_sequence, 0},
      {:recorded_at, nil},
      {:linear_updated_at, nil}
    ]

    for {key, value} <- invalid_values do
      assert @receipt
             |> Map.put(key, value)
             |> HandoffReceipt.resume(@truth) == {:safe_recheck, :receipt_incompatible}
    end
  end

  test "database rows decode schema version before checkpoint sequence" do
    row = [
      1,
      "ARO-166",
      "aroakpm-svg",
      "symphony",
      "00000000-0000-0000-0000-000000000001",
      2,
      7,
      ~U[2026-08-07 00:00:00Z],
      ~U[2026-08-06 23:59:00Z],
      "codex/aro-166-handoff-receipts",
      String.duplicate("f", 64),
      nil,
      String.duplicate("a", 40),
      19,
      "delivery",
      ["preflight", "branch"],
      ["push"],
      [%{"name" => "make all", "status" => "passed"}],
      ["ARO-166:git-commit:1"]
    ]

    assert {:ok, receipt} = HandoffReceipt.decode_row_for_test(row)
    assert receipt.receipt_schema_version == 1
    assert receipt.checkpoint_sequence == 7

    assert HandoffReceipt.decode_row_for_test([7, 1 | Enum.drop(row, 2)]) ==
             {:error, :receipt_incompatible}
  end

  test "append SQL preserves the complete 18-argument function contract" do
    sql = HandoffReceipt.append_sql_for_test()

    assert sql =~ "claim_id::text as claim_id"
    assert sql =~ "$13, $14, $15::text[], $16::text[], $17::jsonb, $18::text[]"
  end

  test "append passes test results as a JSON value instead of encoded JSON text" do
    params = HandoffReceipt.append_params_for_test(@claim, @receipt)

    assert Enum.at(params, 16) == [%{"name" => "make all", "status" => "passed"}]
    refute is_binary(Enum.at(params, 16))
  end

  test "database rows with null or unknown test statuses fail closed" do
    base_row = [
      1,
      "ARO-166",
      "aroakpm-svg",
      "symphony",
      "00000000-0000-0000-0000-000000000001",
      2,
      7,
      ~U[2026-08-07 00:00:00Z],
      ~U[2026-08-06 23:59:00Z],
      "codex/aro-166-handoff-receipts",
      String.duplicate("f", 64),
      nil,
      String.duplicate("a", 40),
      19,
      "delivery",
      ["preflight"],
      ["push"],
      [],
      []
    ]

    for status <- [nil, "unknown"] do
      row = List.replace_at(base_row, 17, [%{"name" => "make all", "status" => status}])
      assert HandoffReceipt.decode_row_for_test(row) == {:error, :receipt_incompatible}
    end

    for name <- [42, "   "] do
      row = List.replace_at(base_row, 17, [%{"name" => name, "status" => "passed"}])
      assert HandoffReceipt.decode_row_for_test(row) == {:error, :receipt_incompatible}
    end

    extra_key = %{"name" => "make all", "status" => "passed", "output" => "ignored"}

    assert base_row
           |> List.replace_at(17, [extra_key])
           |> HandoffReceipt.decode_row_for_test() == {:error, :receipt_incompatible}
  end

  test "database rows validate phase and step shapes before atom conversion" do
    base_row = [
      1,
      "ARO-166",
      "aroakpm-svg",
      "symphony",
      "00000000-0000-0000-0000-000000000001",
      2,
      7,
      ~U[2026-08-07 00:00:00Z],
      ~U[2026-08-06 23:59:00Z],
      "codex/aro-166-handoff-receipts",
      String.duplicate("f", 64),
      nil,
      String.duplicate("a", 40),
      19,
      "delivery",
      ["preflight"],
      ["push"],
      [],
      []
    ]

    malformed_fields = [{14, "legacy"}, {15, ["unknown"]}, {16, nil}]

    for {index, value} <- malformed_fields do
      assert base_row
             |> List.replace_at(index, value)
             |> HandoffReceipt.decode_row_for_test() == {:error, :receipt_incompatible}
    end
  end

  test "step overlap, duplicates, and values outside the allowlist fail closed" do
    overlap = %{@receipt | pending_step_ids: [:commit, :push]}
    duplicate = %{@receipt | completed_step_ids: [:preflight, :preflight]}
    unknown = %{@receipt | pending_step_ids: [:deploy]}

    assert {:safe_recheck, :overlapping_steps} = HandoffReceipt.resume(overlap, @truth)
    assert {:safe_recheck, :invalid_completed_steps} = HandoffReceipt.resume(duplicate, @truth)
    assert {:safe_recheck, :invalid_pending_steps} = HandoffReceipt.resume(unknown, @truth)
  end

  test "completed and pending lists always account for every fixed step" do
    receipt = %{@receipt | completed_step_ids: [:preflight], pending_step_ids: [:review]}

    assert HandoffReceipt.resume(receipt, @truth) ==
             {:safe_recheck, :incomplete_step_accounting}
  end

  test "workflow steps retain their canonical prefix and suffix order" do
    receipt = %{
      @receipt
      | completed_step_ids: [:preflight],
        pending_step_ids: [:review, :branch, :implementation, :tests, :commit, :push, :pull_request]
    }

    assert HandoffReceipt.resume(receipt, @truth) ==
             {:safe_recheck, :noncanonical_step_order}
  end

  test "completed delivery steps require their artifacts" do
    missing_commit = %{@receipt | commit_sha: nil}

    premature_commit = %{
      @receipt
      | completed_step_ids: [:preflight, :branch, :implementation, :tests],
        pending_step_ids: [:commit, :push, :pull_request, :review]
    }

    assert HandoffReceipt.resume(missing_commit, %{@truth | commit_sha: nil}) ==
             {:safe_recheck, :inconsistent_commit_artifact}

    assert HandoffReceipt.resume(premature_commit, @truth) ==
             {:safe_recheck, :inconsistent_commit_artifact}
  end

  test "structured test results reject extra free-form fields" do
    receipt = %{
      @receipt
      | test_results: [%{name: "make all", status: :passed, output: "unbounded text"}]
    }

    assert HandoffReceipt.resume(receipt, @truth) ==
             {:safe_recheck, :invalid_test_results}
  end

  test "failed evidence keeps the tests step pending" do
    failed = %{@receipt | test_results: [%{name: "make all", status: :failed}]}

    assert HandoffReceipt.resume(failed, @truth) ==
             {:safe_recheck, :failed_tests_marked_complete}

    pending = %{
      failed
      | completed_step_ids: [:preflight, :branch, :implementation],
        pending_step_ids: [:tests, :commit, :push, :pull_request, :review],
        commit_sha: nil
    }

    assert HandoffReceipt.resume(pending, %{@truth | commit_sha: nil}) == {:ok, :tests}
  end

  test "completed tests require at least one structured result" do
    receipt = %{@receipt | test_results: []}

    assert HandoffReceipt.resume(receipt, @truth) ==
             {:safe_recheck, :missing_test_evidence}
  end

  test "completion requires terminal phase and every fixed step" do
    all_steps = HandoffReceipt.step_ids()

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :preflight,
                 completed_step_ids: all_steps,
                 pending_step_ids: [],
                 pr_number: 19,
                 remote_branch_sha: String.duplicate("a", 40)
             },
             %{@truth | pr_number: 19, pr_ready?: true, remote_branch_sha: String.duplicate("a", 40)}
           ) == {:safe_recheck, :inconsistent_progress}

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :complete,
                 completed_step_ids: all_steps,
                 pending_step_ids: [],
                 pr_number: 19,
                 remote_branch_sha: String.duplicate("a", 40)
             },
             %{@truth | pr_number: 19, pr_ready?: true, remote_branch_sha: String.duplicate("a", 40)}
           ) == {:ok, :complete}

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :complete,
                 completed_step_ids: Enum.drop(all_steps, -1),
                 pending_step_ids: [List.last(all_steps)],
                 pr_number: 19,
                 remote_branch_sha: String.duplicate("a", 40)
             },
             %{@truth | pr_number: 19, pr_ready?: true, remote_branch_sha: String.duplicate("a", 40)}
           ) == {:safe_recheck, :inconsistent_progress}
  end

  test "changed Git, Linear, claim, or ledger truth requires a safe recheck" do
    cases = [
      {%{@truth | commit_sha: String.duplicate("b", 40)}, :git_or_repository_state_changed},
      {%{@truth | linear_updated_at: ~U[2026-08-07 00:00:00Z]}, :linear_revision_changed},
      {%{@truth | active_claim?: false}, :claim_inactive},
      {%{@truth | effect_operations: %{}}, :effect_ledger_changed},
      {%{@truth | effect_operations: %{"ARO-166:git-commit:1" => :unknown}}, :effect_ledger_changed},
      {%{@truth | effect_operations: %{"ARO-166:git-commit:1" => :failed_no_effect}}, :effect_ledger_changed}
    ]

    for {truth, reason} <- cases do
      assert HandoffReceipt.resume(@receipt, truth) == {:safe_recheck, reason}
    end

    existing_pr = %{
      @receipt
      | completed_step_ids: Enum.drop(HandoffReceipt.step_ids(), -1),
        pending_step_ids: [:review],
        pr_number: 19,
        remote_branch_sha: String.duplicate("a", 40)
    }

    assert HandoffReceipt.resume(existing_pr, %{@truth | pr_number: 19, pr_ready?: false, remote_branch_sha: String.duplicate("a", 40)}) ==
             {:safe_recheck, :pr_not_ready}
  end
end
