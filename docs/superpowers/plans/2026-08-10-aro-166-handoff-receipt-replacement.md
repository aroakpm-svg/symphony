# ARO-166 Handoff Receipt Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a clean, append-only `HandoffReceiptV1` contract that records only remotely verifiable Symphony checkpoints and returns a pure, fail-closed resume decision after fresh native evidence is supplied.

**Architecture:** `SymphonyElixir.HandoffReceipt` is the single domain boundary for the exact V1 value shape, validation, and deterministic `resume/2`; `SymphonyElixir.HandoffReceipt.Store` is the single PostgreSQL boundary for append/latest SQL and row decoding. A scoped staging migration enforces active-claim fencing, test-to-head binding, DB-derived ARO-165 effect snapshots, append-only storage, and function-only runtime access. ARO-167—not this plan—collects Git, GitHub, Linear, claim, and effect-ledger observations and wires the contract into runtime execution.

**Tech Stack:** Elixir 1.19, ExUnit, Postgrex 0.21, PostgreSQL 17, SQL migrations, Bash/psql disposable integration harness, existing `make -C elixir all` gate.

## Global Constraints

- Work only on `codex/aro-166-replacement`, created from canonical `aroakpm-svg/symphony:main@eba99b7c28349a313df60e3493513d33dddc89f2`; re-fetch and fail closed on dependency drift before implementation and before publishing.
- PR #19 and PR #22 remain frozen evidence. Do not patch, merge, resolve, comment on, or close either PR while executing this plan.
- Create only `HandoffReceipt`, `HandoffReceipt.Store`, the ARO-166 forward/down migrations, three focused ExUnit test files, and `elixir/docs/handoff_receipts.md`; modify only `.github/scripts/test-cross-machine-claims.sh` beyond those files. The approved spec and this plan remain decision records.
- Do not modify AgentRunner, Orchestrator, Codex AppServer/DynamicTool, Workspace, GitHubReviewClient, ClaimService, EffectLedger, ARO-164/165 migrations, GitHub workflows/rules, branch protection, production, deployments, or secrets.
- V1 checkpoint kinds are exactly `:pushed`, `:pull_request`, and `:reviewed`; do not restore `preflight`, `branch`, `implementation`, `tests`, `commit`, phases, completed/pending step lists, local paths, worktree fingerprints, prompts, or arbitrary metadata.
- `HandoffReceipt` is a hint only. It cannot authorize comment, push, PR creation/update, review request, Resolve, merge, deployment, Linear mutation, or any other side effect.
- `head_sha` and `tested_head_sha` are distinct evidence fields and must be equal for every persisted checkpoint.
- ARO-167 owns runtime/native observation collection and combined migration lifecycle; ARO-143 owns three-machine live smoke. Do not simulate either responsibility inside ARO-166.
- Use TDD for every task: add the focused failing test, prove the intended failure, add the smallest implementation, rerun the focused test, review the task diff, and commit.
- Do not add dependencies. Keep every public `def` adjacent to an exact `@spec` and keep Store SQL out of the domain module.

---

## Source-of-truth alignment already completed

- Written spec: `docs/superpowers/specs/2026-08-10-aro-166-handoff-receipt-replacement-design.md`, status `Approved after independent first-principles review`.
- Linear ARO-166: replacement contract, frozen PR #19/#22 status, fork publishing exception, ARO-167 boundary, and `:observation_incompatible` are synchronized; state remains `In Review`, assignee remains `PM AROAK`.
- Design 1–4 plans: PR #19 is historical evidence only; all four wait for the approved ARO-166 replacement. Design 2 consumes `HandoffReceipt.latest/2` as a hint and owns effect-status reads through its own ledger integration.
- Implementation order after this PR is unchanged: Design 2 → Design 3 → Design 4 → Design 1. This plan does not implement those designs.

## Locked file map

| File | Responsibility |
| --- | --- |
| `elixir/lib/symphony_elixir/handoff_receipt.ex` | Exact V1 types, structural/invariant validation, pure resume decision, thin append/latest delegates |
| `elixir/lib/symphony_elixir/handoff_receipt/store.ex` | PostgreSQL function calls, parameter encoding, result cardinality, row decoding |
| `elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql` | Append-only staging table, append/latest functions, claim fencing, grants, contract row |
| `elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql` | Remove only ARO-166 objects and contract row |
| `elixir/test/symphony_elixir/handoff_receipt_test.exs` | Exact domain shape, invariants, stable fail-closed reasons, three resume transitions |
| `elixir/test/symphony_elixir/handoff_receipt_store_test.exs` | SQL/parameter mapping, JSON encoding, result cardinality, V1 row decoding |
| `elixir/test/symphony_elixir/handoff_receipt_migration_test.exs` | Static staging-only, fencing, grants, effect derivation, rollback contract |
| `.github/scripts/test-cross-machine-claims.sh` | Disposable PostgreSQL proof for active/stale append, latest ordering, effects, privileges, rollback isolation |
| `elixir/docs/handoff_receipts.md` | Human-readable contract, authority boundary, ARO-167 integration handoff |

No other file is in scope. Stop and amend the written spec before touching an unlisted implementation file.

### Task 1: Pure V1 domain contract and resume decision

**Files:**
- Create: `elixir/lib/symphony_elixir/handoff_receipt.ex`
- Test: `elixir/test/symphony_elixir/handoff_receipt_test.exs`

**Interfaces:**
- Consumes: no runtime service; normalized maps only.
- Produces:
  - `HandoffReceipt.validate/1 :: :ok | {:error, atom()}`
  - `HandoffReceipt.resume/2 :: {:ok, :pull_request | :review | :complete} | {:safe_recheck, atom()}`
  - Public types `checkpoint_kind()`, `test_result()`, `receipt()`, and `observation()` with names and fields copied exactly from the approved spec.

- [ ] **Step 1: Add the canonical passing fixtures and failing shape/invariant tests**

Create `elixir/test/symphony_elixir/handoff_receipt_test.exs` with these exact base values and assertions:

```elixir
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
    assert :ok = HandoffReceipt.validate(%{receipt() | test_results: [%{name: "docs", status: :skipped}], effect_operation_ids: []})
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
      {Map.put(receipt(), :test_results, [%{name: "make all", status: :passed, detail: "extra"}]), :test_results},
      {Map.put(receipt(), :effect_operation_ids, ["ARO-166:git_push", "ARO-166:git_push"]), :effect_operation_ids},
      {Map.put(receipt(), :effect_operation_ids, [""]), :effect_operation_ids},
      {Map.put(receipt(), :effect_operation_ids, "ARO-166:git_push"), :effect_operation_ids}
    ]

    for {value, reason} <- invalid do
      assert {:error, ^reason} = HandoffReceipt.validate(value)
    end
  end
end
```

- [ ] **Step 2: Run the focused domain test and prove the module is missing**

Run:

