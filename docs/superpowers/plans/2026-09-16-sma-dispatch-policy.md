# Social Media Analysis Dispatch Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure, fail-closed dispatch authorization function and prove it with offline tests, without integrating it into the live orchestrator.

**Architecture:** `SymphonyElixir.DispatchPolicy.evaluate/5` accepts already-fetched maps plus an explicit clock. It validates scope, issue eligibility, claim ownership, blocker evidence, approval bindings, quota state, pause state, and model capability, then returns deterministic denial reasons or a short-lived receipt.

**Tech Stack:** Elixir 1.19.5 / OTP 28, ExUnit, Dialyzer, Credo.

**Spec:** [Immutable Social Media Analysis runner handoff](https://github.com/aroakpm-svg/Social-Media-Analysis/blob/a93b8b36f22b5ac2148b16bb9ca818e648104681/docs/superpowers/specs/2026-09-16-sma-runner-integration-handoff.md)

## Global Constraints

- Base: Symphony PR #49 commit `77e7dbf5e8e7f04b34b88bfba34c3d0bcb54e906`; do not merge or enable that runtime.
- `evaluate/5` is pure: no network, database, process, environment, filesystem, credential, Linear, or clock reads.
- Match Team, Project, state, and label by immutable IDs; match repository by exact slug. Never authorize by display name, issue key, or project slug.
- Return `{:allow, decision}` or `{:deny, reason_codes}`. Reasons are unique atoms in documented order. Missing or malformed input fails closed without raising.
- Blockers require complete, fresh evidence and an exact `%{state: "Done", accepted: true}` record for every blocker ID. Other states, unknown records, or missing acceptance deny.
- Evidence requires `status: :ok`, complete pagination, a non-future `DateTime` read time, positive TTL, and `now` no later than the deadline.
- Required human approval binds the exact issue revision, policy revision, and workflow SHA.
- In Progress requires an active exact-issue claim with positive generation; Todo does not.
- Time, turn, and failure quotas deny at or above their maximum. For the 24-hour unique-issue quota, an issue already present may continue while the distinct count is at the maximum; a previously unseen issue is denied when adding it would exceed the maximum. `pause_state` must equal `:active`. Model matching is exact.
- Allow receipts contain only `issue_id`, `policy_revision`, `workflow_sha`, `evidence_version`, and `evidence_valid_until`.
- Do not add the Social Media Analysis profile or modify orchestrator, Linear adapters, claims, runtime config, credentials, scheduled tasks, or external services.
- Existing `central-brain` and `project-management` behavior must remain unchanged.
- Every public `def` in `elixir/lib` has an adjacent `@spec`.

---

### Task 1: Pure Offline Dispatch Policy

**Files:**
- Create: `elixir/lib/symphony_elixir/dispatch_policy.ex`
- Create: `elixir/test/symphony_elixir/dispatch_policy_test.exs`
- Verify unchanged: `elixir/test/symphony_elixir/dispatch_candidate_test.exs`
- Verify unchanged: `elixir/test/symphony_elixir/project_profiles_test.exs`

**Interfaces:**
- Consumes: `issue`, `policy`, `run_state`, `evidence`, explicit `DateTime.t()` `now`.
- Produces: `evaluate/5 :: {:allow, decision()} | {:deny, [reason_code(), ...]}`.
- Reason order: `[:invalid_input, :wrong_team, :wrong_project, :wrong_repository, :missing_worker_label, :inactive_state, :unowned_in_progress, :evidence_unavailable, :blocker_not_accepted, :human_gate_pending, :policy_revision_mismatch, :quota_exhausted, :paused, :unsupported_model]`.

- [ ] **Step 1: Write the first failing allow test and literal fixtures**

Use async ExUnit. Fixture helpers may only `Map.merge/2` literal maps; they must not call production code. The complete baseline values are:

```elixir
@now ~U[2026-09-16 06:00:00Z]

issue = %{
  id: "issue-1",
  team_id: "e057ed6d-08c4-449d-becb-2c1fbc3fcabc",
  project_id: "6616d485-7a2d-42e4-bc34-b6510e08ff55",
  repository: "aroakpm-svg/Social-Media-Analysis",
  state_id: "todo-state",
  label_ids: ["sma-worker-label"],
  revision: "issue-revision-7",
  blocked_by: [%{id: "blocker-1"}]
}

policy = %{
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
}

run_state = %{
  claim: nil,
  approved_issue_revision: "issue-revision-7",
  approved_policy_revision: 3,
  approved_workflow_sha: "workflow-sha-3",
  accumulated_minutes: 4,
  turns: 2,
  failures: 0,
  issue_ids_24h: ["older-issue"],
  pause_state: :active
}

evidence = %{
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
}
```

Assert the full literal receipt, including `evidence_valid_until: ~U[2026-09-16 06:03:00Z]` and no additional keys.

- [ ] **Step 2: Run the allow test and observe RED**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dispatch_policy_test.exs --trace
```

Expected: compilation failure because `SymphonyElixir.DispatchPolicy` does not exist. Record the relevant failure before creating production code.

- [ ] **Step 3: Add failing denial-matrix tests**

Use literal expected reason lists. Cover each row independently:

| Mutation | Expected result |
|---|---|
| missing/other Team | `{:deny, [:wrong_team]}` |
| same-name other Project ID | `{:deny, [:wrong_project]}` |
| other repository | `{:deny, [:wrong_repository]}` |
| empty labels | `{:deny, [:missing_worker_label]}` |
| unapproved state ID | `{:deny, [:inactive_state]}` |
| In Progress and no claim | `{:deny, [:unowned_in_progress]}` |
| In Progress and exact `%{issue_id: "issue-1", generation: 2, active: true}` claim | allow |
| In Progress and wrong issue, non-positive generation, or inactive claim | `{:deny, [:unowned_in_progress]}` |
| blocker evidence state `"Canceled"`, `"Duplicate"`, `"Unknown"`, missing, or `accepted: false` | `{:deny, [:blocker_not_accepted]}` |
| no blockers and empty acceptance map | allow |
| evidence error, incomplete pagination, future read, expired TTL, missing model list, or non-DateTime read | `{:deny, [:evidence_unavailable]}` |
| required gate status pending | `{:deny, [:human_gate_pending]}` |
| issue, policy, or workflow approval binding differs | `{:deny, [:policy_revision_mismatch]}` |
| any quota counter equals its maximum | `{:deny, [:quota_exhausted]}` |
| duplicated 24-hour issue IDs below distinct-ID maximum | remains eligible |
| pause state paused or stopped | `{:deny, [:paused]}` |
| exact model absent from valid supported-model evidence | `{:deny, [:unsupported_model]}` |
| wrong Team + missing label + paused | `{:deny, [:wrong_team, :missing_worker_label, :paused]}` |
| any top-level input is not a map, or `now` is not a DateTime | `{:deny, [:invalid_input]}` |

Add one generic-policy regression loop using these exact project/repository pairs. Override both `issue.project_id`/`issue.repository` and `policy.scope`; assert allow for each:

```elixir
[
  {"d0acfb71-f68c-4a9f-8a1a-477265d3c3ec", "aroakpm-svg/aroak-central-brain"},
  {"708053e0-f42c-4e93-bec4-7abbb37e74af", "aroakpm-svg/aroak-project-management"}
]
```

- [ ] **Step 4: Implement the smallest pure module that satisfies the contract**

Define the public contract exactly:

```elixir
@type reason_code ::
        :invalid_input
        | :wrong_team
        | :wrong_project
        | :wrong_repository
        | :missing_worker_label
        | :inactive_state
        | :unowned_in_progress
        | :evidence_unavailable
        | :blocker_not_accepted
        | :human_gate_pending
        | :policy_revision_mismatch
        | :quota_exhausted
        | :paused
        | :unsupported_model

@type decision :: %{
        issue_id: String.t(),
        policy_revision: term(),
        workflow_sha: String.t(),
        evidence_version: term(),
        evidence_valid_until: DateTime.t()
      }

@spec evaluate(term(), term(), term(), term(), term()) ::
        {:allow, decision()} | {:deny, [reason_code(), ...]}
def evaluate(issue, policy, run_state, evidence, now)
```

Implementation rules:

1. Non-map top-level inputs or non-DateTime `now` return exactly `{:deny, [:invalid_input]}`.
2. Validate required nested policy structures and `human_gate` (`:required` or `:disabled`); invalid structure adds `:invalid_input` and must not raise. An allow path requires non-empty binary issue ID/revision/repository, non-empty policy workflow SHA/model, a present policy revision, lists of binary state/label IDs, and a well-formed scope map.
3. Compute direct issue/run-state reasons independently, then emit the documented order without duplicates.
4. Evidence is usable only when every evidence constraint passes. If unusable, add only `:evidence_unavailable` for evidence-dependent checks; do not also derive blocker/gate/binding/model reasons from it.
5. Use `DateTime.compare/2` and `DateTime.add/3`. Equality at the deadline is valid; later is expired.
6. For a required gate, non-approved status adds `:human_gate_pending`; approved evidence with a mismatched issue revision, policy revision, or workflow SHA adds `:policy_revision_mismatch`. Disabled gates need no approval.
7. The three `run_state.approved_*` values must also exactly match current issue/policy values; any mismatch adds `:policy_revision_mismatch`.
8. Each blocker ID must be a non-empty binary and have exact accepted Done evidence; otherwise add `:blocker_not_accepted`.
9. Quota counters/maxima must be non-negative numbers, `max_issues_24h` a non-negative integer, and issue IDs a list of binaries. Malformed quota data adds `:quota_exhausted`. Count distinct IDs. If the current issue is already present, deny only when the distinct count exceeds the maximum; if it is new, deny when inserting it would exceed the maximum.
10. Return the exact allow receipt only when the final reason list is empty. Add no adapters, schemas, structs, config, or integration hooks.

- [ ] **Step 5: Run focused tests and observe GREEN**

```bash
cd elixir
mise exec -- mix format lib/symphony_elixir/dispatch_policy.ex test/symphony_elixir/dispatch_policy_test.exs
mise exec -- mix test test/symphony_elixir/dispatch_policy_test.exs --trace
mise exec -- mix specs.check
```

Expected: all new tests and the public-spec checker pass.

- [ ] **Step 6: Run regressions and the full quality gate**

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/dispatch_candidate_test.exs test/symphony_elixir/project_profiles_test.exs
mise exec -- make all
```

Expected: the existing profile/dispatch tests and full format, lint, coverage, and Dialyzer gate pass. Record dependency advisories separately; do not change dependency versions in this scoped task.

- [ ] **Step 7: Self-review and commit**

Check purity, fail-closed behavior, reason order, exact receipt keys, and absence of integration/config changes:

```bash
git diff --check
git status --short
git add docs/superpowers/plans/2026-09-16-sma-dispatch-policy.md \
  elixir/lib/symphony_elixir/dispatch_policy.ex \
  elixir/test/symphony_elixir/dispatch_policy_test.exs
git commit -m "feat: add offline dispatch policy"
```

The report must contain the observed RED failure, GREEN focused result, regression result, full-gate result, commit SHA, and any pre-existing advisory or infrastructure concern.
