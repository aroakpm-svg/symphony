# ARO-286 Project Workspace Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind every authorized multi-project worker to one approved project workspace and credential reference while exposing secret-safe runtime health and restart-failure evidence.

**Architecture:** A typed immutable `ProjectExecutionContext` crosses the existing Orchestrator → AgentRunner → Workspace boundary. Workspace readiness persists only opaque profile identity, while a narrow injected credential provider supplies per-attempt process environment. A separate `RuntimeHealth` GenServer owns bounded diagnostics and final receipts without changing ARO-287 claim/retry decisions.

**Tech Stack:** Elixir 1.19/OTP 28, Ecto embedded config, ExUnit, PowerShell watchdog, existing Phoenix status surfaces.

**Spec:** `docs/superpowers/specs/2026-08-28-aro-286-project-workspace-isolation-design.md`

## Global Constraints

- Do not implement the ARO-195/ARO-196 canonical GitHub credential resolver or inspect secret values.
- Do not add a scheduler, claim path, capacity store, lease, deployment, Production access, shared database mutation, or external resource.
- Preserve the legacy single-project workspace behavior.
- Multi-project authorization or isolation uncertainty fails closed before Codex starts.
- Every public `def` in `elixir/lib` has an adjacent `@spec`.
- Logs follow `elixir/docs/logging.md` and include `issue_id` plus `issue_identifier` for issue-scoped events.
- Sanitization happens before truncation; no status, receipt, error, fixture, or notification contains credential material.
- The recorded Windows baseline is 843/884 passed with 41 pre-existing environment failures; no ARO-286 focused or related regression may fail.

---

### Task 1: Typed Project Execution Context

**Files:**
- Create: `elixir/lib/symphony_elixir/project_execution_context.ex`
- Create: `elixir/test/symphony_elixir/project_execution_context_test.exs`

**Interfaces:**
- Consumes: `%SymphonyElixir.Linear.Issue{project_profile: map(), repository: String.t(), routing_revision: pos_integer()}`.
- Produces: `ProjectExecutionContext.from_issue/1 :: {:ok, t()} | {:error, reason()}` and `ProjectExecutionContext.safe_metadata/1 :: map()`.

- [ ] **Step 1: Write failing construction and fail-closed tests**

Cover both approved profiles, missing profile, mismatched `project_id`, mismatched repository, missing routing revision, malformed namespace, and any environment other than `local_non_production`. Assert errors contain field/reason atoms but no submitted credential reference.