```bash
cd elixir
mix test test/symphony_elixir/handoff_receipt_test.exs
```

Expected: FAIL because `SymphonyElixir.HandoffReceipt` and `validate/1` do not exist. A syntax or fixture failure is not the expected red state; correct the test before proceeding.

- [ ] **Step 3: Implement exact V1 validation without I/O**

Create `elixir/lib/symphony_elixir/handoff_receipt.ex`. Use exact top-level key sets (`MapSet`), `Ecto.UUID.cast/1`, lower-case `owner/name` validation, a 40-character lower-case SHA regex, exact test-result key sets, and unique non-empty effect IDs. Keep the validation order represented by this skeleton so tests and callers receive stable reasons:

```elixir
defmodule SymphonyElixir.HandoffReceipt do
  @moduledoc """
  Defines the remotely verifiable ARO-166 handoff receipt contract.

  A receipt is a hint. Fresh native evidence, claim fencing, and the effect
  ledger remain authoritative for every mutation.
  """

  @checkpoint_kinds ~w(pushed pull_request reviewed)a
  @receipt_keys MapSet.new(~w(
    receipt_schema_version issue_id repository claim_id generation
    checkpoint_sequence recorded_at checkpoint_kind branch head_sha
    tested_head_sha pr_number test_results effect_operation_ids
  )a)
  @observation_keys MapSet.new(~w(
    issue_id repository branch remote_head_sha pr_number pr_head_sha git_ready?
    linear_current? active_claim? exact_head_review_passed? effect_statuses
  )a)
  @sha_pattern ~r/^[0-9a-f]{40}$/
  @repository_pattern ~r/^[a-z0-9_.-]+\/[a-z0-9_.-]+$/

  @type checkpoint_kind :: :pushed | :pull_request | :reviewed
  @type test_result :: %{name: String.t(), status: :passed | :skipped}
  @type effect_status :: :succeeded | :pending | :failed_no_effect | :unknown
  @type receipt :: %{
          receipt_schema_version: 1,
          issue_id: String.t(),
          repository: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          checkpoint_sequence: pos_integer(),
          recorded_at: DateTime.t(),
          checkpoint_kind: checkpoint_kind(),
          branch: String.t(),
          head_sha: String.t(),
          tested_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          test_results: [test_result()],
          effect_operation_ids: [String.t()]
        }
  @type observation :: %{
          issue_id: String.t(),
          repository: String.t(),
          branch: String.t(),
          remote_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          pr_head_sha: String.t() | nil,
          git_ready?: boolean(),
          linear_current?: boolean(),
          active_claim?: boolean(),
          exact_head_review_passed?: boolean(),
          effect_statuses: %{optional(String.t()) => effect_status()}
        }

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(receipt) when is_map(receipt) do
    with :ok <- exact_keys(receipt, @receipt_keys, :receipt_shape),
         :ok <- exact_value(receipt.receipt_schema_version, 1, :schema_version),
         :ok <- non_empty(receipt.issue_id, :issue_id),
         :ok <- repository(receipt.repository),
         :ok <- uuid(receipt.claim_id, :claim_id),
         :ok <- positive(receipt.generation, :generation),
         :ok <- positive(receipt.checkpoint_sequence, :checkpoint_sequence),
         :ok <- recorded_at(receipt.recorded_at),
         :ok <- checkpoint_kind(receipt.checkpoint_kind),
         :ok <- non_empty(receipt.branch, :branch),
         :ok <- sha(receipt.head_sha, :head_sha),
         :ok <- tested_sha(receipt.tested_head_sha, receipt.head_sha),
         :ok <- pr_number(receipt.checkpoint_kind, receipt.pr_number),
         :ok <- test_results(receipt.test_results),
         :ok <- effect_operation_ids(receipt.effect_operation_ids) do
      :ok
    end
  end

  def validate(_receipt), do: {:error, :receipt_shape}

end
```

Implement the private validators with these exact rules:

```elixir
defp exact_keys(map, expected, reason),
  do: if(MapSet.new(Map.keys(map)) == expected, do: :ok, else: {:error, reason})

defp exact_value(value, value, _reason), do: :ok
defp exact_value(_actual, _expected, reason), do: {:error, reason}

defp non_empty(value, reason) when is_binary(value) do
  if String.trim(value) == "", do: {:error, reason}, else: :ok
end

defp non_empty(_value, reason), do: {:error, reason}

defp positive(value, _reason) when is_integer(value) and value > 0, do: :ok
defp positive(_value, reason), do: {:error, reason}

defp uuid(value, _reason) when is_binary(value) do
  case Ecto.UUID.cast(value) do
    {:ok, _uuid} -> :ok
    :error -> {:error, :claim_id}
  end
end

defp uuid(_value, reason), do: {:error, reason}
defp recorded_at(%DateTime{}), do: :ok
defp recorded_at(_value), do: {:error, :recorded_at}
defp checkpoint_kind(kind) when kind in @checkpoint_kinds, do: :ok
defp checkpoint_kind(_kind), do: {:error, :checkpoint_kind}

defp repository(value) when is_binary(value) do
  if Regex.match?(@repository_pattern, value), do: :ok, else: {:error, :repository}
end

defp repository(_value), do: {:error, :repository}
defp sha(value, reason) when is_binary(value) do
  if Regex.match?(@sha_pattern, value), do: :ok, else: {:error, reason}
end

defp sha(_value, reason), do: {:error, reason}
defp tested_sha(value, head_sha) when value == head_sha, do: sha(value, :tested_head_sha)
defp tested_sha(_value, _head_sha), do: {:error, :tested_head_sha}
defp pr_number(:pushed, nil), do: :ok
defp pr_number(kind, value) when kind in [:pull_request, :reviewed] and is_integer(value) and value > 0, do: :ok
defp pr_number(_kind, _value), do: {:error, :pr_number}

defp test_results(results) when is_list(results) and results != [] do
  if Enum.all?(results, &valid_test_result?/1), do: :ok, else: {:error, :test_results}
end

defp test_results(_results), do: {:error, :test_results}

defp valid_test_result?(result) when is_map(result) do
  MapSet.new(Map.keys(result)) == MapSet.new([:name, :status]) and
    is_binary(result.name) and String.trim(result.name) != "" and
    result.status in [:passed, :skipped]
end

defp valid_test_result?(_result), do: false

defp effect_operation_ids(ids) when is_list(ids) do
  valid = Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != ""))
  if valid and length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :effect_operation_ids}
end

defp effect_operation_ids(_ids), do: {:error, :effect_operation_ids}
```

For `test_results/1`, require a non-empty list whose every item has exactly the keys `:name` and `:status`, a non-empty string name, and a status in `[:passed, :skipped]`. For `effect_operation_ids/1`, require a list of unique non-empty strings; the empty list is valid because a checkpoint can precede the first side effect. Do not require a specific test name or effect operation ID in ARO-166.

