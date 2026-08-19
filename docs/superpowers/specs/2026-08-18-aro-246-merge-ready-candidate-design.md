# ARO-246 MergeReadyCandidate and Human Landing Gate Design

**Status:** Proposed for written-spec approval

**Date:** 2026-08-18

**Repository:** `aroakpm-svg/symphony`

**Work item:** ARO-246

## 1. Decision

Implement Design 1 as a fail-closed, evidence-only merge-readiness boundary.
Symphony may derive an immutable `MergeReadyCandidate` after all earlier design
stages have completed and fresh native evidence agrees. It must not merge the
pull request, mark Linear Done, deploy, or activate an autonomous landing
worker.

The selected landing mode is `human`. A maintainer remains the only actor that
performs the final GitHub merge and any subsequent Linear state transition.

## 2. Scope and non-goals

ARO-246 owns:

- canonical final evidence normalization;
- pure merge-readiness derivation;
- exact repository, PR, base, and head identity checks;
- final live GitHub and Linear revalidation;
- deterministic blocker receipts;
- the `human` landing-mode boundary;
- integration at the terminal `ReviewMonitor` seam after Design 4 reports
  `{:finding_complete, landing_evidence}`;
- tests and documentation for this boundary.

ARO-246 does not own:

- GitHub merge execution or merge-queue enrollment;
- automatic Linear status changes;
- deployment, Production credentials, worker activation, or scheduling;
- re-running Design 2 classification, Design 3 authorization, or Design 4
  settlement;
- replacing `ReadinessGate`, which is an earlier pre-agent gate;
- persisting candidates as a new source of truth;
- changing branch protection or bypassing repository rules.

## 3. Architecture

### 3.1 Pure candidate derivation

Create `SymphonyElixir.MergeReadyCandidate` as an independent pure domain
module. Its public boundary is:

```elixir
@spec derive(final_evidence(), native_snapshot(), keyword()) ::
        {:ok, candidate()} | {:blocked, [blocker_receipt()]}

@spec matches_live_snapshot?(candidate(), native_snapshot()) :: boolean()
```

`derive/3` performs no I/O and no mutation. Callers must supply normalized
evidence collected from authoritative systems. It returns a candidate only
when every required fact is present, well-formed, current, and mutually
consistent. Missing and unknown values never mean empty or successful.

`matches_live_snapshot?/2` is a final identity fence. It confirms that the
candidate still describes the exact current repository, PR, base SHA, head
SHA, Linear issue mapping, review state, and required-check set. Any drift
invalidates the candidate and requires fresh derivation.

### 3.2 Evidence model

`final_evidence` contains the completed internal proof chain:

- the ARO-166 handoff identity and tested head;
- canonical repository, PR number, base SHA, and evaluated head SHA;
- the verified Linear issue mapping;
- acceptance-criteria completion;
- exact-head review-policy result;
- Design 4 per-finding settlement results;
- compatibility receipts required from ARO-143, ARO-170, ARO-171, ARO-167,
  and ARO-135;
- explicit pending, unknown, blocked, stale, conflict, and safety-stop lists;
- evidence references and contract versions needed to audit the decision.

`native_snapshot` contains freshly read external truth:

- repository and PR identity;
- PR open/non-draft state;
- current base and head SHAs;
- mergeability and conflict state;
- required-check names and terminal conclusions;
- exact-head trusted review evidence;
- trusted actionable review-thread count;
- Linear issue identity and current mapping revision.

The collector that performs GitHub and Linear I/O remains outside the pure
module. Production integration must use the repository's existing formal
readback providers; test maps are not a production fallback.

### 3.3 Candidate contract

A successful candidate is immutable data containing:

- `candidate_schema_version`;
- repository, PR number, Linear issue ID;
- exact base and head SHAs;
- derived-at timestamp supplied by the caller;
- canonical evidence references and contract versions;
- the sorted required-check identities;
- the sorted settled-finding identities;
- a canonical candidate digest.

The digest is computed from a versioned canonical field projection with stable
ordering and explicit value encodings. It must not depend on map iteration
order, timestamps generated inside the pure function, or arbitrary Erlang term
serialization.

The candidate is a short-lived proof, not merge authority. It is not stored in
a new table and cannot substitute for a fresh native snapshot.

## 4. Readiness predicate

