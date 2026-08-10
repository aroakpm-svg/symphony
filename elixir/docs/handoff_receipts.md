# Handoff receipts

## What a receipt is

A handoff receipt is an append-only, remotely verifiable hint about the latest observed repository handoff checkpoint. It records the issue, repository, branch, exact head under test, checkpoint kind, test results, and the effect operations read back from the database. A receipt is evidence for a later observer; it is not authority, approval, or merge readiness.

## V1 checkpoint sequence

The V1 sequence is ordered by checkpoint identity:

- `pushed`: the tested commit was pushed. Candidate next action: refresh the issue, repository, branch, active claim, and remote head before considering pull-request work.
- `pull_request`: the pushed commit is associated with a pull request. Candidate next action: verify current checks and obtain a fresh review observation for that exact head.
- `reviewed`: the pull request and review observation were recorded for the exact head. Candidate next action: re-check all required evidence and route any remaining decision to the authorized human owner.

Each checkpoint remains a claim-bound observation. A later checkpoint does not make earlier evidence authoritative when the issue, identity, claim, remote head, review, or effects have changed.

## Retry and regression contract

The retry amendment is contract version 2. It keeps the V1 receipt shape and adds
only deterministic same-generation append semantics:

- A `(issue_id, claim_id, generation)` is bound to one repository, branch, and `head_sha`. A different head or branch must use a new claim generation and is rejected fail closed.
- A logical checkpoint identity is `(issue_id, claim_id, generation, head_sha, checkpoint_kind, pr_number)`. `pr_number` is null for `pushed` and required for the other two kinds.
- Repeating the same logical checkpoint with the same test results returns the original receipt and does not allocate a new sequence. Conflicting test results fail closed.
- A late lower-ranked checkpoint (`pushed` < `pull_request` < `reviewed`) returns the already recorded higher-ranked receipt and does not insert a new row.
- A same-generation pull-request identity cannot change after one has been recorded. Such a change requires a new generation.

This makes database arrival order safe for the bounded V1 chain without adding a
second retry ledger, caller-supplied sequence, timestamp ordering, or runtime
workflow. New-head progression is intentionally a new generation boundary.

The version-2 migration first checks for duplicate V1 checkpoint identities and
conflicting repository, branch, head, or pull-request bindings within one
legacy generation. If either condition exists, it stops before replacing the V1
function or contract registration and asks for explicit human reconciliation.
It does not delete or rewrite append-only receipt history. The append function
also rejects all-whitespace branches and test-result names before persistence,
matching the domain validator's fail-closed boundary.

## Required fresh observation

Before treating a receipt as useful evidence, collect a fresh observation of:

- the issue identity, repository, and branch;
- the active claim identity, node, instance, and generation;
- the current Linear revision and any relevant issue state;
- Git readiness for the exact intended operation;
- the remote head SHA, compared with the tested head SHA;
- the current pull request and review state when the checkpoint requires them;
- the exact database effect readback for the operation, including settled status and native result.

The observation must be internally consistent with the receipt. Missing or stale evidence is a failure, not an invitation to infer the current state.

## Storage boundary

Staging access is function-only: callers append and read receipts through the handoff receipt functions while holding a matching active claim generation. The database derives the recorded effect-operation IDs from the effect ledger; callers cannot supply or rewrite that evidence. Direct table inserts, updates, and deletes are not part of the API. The rollback is scoped to the ARO-166 handoff receipt objects and contract registration, leaving the ARO-164 claim and ARO-165 effect boundaries intact.

Contract version 2 adds the retry identity and checkpoint-rank rules above without
adding a second storage path or changing the function-only access boundary.

## ARO-167 integration boundary

ARO-167 runtime wiring and native reads are deliberately absent from V1. No runtime path, worker, native provider, or application read is implied by storing a receipt. Integration must define its own fresh-observation and authorization boundary before it consumes this evidence.

## Failure behavior

Consumers fail closed with one of these stable reasons:

- `receipt_missing` — no receipt is available for the requested issue or checkpoint.
- `receipt_incompatible` — the receipt shape, checkpoint sequence, or recorded fields do not match the requested contract.
- `observation_incompatible` — the fresh observation does not match the receipt.
- `identity_changed` — the issue, repository, branch, or other handoff identity changed.
- `claim_inactive` — the claim, node, instance, or generation is no longer active and matching.
- `linear_changed` — the Linear revision or issue state changed after the observation.
- `git_unready` — the required Git operation is not ready for the observed handoff.
- `remote_head_changed` — the remote head differs from the tested head.
- `pull_request_changed` — the pull request identity or relevant state changed.
- `review_stale` — the review evidence is not fresh for the exact current head.
- `native_state_advanced` — native state moved beyond the receipt's observed state.
- `effect_unsettled` — a required database effect is pending, in flight, unknown, or otherwise not settled.