- [ ] **Step 4: Add the failing resume decision matrix**

Append these cases to `handoff_receipt_test.exs`:

```elixir
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
  assert {:safe_recheck, :native_state_advanced} = HandoffReceipt.resume(receipt(:pull_request), review_exists)
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
```

- [ ] **Step 5: Run the resume tests and prove `resume/2` is missing**

Run:

```bash
cd elixir
mix test test/symphony_elixir/handoff_receipt_test.exs
```

Expected: validation tests PASS; resume tests FAIL with `undefined function resume/2`.

- [ ] **Step 6: Implement pure fail-closed resume logic**

Add `resume/2` with this exact ordering: receipt shape, observation shape/types, identity, active claim, Linear freshness, Git readiness, remote head, PR binding for PR/reviewed receipts, exact-head review for reviewed receipts, exact effect key set/all-succeeded, native-state advancement, then the three next-action results.

```elixir
@spec resume(receipt() | nil, observation()) ::
        {:ok, :pull_request | :review | :complete} | {:safe_recheck, atom()}
def resume(nil, _observation), do: {:safe_recheck, :receipt_missing}

def resume(receipt, observation) do
  with :ok <- compatible_receipt(receipt),
       :ok <- compatible_observation(observation),
       :ok <- matching_identity(receipt, observation),
       :ok <- required_flag(observation.active_claim?, :claim_inactive),
       :ok <- required_flag(observation.linear_current?, :linear_changed),
       :ok <- required_flag(observation.git_ready?, :git_unready),
       :ok <- equal(observation.remote_head_sha, receipt.head_sha, :remote_head_changed),
       :ok <- matching_pull_request(receipt, observation),
       :ok <- matching_review(receipt, observation),
       :ok <- settled_effects(receipt, observation),
       :ok <- native_state_not_advanced(receipt, observation) do
    next_action(receipt.checkpoint_kind)
  else
    {:error, reason} -> {:safe_recheck, reason}
  end
end

defp compatible_receipt(receipt) do
  case validate(receipt) do
    :ok -> :ok
    {:error, _reason} -> {:error, :receipt_incompatible}
  end
end

defp compatible_observation(observation) when is_map(observation) do
  result =
    with :ok <- exact_keys(observation, @observation_keys, :observation_incompatible),
         :ok <- non_empty(observation.issue_id, :issue_id),
         :ok <- repository(observation.repository),
         :ok <- non_empty(observation.branch, :branch),
         :ok <- sha(observation.remote_head_sha, :remote_head_sha),
         :ok <- optional_positive(observation.pr_number),
         :ok <- optional_sha(observation.pr_head_sha),
         :ok <- booleans(observation),
         :ok <- effect_statuses(observation.effect_statuses) do
      :ok
    end

  case result do
    :ok -> :ok
    {:error, _reason} -> {:error, :observation_incompatible}
  end
end

defp compatible_observation(_observation), do: {:error, :observation_incompatible}

defp optional_positive(nil), do: :ok
defp optional_positive(value) when is_integer(value) and value > 0, do: :ok
defp optional_positive(_value), do: {:error, :pr_number}

defp optional_sha(nil), do: :ok
defp optional_sha(value), do: sha(value, :pr_head_sha)

defp booleans(observation) do
  values = [
    observation.git_ready?, observation.linear_current?, observation.active_claim?,
    observation.exact_head_review_passed?
  ]

  if Enum.all?(values, &is_boolean/1), do: :ok, else: {:error, :boolean_flag}
end

defp effect_statuses(statuses) when is_map(statuses) do
  valid =
    Enum.all?(statuses, fn {operation_id, status} ->
      is_binary(operation_id) and String.trim(operation_id) != "" and
        status in [:succeeded, :pending, :failed_no_effect, :unknown]
    end)

  if valid, do: :ok, else: {:error, :effect_statuses}
end

defp effect_statuses(_statuses), do: {:error, :effect_statuses}

defp matching_identity(receipt, observation) do
  stored = {receipt.issue_id, receipt.repository, receipt.branch}
  native = {observation.issue_id, observation.repository, observation.branch}
  if stored == native, do: :ok, else: {:error, :identity_changed}
end

defp required_flag(true, _reason), do: :ok
defp required_flag(false, reason), do: {:error, reason}

defp equal(value, value, _reason), do: :ok
defp equal(_actual, _expected, reason), do: {:error, reason}

defp matching_pull_request(%{checkpoint_kind: :pushed}, _observation), do: :ok

defp matching_pull_request(receipt, observation) do
  if observation.pr_number == receipt.pr_number and observation.pr_head_sha == receipt.head_sha,
    do: :ok,
    else: {:error, :pull_request_changed}
end

defp matching_review(%{checkpoint_kind: :reviewed}, %{exact_head_review_passed?: true}), do: :ok
defp matching_review(%{checkpoint_kind: :reviewed}, _observation), do: {:error, :review_stale}
defp matching_review(_receipt, _observation), do: :ok

defp settled_effects(receipt, observation) do
  expected = MapSet.new(receipt.effect_operation_ids)
  observed = MapSet.new(Map.keys(observation.effect_statuses))

  if expected == observed and Enum.all?(observation.effect_statuses, fn {_id, status} -> status == :succeeded end),
    do: :ok,
    else: {:error, :effect_unsettled}
end

defp native_state_not_advanced(%{checkpoint_kind: :pushed}, observation) do
  if is_nil(observation.pr_number) and is_nil(observation.pr_head_sha) and
       not observation.exact_head_review_passed?,
    do: :ok,
    else: {:error, :native_state_advanced}
end

defp native_state_not_advanced(%{checkpoint_kind: :pull_request}, observation) do
  if observation.exact_head_review_passed?,
    do: {:error, :native_state_advanced},
    else: :ok
end

defp native_state_not_advanced(%{checkpoint_kind: :reviewed}, _observation), do: :ok

defp next_action(:pushed), do: {:ok, :pull_request}
defp next_action(:pull_request), do: {:ok, :review}
defp next_action(:reviewed), do: {:ok, :complete}
```

`compatible_observation/1` must also validate each field type, including a canonical repository, non-empty branch, lower-case SHA, optional positive PR number, optional lower-case PR head SHA, booleans, string effect keys, and statuses only in `[:succeeded, :pending, :failed_no_effect, :unknown]`. Any type failure maps to `{:error, :observation_incompatible}`. `settled_effects/2` compares `MapSet.new(Map.keys(effect_statuses))` to `MapSet.new(effect_operation_ids)` and then requires every value to equal `:succeeded`.

- [ ] **Step 7: Run, format, and review Task 1**

Run:

```bash
cd elixir
mix format lib/symphony_elixir/handoff_receipt.ex test/symphony_elixir/handoff_receipt_test.exs
mix test test/symphony_elixir/handoff_receipt_test.exs
mix specs.check
git diff --check
git diff -- lib/symphony_elixir/handoff_receipt.ex test/symphony_elixir/handoff_receipt_test.exs
```

