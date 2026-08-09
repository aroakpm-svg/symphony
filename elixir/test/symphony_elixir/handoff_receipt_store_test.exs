defmodule SymphonyElixir.HandoffReceipt.StoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HandoffReceipt
  alias SymphonyElixir.HandoffReceipt.Store

  @sha String.duplicate("a", 40)
  @claim %{
    issue_id: "ARO-166",
    claim_id: "10000000-0000-0000-0000-000000000001",
    generation: 2,
    node_id: "20000000-0000-0000-0000-000000000001",
    node_instance_id: "30000000-0000-0000-0000-000000000001"
  }
  @attrs %{
    repository: "aroakpm-svg/symphony",
    checkpoint_kind: :pushed,
    branch: "codex/aro-166-replacement",
    head_sha: @sha,
    tested_head_sha: @sha,
    pr_number: nil,
    test_results: [%{name: "make all", status: :passed}]
  }
  @row [
    1,
    "ARO-166",
    "aroakpm-svg/symphony",
    "10000000-0000-0000-0000-000000000001",
    2,
    7,
    ~U[2026-08-10 02:00:00Z],
    "pushed",
    "codex/aro-166-replacement",
    @sha,
    @sha,
    nil,
    [%{"name" => "make all", "status" => "passed"}],
    ["ARO-166:git_push"]
  ]

  test "append calls only the append function with canonical parameter order" do
    parent = self()

    query = fn sql, params ->
      send(parent, {:query, sql, params})
      {:ok, %Postgrex.Result{rows: [@row], num_rows: 1}}
    end

    assert {:ok, %{checkpoint_kind: :pushed, test_results: [%{status: :passed}]}} =
             HandoffReceipt.append(query, @claim, @attrs)

    assert_receive {:query, sql, params}
    assert sql =~ "symphony_staging.append_handoff_receipt("

    assert params == [
             "ARO-166",
             @claim.claim_id,
             2,
             @claim.node_id,
             @claim.node_instance_id,
             "aroakpm-svg/symphony",
             "pushed",
             "codex/aro-166-replacement",
             @sha,
             @sha,
             nil,
             [%{"name" => "make all", "status" => "passed"}]
           ]
  end

  test "latest returns nil for no row and decodes exactly one V1 row" do
    assert {:ok, nil} = HandoffReceipt.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [], num_rows: 0}} end, @claim)

    assert {:ok, %{checkpoint_sequence: 7}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [@row], num_rows: 1}} end, @claim)
  end

  test "decodes every checkpoint and both allowed test statuses" do
    for {kind, pr_number} <- [{"pushed", nil}, {"pull_request", 23}, {"reviewed", 23}] do
      row =
        @row
        |> List.replace_at(7, kind)
        |> List.replace_at(11, pr_number)
        |> List.replace_at(12, [%{"name" => "docs", "status" => "skipped"}])

      assert {:ok, %{checkpoint_kind: decoded, test_results: [%{status: :skipped}]}} =
               Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [row], num_rows: 1}} end, @claim)

      assert Atom.to_string(decoded) == kind
    end
  end

  test "query errors, unexpected cardinality, and incompatible rows fail closed" do
    assert {:error, :offline} = Store.latest(fn _sql, _params -> {:error, :offline} end, @claim)
    assert {:error, :offline} = Store.append(fn _sql, _params -> {:error, :offline} end, @claim, @attrs)

    assert {:error, {:unexpected_append_result, 0}} =
             Store.append(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [], num_rows: 0}} end, @claim, @attrs)

    assert {:error, {:unexpected_latest_result, 2}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [@row, @row], num_rows: 2}} end, @claim)

    incompatible = List.replace_at(@row, 0, 2)

    assert {:error, {:incompatible_receipt, :schema_version}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [incompatible], num_rows: 1}} end, @claim)

    invalid_kind = List.replace_at(@row, 7, "tests")

    assert {:error, {:incompatible_receipt, :checkpoint_kind}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [invalid_kind], num_rows: 1}} end, @claim)

    invalid_tests = List.replace_at(@row, 12, [%{"name" => "make all", "status" => "failed"}])

    assert {:error, {:incompatible_receipt, :test_results}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [invalid_tests], num_rows: 1}} end, @claim)

    non_list_tests = List.replace_at(@row, 12, %{"name" => "make all", "status" => "passed"})

    assert {:error, {:incompatible_receipt, :test_results}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [non_list_tests], num_rows: 1}} end, @claim)

    assert {:error, {:incompatible_receipt, :receipt_shape}} =
             Store.latest(fn _sql, _params -> {:ok, %Postgrex.Result{rows: [[1, 2]], num_rows: 1}} end, @claim)
  end
end
