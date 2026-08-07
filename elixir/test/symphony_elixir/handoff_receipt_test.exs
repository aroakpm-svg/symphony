defmodule SymphonyElixir.HandoffReceiptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HandoffReceipt

  @receipt %{
    receipt_schema_version: 1,
    issue_id: "ARO-166",
    canonical_owner: "aroakpm-svg",
    canonical_repository: "symphony",
    claim_id: "00000000-0000-0000-0000-000000000001",
    generation: 2,
    checkpoint_sequence: 7,
    recorded_at: ~U[2026-08-07 00:00:00Z],
    branch: "codex/aro-166-handoff-receipts",
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
    commit_sha: String.duplicate("a", 40),
    pr_number: nil,
    pr_ready?: false,
    linear_revision_current?: true,
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
      {:recorded_at, nil}
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
      "codex/aro-166-handoff-receipts",
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

  test "append SQL preserves the complete 16-argument function contract" do
    sql = HandoffReceipt.append_sql_for_test()

    assert sql =~ "claim_id::text as claim_id"
    assert sql =~ "$11, $12, $13::text[], $14::text[], $15::jsonb, $16::text[]"
    refute sql =~ "$12::text[]"
  end

  test "append passes test results as a JSON value instead of encoded JSON text" do
    params = HandoffReceipt.append_params_for_test(@claim, @receipt)

    assert Enum.at(params, 14) == [%{"name" => "make all", "status" => "passed"}]
    refute is_binary(Enum.at(params, 14))
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
      "codex/aro-166-handoff-receipts",
      String.duplicate("a", 40),
      19,
      "delivery",
      ["preflight"],
      ["push"],
      [],
      []
    ]

    for status <- [nil, "unknown"] do
      row = List.replace_at(base_row, 14, [%{"name" => "make all", "status" => status}])
      assert HandoffReceipt.decode_row_for_test(row) == {:error, :receipt_incompatible}
    end

    for name <- [42, "   "] do
      row = List.replace_at(base_row, 14, [%{"name" => name, "status" => "passed"}])
      assert HandoffReceipt.decode_row_for_test(row) == {:error, :receipt_incompatible}
    end

    extra_key = %{"name" => "make all", "status" => "passed", "output" => "ignored"}

    assert base_row
           |> List.replace_at(14, [extra_key])
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
      "codex/aro-166-handoff-receipts",
      String.duplicate("a", 40),
      19,
      "delivery",
      ["preflight"],
      ["push"],
      [],
      []
    ]

    malformed_fields = [{11, "legacy"}, {12, ["unknown"]}, {13, nil}]

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

  test "completion requires terminal phase and every fixed step" do
    all_steps = HandoffReceipt.step_ids()

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :preflight,
                 completed_step_ids: all_steps,
                 pending_step_ids: [],
                 pr_number: 19
             },
             %{@truth | pr_number: 19, pr_ready?: true}
           ) == {:safe_recheck, :inconsistent_progress}

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :complete,
                 completed_step_ids: all_steps,
                 pending_step_ids: [],
                 pr_number: 19
             },
             %{@truth | pr_number: 19, pr_ready?: true}
           ) == {:ok, :complete}

    assert HandoffReceipt.resume(
             %{
               @receipt
               | current_phase: :complete,
                 completed_step_ids: Enum.drop(all_steps, -1),
                 pending_step_ids: [List.last(all_steps)],
                 pr_number: 19
             },
             %{@truth | pr_number: 19, pr_ready?: true}
           ) == {:safe_recheck, :inconsistent_progress}
  end

  test "changed Git, Linear, claim, or ledger truth requires a safe recheck" do
    cases = [
      {%{@truth | commit_sha: String.duplicate("b", 40)}, :git_or_repository_state_changed},
      {%{@truth | linear_revision_current?: false}, :linear_revision_changed},
      {%{@truth | active_claim?: false}, :claim_inactive},
      {%{@truth | effect_operations: %{}}, :effect_ledger_changed},
      {%{@truth | effect_operations: %{"ARO-166:git-commit:1" => :unknown}}, :effect_ledger_changed}
    ]

    for {truth, reason} <- cases do
      assert HandoffReceipt.resume(@receipt, truth) == {:safe_recheck, reason}
    end

    existing_pr = %{
      @receipt
      | completed_step_ids: Enum.drop(HandoffReceipt.step_ids(), -1),
        pending_step_ids: [:review],
        pr_number: 19
    }

    assert HandoffReceipt.resume(existing_pr, %{@truth | pr_number: 19, pr_ready?: false}) ==
             {:safe_recheck, :pr_not_ready}
  end
end