Expected: all focused tests PASS; specs check PASS; diff contains no I/O, no runtime integration, and no second workflow state.

- [ ] **Step 8: Commit Task 1**

```bash
git add elixir/lib/symphony_elixir/handoff_receipt.ex \
  elixir/test/symphony_elixir/handoff_receipt_test.exs
git commit -m "feat(aro-166): define handoff receipt contract"
```

### Task 2: PostgreSQL store boundary and row decoder

**Files:**
- Create: `elixir/lib/symphony_elixir/handoff_receipt/store.ex`
- Test: `elixir/test/symphony_elixir/handoff_receipt_store_test.exs`
- Modify: `elixir/lib/symphony_elixir/handoff_receipt.ex` to add only the two thin Store delegates; do not change domain decisions.

**Interfaces:**
- Consumes: `HandoffReceipt.validate/1`, `HandoffReceipt.receipt()`, `HandoffReceipt.checkpoint_kind()`, and `HandoffReceipt.test_result()` from Task 1.
- Produces:
  - `Store.append/3 :: {:ok, HandoffReceipt.receipt()} | {:error, term()}`
  - `Store.latest/2 :: {:ok, HandoffReceipt.receipt() | nil} | {:error, term()}`
  - `Store.claim_context/0` and `Store.append_attrs/0` types exactly as approved.
  - `HandoffReceipt.append/3` and `HandoffReceipt.latest/2` thin delegates with the same return types.

- [ ] **Step 1: Add failing Store contract tests with a local query function**

Create `elixir/test/symphony_elixir/handoff_receipt_store_test.exs`. The first argument remains the production connection slot; tests pass a two-argument query function into that slot so Store SQL and decoding are testable without a global adapter or a second public API.

```elixir
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
    1, "ARO-166", "aroakpm-svg/symphony",
    "10000000-0000-0000-0000-000000000001", 2, 7,
    ~U[2026-08-10 02:00:00Z], "pushed", "codex/aro-166-replacement",
    @sha, @sha, nil, [%{"name" => "make all", "status" => "passed"}],
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
      "ARO-166", @claim.claim_id, 2, @claim.node_id, @claim.node_instance_id,
      "aroakpm-svg/symphony", "pushed", "codex/aro-166-replacement",
      @sha, @sha, nil, [%{"name" => "make all", "status" => "passed"}]
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
```

- [ ] **Step 2: Run the Store test and prove the module is missing**

Run:

```bash
cd elixir
mix test test/symphony_elixir/handoff_receipt_store_test.exs
```

Expected: FAIL because `HandoffReceipt.Store` does not exist.

- [ ] **Step 3: Implement the Store with only append/latest public operations**

Create `elixir/lib/symphony_elixir/handoff_receipt/store.ex`. Keep the query seam private and local; do not add application environment, a global mock, or public `append_with`/`latest_with` functions.

```elixir
defmodule SymphonyElixir.HandoffReceipt.Store do
  @moduledoc """
  Persists and reads ARO-166 receipts through function-only PostgreSQL access.
  """

  alias SymphonyElixir.HandoffReceipt

  @append_sql """
  select receipt_schema_version, issue_id, repository, claim_id::text,
         generation, checkpoint_sequence, recorded_at, checkpoint_kind,
         branch, head_sha, tested_head_sha, pr_number, test_results,
         effect_operation_ids
  from symphony_staging.append_handoff_receipt(
    $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid,
    $6, $7, $8, $9, $10, $11, $12::jsonb
  )
  """

  @latest_sql """
  select receipt_schema_version, issue_id, repository, claim_id::text,
         generation, checkpoint_sequence, recorded_at, checkpoint_kind,
         branch, head_sha, tested_head_sha, pr_number, test_results,
         effect_operation_ids
  from symphony_staging.latest_handoff_receipt(
    $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid
  )
  """

  @type claim_context :: %{
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          node_id: String.t(),
          node_instance_id: String.t()
        }
  @type append_attrs :: %{
          repository: String.t(),
          checkpoint_kind: HandoffReceipt.checkpoint_kind(),
          branch: String.t(),
          head_sha: String.t(),
          tested_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          test_results: [HandoffReceipt.test_result()]
        }

  @spec append(Postgrex.conn(), claim_context(), append_attrs()) ::
          {:ok, HandoffReceipt.receipt()} | {:error, term()}
  def append(connection, claim, attrs) do
    params = [
      claim.issue_id, claim.claim_id, claim.generation, claim.node_id,
      claim.node_instance_id, attrs.repository, Atom.to_string(attrs.checkpoint_kind),
      attrs.branch, attrs.head_sha, attrs.tested_head_sha, attrs.pr_number,
      encode_test_results(attrs.test_results)
    ]

    connection
    |> run_query(@append_sql, params)
    |> one_receipt()
  end

  @spec latest(Postgrex.conn(), claim_context()) ::
          {:ok, HandoffReceipt.receipt() | nil} | {:error, term()}
  def latest(connection, claim) do
    params = [claim.issue_id, claim.claim_id, claim.generation, claim.node_id, claim.node_instance_id]

    connection
    |> run_query(@latest_sql, params)
    |> optional_receipt()
  end

  defp run_query(connection, sql, params) do
    query = if is_function(connection, 2), do: connection, else: &Postgrex.query(connection, &1, &2)
    query.(sql, params)
  end

  defp one_receipt({:ok, %Postgrex.Result{rows: [row], num_rows: 1}}), do: decode_row(row)

  defp one_receipt({:ok, %Postgrex.Result{num_rows: count}}),
    do: {:error, {:unexpected_append_result, count}}

  defp one_receipt({:error, reason}), do: {:error, reason}

  defp optional_receipt({:ok, %Postgrex.Result{rows: [], num_rows: 0}}), do: {:ok, nil}
  defp optional_receipt({:ok, %Postgrex.Result{rows: [row], num_rows: 1}}), do: decode_row(row)

  defp optional_receipt({:ok, %Postgrex.Result{num_rows: count}}),
    do: {:error, {:unexpected_latest_result, count}}

  defp optional_receipt({:error, reason}), do: {:error, reason}

  defp decode_row([
         version, issue_id, repository, claim_id, generation, sequence,
         recorded_at, kind, branch, head_sha, tested_head_sha, pr_number,
         test_results, effect_operation_ids
       ]) do
    with {:ok, checkpoint_kind} <- decode_kind(kind),
         {:ok, decoded_tests} <- decode_test_results(test_results) do
      receipt = %{
        receipt_schema_version: version,
        issue_id: issue_id,
        repository: repository,
        claim_id: claim_id,
        generation: generation,
        checkpoint_sequence: sequence,
        recorded_at: recorded_at,
        checkpoint_kind: checkpoint_kind,
        branch: branch,
        head_sha: head_sha,
        tested_head_sha: tested_head_sha,
        pr_number: pr_number,
        test_results: decoded_tests,
        effect_operation_ids: effect_operation_ids
      }

      case HandoffReceipt.validate(receipt) do
        :ok -> {:ok, receipt}
        {:error, reason} -> {:error, {:incompatible_receipt, reason}}
      end
    else
      {:error, reason} -> {:error, {:incompatible_receipt, reason}}
    end
  end

  defp decode_row(_row), do: {:error, {:incompatible_receipt, :receipt_shape}}

  defp decode_kind("pushed"), do: {:ok, :pushed}
  defp decode_kind("pull_request"), do: {:ok, :pull_request}
  defp decode_kind("reviewed"), do: {:ok, :reviewed}
  defp decode_kind(_kind), do: {:error, :checkpoint_kind}

  defp encode_test_results(results) do
    Enum.map(results, fn %{name: name, status: status} ->
      %{"name" => name, "status" => Atom.to_string(status)}
    end)
  end

  defp decode_test_results(results) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      %{"name" => name, "status" => status} = item, {:ok, decoded}
      when map_size(item) == 2 and status in ["passed", "skipped"] ->
        {:cont, {:ok, [%{name: name, status: String.to_existing_atom(status)} | decoded]}}

      _item, _decoded ->
        {:halt, {:error, :test_results}}
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end)
  end

  defp decode_test_results(_results), do: {:error, :test_results}
end
```