`derive/3` succeeds only when all conditions are true:

1. The PR is open and not draft.
2. Repository, PR, Linear issue, base SHA, evaluated head SHA, tested head SHA,
   and current native head are complete and consistent.
3. Every configured required check is present, terminal, and successful for
   the exact head; unexpected absence or an unknown conclusion blocks.
4. The exact-head review policy is satisfied.
5. No trusted actionable review thread remains.
6. Every canonical finding has a verified terminal Design 4 settlement.
7. Pending, unknown, blocked, stale, conflict, and safety-stop lists are all
   explicitly present and empty.
8. Acceptance evidence is complete for the exact ticket and head.
9. The Linear issue mapping and its native revision are verified.
10. All required compatibility receipts are present, current, identity-bound,
    and supported.
11. The PR is mergeable and has no native conflict.

The predicate is conjunctive. No individual success, including green CI or a
clean Codex review, can compensate for missing evidence elsewhere.

## 5. Deterministic blockers and precedence

Failure returns one or more stable blocker receipts. Each receipt contains a
blocker atom, the affected identity, and bounded evidence references; it does
not contain arbitrary external payloads.

Validation uses this precedence so callers and tests receive stable results:

1. malformed or unsupported contract;
2. repository, PR, Linear, base, or head identity mismatch;
3. inactive/closed/draft/conflicted PR state;
4. stale or incomplete compatibility and handoff receipts;
5. required-check missing, pending, unknown, or failed;
6. exact-head review missing or stale;
7. trusted actionable review thread present;
8. settlement, pending-effect, blocked, conflict, or safety-stop evidence;
9. incomplete acceptance or Linear mapping evidence.

Representative blocker atoms include `:evidence_incompatible`,
`:identity_changed`, `:head_changed`, `:pull_request_not_open`,
`:pull_request_draft`, `:merge_conflict`, `:required_check_unsettled`,
`:review_stale`, `:actionable_review_remaining`, `:finding_unsettled`,
`:effect_unknown`, `:safety_stop_present`, `:acceptance_incomplete`, and
`:linear_mapping_unverified`.

All applicable blockers may be returned, but their ordering is canonical.

## 6. Live revalidation and recurrence

Candidate derivation occurs only after final native reads. Immediately before
the candidate is exposed to a human landing surface, the caller obtains a new
snapshot and applies `matches_live_snapshot?/2`.

The following events invalidate an existing candidate:

- head or base movement;
- PR identity, open/draft, mergeability, or conflict change;
- required-check set or conclusion change;
- a new or reopened trusted actionable review thread;
- review evidence no longer referring to the exact head;
- Linear mapping revision or issue identity change;
- any settlement, effect, blocker, conflict, acceptance, or safety evidence
  becoming stale or contradictory.

Invalidation is not repaired by editing the candidate. The complete evidence
chain is read and derived again. Repeated input produces the same semantic
result and digest, making retries idempotent.

## 7. ReviewMonitor integration

The only integration point is the terminal path where the existing claimed
flow returns `{:finding_complete, landing_evidence}`.

At that point `ReviewMonitor` may:

1. collect formal native GitHub and Linear snapshots;
2. normalize the completed Design 1-4 evidence;
3. call `MergeReadyCandidate.derive/3`;
4. perform one final live-snapshot match;
5. expose either the candidate or deterministic blockers to the owner-facing
   result.

This seam must not acquire a new claim, repeat earlier classification or
settlement, resolve threads, push code, comment, merge, or change Linear.
Keeping derivation independent prevents more landing policy from accumulating
inside `ReviewMonitor`.

## 8. Landing mode boundary

Add a documented landing configuration whose supported value in this scope is:

```elixir
landing: [mode: :human]
```

The default is `:human`. In human mode, a verified candidate is reported to the
maintainer and no external mutation occurs. Missing, invalid, or unsupported
mode values fail closed; they do not enable automatic behavior.

An `:automatic` mode is deliberately not implemented or accepted by ARO-246.
Enabling managed landing later requires a separate approved design, explicit
runtime activation, credentials, effect-ledger operations, native readback,
and rollout evidence.

## 9. Error handling and observability

- Provider unavailable, malformed response, rate limit, timeout, and unknown
  status all become blockers.
- External error text is bounded and redacted before appearing in evidence
  references.