```elixir
assert {:ok, %{profile_key: "central-brain", workspace_namespace: "central-brain"}} =
         ProjectExecutionContext.from_issue(authorized_issue())

assert {:error, :repository_mismatch} =
         authorized_issue(repository: "aroakpm-svg/aroak-project-management")
         |> ProjectExecutionContext.from_issue()
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `mix test test/symphony_elixir/project_execution_context_test.exs`

Expected: compilation failure because `ProjectExecutionContext` does not exist.

- [ ] **Step 3: Implement the minimal immutable context**

Define an `@enforce_keys` struct containing `issue_id`, `issue_identifier`, `profile_key`, `linear_project_id`, `repository`, `canonical_branch`, `workspace_namespace`, `credential_ref`, `environment`, and `routing_revision`. Compare Linear UUIDs semantically with `Ecto.UUID.cast/1`; require the issue repository and profile repository to be identical; accept only the approved non-Production environment.

`safe_metadata/1` returns issue IDs, profile key, repository, canonical branch, workspace namespace, environment, and routing revision, but deliberately omits `credential_ref`.

- [ ] **Step 4: Run focused tests and specs check**

Run: `mix test test/symphony_elixir/project_execution_context_test.exs && mix specs.check`

Expected: all Task 1 tests pass and specs check exits 0.

- [ ] **Step 5: Commit Task 1**

```bash
git add elixir/lib/symphony_elixir/project_execution_context.ex elixir/test/symphony_elixir/project_execution_context_test.exs
git commit -m "feat: bind authorized project execution context"
```

### Task 2: Project-Namespaced Workspace and Durable Identity

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/test/symphony_elixir/workspace_readiness_state_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: `ProjectExecutionContext.t() | nil` from Task 1.
- Produces: `Workspace.prepare_for_issue/3`, `Workspace.create_for_issue/3`, and `Workspace.remove_issue_workspaces/3`, with the third argument being context and legacy two-argument calls preserved.

- [ ] **Step 1: Write failing namespacing and collision tests**

Assert that the same issue identifier maps to different canonical paths:

```elixir
assert central.path == Path.join([root, "central-brain", "ARO-286"])
assert management.path == Path.join([root, "project-management", "ARO-286"])
```

Add local and SSH-path tests for path containment, symlink escape, Production-like root rejection, cleanup target precision, and no deletion of the namespace or workspace root.

- [ ] **Step 2: Write failing durable-context drift tests**

Extend `Workspace.ReadinessState` with `profile_key`, `linear_project_id`, `repository`, `canonical_branch`, `workspace_namespace`, and `credential_ref`. Assert exact reuse succeeds while project, repo, branch, namespace, credential reference, and workspace path drift each fail closed before hooks run.

- [ ] **Step 3: Run focused workspace tests and confirm RED**

Run: `mix test test/symphony_elixir/workspace_readiness_state_test.exs test/symphony_elixir/workspace_and_config_test.exs`

Expected: failures for missing context-aware arities and readiness fields.

- [ ] **Step 4: Implement context-aware path and readiness state**

Derive the relative path only from validated context namespace plus the existing sanitized issue identifier. Keep the legacy path `<root>/<issue>` when context is `nil`. Encode/decode the new readiness fields and require exact equality for context-aware reuse. Do not enrich a legacy workspace into a multi-project workspace; return a stable `:workspace_context_missing` error.

- [ ] **Step 5: Implement context-aware cleanup**

Compute exactly one context-derived issue path and call the existing safe removal path. Validate the final path remains a strict descendant of the configured root and namespace. Never enumerate and delete a broad root to compensate for missing context.

- [ ] **Step 6: Run focused workspace suites**

Run: `mix test test/symphony_elixir/workspace_readiness_state_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/workspace_preflight_blocker_test.exs`

Expected: all tests not dependent on the recorded Windows Bash environment pass; any environment failure must match the baseline signature and count.

- [ ] **Step 7: Commit Task 2**

```bash
git add elixir/lib/symphony_elixir/workspace.ex elixir/test/symphony_elixir/workspace_readiness_state_test.exs elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: isolate workspaces by approved project"
```

### Task 3: Credential Reference Execution Boundary

**Files:**
- Create: `elixir/lib/symphony_elixir/project_credential_provider.ex`
- Create: `elixir/test/symphony_elixir/project_credential_provider_test.exs`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs`

**Interfaces:**
- Consumes: `ProjectExecutionContext.t()` and injected `:credential_provider` option.
- Produces: `ProjectCredentialProvider.resolve/2 :: {:ok, %{optional(String.t()) => String.t()}} | {:error, reason()}`; the default provider returns `{:error, :credential_provider_unconfigured}` for multi-project execution.

- [ ] **Step 1: Write failing provider isolation tests**

Use opaque fixture values generated inside the test process. Assert the central profile provider is called only with `github-central-brain`, the management provider only with `github-project-management`, and neither result reaches the other command runner. Test missing, ambiguous, wrong-reference, and exception outcomes.

- [ ] **Step 2: Write failing AgentRunner propagation tests**

Assert `AgentRunner.run/3` creates one `ProjectExecutionContext`, passes it to workspace preparation, readiness, hooks, and Codex runtime settings, and injects the returned environment only into subprocess execution. Assert a provider failure reports an agent hard blocker before Codex starts and retains existing claim cleanup semantics.

- [ ] **Step 3: Run focused tests and confirm RED**

Run: `mix test test/symphony_elixir/project_credential_provider_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs`

Expected: failures for the missing provider and propagation interfaces.

- [ ] **Step 4: Implement the provider boundary and subprocess-only environment**

The provider accepts only the context and explicit injected resolver. Validate returned keys and binary values without logging them. Thread the environment to Git/readiness/Codex command execution via options; never merge it into `System` environment or application state. Sanitize all provider failure output before it reaches errors.

- [ ] **Step 5: Run AgentRunner, readiness, and workspace regressions**

Run: `mix test test/symphony_elixir/project_credential_provider_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_preflight_blocker_test.exs`

Expected: new credential tests pass; any Codex/Bash environment failures exactly match the recorded baseline.

- [ ] **Step 6: Commit Task 3**

```bash
git add elixir/lib/symphony_elixir/project_credential_provider.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/lib/symphony_elixir/workspace.ex elixir/test/symphony_elixir/project_credential_provider_test.exs elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs
git commit -m "feat: isolate project credential execution"
```