After Store compiles, add only this alias and these delegates to `HandoffReceipt`:

```elixir
alias SymphonyElixir.HandoffReceipt.Store

@spec append(Postgrex.conn(), Store.claim_context(), Store.append_attrs()) ::
        {:ok, receipt()} | {:error, term()}
def append(connection, claim, attrs), do: Store.append(connection, claim, attrs)

@spec latest(Postgrex.conn(), Store.claim_context()) ::
        {:ok, receipt() | nil} | {:error, term()}
def latest(connection, claim), do: Store.latest(connection, claim)
```

Implement `one_receipt/2` and `optional_receipt/1` with these exact cardinalities:

- append: exactly one row is success; every other successful result is `{:error, {:unexpected_append_result, num_rows}}`;
- latest: zero rows is `{:ok, nil}`, exactly one row is decoded, every other successful result is `{:error, {:unexpected_latest_result, num_rows}}`;
- Postgrex errors pass through unchanged;
- a row must have exactly the 14 selected columns;
- checkpoint kind strings decode only to the three atoms;
- test result maps must contain string keys `name` and `status`, with statuses decoding only to `:passed` or `:skipped`;
- the decoded map must pass `HandoffReceipt.validate/1`; otherwise return `{:error, {:incompatible_receipt, reason}}`.

- [ ] **Step 4: Run, format, and review Task 2**

Run:

```bash
cd elixir
mix format lib/symphony_elixir/handoff_receipt.ex \
  lib/symphony_elixir/handoff_receipt/store.ex \
  test/symphony_elixir/handoff_receipt_store_test.exs
mix test test/symphony_elixir/handoff_receipt_test.exs \
  test/symphony_elixir/handoff_receipt_store_test.exs
mix specs.check
git diff --check
git diff -- lib/symphony_elixir/handoff_receipt.ex \
  lib/symphony_elixir/handoff_receipt/store.ex \
  test/symphony_elixir/handoff_receipt_store_test.exs
```

Expected: focused tests PASS; Store has no runtime integration, no global adapter, no second persistence path, and no public operation beyond `append/3` and `latest/2`.

- [ ] **Step 5: Commit Task 2**

```bash
git add elixir/lib/symphony_elixir/handoff_receipt.ex \
  elixir/lib/symphony_elixir/handoff_receipt/store.ex \
  elixir/test/symphony_elixir/handoff_receipt_store_test.exs
git commit -m "feat(aro-166): add handoff receipt store"
```

### Task 3: Scoped staging migration and static contract tests

**Files:**
- Create: `elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql`
- Create: `elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql`
- Test: `elixir/test/symphony_elixir/handoff_receipt_migration_test.exs`

**Interfaces:**
- Consumes: existing `symphony_staging.issue_claims`, `nodes`, `node_login_principals`, `active_node_instances`, `effect_operations`, and `contract_versions` from ARO-163/164/165.
- Produces:
  - `symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb)`
  - `symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid)`
  - contract row `handoff-receipts`, version `1`, migration name `20260806000000_aro_166_handoff_receipts`.

- [ ] **Step 1: Add failing migration contract tests**

Create `elixir/test/symphony_elixir/handoff_receipt_migration_test.exs`:

```elixir
defmodule SymphonyElixir.HandoffReceiptMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql",
              __DIR__
            )

  test "migration is staging-only and persists the exact V1 contract" do
    sql = File.read!(@migration)

    refute sql =~ "symphony_production."
    assert sql =~ "create table symphony_staging.handoff_receipts"
    assert sql =~ "checkpoint_kind in ('pushed', 'pull_request', 'reviewed')"
    assert sql =~ "tested_head_sha = head_sha"
    assert sql =~ "jsonb_array_length(test_results) > 0"
    assert sql =~ "create or replace function symphony_staging.append_handoff_receipt("
    assert sql =~ "create or replace function symphony_staging.latest_handoff_receipt("
    refute sql =~ "current_phase"
    refute sql =~ "completed_step_ids"
    refute sql =~ "pending_step_ids"
  end

  test "append fences the exact active owner and derives the complete effect snapshot" do
    sql = File.read!(@migration)

    assert sql =~ "claims.claim_id = requested_claim_id"
    assert sql =~ "claims.generation = requested_generation"
    assert sql =~ "claims.node_id = requested_node_id"
    assert sql =~ "claims.node_instance_id = requested_node_instance_id"
    assert sql =~ "claims.lease_expires_at > clock_timestamp()"
    assert sql =~ "for update of claims"
    assert sql =~ "from symphony_staging.effect_operations operations"
    assert sql =~ "operations.issue_id = requested_issue_id"
    assert sql =~ "array_agg(operations.operation_id order by operations.operation_id)"
  end

  test "runtime access is function-only and follows enrolled node roles" do
    sql = File.read!(@migration)

    assert sql =~ "revoke all on table symphony_staging.handoff_receipts"
    assert sql =~ "grant execute on function"
    assert sql =~ "to symphony_staging_runtime"
    assert sql =~ "grant_handoff_receipt_api_to_node_login"
    assert sql =~ "select login_role from symphony_staging.node_login_principals"
    assert sql =~ "set search_path = pg_catalog, pg_temp"
  end

  test "latest requires a fresh same-issue claim and returns newest generation then sequence" do
    sql = File.read!(@migration)

    assert length(Regex.scan(~r/claims.issue_id = requested_issue_id/, sql)) >= 2
    assert sql =~ "order by receipts.generation desc, receipts.checkpoint_sequence desc"
    assert sql =~ "limit 1"
  end

  test "rollback removes only ARO-166 objects" do
    rollback = File.read!(@rollback)

    assert rollback =~ "where contract_name = 'handoff-receipts'"
    assert rollback =~ "drop table if exists symphony_staging.handoff_receipts"
    refute rollback =~ "effect_operations"
    refute rollback =~ "issue_claims"
    refute rollback =~ "drop schema"
    refute rollback =~ "symphony_production"
  end
end
```

