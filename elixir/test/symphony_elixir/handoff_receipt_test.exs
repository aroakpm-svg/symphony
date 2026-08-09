defmodule SymphonyElixir.HandoffReceiptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HandoffReceipt

  @sha String.duplicate("a", 40)
  @claim_id "10000000-0000-0000-0000-000000000001"

  defp receipt(kind \\ :pushed) do
    %{
      receipt_schema_version: 1,
      issue_id: "ARO-166",
      repository: "aroakpm-svg/symphony",
      claim_id: @claim_id,
      generation: 2,
      checkpoint_sequence: 7,
      recorded_at: ~U[2026-08-10 02:00:00Z],
      checkpoint_kind: kind,
      branch: "codex/aro-166-replacement",
      head_sha: @sha,
      tested_head_sha: @sha,
      pr_number: if(kind == :pushed, do: nil, else: 23),
      test_results: [%{name: "make all", status: :passed}],
      effect_operation_ids: ["ARO-166:git_push"]
    }
  end

  defp observation do
    %{
      issue_id: "ARO-166",
      repository: "aroakpm-svg/symphony",
      branch: "codex/aro-166-replacement",
      remote_head_sha: @sha,
      pr_number: nil,
      pr_head_sha: nil,
      git_ready?: true,
      linear_current?: true,
      active_claim?: true,
      exact_head_review_passed?: false,
      effect_statuses: %{"ARO-166:git_push" => :succeeded}
    }
  end

  test "accepts only the exact V1 receipt shape" do
    assert :ok = HandoffReceipt.validate(receipt())

    assert :ok =
             HandoffReceipt.validate(%{
               receipt()
               | test_results: [%{name: "docs", status: :skipped}],
                 effect_operation_ids: []
             })

    assert {:error, :receipt_shape} = HandoffReceipt.validate(Map.put(receipt(), :current_phase, "tests"))
    assert {:error, :receipt_shape} = HandoffReceipt.validate(Map.delete(receipt(), :branch))
    assert {:error, :receipt_shape} = HandoffReceipt.validate(nil)
  end

  test "rejects invalid schema, identity, checkpoint, SHA, PR, tests, and effect IDs" do
    invalid = [
      {Map.put(receipt(), :receipt_schema_version, 2), :schema_version},
      {Map.put(receipt(), :issue_id, ""), :issue_id},
      {Map.put(receipt(), :repository, "AROAKPM-SVG/symphony"), :repository},
      {Map.put(receipt(), :repository, 42), :repository},
      {Map.put(receipt(), :claim_id, "not-a-uuid"), :claim_id},
      {Map.put(receipt(), :claim_id, nil), :claim_id},
      {Map.put(receipt(), :generation, 0), :generation},
      {Map.put(receipt(), :checkpoint_sequence, 0), :checkpoint_sequence},
      {Map.put(receipt(), :recorded_at, "2026-08-10"), :recorded_at},
      {Map.put(receipt(), :checkpoint_kind, :tests), :checkpoint_kind},
      {Map.put(receipt(), :branch, ""), :branch},
      {Map.put(receipt(), :head_sha, "abc"), :head_sha},
      {Map.put(receipt(), :head_sha, nil), :head_sha},
      {Map.put(receipt(), :tested_head_sha, String.duplicate("b", 40)), :tested_head_sha},
      {Map.put(receipt(), :pr_number, 23), :pr_number},
      {Map.put(receipt(:reviewed), :pr_number, nil), :pr_number},
      {Map.put(receipt(), :test_results, []), :test_results},
      {Map.put(receipt(), :test_results, "passed"), :test_results},
      {Map.put(receipt(), :test_results, [42]), :test_results},
      {Map.put(receipt(), :test_results, [%{name: "make all", status: :failed}]), :test_results},
      {
        Map.put(receipt(), :test_results, [%{name: "make all", status: :passed, detail: "extra"}]),
        :test_results
      },
      {
        Map.put(receipt(), :effect_operation_ids, ["ARO-166:git_push", "ARO-166:git_push"]),
        :effect_operation_ids
      },
      {Map.put(receipt(), :effect_operation_ids, [""]), :effect_operation_ids},
      {Map.put(receipt(), :effect_operation_ids, "ARO-166:git_push"), :effect_operation_ids}
    ]

    for {value, reason} <- invalid do
      assert {:error, ^reason} = HandoffReceipt.validate(value)
    end
  end

  test "returns the next candidate action for the three durable checkpoints" do
    assert {:ok, :pull_request} = HandoffReceipt.resume(receipt(:pushed), observation())

    pr_observation = %{observation() | pr_number: 23, pr_head_sha: @sha}
    assert {:ok, :review} = HandoffReceipt.resume(receipt(:pull_request), pr_observation)

    reviewed_observation = %{pr_observation | exact_head_review_passed?: true}
    assert {:ok, :complete} = HandoffReceipt.resume(receipt(:reviewed), reviewed_observation)
  end

  test "fails closed with one stable reason in validation order" do
    cases = [
      {nil, observation(), :receipt_missing},
      {Map.put(receipt(), :current_phase, "tests"), observation(), :receipt_incompatible},
      {receipt(), Map.put(observation(), :extra, true), :observation_incompatible},
      {receipt(), %{observation() | issue_id: "ARO-999"}, :identity_changed},
      {receipt(), %{observation() | active_claim?: false}, :claim_inactive},
      {receipt(), %{observation() | linear_current?: false}, :linear_changed},
      {receipt(), %{observation() | git_ready?: false}, :git_unready},
      {receipt(), %{observation() | remote_head_sha: String.duplicate("b", 40)}, :remote_head_changed},
      {receipt(:pull_request), %{observation() | pr_number: 24, pr_head_sha: @sha}, :pull_request_changed},
      {receipt(:reviewed), %{observation() | pr_number: 23, pr_head_sha: @sha}, :review_stale},
      {receipt(), %{observation() | effect_statuses: %{"ARO-166:git_push" => :unknown}}, :effect_unsettled}
    ]

    for {stored, native, reason} <- cases do
      assert {:safe_recheck, ^reason} = HandoffReceipt.resume(stored, native)
    end
  end

  test "native progress beyond a receipt never repeats the older action" do
    pr_exists = %{observation() | pr_number: 23, pr_head_sha: @sha}
    assert {:safe_recheck, :native_state_advanced} = HandoffReceipt.resume(receipt(:pushed), pr_exists)

    review_exists = %{pr_exists | exact_head_review_passed?: true}

    assert {:safe_recheck, :native_state_advanced} =
             HandoffReceipt.resume(receipt(:pull_request), review_exists)
  end

  test "malformed native observations share the stable incompatible reason" do
    malformed = [
      nil,
      Map.delete(observation(), :branch),
      %{observation() | issue_id: 166},
      %{observation() | repository: "AROAKPM-SVG/symphony"},
      %{observation() | branch: ""},
      %{observation() | remote_head_sha: nil},
      %{observation() | pr_number: 0},
      %{observation() | pr_head_sha: "abc"},
      %{observation() | git_ready?: "yes"},
      %{observation() | effect_statuses: []},
      %{observation() | effect_statuses: %{42 => :succeeded}},
      %{observation() | effect_statuses: %{"ARO-166:git_push" => :alien}}
    ]

    for native <- malformed do
      assert {:safe_recheck, :observation_incompatible} = HandoffReceipt.resume(receipt(), native)
    end
  end
end
