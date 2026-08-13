# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Review convergence is latest-head only: prefer a formal review; the restricted clean-comment
  compatibility path additionally requires a unique persisted current-head request, strict time
  ordering, trusted App/bot database identities, and reviewed-commit binding. Always require passing
  checks and no unresolved P1-P4 threads. Never treat convergence as merge authorization.
- Keep review requests, tracker comments/state writes, retries, and human escalation idempotent with
  stable keys. When evidence cannot be verified, remain in review and fail closed.
- Rework state changes use a durable transition operation: persist intent before changing Linear,
  record completion separately, and resume incomplete operations from both review and in-progress
  states. Count a fix round only after the target state is observed and completion is durable.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## Authority Change Gate

Applies to any change that grants, caches, retains, or releases authority — grants,
claims, generations, leases, once-only markers. Satisfy every item before requesting
review; each one has produced a P1 finding in this repository.

- **Cache identity is total, or the grant is revalidated.** Enumerating fields into a
  cache key does not converge; each round of review finds one more input that was
  left out. Either the key covers every authorization-relevant input, or a cached
  grant is revalidated before it is replayed. Store the cached result under the full
  transition key too, not under a narrower identifier that a later transition can
  overwrite.
- **Cycle snapshot.** State accumulated across poll cycles must be filtered to the
  current cycle's decisions before it is read. Never fold a historical entry into a
  current result, and never assume a stored entry still matches the clause shape that
  reads it.
- **Persist atomically before return.** A successful attempt must reach the history
  that later attempts consult before the success is returned, but only once the whole
  batch grants. Committing one decision while a sibling blocks poisons the next poll
  with a grant that was never delivered. A new head alone is not progress.
- **Validate at the boundary, before any traversal.** Externally supplied collections
  must be shape-checked before `++`, `Enum`, or key access touches them. Raising
  inside preprocessing is not failing closed; it aborts the poll. Checking `is_map/1`
  on an element is not validation — check the fields the decision actually reads.
- **Retention needs an exit.** If a claim is retained past its normal release point,
  there must be an arm that consumes or releases it under unchanged inputs. Prove it
  with consecutive polls, not one: a single follow-up poll passes even when the claim
  renews forever.
- **Spec-required means validated.** Any field that `../SPEC.md` or the change plan
  names as required must fail closed when absent. Never let it default to `nil`.

Exercise the full sequence in `test/symphony_elixir/review_convergence_test.exs`, not
only the transition being changed:

```
acquire -> grant -> next poll with claim already owned -> claim lost or expired
        -> re-acquire at the same head with the same receipt
```

Unit tests over pure authorization functions do not cover this gate; the failures it
guards live at the cross-poll boundary.

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