- [ ] **Step 2: Run the migration test and prove both files are missing**

Run:

```bash
cd elixir
mix test test/symphony_elixir/handoff_receipt_migration_test.exs
```

Expected: FAIL with `File.Error` for the forward migration.

- [ ] **Step 3: Create the append-only table and exact checks**

Start the forward migration with one transaction and this exact table shape:

```sql
begin;

create table symphony_staging.handoff_receipts (
  checkpoint_sequence bigint generated always as identity primary key,
  receipt_schema_version integer not null check (receipt_schema_version = 1),
  issue_id text not null check (btrim(issue_id) <> ''),
  repository text not null
    check (repository = lower(repository) and repository ~ '^[a-z0-9_.-]+/[a-z0-9_.-]+$'),
  claim_id uuid not null,
  generation bigint not null check (generation > 0),
  recorded_at timestamptz not null default clock_timestamp(),
  checkpoint_kind text not null check (checkpoint_kind in ('pushed', 'pull_request', 'reviewed')),
  branch text not null check (btrim(branch) <> ''),
  head_sha text not null check (head_sha ~ '^[0-9a-f]{40}$'),
  tested_head_sha text not null check (tested_head_sha ~ '^[0-9a-f]{40}$'),
  pr_number bigint,
  test_results jsonb not null,
  effect_operation_ids text[] not null default '{}',
  constraint handoff_receipt_tested_head_matches check (tested_head_sha = head_sha),
  constraint handoff_receipt_pr_matches_kind check (
    (checkpoint_kind = 'pushed' and pr_number is null) or
    (checkpoint_kind in ('pull_request', 'reviewed') and pr_number > 0)
  ),
  constraint handoff_receipt_test_results_array check (
    case
      when jsonb_typeof(test_results) = 'array'
        then jsonb_array_length(test_results) > 0
      else false
    end
  )
);

alter table symphony_staging.handoff_receipts enable row level security;

revoke all on table symphony_staging.handoff_receipts
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
```

Do not add update/delete functions, retention behavior, a status column, a payload hash, a foreign key that can delete historical receipts, or a second sequence source.

- [ ] **Step 4: Add append with claim fencing, JSON validation, and DB-derived effect IDs**

Create `append_handoff_receipt` with the 12-argument signature declared in Interfaces and `returns symphony_staging.handoff_receipts`. Its body must:

1. reject null/blank repository/branch/issue, invalid kind, invalid SHA, mismatched tested SHA, invalid conditional PR, or malformed tests with SQLSTATE `22023`;
2. validate every JSON array item has exactly keys `name` and `status`, a non-empty string name, and status `passed` or `skipped` with this predicate after the separate array check:

```sql
if exists (
  select 1
  from jsonb_array_elements(requested_test_results) item
  where jsonb_typeof(item) <> 'object'
     or not (item ? 'name' and item ? 'status')
     or item - 'name' - 'status' <> '{}'::jsonb
     or nullif(btrim(item ->> 'name'), '') is null
     or item ->> 'status' not in ('passed', 'skipped')
) then
  raise exception using errcode = '22023', message = 'test results must contain only passed or skipped named tests';
end if;
```
3. lock one matching active claim owned by `session_user`, exact generation/node/instance, active node, present active instance, unreleased/uncompleted lease, and `lease_expires_at > clock_timestamp()`; otherwise raise SQLSTATE `55000` with `handoff receipt requires a matching active claim generation`;
4. derive `effect_operation_ids` with this exact query and never accept IDs from the caller:

```sql
select coalesce(
  array_agg(operations.operation_id order by operations.operation_id),
  '{}'::text[]
)
into derived_effect_operation_ids
from symphony_staging.effect_operations operations
where operations.issue_id = requested_issue_id;
```

5. insert one row and `returning *` without updating any prior row.

Use `security definer` and `set search_path = pg_catalog, pg_temp`. Fully qualify every staging object.

- [ ] **Step 5: Add latest with a new active same-issue claim**

Create `latest_handoff_receipt` with the five-argument signature declared in Interfaces and `returns setof symphony_staging.handoff_receipts`. It must perform the same active-owner proof for the requested issue, then return at most one historical receipt:

```sql
return query
select receipts.*
from symphony_staging.handoff_receipts receipts
where receipts.issue_id = requested_issue_id
order by receipts.generation desc, receipts.checkpoint_sequence desc
limit 1;
```

The current claim may be a later generation than the returned receipt. It authorizes only the read of the same issue; it does not rewrite the historical receipt.

- [ ] **Step 6: Add function-only grants, future-login grant trigger, and contract row**

Follow the existing ARO-165 grant pattern, but grant only the two ARO-166 functions. The trigger function name is `symphony_staging.grant_handoff_receipt_api_to_node_login()`, and the trigger name is `grant_handoff_receipt_api_to_node_login`. Revoke the helper from all runtime/API/provisioner roles. Grant current enrolled login roles in a `DO` block that quotes identifiers with `format('%I', login_role)`.

Finish with:

```sql
insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'handoff-receipts', 1, '20260806000000_aro_166_handoff_receipts'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

commit;
```

- [ ] **Step 7: Add the scoped down migration**

Create `20260806000000_aro_166_handoff_receipts.down.sql` in this order:

```sql
begin;

delete from symphony_staging.contract_versions
where contract_name = 'handoff-receipts';

drop trigger if exists grant_handoff_receipt_api_to_node_login
  on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_handoff_receipt_api_to_node_login();
drop function if exists symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.append_handoff_receipt(
  text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb
);
drop table if exists symphony_staging.handoff_receipts;

commit;
```

- [ ] **Step 8: Run and review Task 3**

Run:

```bash
cd elixir
mix format test/symphony_elixir/handoff_receipt_migration_test.exs
mix test test/symphony_elixir/handoff_receipt_migration_test.exs
git diff --check
git diff -- priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql \
  priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql \
  test/symphony_elixir/handoff_receipt_migration_test.exs
```

Expected: static contract tests PASS; no production schema, ARO-164/165 rewrite, direct table privilege, update/delete API, compatibility layer, or runtime wiring appears.

- [ ] **Step 9: Commit Task 3**

```bash
git add elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql \
  elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql \
  elixir/test/symphony_elixir/handoff_receipt_migration_test.exs
git commit -m "feat(aro-166): persist fenced handoff receipts"
```

### Task 4: Disposable PostgreSQL proof and contract documentation

