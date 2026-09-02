# ARO-286 Final Isolation Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two load-bearing isolation defects left by ARO-286 final review without changing its approved feature scope.

**Architecture:** Workspace attestations compare only stable filesystem identity, never mutable directory metadata. Subprocess environment construction becomes side-effect free; Workspace creates the context-private home only after the exact project workspace and namespace have passed lexical, canonical, and physical validation.

**Tech Stack:** Elixir/OTP, ExUnit, Windows file IDs, POSIX device/inode identity.

**Spec:** `docs/superpowers/specs/2026-08-28-aro-286-project-workspace-isolation-design.md`

## Global Constraints

- Do not implement the ARO-195/ARO-196 canonical GitHub credential resolver or inspect secret values.
- Do not add a scheduler, claim path, capacity store, lease, deployment, Production access, shared database mutation, or external resource.
- Preserve legacy single-project workspace behavior.
- Multi-project authorization or isolation uncertainty fails closed before Codex starts.
- Every public `def` in `elixir/lib` has an adjacent `@spec`.
- Sanitization happens before truncation; no status, receipt, error, fixture, or notification contains credential material.
- Use RED-GREEN TDD and do not push or merge.

---

### Task 1: Stable Local Workspace Identity

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: the existing `%{kind: :local, path: path, identity: identity}` workspace attestation.
- Produces: a stable identity containing POSIX directory type/device/inode or the native Windows file ID, with validation that survives normal directory-content mutation but rejects path replacement.

- [ ] **Step 1: Write failing stable-identity regressions**

  Add a real local project-workspace test that obtains an attestation, creates and removes top-level subdirectories/files as clone/hooks/Codex would, and proves preflight, hook validation, AppServer validation, and cleanup still accept the unchanged directory. Keep the existing rename/recreate replacement tests and add an assertion that replacement remains rejected after the identity change.

- [ ] **Step 2: Run the selected tests and confirm RED**

  Run the new line-selected tests from `workspace_and_config_test.exs`. Expected: the same inode is rejected because `size` or `links` changed.

- [ ] **Step 3: Implement the minimal stable identity**

  On POSIX retain only directory `type`, `major_device`, `minor_device`, and `inode`. On Windows retain directory `type` plus `windows_file_id`; do not compare size, mode, timestamps, or link count. Fail closed when the platform identity cannot be obtained. Keep canonical path equality and the existing immediate revalidation at every effect boundary.

- [ ] **Step 4: Verify GREEN and related replacement safety**

  Run the new tests plus all existing workspace attestation, AppServer, readiness, cleanup, and multi-project regressions. Run formatter, specs, Dialyzer, and diff checks.

- [ ] **Step 5: Commit Task 1**

  Commit message: `fix: stabilize project workspace identity`

---

### Task 2: Validated Context-Private Subprocess Home

**Files:**
- Modify: `elixir/lib/symphony_elixir/subprocess_environment.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/test/symphony_elixir/subprocess_environment_test.exs`
- Modify: `elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Produces: side-effect-free `SubprocessEnvironment.build/2` and a context-private home path contract.
- Consumes: Workspace's already validated exact project namespace/workspace and local workspace attestation before creating any private-home directory.

- [ ] **Step 1: Write failing no-mutation and alias regressions**

  Cover an unsafe/Production-like workspace root, a namespace symlink/junction to a sibling/outside root, a pre-existing `.symphony-subprocess` alias, and aliased issue-home/`gh`/`codex` descendants. Assert environment construction alone creates nothing; Workspace preparation fails before any provider-scoped directory or marker appears outside the approved namespace. Add a normal case asserting every private directory is canonical, contained, non-reparse, and private to the current user where the platform exposes permissions.

- [ ] **Step 2: Run selected tests and confirm RED**

  Expected: `SubprocessEnvironment.build/2` creates directories before Workspace validation and follows at least one alias.

- [ ] **Step 3: Make environment construction pure**

  Compute the private-home paths and environment values without filesystem mutation. Preserve the deny-by-default variable contract and provider allowlist.

- [ ] **Step 4: Move secure creation behind Workspace validation**

  After Workspace has validated the exact context path and obtained its attestation, create each private-home component using explicit paths. Reject existing symlink/reparse components, canonical escape, sibling-project identity, and post-check replacement. Apply owner-private permissions/ACLs where supported. Do this before any hook, Git, or Codex subprocess consumes the environment. On failure return only a bounded safe reason and perform no external mutation.

- [ ] **Step 5: Verify GREEN and full isolation regressions**

  Run subprocess-environment, AgentRunner, Workspace/AppServer, ARO-286 acceptance, both PowerShell watchdog suites, formatter, specs, Dialyzer, compile, and diff checks. Classify only unchanged full-suite baselines separately.

- [ ] **Step 6: Update acceptance evidence and commit Task 2**

  Amend `elixir/docs/aro_286_acceptance.md` and the remediation report with exact stable-identity/private-home tests. Commit message: `fix: validate project subprocess homes`

---

### Task 3: Whole-Branch Remediation Review

**Files:**
- Create: `.superpowers/sdd/2026-09-01-aro-286-final-isolation-remediation/remediation-report.md`

**Interfaces:**
- Consumes: Tasks 1 and 2 exact-head commits and evidence.
- Produces: final merge-readiness verdict for the two residual isolation boundaries.

- [ ] **Step 1: Run exact remediation and ARO-286 gates**

  Run all changed focused suites, the 13-file ARO-286 acceptance command, `mix specs.check`, `mix dialyzer`, targeted formatting, compile with warnings as errors where supported, and `git diff --check`.

- [ ] **Step 2: Run the full suite and record exact baseline differences**

  Run `mix test --seed 0`; compare any failures against the recorded 15 CRLF-sensitive baseline failures. Do not report a green full gate unless exit status is zero.

- [ ] **Step 3: Request independent whole-remediation review**

  Review from base `2399ab8` through remediation HEAD, explicitly checking stable POSIX/Windows identity, private-home symlink/junction safety, effect ordering, legacy behavior, and absence of new credential exposure.

- [ ] **Step 4: Record the final verdict**

  Do not push or merge. Preserve the worktree and report any residual Critical/Important issue to the user.
