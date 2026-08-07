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
    pr_number: 19,
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
    pr_number: 19,
    pr_ready?: true,
    linear_revision_current?: true,
    active_claim?: true,
    effect_operations: %{"ARO-166:git-commit:1" => :succeeded}
  }

  test "a compatible receipt plus freshly verified truths selects the next step" do
    assert HandoffReceipt.resume(@receipt, @truth) == {:ok, :push}
  end

  test "missing or future receipts safely require a full recheck" do
    assert HandoffReceipt.resume(nil, @truth) == {:safe_recheck, :receipt_missing}

    assert HandoffReceipt.resume(%{@receipt | receipt_schema_version: 2}, @truth) ==
             {:safe_recheck, :receipt_incompatible}
  end

  test "step overlap, duplicates, and values outside the allowlist fail closed" do
    overlap = %{@receipt | pending_step_ids: [:commit, :push]}
    duplicate = %{@receipt | completed_step_ids: [:preflight, :preflight]}
    unknown = %{@receipt | pending_step_ids: [:deploy]}

    assert {:safe_recheck, :overlapping_steps} = HandoffReceipt.resume(overlap, @truth)
    assert {:safe_recheck, :invalid_completed_steps} = HandoffReceipt.resume(duplicate, @truth)
    assert {:safe_recheck, :invalid_pending_steps} = HandoffReceipt.resume(unknown, @truth)
  end

  test "structured test results reject extra free-form fields" do
    receipt = %{
      @receipt
      | test_results: [%{name: "make all", status: :passed, output: "unbounded text"}]
    }

    assert HandoffReceipt.resume(receipt, @truth) ==
             {:safe_recheck, :invalid_test_results}
  end

  test "changed Git, Linear, claim, or ledger truth requires a safe recheck" do
    cases = [
      {%{@truth | commit_sha: String.duplicate("b", 40)}, :git_or_repository_state_changed},
      {%{@truth | linear_revision_current?: false}, :linear_revision_changed},
      {%{@truth | active_claim?: false}, :claim_inactive},
      {%{@truth | pr_ready?: false}, :pr_not_ready},
      {%{@truth | effect_operations: %{}}, :effect_ledger_changed},
      {%{@truth | effect_operations: %{"ARO-166:git-commit:1" => :unknown}}, :effect_ledger_changed}
    ]

    for {truth, reason} <- cases do
      assert HandoffReceipt.resume(@receipt, truth) == {:safe_recheck, reason}
    end
  end
end