**Files:**
- Modify: `.github/scripts/test-cross-machine-claims.sh`
- Create: `elixir/docs/handoff_receipts.md`
- Test: `.github/scripts/test-cross-machine-claims.sh`

**Interfaces:**
- Consumes: ARO-164 claim functions, ARO-165 effect functions/table, and both ARO-166 migrations.
- Produces: disposable evidence that database enforcement matches the static contract; concise operator-facing boundary documentation.

- [ ] **Step 1: Extend the disposable harness with ARO-166 file variables**

Add only these variables beside the existing migration variables:

```bash
handoff_migration="$root_dir/elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql"
handoff_rollback="$root_dir/elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql"
```

Apply `handoff_migration` after `effect_migration`; do not add a workflow, service, secret, or database image.

- [ ] **Step 2: Add a dedicated issue and completed ledger operation**

Add `HANDOFF` to the existing routing-assignment seed. Insert the ARO-166 lifecycle after the existing `effect-stale` rejection and before the existing ROUTE-CHANGE claim assignment, when node C is free. Claim HANDOFF with node C, capture `handoff_receipt_claim_id` and `handoff_receipt_generation`, then create and finish `handoff-git-push` for issue `HANDOFF` through existing `begin_effect`/`finish_effect` SQL. Use the existing disposable UUID and password helpers; do not print credentials or the database URL.

- [ ] **Step 3: Prove active append, exact fields, DB-derived effects, and table isolation**

Append `pushed`, then `pull_request`, then `reviewed` through `append_handoff_receipt`. For each call, pass the exact head SHA `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`, matching tested SHA, and JSON `[ {"name":"make all","status":"passed"} ]`. Assert:

```bash
test "$pushed" = "1|pushed||{handoff-git-push}"
test "$pull_request" = "2|pull_request|23|{handoff-git-push}"
test "$reviewed" = "3|reviewed|23|{handoff-git-push}"
```

Build each variable with `psql -A -t` selecting `checkpoint_sequence || '|' || checkpoint_kind || '|' || coalesce(pr_number::text, '') || '|' || effect_operation_ids::text` from the function result. As `claim_node_c`, assert direct `insert`, `update`, and `delete` on `symphony_staging.handoff_receipts` each fail.

- [ ] **Step 4: Prove stale rejection and cross-generation latest ordering**

Release the active EFFECTS claim held by node B after all existing effect reconciliation assertions, then release the HANDOFF generation-1 claim and acquire HANDOFF generation 2 with node B. Assert node C cannot append with generation 1. As node B, call `latest_handoff_receipt` with the generation-2 claim and assert it returns the generation-1 `reviewed` receipt. Then append a generation-2 `pushed` receipt at a new exact SHA `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` and assert latest returns generation 2 with the larger sequence. Release HANDOFF generation 2 before the existing ROUTE-CHANGE claim so the added proof cannot consume capacity needed by pre-existing tests.

- [ ] **Step 5: Prove invalid tests/SHA/PR combinations fail**

Add this helper and invoke it with complete SQL for each rejected input:

```bash
expect_handoff_append_failure() {
  local label="$1" statement="$2"
  if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -d "$(node_url claim_node_b)" -c "$statement" >/dev/null 2>&1; then
    echo "$label unexpectedly accepted" >&2
    exit 1
  fi
}

expect_handoff_append_failure "empty handoff tests" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[]'::jsonb);"
expect_handoff_append_failure "failed handoff test" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[{\"name\":\"make all\",\"status\":\"failed\"}]'::jsonb);"
expect_handoff_append_failure "mismatched tested head" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('c',40),null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
expect_handoff_append_failure "pushed receipt with PR" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),23,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
expect_handoff_append_failure "reviewed receipt without PR" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','reviewed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
```

These calls prove the function rejects:

- empty `test_results`;
- status `failed`;
- mismatched `head_sha`/`tested_head_sha`;
- `pushed` with PR number;
- `reviewed` without PR number.

Each block must redirect expected PostgreSQL error output to `/dev/null`; never hide an unexpected success.

- [ ] **Step 6: Prove the down migration is ARO-166-only**

Apply `handoff_rollback` before the existing ARO-165 rollback. Assert:

```bash
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.handoff_receipts') is null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations') is not null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.issue_claims') is not null;")" = "t"
```

Then continue the existing ARO-165 rollback assertions unchanged. Change the final success line to `ARO-164/165/166 disposable PostgreSQL claim, effect, and handoff lifecycle passed without printing credentials`.

- [ ] **Step 7: Run the harness in a disposable PostgreSQL 17 environment**

Run the existing local equivalent only if PostgreSQL 17 and `psql` are available; otherwise rely on the unchanged `cross-machine-claims-postgres` workflow after publication and report local DB evidence as unavailable, not passed.

```bash
TEST_DATABASE_URL=postgresql://postgres@localhost:5432/postgres \
  bash .github/scripts/test-cross-machine-claims.sh
```

Expected: the final ARO-164/165/166 success line and no credential output. Do not connect to shared staging or production.

- [ ] **Step 8: Write the concise human-readable contract doc**

Create `elixir/docs/handoff_receipts.md` with exactly these sections:

1. `# Handoff receipts`
2. `## What a receipt is` — append-only, remotely verifiable hint; not authority or merge readiness.
3. `## V1 checkpoint sequence` — the three kinds and their candidate next actions.
4. `## Required fresh observation` — issue/repo/branch, active claim, Linear freshness, Git readiness, remote head, conditional PR/review, exact effect readback.
5. `## Storage boundary` — function-only staging access, DB-derived effects, no direct table writes, scoped rollback.
6. `## ARO-167 integration boundary` — runtime wiring and native reads are deliberately absent.
7. `## Failure behavior` — list all stable reasons, including `receipt_missing`, `receipt_incompatible`, `observation_incompatible`, `identity_changed`, `claim_inactive`, `linear_changed`, `git_unready`, `remote_head_changed`, `pull_request_changed`, `review_stale`, `native_state_advanced`, and `effect_unsettled`.

Do not include PR #19 APIs, local paths, execution prompts, phases, operator credentials, or an assertion that `:complete` allows merge.

- [ ] **Step 9: Run and review Task 4**

Run:

```bash
bash -n .github/scripts/test-cross-machine-claims.sh
git diff --check
git diff -- .github/scripts/test-cross-machine-claims.sh elixir/docs/handoff_receipts.md
```

Expected: Bash syntax PASS; docs state the authority boundary; shell changes only extend the existing disposable lifecycle.

- [ ] **Step 10: Commit Task 4**

```bash
git add .github/scripts/test-cross-machine-claims.sh elixir/docs/handoff_receipts.md
git commit -m "test(aro-166): verify handoff receipt lifecycle"
```

### Task 5: Whole-slice verification and replacement PR publication

