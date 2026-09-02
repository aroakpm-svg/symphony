# ARO-286 Execution Context Retirement Design

## Purpose

ARO-286 binds each authorized multi-project attempt to one immutable
`ProjectExecutionContext`. That context selects the project namespace, repository, routing revision,
credential reference, workspace, readiness sidecar, and private subprocess homes. The current
orchestrator can release ownership after a confirmed project identity change without first retiring
the resources selected by the old context. Once the old running, blocked, or retry entry is removed,
later reconciliation has only the new project identity and cannot safely derive authority for the old
namespace.

This change makes retirement of an invalidated project execution context an explicit lifecycle
operation. It does not broaden cleanup to ordinary retry, temporary invisibility, reassignment, or
non-terminal workflow transitions.

## Scope and Ticket Ownership

This is required by ARO-286's existing guarantees that cleanup uses the same context-derived target
as execution and that project workspaces and credential homes remain isolated. ARO-287 continues to
own project routing, claim ownership, and dispatch authorization; this change consumes its confirmed
project-identity transition and retires only ARO-286 resources.

The following remain outside this change:

- the ARO-195/ARO-196 credential inventory and canonical GitHub credential resolver;
- ARO-285 live non-Production end-to-end acceptance;
- a durable cleanup queue, cleanup ledger, scheduler, database schema, or new claim authority;
- cleanup triggered solely by temporary issue invisibility, reassignment, ordinary inactive states,
  or retry/backoff;
- Production access, deployment, external resource mutation, automatic merge, or Linear state
  changes.

No other repository ticket or pull request is recorded as owning retirement of the project-scoped
workspace and private home introduced by ARO-286.

## Root Cause

`terminate_running_issue/3` currently accepts a boolean named `cleanup_workspace`. The boolean mixes
two independent decisions:

1. why execution ownership is ending; and
2. whether the stored execution context must retain or retire its resources.

Consequently a confirmed project identity change is treated like a temporary release: the task and
claim are released, but the old context is discarded without cleanup. Blocked and retry ownership
use separate release paths and can make the same mistake.

The missing abstraction is context retirement. Task termination, claim finalization, and context
resource retirement are related actions, but they are not interchangeable.

## Design

### Explicit termination policy

Replace the cleanup boolean at the running termination boundary with explicit internal policies:

- `:complete` stops the task, retires the stored context, and completes the distributed claim;
- `:invalidate_context` stops the task, retires the stored context, and releases the distributed
  claim;
- `:retain_context` stops the task and releases the distributed claim without cleanup.

Callers select policy from the observed transition:

| Transition | Policy |
| --- | --- |
| Terminal state | `:complete` |
| Confirmed project identity mismatch | `:invalidate_context` |
| No longer routable to this worker | `:retain_context` |
| Non-active but non-terminal state | `:retain_context` |
| Temporarily missing from refresh | `:retain_context` |
| Stall/retry/backoff | `:retain_context` |

The policy is internal and does not change public configuration or external APIs.

### One context-retirement boundary

Add one orchestrator helper that consumes the stored resource authority:

- issue identifier;
- exact worker host;
- old `ProjectExecutionContext`;
- stored workspace attestation, if available.

For a project context with a missing attestation, it uses the existing exact-host attestation
reacquisition path. It then delegates to `Workspace.remove_issue_workspaces/4`, which already
validates and removes the context-bound workspace, readiness sidecar, and all exact issue routing
revision homes. Legacy nil-context cleanup keeps its current behavior.

Retirement happens before the orchestrator deletes the entry containing the old authority. Claim
finalization and in-memory state removal follow the cleanup attempt, preserving the existing
best-effort cleanup contract: an unsafe or unverifiable target fails closed and is logged, but this
change does not introduce a durable retry ledger.

### Apply retirement consistently to ownership states

Running, blocked, and retry state can each retain project execution authority.

- Running project mismatch uses `:invalidate_context` through the explicit termination policy.
- Blocked project mismatch invokes the same retirement boundary before releasing blocked, claimed,
  and retry state.
- Retry reconciliation compares the refreshed authoritative project ID with the stored execution
  context when both are present. A confirmed mismatch retires the old context before retry ownership
  is released. A missing result or fetch failure is not treated as a confirmed mismatch and retains
  existing behavior.

Project identity comparison continues to use normalized UUID equality. A malformed or absent
refreshed identity is a mismatch only in paths that already possess an authoritative refreshed issue;
it must not cause speculative cleanup from an empty fetch result.

### Ordering and safety invariants

For context invalidation, ordering is:

1. stop the active task when one exists;
2. retain the stored old execution context and attestation in memory;
3. attest or reacquire authority for the exact old host and namespace;
4. request removal of only the old context-bound resources;
5. release the distributed claim;
6. remove running, blocked, claimed, and retry metadata.

Cleanup must never derive its target from the refreshed/new project profile. It must not inspect or
remove sibling project namespaces, legacy workspaces, similarly prefixed issue homes, or the new
project's workspace.

## Error Handling

Workspace validation remains fail closed. If attestation cannot be acquired or validation rejects
the target, the orchestrator logs the existing bounded cleanup warning and continues the existing
claim-release transition. This design does not claim crash-atomic cleanup or durable recovery after a
process failure between cleanup and claim release.

Credential values, environment dumps, filesystem identities, and unbounded external errors must not
enter logs or state. No cleanup error changes an unauthorized context back into an authorized one.

## Test Strategy

Tests are written before implementation and must fail because the old context remains on the current
head.

### Context invalidation regressions

- A running profiled issue moved to another configured project removes the old namespaced workspace,
  readiness sidecar, current private home, and prior revision homes before releasing ownership.
- A blocked profiled issue moved to another configured project performs the same retirement.
- A retry entry receiving an authoritative refreshed issue from another project performs the same
  retirement.
- Each case preserves a workspace in the new project namespace, a legacy workspace, a similarly
  prefixed issue home, and unrelated revision directories.
- A missing stored attestation is safely reacquired for the exact stored worker host.

### Retention regressions

- reassignment or other loss of routability retains the workspace;
- ordinary non-terminal inactive state retains the workspace;
- missing refresh result retains the workspace;
- stall and ordinary retry/backoff retain the workspace;
- UUID case normalization does not retire a context whose project identity is unchanged.

### Verification

Run the focused orchestrator lifecycle tests first, then the ARO-286 deterministic acceptance suite,
the repository quality gate, formatting, specs, compilation with warnings as errors, Dialyzer, and
`git diff --check`. Any platform-specific baseline failure must be reported separately and must not be
described as passing.

## Acceptance Criteria

1. No confirmed project identity transition can discard the only stored cleanup authority before
   attempting retirement of the old context.
2. Running, blocked, and retry ownership apply the same context-retirement rule.
3. Temporary release and retry paths preserve their existing workspace-retention behavior.
4. Cleanup uses only the stored old context and exact worker host and remains fail closed.
5. No new durable service, database object, credential resolver, deployment behavior, or Production
   access is introduced.