### Task 4: Real Linear Startup Identity Gate

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Create: `elixir/test/symphony_elixir/linear_startup_identity_test.exs`

**Interfaces:**
- Produces: `Linear.Client.validate_identity/1 :: {:ok, %{viewer_id: String.t()}} | {:error, atom()}` and `Tracker.validate_identity/0`.

- [ ] **Step 1: Write failing identity response classification tests**

Exercise a real read-only viewer GraphQL payload through an injected request function. Cover 200 with viewer ID, 401, 403, 200 with GraphQL auth errors, missing viewer, malformed JSON, timeout, and transport failure. Expected error atoms distinguish `:linear_unauthorized`, `:linear_forbidden`, `:linear_identity_missing`, `:linear_response_invalid`, and `:linear_unavailable` without response bodies.

- [ ] **Step 2: Write failing startup-gate tests**

Inject `identity_validator` into Orchestrator initialization. Assert workers and polling timers start only after success. Authentication or identity mismatch stops startup; transient unavailability is returned distinctly and no workspace/claim effect occurs.

- [ ] **Step 3: Run focused tests and confirm RED**

Run: `mix test test/symphony_elixir/linear_startup_identity_test.exs test/symphony_elixir/core_test.exs`

- [ ] **Step 4: Implement the read-only identity gate**

Reuse `@viewer_query` and the existing request path. Add the public client and tracker functions with specs. Call the validator before terminal cleanup and tick scheduling. Do not print API keys, headers, bodies, or raw GraphQL errors.

- [ ] **Step 5: Run Linear and Orchestrator focused suites**

Run: `mix test test/symphony_elixir/linear_startup_identity_test.exs test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/core_test.exs`

- [ ] **Step 6: Commit Task 4**

```bash
git add elixir/lib/symphony_elixir/linear/client.ex elixir/lib/symphony_elixir/tracker.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/linear_startup_identity_test.exs elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: verify Linear identity before polling"
```

### Task 5: Secret-Safe Runtime Health State

**Files:**
- Create: `elixir/lib/symphony_elixir/runtime_health.ex`
- Create: `elixir/test/symphony_elixir/runtime_health_test.exs`
- Modify: `elixir/lib/symphony_elixir.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`

**Interfaces:**
- Produces: `RuntimeHealth.stage/3`, `RuntimeHealth.dependency/3`, `RuntimeHealth.poll_succeeded/1`, `RuntimeHealth.stop/2`, and `RuntimeHealth.snapshot/1`.
- Consumes: fixed stage atoms and safe metadata from Task 1; it rejects unknown keys and credential-like values.

- [ ] **Step 1: Write failing typed-state tests**

Cover all seven required stages, last successful poll timestamp, Linear/claim-store state, final stop category, bounded history, idempotent repeated transitions, unknown-stage rejection, and secret-bearing value rejection. Use a deterministic clock and temporary receipt root.

- [ ] **Step 2: Write failing orchestration instrumentation tests**

For candidate fetch, refresh, routing, profile resolution, preflight, claim, and dispatch, assert exactly one start/outcome transition with profile and issue context. Verify instrumentation failure cannot authorize, release, retain, or retry a claim differently.

- [ ] **Step 3: Run health/status tests and confirm RED**

Run: `mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs`

- [ ] **Step 4: Implement RuntimeHealth and atomic stop receipt**

Add the GenServer before `CoreSupervisor` so startup and shutdown events are available to other children. Store only typed allowed fields. Write the final JSON receipt via temporary file plus same-directory rename beneath a dedicated runtime-state directory. Reject root or workspace paths as receipt targets.

- [ ] **Step 5: Instrument the existing flow and expose the snapshot**

Add calls at existing decision boundaries rather than wrapping them in a second orchestration path. Include health in Orchestrator snapshot, terminal dashboard, and web presenter. Render `unknown` rather than guessing when evidence is absent.

- [ ] **Step 6: Run focused health and multi-project regressions**

Run: `mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs`

- [ ] **Step 7: Commit Task 5**

```bash
git add elixir/lib/symphony_elixir/runtime_health.ex elixir/lib/symphony_elixir.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir/status_dashboard.ex elixir/lib/symphony_elixir_web/presenter.ex elixir/test/symphony_elixir/runtime_health_test.exs elixir/test/symphony_elixir/orchestrator_status_test.exs elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs
git commit -m "feat: expose fail-closed runtime health"
```

### Task 6: Windows Restart-Limit Notification