**Files:**
- Review only: every file in the locked file map plus the approved spec and this plan.
- GitHub write only after all local gates pass: push the current branch and create one replacement PR into `aroakpm-svg/symphony:main`.

**Interfaces:**
- Consumes: the completed Tasks 1–4 and current upstream/fork permissions.
- Produces: one exact-head replacement PR with complete evidence; PR #19/#22 remain open and frozen until this replacement is actually merge-ready.

- [ ] **Step 1: Verify the exact diff manifest before broad tests**

Run:

```bash
git fetch origin main
git diff --name-only origin/main...HEAD | sort
git diff --check origin/main...HEAD
git status --short --branch
```

Expected implementation diff names are exactly:

```text
.github/scripts/test-cross-machine-claims.sh
docs/superpowers/plans/2026-08-10-aro-166-handoff-receipt-replacement.md
docs/superpowers/specs/2026-08-10-aro-166-handoff-receipt-replacement-design.md
elixir/docs/handoff_receipts.md
elixir/lib/symphony_elixir/handoff_receipt.ex
elixir/lib/symphony_elixir/handoff_receipt/store.ex
elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql
elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql
elixir/test/symphony_elixir/handoff_receipt_migration_test.exs
elixir/test/symphony_elixir/handoff_receipt_store_test.exs
elixir/test/symphony_elixir/handoff_receipt_test.exs
```

Any additional path is a hard stop. If `origin/main` has advanced, inspect the exact dependency diff; rebase only if it is clean and does not invalidate ARO-164/165 contracts or the approved spec. Never rebuild from PR #19/#22.

- [ ] **Step 2: Run focused tests and static checks**

Run:

```bash
cd elixir
mix format --check-formatted
mix test test/symphony_elixir/handoff_receipt_test.exs \
  test/symphony_elixir/handoff_receipt_store_test.exs \
  test/symphony_elixir/handoff_receipt_migration_test.exs
mix specs.check
mix credo --strict
```

Expected: all PASS with no warnings attributable to the slice.

- [ ] **Step 3: Run the full repository gate once on the final local head**

Run:

```bash
make -C elixir all
```

Expected: build, formatting, specs, Credo, 100% configured coverage, and Dialyzer all PASS. Fix only ARO-166-introduced failures; unrelated failures are reported with exact evidence and are not patched in this PR.

- [ ] **Step 4: Perform one independent whole-diff first-principles review**

Review:

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
rg -n "current_phase|completed_step_ids|pending_step_ids|worktree|auto.*merge|resolve.*thread|symphony_production" \
  elixir/lib/symphony_elixir/handoff_receipt.ex \
  elixir/lib/symphony_elixir/handoff_receipt/store.ex \
  elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql \
  elixir/docs/handoff_receipts.md
```

Acceptance decision:

- high cohesion: domain, Store, SQL, proof, and docs each own one responsibility;
- low coupling: ARO-166 reads only ARO-164/165 database contracts and exports only append/latest/resume;
- lightweight: three checkpoint kinds, one row type, two DB functions, no workflow/compatibility engine;
- modular: ARO-167 can supply observations and use the Store without changing the V1 domain.

Any failure of those four statements is a hard stop and requires a written-spec amendment before code changes.

- [ ] **Step 5: Commit any final formatting-only adjustment, then freeze the head**

If format produced no change, do not create an empty commit. If it produced an in-scope change:

```bash
git add elixir/lib/symphony_elixir/handoff_receipt.ex \
  elixir/lib/symphony_elixir/handoff_receipt/store.ex \
  elixir/test/symphony_elixir/handoff_receipt_test.exs \
  elixir/test/symphony_elixir/handoff_receipt_store_test.exs \
  elixir/test/symphony_elixir/handoff_receipt_migration_test.exs
git commit -m "style(aro-166): format replacement slice"
```

Record `git rev-parse HEAD`; every later review/check must bind to that exact SHA.

- [ ] **Step 6: Reverify publishing authority and push only to the authorized transport**

Use GitHub native metadata to verify:

- current actor identity;
- read access to `aroakpm-svg/symphony`;
- write access to `digitaltriumphs-tw/symphony` if upstream write remains false;
- upstream default branch is still `main`;
- the fork branch can target `aroakpm-svg/symphony:main`.

If those facts hold, push `codex/aro-166-replacement` to the authorized fork. Do not force-push. If actor, permissions, or target differ, stop before writing GitHub state.

- [ ] **Step 7: Open one replacement PR with the repository Scope Contract**

Use the exact PR body required by `elixir/AGENTS.md`, including:

- Scope Contract identifying ARO-166 only;
- explicit non-goals: no runtime wiring, no ARO-164/165 rewrite, no Design 1–4 behavior, no GitHub admin/deployment/production writes;
- validation commands and exact final SHA;
- disposable PostgreSQL result or honest unavailable state;
- statement that PR #19/#22 remain frozen until replacement merge-ready;
- no claim that implementation completion equals human merge approval.

Open from `digitaltriumphs-tw:codex/aro-166-replacement` to `aroakpm-svg/symphony:main` if upstream push is still unavailable.

- [ ] **Step 8: Request one exact-head Codex review and wait for terminal evidence**

Post `@codex review` once after the final pushed commit. Wait for an actual review bound to the exact current head; emoji reactions are not review evidence. Classify every current-head finding once:

- fix only an ARO-166-introduced correctness/safety defect required by this approved contract;
- defer an out-of-scope or pre-existing finding with evidence and do not patch-loop;
- reject an incorrect finding with exact current-base/current-head evidence and do not patch-loop.

Do not resolve threads automatically unless the finding was fixed in this PR and the current-head evidence proves it. A new commit invalidates the prior review and requires exactly one new exact-head request.

- [ ] **Step 9: Decide whether the replacement is actually merge-ready**

Merge-ready requires all of:

- required repository checks green on the latest head;
- latest-head Codex review says no major issues;
- no unresolved actionable current-head thread;
- exact diff manifest and ARO-166 acceptance evidence still valid;
- GitHub reports the PR mergeable;
- no production, deployment, secret, or admin-setting blocker.

Do not merge in this step. Only after these conditions are true may the separate authorized follow-up post one superseded comment on PR #19 and PR #22 and close them. Until then, both old PRs stay frozen and open.

## Plan self-review receipt

- Spec coverage: every approved field, invariant, stable fail-closed reason, ownership boundary, migration/grant rule, disposable DB acceptance case, publishing constraint, and PR #19/#22 freeze rule maps to a task above.
- Placeholder scan: no unresolved marker, unnamed validator, or undefined cross-task API remains.
- Type consistency: `checkpoint_kind`, receipt/observation keys, Store signatures, SQL function signatures, selected row order, migration filenames, contract name, and test status names are identical across Tasks 1–4.
- Scope check: this plan produces one testable ARO-166 contract slice. Runtime integration remains wholly in ARO-167; Design 1–4 remain downstream consumers.