- Logs identify the issue, PR, exact head, candidate digest when present, and
  stable blocker atoms; they never claim that a merge happened.
- A successful derivation is described as `merge_ready_candidate`, not
  `merged`, `landed`, or `done`.
- A failure after earlier success invalidates the earlier candidate and emits
  a new blocker result rather than silently retaining readiness.

## 10. Test strategy

Implementation follows test-driven development. The test matrix covers:

### Pure domain tests

- fully valid evidence produces the canonical candidate;
- deterministic digest and blocker ordering across map/list ordering;
- every required field rejects nil, unknown, malformed, and contradictory
  values;
- required CI failure, pending status, unknown conclusion, and missing check;
- exact-head review missing or stale;
- new/reopened actionable comment;
- incomplete or mismatched Design 4 settlement;
- pending/unknown effects and safety stops;
- incomplete acceptance and stale Linear mapping;
- missing/stale/mismatched compatibility receipts;
- unsupported landing mode.

### Transition and identity tests

- H1 candidate invalidates when native head becomes H2;
- base SHA, PR identity, repository, or Linear mapping drift invalidates;
- check-set or review-thread recurrence invalidates;
- identical evidence is idempotent across poll and process restart;
- stale candidate data cannot be updated in place to match a new snapshot.

### Integration tests

- production terminal entry derives only after `:finding_complete`;
- formal GitHub/Linear providers are used and unavailable providers fail
  closed;
- blocker results perform no external mutation;
- human-mode success performs no merge and no Linear transition;
- earlier Design 2-4 stages are not rerun;
- logs and owner-facing result use truthful candidate language.

### Repository gates

- targeted tests;
- full Elixir test suite with 100% coverage;
- formatter;
- `mix specs.check`;
- strict Credo;
- Dialyzer;
- `make all` in GitHub Actions;
- `git diff --check`;
- exact-latest-head Codex review with all actionable threads resolved.

## 11. Documentation and rollout

Update `SPEC.md`, the root README, `elixir/README.md`, and the relevant runtime
configuration documentation to state:

- what a candidate proves;
- what it does not authorize;
- the complete fail-closed predicate;
- candidate invalidation rules;
- `landing.mode: :human` as the only supported/default mode;
- the human merge and Linear completion handoff.

ARO-246 acceptance mapping must link each ticket criterion to its source,
test, or documentation evidence. The pull request remains a normal code change:
no repository settings, deployment state, Production resource, or worker is
modified.

## 12. Acceptance criteria

ARO-246 is complete when:

1. `MergeReadyCandidate` is a pure, independently tested module.
2. Complete exact-head evidence produces one deterministic immutable candidate.
3. Missing, stale, conflicting, unknown, or malformed evidence blocks.
4. Live head, review, check, PR, or Linear drift invalidates the candidate.
5. The terminal ReviewMonitor seam uses formal providers without rerunning
   earlier stages.
6. Human mode is the only supported/default landing mode.
7. No code path merges, marks Linear Done, deploys, or activates a worker.
8. Tests cover the success, failure, recurrence, restart, and identity matrix.
9. Documentation and ARO-246 acceptance mapping match the implemented
   contract.
10. Repository gates and exact-latest-head review pass with no unresolved
    actionable thread.

## 13. Written-spec self-review receipt

- **Cohesion:** Candidate validation, canonical identity, digest, and blocker
  semantics have one domain owner.
- **Coupling:** External systems are represented by normalized evidence;
  GitHub and Linear clients do not enter the pure module.
- **Safety:** The entire predicate is fail closed, live revalidation is
  mandatory, and a candidate grants no mutation authority.
- **Scope:** Automatic merge, Linear Done, deployment, worker activation,
  branch protection, and earlier Design stages are explicitly excluded.
- **Modularity:** `ReviewMonitor` supplies one terminal seam instead of owning
  another dispersed condition tree.
- **Durability:** No candidate store is introduced; native systems and existing
  receipts remain authoritative after restart.
- **Testability:** Pure, transition, integration, and repository-gate tests are
  separated and cover boundary failures without a full Cartesian explosion.
- **Decision check:** The design implements the user's selected option A and
  contains no hidden automatic landing path.
- **Open-marker check:** No TODO, TBD, placeholder, or unresolved design choice
  remains. Implementation is pending written-spec approval and a separate
  implementation plan.