**Files:**
- Create: `elixir/lib/symphony_elixir/runtime_notifier.ex`
- Create: `elixir/test/symphony_elixir/runtime_notifier_test.exs`
- Create: `elixir/bin/symphony-watchdog.ps1`
- Create: `elixir/test/bin/symphony_watchdog_test.exs`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Config adds `observability.runtime_state_root`, `observability.notification_command`, `observability.notification_receiver`, `observability.restart_limit`, and `observability.notification_timeout_ms`.
- Produces: `RuntimeNotifier.notify_restart_limit/2 :: :ok | {:error, reason()}`.

- [ ] **Step 1: Write failing config and notifier tests**

Require an absolute non-Production runtime-state root. When restart notification is enabled, require a nonblank command, opaque receiver, positive retry limit, and timeout. Test successful stdin JSON delivery, timeout, non-zero exit, missing receiver, idempotent same-epoch replay, distinct epoch delivery, and command output containing a canary secret.

- [ ] **Step 2: Write failing PowerShell watchdog contract tests**

Parse the script as text and run it with an injected child command and notifier fixture. Assert restart count increments, success resets the epoch, limit invokes exactly one notification, and the script never prints child environment variables or notification command output.

- [ ] **Step 3: Run focused tests and confirm RED**

Run: `mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 4: Implement notifier and watchdog**

Serialize a fixed event containing runtime identity, receiver, attempt count, stop category, timestamp, epoch, and receipt path. Send it on stdin to the configured local command with the existing bounded command-runner pattern. Record delivery only on zero exit; sanitize and discard subprocess output on every path. Use explicit validated paths for watchdog state and receipt files.

- [ ] **Step 5: Run focused notifier/config tests**

Run: `mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 6: Commit Task 6**

```bash
git add elixir/lib/symphony_elixir/runtime_notifier.ex elixir/lib/symphony_elixir/config/schema.ex elixir/bin/symphony-watchdog.ps1 elixir/test/symphony_elixir/runtime_notifier_test.exs elixir/test/bin/symphony_watchdog_test.exs elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: notify on terminal Windows restart failure"
```

### Task 7: Documentation, Acceptance Mapping, and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Modify: `SPEC.md`
- Create: `elixir/docs/aro_286_acceptance.md`

**Interfaces:**
- Documents the exact config, legacy boundary, ARO-195/196 dependency, failure codes, local watchdog operation, and non-Production restrictions.

- [ ] **Step 1: Update operator and contract documentation**

Document namespaced workspace examples for both approved profiles, opaque credential references, fail-closed default provider behavior, real Linear identity startup request, runtime-health fields, notifier stdin schema, and Windows watchdog invocation. State that configured notification commands and receivers are operator-provided and must not contain secrets.

- [ ] **Step 2: Write the acceptance mapping**

Map every ARO-286 bullet to exact tests and modules. Record the ARO-195/196 ownership boundary and that ARO-285 owns live non-Production end-to-end acceptance.

- [ ] **Step 3: Run focused ARO-286 verification**

Run all new ARO-286 test files plus:

```bash
mix test test/symphony_elixir/multi_project_dispatch_test.exs \
  test/symphony_elixir/workspace_readiness_state_test.exs \
  test/symphony_elixir/workspace_and_config_test.exs \
  test/symphony_elixir/workspace_preflight_blocker_test.exs \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/status_dashboard_snapshot_test.exs
```

Expected: all ARO-286 assertions pass; any host-environment failure is identical to the recorded baseline and called out separately.

- [ ] **Step 4: Run repository gates**

Run:

```bash
mix format --check-formatted
mix specs.check
mix credo --strict
mix dialyzer
make all
git diff --check origin/main...HEAD
```

Expected: formatter/specs/Credo/Dialyzer/diff pass. Compare `make all` failures to the recorded 41-test Windows baseline; do not repair unrelated failures in this ticket.

- [ ] **Step 5: Review scope and secrets**

Run searches for Production paths, credential-like literals, environment dumps, raw headers/bodies, and changes outside the mapped files. Confirm no external resource, deployment, database mutation, or ARO-195/196 resolver implementation was added.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md SPEC.md elixir/README.md elixir/WORKFLOW.md elixir/docs/aro_286_acceptance.md
git commit -m "docs: map ARO-286 isolation acceptance"
```

- [ ] **Step 7: Request latest-head review**

Use `superpowers:requesting-code-review`, resolve only verified in-scope findings, rerun focused and full available gates after every code-changing review fix, and require no unresolved actionable threads on the exact head. Do not merge the PR.
