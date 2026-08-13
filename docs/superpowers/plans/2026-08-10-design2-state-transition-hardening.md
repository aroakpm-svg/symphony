# Design 2 State-Transition Hardening

Status: Draft / non-normative. This document is an implementation contract and
test fixture source for the PR #25 hardening slice. It does not amend `SPEC.md`
and does not claim that any production behavior is already implemented.

## Scope

This slice closes the state-transition boundaries exposed by the latest review
of PR #25 while retaining the existing Design 2 ownership, ledger, claim, and
receipt architecture.

In scope:

- generation-aware historical readback and current-generation mutation fencing;
- claim acquisition ownership and release lifecycle;
- canonical identity validation for persisted finding fingerprints;
- explicit successful preflight evidence;
- readback permission continuity for nodes enrolled after the migration;
- one responsibility decision table shared by tests, predicate, and docs.

Out of scope:

- ARO-166 HandoffReceipt V1 implementation;
- a second finding evaluator, settlement engine, claim path, ledger path,
  receipt path, or coordinator;
- changes to the existing ClaimService lifecycle beyond the minimum ownership
  metadata needed by this monitor boundary;
- Design 3/4 owner API stubs or local substitutes;
- enabling `aroak_autonomous_v1`, starting workers, staging credentials,
  deployment, Production, merge, Landing, Linear Done, or authorization to
  perform any of those actions.

## State model and invariants

### Generation transition

An issue claim follows this transition shape:

```text
generation N (active) -> released/expired -> generation N+1 (active)
```

The following invariants must hold:

1. A current, verified claim for generation `N+1` may authenticate a historical
   readback for the same issue, including unresolved `pending` and `unknown`
   effects created under generation `N`.
2. A historical effect, historical claim, or historical generation alone can
   never authorize a new external mutation for generation `N+1`.
3. Readback may expose old-generation evidence for reconciliation, but the
   current claim identity remains the only mutation authorization context.
4. A row with a different issue identity, malformed claim identity, malformed
   generation, or contradictory current/old scope fails closed.

### Claim ownership

Each monitor invocation must distinguish:

| Claim result | Meaning | May this invocation release it? |
| --- | --- | --- |
| `{:ok, acquisition: :new}` | This invocation acquired the active generation | Yes, after its readback cycle |
| `{:ok, acquisition: :existing}` | The claim already belonged to a worker or prior local owner | No |
| `{:error, _}` | No claim was acquired by this invocation | No |

Binding the monitor process for readback must not overwrite the worker owner
metadata of an existing claim. A failed claim attempt must not call release as a
cleanup shortcut.

### Canonical finding identity

Fingerprint decoding is an authentication boundary for lock reconciliation. A
decoded fingerprint is accepted only after rebuilding `FindingKey` and
`FindingLineageKey` from the embedded repository/PR/thread/body identity and
comparing every canonical field, including each digest. Missing, malformed,
out-of-scope, or conflicting nested identity evidence is invalid.

### Preflight

The global preflight gate is conjunctive:

```text
verified? == true AND valid? == true
```

Missing, false, unknown, malformed, or conflicting values are not affirmative
evidence and therefore fail closed before any finding disposition can authorize
an effect.

### Migration lifecycle

Readback `EXECUTE` permission must hold for all three node-principal states:

1. a principal that existed before the migration;
2. a principal enrolled while the migration's lifecycle is active; and
3. a principal enrolled after the migration has committed.

The third state requires the node-enrollment grant hook to include the readback
function, not only a one-time grant loop.

## Responsibility decision table

The table fixes the candidate semantics used by the hardening tests. “OR” is
only for responsibility evidence; safety and evidence validity remain
conjunctive fail-closed gates.

```text
safe_to_route = evidence_valid
               AND preflight.verified? == true
               AND preflight.valid? == true
               AND still_applies? == true
               AND root_cause_bounded? == true
               AND requires_new_decision? == false

responsibility_proven = introduced_by_pr? == true
                        OR invariant_violation? == true

fix_in_current_pr = safe_to_route AND responsibility_proven
```

| Evidence | Introduced by PR | Invariant violation | Scope fact | Candidate result |
| --- | ---: | ---: | --- | --- |
| valid and all safety checks pass | true | false | outside declared scope | `fix_in_current_pr` |
| valid and all safety checks pass | false | true | outside declared scope | `fix_in_current_pr` |
| valid and all safety checks pass | false | false | outside declared scope | `follow_up_required` or blocked by follow-up contract |
| missing, malformed, or conflicting | any | any | any | `blocked_unverified` |
| preflight not explicitly `true`/`true` | any | any | any | global blocked result |

`in_scope?` is retained as evidence for follow-up routing and plan context; it
is not allowed to erase either positive responsibility proof. The final
production predicate, tests, and formal docs must be updated together from this
table. Until that convergence, this draft is the source for the hardening slice
only and does not change the formal spec.

## Required state-transition fixtures

The fixtures and focused tests must cover:

- `N -> released/expired -> N+1`;
- old-generation `pending` and `unknown` effects visible under a valid current
  claim;
- old-generation effect/claim rejected as current mutation authority;
- existing worker claim, newly acquired claim, and failed claim release;
- canonical fingerprint digest or nested scope tampering;
- missing, false, unknown, malformed, and conflicting preflight evidence;
- pre-migration, migration-time, and post-migration node enrollment;
- every ownership table boundary, including responsibility OR and safety AND.

The initial contract/fixture baseline was followed on the same branch by the
implementation slice mapped to these invariants. The follow-up hardening slice
also covers the adjacent enforcement paths that can bypass the same contract:

- missing or partial finding identity cannot select an actionable disposition;
- `follow_up_required` requires explicit boolean ownership evidence with no
  conflict;
- a missing or unsupported review author is retained as untrusted evidence while
  the remaining review snapshot is preserved;
- raw actionable threads remain blocking when a finding summary is empty or
  otherwise incomplete;
- a successful autonomous readback/reconciliation cycle clears stale transient
  `global_blocker` state before applying new blockers.

Each item is covered by a focused regression or state-transition test and must
remain mapped to the canonical identity, evidence-validity, snapshot
normalization, convergence, or recovery invariant. This document remains a
draft/non-normative implementation contract and does not authorize merge,
deployment, autonomous worker activation, or owner API execution.
