# Trusted multi-target review control plane

The ordinary `ReviewMonitor` remains the issue-scoped review workflow. It
loads one repository from `WORKFLOW.md` and may write Linear comments and state
transitions for that workflow.

The trusted multi-target control plane is a separate, status-only boundary for
reviewing explicitly selected pull requests across repositories. It uses the
same `ReviewConvergence` policy evaluator, but it does not add another
evaluator, patch authorizer, settlement engine, merge path, or landing path.

## Target identity

Every target is immutable for one control-plane run:

```text
target = repository + pull_request_number + head_sha
key    = repository#pull_request_number@head_sha
```

The repository, pull request number, and full 40-character lowercase head SHA
are required. A new head is a new target; it cannot reuse the previous target's
state, review request, status, or history.

The control-plane state map and deduplication keys use the complete target key.
Therefore the following targets remain independent even when their PR numbers
match:

```text
aroakpm-svg/aroak-central-brain#25@<head-a>
aroakpm-svg/symphony#25@<head-a>
aroakpm-svg/symphony#25@<head-b>
```

Before any status is published, the fresh GitHub snapshot must match all three
identity fields. A mismatch fails closed and publishes no status.

Target-scoped issue-comment review requests persist the pinned head explicitly
as `currentHeadSha` alongside the opaque `dedup-key`. The target-aware
existence check requires both values, so an older hash-only request cannot
suppress a corrected request for the same target. The ordinary issue-scoped
request path remains compatible with the legacy body shape.

## Trust boundary

`SYMPHONY_REVIEW_TARGETS` is loaded by the trusted runtime environment, not
from the target repository's `WORKFLOW.md`, PR body, branch, or code. A target
PR therefore cannot add itself to the allowlist or redirect its own status.

The runtime must be started from a separately trusted Symphony checkout pinned
to an already trusted `main` or release SHA. The target PR is read through the
GitHub API; its reviewer implementation is never loaded as the runtime that
publishes the status.

The GitHub credential used by `gh` must belong to the trusted runtime operator
or service account and must have permission to read the target PR and publish a
commit status. Missing or contradictory evidence remains blocked.

## Bootstrap a target

From the trusted Symphony checkout, set an explicit target registry. The head
SHA is intentionally pinned so a later push cannot silently inherit this
review result:

```bash
export SYMPHONY_REVIEW_TARGETS='[
  {"repository":"aroakpm-svg/symphony","pull_request_number":25,"head_sha":"<full-lowercase-head-sha>"}
]'

mix review.control_plane
```

The task prints one JSON outcome per target and exits successfully only when
every target reports `success`. It publishes the fixed `Review Convergence
Gate` context on the verified target head. `pending`, `failure`, `error`, or
`blocked` outcomes are truthful non-converged results and require the target's
normal review or human follow-up.

For Symphony PR #25, the trusted runtime must be based on `aroakpm-svg/symphony`
`main` (or a released trusted build), while the target registry points at
`aroakpm-svg/symphony#25` and its exact current head. This is external review of
Symphony; it is not self-review by the PR checkout.

## Generalization

Add another repository only by changing the trusted runtime's explicit target
registry. Do not make a target repository's PR responsible for editing that
registry. A later durable control-plane change may add discovery, persisted
target history, and multiple runtime workers, but it must preserve the same
target identity and status destination contract.
