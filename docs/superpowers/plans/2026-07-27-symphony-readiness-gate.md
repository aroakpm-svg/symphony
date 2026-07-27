# Symphony Readiness Gate Implementation Plan

> **Execution note:** Implement as one bounded work package. During development run focused tests only; run the full repository gate, coverage, and exact-head review once on the final head.

**Goal:** Prevent Symphony from starting Codex for a new issue workspace unless the branch base is provably the live canonical remote default head, while preserving existing issue/PR branches and allowing stacked work only with exact typed upstream evidence.

**Architecture:** Add a pure, typed `GitBranchResolver` that obtains the canonical default ref through `git ls-remote --symref origin HEAD`, fetches that exact ref, and returns a redacted receipt. Add a `ReadinessGate` that classifies continuation, independent-new, and explicit-stacked work before `before_run` / AppServer launch. It may create a fresh issue branch, but it must never reset, rebase, force-checkout, or delete an existing work branch. Missing or ambiguous evidence fails closed through the existing hard-blocker path.

**Tech stack:** Elixir/OTP, existing `Workspace` command runner and timeout/redaction conventions, ExUnit temp repositories, existing `AgentRunner` and orchestrator hard-blocker contract.

---

## Scope Contract

### Work Item

Add a canonical Git branch resolver and pre-dispatch readiness gate for Symphony issue workspaces.

### Invariants

- Canonical default branch authority comes from the live remote symref and fetched SHA, not a hard-coded branch, stale local `origin/HEAD`, or prose.
- Existing issue/PR branches are continuation work and are never reset or rebased merely because the default branch advanced.
- Independent new work starts at exactly the live canonical default SHA in a clean workspace.
- Stacked work requires an exact typed upstream branch and head SHA; missing, multiple, stale, or mismatched evidence blocks.
- Any unverifiable Git state fails closed before `before_run` and before Codex AppServer launch.
- Receipts and errors redact credentials and include the smallest operator action.

### Acceptance Criteria

- AC-1: Resolve non-`main` default branches and slash-containing refs from `git ls-remote --symref origin HEAD`, then verify the fetched SHA matches the advertised SHA.
- AC-2: Block malformed/missing/duplicate symrefs, auth/timeout/fetch errors, SHA races, detached or mismatched continuation branches, dirty independent workspaces, and ambiguous stacked evidence.
- AC-3: Reuse a matching existing issue/remote PR branch without destructive repair even when the canonical default has advanced.
- AC-4: Create an independent issue branch only from the verified live canonical SHA and re-read branch/HEAD before returning ready.
- AC-5: Accept stacked work only when exact typed upstream branch and SHA evidence is supplied and verified.
- AC-6: A readiness failure uses the existing hard-blocker outcome, starts neither `before_run` nor AppServer, and does not enter an automatic retry loop.
- AC-7: Focused unit/integration tests cover local and SSH command seams, redaction, race handling, continuation preservation, and the three-state gate matrix.

### Non-Goals

- Finding Router or review-disposition semantics.
- Finding clustering, review budgets, or Convergence Hold policy.
- GitHub rulesets, required-check configuration, merge authorization, Done transitions, or dashboard metrics.
- Automatic rebasing, resetting, deleting, or otherwise repairing existing work branches.
- Inferring stacked dependencies from free-form issue or PR text.

### Dependencies

- Existing workspace preflight, Git command execution, redaction, AgentRunner ordering, and orchestrator hard-blocker behavior.

### Follow-Ups

- Automatic readiness-only rechecks after an operator fixes a hard blocker.
- Richer Linear/GitHub typed dependency projection if the current issue model cannot supply exact stacked branch and head evidence.

## Implementation batch

**Likely owned files:**

- `elixir/lib/symphony_elixir/git_branch_resolver.ex` (new)
- `elixir/lib/symphony_elixir/readiness_gate.ex` (new)
- `elixir/lib/symphony_elixir/workspace.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- The smallest typed issue/config seam needed for stacked evidence; do not parse prose
- Focused tests for the new modules and integration boundary
- `SPEC.md`, `elixir/README.md`, and `elixir/WORKFLOW.md`

**TDD sequence:**

1. Add failing pure resolver tests for symref parsing, ref validation, advertised/fetched SHA equality, races, timeouts/auth errors, slash refs, and redaction.
2. Add failing readiness matrix tests for continuation, independent-new, explicit-stacked, dirty/detached/ambiguous states, and no destructive commands.
3. Add a failing AgentRunner integration proving a stale new workspace is blocked before `before_run` and AppServer, while a continuation branch remains usable after the default advances.
4. Implement the smallest typed modules and integration seam; reuse existing command execution and hard-blocker machinery.
5. Update the normative docs without changing review routing or merge policy.

**Development verification:** focused tests for touched modules, `mix format --check-formatted`, `mix specs.check`, `mix credo --strict`, and `git diff --check`.

**Final-head verification (controller only, once):** `make -C elixir all`, repository coverage, independent whole-diff review, then one exact-head `@codex review` request and full unresolved-thread check.
