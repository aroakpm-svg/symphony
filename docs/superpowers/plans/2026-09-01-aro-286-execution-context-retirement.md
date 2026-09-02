# ARO-286 Execution Context Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the old project-scoped workspace authority before running, blocked, or retry ownership discards a confirmed-invalid execution context.

**Architecture:** Replace the running cleanup boolean with an explicit termination policy and route all confirmed project-identity invalidation through one stored-context retirement helper. Preserve existing retain-on-retry, missing, inactive, and unroutable behavior, and continue delegating exact-host fail-closed deletion to `Workspace`.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, existing `SymphonyElixir.Orchestrator` and `Workspace` APIs.

**Spec:** `docs/superpowers/specs/2026-09-01-aro-286-execution-context-retirement-design.md`

## Global Constraints

- Do not add a database object, cleanup queue, scheduler, claim authority, or durable cleanup ledger.
- Do not implement ARO-195/ARO-196 credential resolution or ARO-285 live acceptance.
- Use only the stored old execution context, exact worker host, and attestation for invalidation cleanup.
- Ordinary retry, temporary invisibility, reassignment, and non-terminal inactive transitions retain their existing workspace behavior.
- Write and observe each regression failing before modifying production code.

---

### Task 1: Running Context Invalidation Policy

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

**Interfaces:**
- Consumes: stored running-entry `identifier`, `worker_host`, `execution_context`, and `workspace_attestation`.
- Produces: internal `terminate_running_issue(state, issue_id, :complete | :invalidate_context | :retain_context)` behavior.

- [ ] **Step 1: Write the failing running-project-move regression**

  Prepare an old project workspace and current/prior private homes through the real `Workspace` API,
  preserve unrelated new-project and similarly named targets, reconcile an authoritative issue whose
  project UUID changed, and assert only the old context resources and ownership are removed.

- [ ] **Step 2: Run the focused test and verify RED**

  Run `mix test test/symphony_elixir/core_test.exs:<line>` and confirm it fails because the old
  namespaced workspace still exists on the unmodified head.

- [ ] **Step 3: Replace the boolean with explicit policy**

  Change every `terminate_running_issue/3` call to one of `:complete`, `:invalidate_context`, or
  `:retain_context`. Add private predicates mapping `:complete` and `:invalidate_context` to context
  retirement and mapping only `:complete` to distributed claim completion. Keep task-stop and state
  deletion ordering unchanged except that retirement consumes the stored entry before deletion.

- [ ] **Step 4: Run focused running and existing terminal tests and verify GREEN**

  Run the new test plus existing running terminal, missing, stalled, and non-routable reconciliation
  cases.

- [ ] **Step 5: Commit**

  Commit the running policy and its regression as `fix: retire invalidated running contexts`.

### Task 2: Blocked and Retry Context Retirement

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

**Interfaces:**
- Consumes: the context-retirement helper established by Task 1.
- Produces: identical invalidation behavior for stored blocked entries and authoritative retry refreshes.

- [ ] **Step 1: Write the failing blocked-project-move regression**

  Extend the existing blocked project-move test to prepare real old-context resources and assert
  their removal while unrelated/new-context targets remain.

- [ ] **Step 2: Write the failing retry-project-move regression**

  Invoke `handle_retry_issue_lookup_for_test/6` with retry metadata containing the old context and an
  authoritative refreshed issue with a different valid project UUID. Assert old resources and
  ownership are removed. Add a separate nil-refresh retention assertion.

- [ ] **Step 3: Run both tests and verify RED**

  Confirm blocked and retry tests fail because the old resources remain, not because fixtures or
  configuration are invalid.

- [ ] **Step 4: Apply the shared retirement boundary**

  Before releasing a confirmed-mismatched blocked entry, pass its stored authority to the shared
  retirement helper. During retry lookup, compare an authoritative refreshed issue project UUID with
  metadata's `%ProjectExecutionContext{}` and retire before transition release on mismatch. Do not
  infer mismatch from nil lookup or fetch failure.

- [ ] **Step 5: Run focused invalidation and retention tests and verify GREEN**

  Run all new cases and the existing terminal blocked/retry cleanup cases.

- [ ] **Step 6: Commit**

  Commit as `fix: retire blocked and retry project contexts`.

### Task 3: Lifecycle Regression and Quality Verification

**Files:**
- Modify: `elixir/docs/aro_286_acceptance.md`
- Modify only if required by formatting: files changed in Tasks 1 and 2.

**Interfaces:**
- Consumes: final behavior from Tasks 1 and 2.
- Produces: acceptance mapping and fresh verification evidence.

- [ ] **Step 1: Update the acceptance map**

  Add the running/blocked/retry project-invalidation regressions to the cross-repository workspace and
  credential isolation evidence without changing ticket ownership or claiming live E2E coverage.

- [ ] **Step 2: Run focused lifecycle suites**

  Run `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/workspace_and_config_test.exs`.

- [ ] **Step 3: Run ARO-286 deterministic acceptance**

  Run the exact command recorded in `elixir/docs/aro_286_acceptance.md` and report the actual pass,
  failure, and skip counts.

- [ ] **Step 4: Run repository quality gates**

  Run `mix format --check-formatted`, `mix specs.check`, `mix compile --warnings-as-errors`,
  `mix dialyzer --format short`, the repository `make all` gate where supported, and
  `git diff --check`.

- [ ] **Step 5: Review the final diff against the spec**

  Confirm every termination caller has an explicit policy; every confirmed project mismatch with
  stored context retires it; retention paths still retain; and no unrelated subsystem or external
  authority was added.

- [ ] **Step 6: Commit**

  Commit documentation or final verification adjustments as `docs: cover execution context retirement`.
