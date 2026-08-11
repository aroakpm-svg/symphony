# Design 3 Safety Model: PR-Scoped Patch Authorization

Status: contract baseline; non-normative until the Design 2 dependency is merged and the
integration gates below are verified.

This document fixes the Design 3 safety model before production implementation. It is intentionally
independent of the current Design 2 branch. Design 3 must not copy an unmerged Design 2 module,
create a local replacement, or infer that a missing owner API is complete.

## Scope

Design 3 governs only bounded authorization to apply code patches for findings already classified as
`fix_in_current_pr` by Design 2.

It owns:

- PR-scoped authorization slots;
- deterministic, reconstructable budget projection;
- correction-slot qualification;
- human authorization-request and approval binding;
- stop, retry, reconciliation, and fail-closed outcomes.

It does not own:

- finding identity or classification;
- managed patch-publish effect identity, fingerprint encoding, or native reconciliation;
- EffectLedger normalization or migrations;
- claim acquisition, lease ownership, or receipt authority;
- review settlement, merge readiness, merge, Resolve, Linear `Done`, deployment, production,
  permissions, secrets, credentials, or worker activation.

When a Design 2 owner API is missing or incompatible, Design 3 returns a blocked result. It does
not add a local stub, second ledger, second publisher, second claim path, or alternate operation-ID
codec.

## Core authority rule

```text
Patch authority belongs to a PR-scoped authorization slot, not to a worker, node, generation,
session, commit count, review round, comment count, receipt field, or mutable batch counter.
```

Every slot authorizes at most one logical managed patch-publish operation. A retry or handoff may
reconcile the same operation, but it cannot mint a new operation by changing worker, generation,
operation ID, or local state.

The resulting grant authorizes only the bounded patch lifecycle. It never grants merge, review
settlement, issue transition, deployment, production, permission, secret, or credential authority.

## Stable slots

Each PR has two fixed automatic slot identities:

| Slot | Authority | Eligibility |
|---|---|---|
| `automatic_initial_v1` | First complete reviewed snapshot | All currently eligible `fix_in_current_pr` findings in that immutable snapshot |
| `automatic_correction_v1` | One bounded correction | A verified regression caused by the initial patch, or a missed acceptance failure from the original issue |

Human slots are created only from a unique managed authorization request, one exact GitHub approval
comment, and one verified human actor identity:

```text
{:human, request_id, approval_comment_id, verified_actor_id}
```

The human slot does not reset or consume the automatic-slot history. One approval comment ID cannot
create two human slots.

There is no authoritative `batch_count`. The words "first round" and "correction round" may appear
in human-readable output but are not security state.

## Authoritative evidence and projection

`PatchBudgetProjection` is a read-only value rebuilt on every authorization attempt. It is not a
database, table, service, mutable counter, or worker-owned cache.

The only authoritative inputs are:

1. Design 2's normalized managed-publish ledger projection;
2. GitHub native head, commit, ref, managed-request, and approval evidence;
3. Design 2's verified FindingKey set and finding-set digest;
4. verified human authorization evidence when the human path is reached.

The roles remain separate:

| Component | Allowed responsibility | Not authority for |
|---|---|---|
| ClaimService | Prevent concurrent mutation and expose the current claim context | Historical budget or slot consumption |
| HandoffReceiptV1 | Opaque recovery hint | Slot state, approval, or patch permission |
| Design 2 | FindingKey, classification, managed publish identity/effect, ledger readback, reconciliation, publisher | Human policy or Design 3 slot semantics |
| GitHub | Native remote and comment evidence | Local classification or approval interpretation |
| Design 3 | Slot projection and exact authorization binding | Rebuilding Design 2 identity or publishing itself |

Every machine with the same verified inputs must derive the same projection. Missing, stale,
malformed, contradictory, or unverified evidence is not treated as an empty history.

## Five derived slot states

Each slot has exactly one derived state:

| Evidence | State | Allowed behavior |
|---|---|---|
| No matching verified managed intent | `available` | Create one matching intent if all other gates pass |
| Matching intent is pending or unknown | `reserved_unresolved` | Reconcile that operation only; create no new operation |
| Ledger and GitHub native readback prove the expected success | `consumed` | No reuse |
| The same operation is proven to have had no external effect | `reserved_failed_no_effect` | Continue only the same operation under existing Design 2 policy |
| Ledger, fingerprint, identity, native state, or request evidence conflicts | `blocked_conflict` | Global fail closed; require human investigation |

`reserved_failed_no_effect` is not `available`. It cannot be converted into a new batch by changing
the operation ID. If safe continuation of the original operation is not supported by Design 2,
the result is blocked.

## State-transition invariants

The following transitions are the only valid automatic lifecycle:

```text
available
  -> reserved_unresolved  when the one matching intent is durably created
  -> consumed             when the same operation's expected native effect is verified
  -> reserved_failed_no_effect when the same operation is durably proven to have no effect

reserved_unresolved
  -> consumed             after successful reconciliation
  -> reserved_failed_no_effect after verified no-effect reconciliation
  -> reserved_unresolved when still pending or unknown
  -> blocked_conflict     on any contradictory evidence

reserved_failed_no_effect
  -> reserved_unresolved only by continuing the same operation under Design 2 policy
  -> blocked_conflict on contradiction

consumed
  -> consumed only; never available again

blocked_conflict
  -> blocked_conflict until a fresh, human-reviewed evidence decision exists
```

Invalid transitions fail closed:

- pending or unknown cannot become a fresh slot;
- consumed cannot become available;
- failed-no-effect cannot mint a second operation;
- a new worker or generation cannot reset a slot;
- a new finding cannot be added to an existing authorization snapshot;
- a changed head cannot inherit an old request or approval;
- a changed FindingKey set cannot inherit an old request or approval.

## Automatic slot rules

`automatic_initial_v1` is eligible only when the current Design 2 snapshot is complete and all
`fix_in_current_pr` findings are verified against the same evaluated head. Design 2 remains the
sole classifier; Design 3 does not infer eligibility from prose, review-round count, comments, or
worker state.

`automatic_correction_v1` requires objective evidence for one of exactly two bases:

1. the initial managed patch directly caused the regression; or
2. the initial eligible snapshot missed an acceptance criterion already present in the original
   issue.

Correction evidence must bind the initial operation, initial resulting head, initial evaluated
head, current evaluated head, initial FindingKey-set digest, acceptance criterion when applicable,
and a stable evidence reference. A new feature, new security decision, new permission or secret
decision, opportunistic improvement, or unbounded review request cannot consume this slot.

The absence of a human authority policy does not block an eligible automatic slot. Human policy is
loaded only when the human request or approval path is reached.

## Human authorization model

When both automatic slots are unavailable but eligible current-scope findings remain, the runtime
creates or reconciles one idempotent managed authorization request. The human-facing command is
exactly:

```text
批准再修一輪
```

Only outer whitespace may be ignored. No lowercase conversion, translation, punctuation
normalization, LLM interpretation, or free-text synonym is allowed.

The request fingerprint is immutable and contains:

- profile version;
- repository and PR number;
- current evaluated head SHA;
- Design 2 canonical sorted FindingKey-set digest;
- human-readable eligible-finding summary;
- policy version;
- expected next transition;
- request identity.

Before accepting an approval, runtime must prove all of the following:

1. The actor has verified authority under the injected policy.
2. Exactly one active managed request matches the request identity.
3. The current head equals the request head.
4. The current Design 2 eligible FindingKey-set digest equals the request digest.
5. The approval command matches exactly after outer whitespace trimming.
6. The approval comment ID has never been used.
7. The policy version and actor identity are present, verified, and consistent.

Request evidence is not trusted merely because its marker decodes or its fields exist. Runtime
reconstructs the canonical request ID and immutable request fingerprint from the verified request
fields and compares both values before using the request. A missing, extra, or changed
fingerprinted field, including the expected transition or human summary, is an identity conflict
and fails closed.

If the request head or FindingKey set changes before the matching intent is established, the old
request and approval are stale. They cannot transfer to the new snapshot; runtime must stop and
produce a new deduplicated request. If a matching intent already exists, only the expected
fingerprint-bound transition is accepted.

Human policy absence, unknown policy result, missing actor identity, ambiguous active request,
stale head, changed FindingKey set, reused approval comment, and fingerprint conflict all fail
closed. None can fall back to display-only `human_owner` text or repository permissions inferred
from prose.

## Operation and effect ownership

Design 3 uses an opaque Design 2 managed-publish identity. It does not:

- name or recreate the Design 2 patch-publish effect atom;
- serialize or hash FindingKeys itself;
- derive a competing operation ID;
- validate or reconcile the patch payload itself;
- call the raw patch-publish adapter.

The only Design 3-owned external effect is the managed authorization-request comment, and it must
use the existing `:github_comment` EffectLedger path. There is exactly one request-comment create
and reconciliation path inside the `PatchAuthorization.authorize/5` wrapper. ReviewMonitor must not
call the raw GitHub adapter directly.

The sole public Design 3 orchestration result is one of:

```elixir
{:ok, grant}
{:authorization_required, managed_request}
{:reconcile, evidence}
{:blocked, reason}
```

Only `{:ok, grant}` may be passed unchanged to the Design 2 publisher after the dependency is
present. `{:authorization_required, ...}` retains review state and creates no patch. `{:reconcile,
...}` invokes Design 2 reconciliation only. `{:blocked, ...}` performs no request, publish,
tracker transition, merge, deployment, or secret mutation.

## Claim and recovery order

Design 3 reuses the existing lifecycle and adds no ClaimService API:

```text
acquire active claim
→ read HandoffReceiptV1 as an opaque hint
→ read Design 2 ledger projection
→ read GitHub native and authorization evidence
→ reconcile pending/unknown effects
→ rebuild PatchBudgetProjection
→ create one intent only for one eligible available slot
```

Before routing an `{:ok, grant}` across an asynchronous boundary, runtime rechecks active claim
ownership. Claim release is cleanup, not authority evidence. A receipt row is never a substitute
for current claim, Design 2 ledger, GitHub state, or authorization evidence.

Worker restart, node handoff, higher generation, retry, timeout, and changed local state do not
reset slots or change the request snapshot.

## Fail-closed decision table

| Evidence condition | Design 3 result | Side effect allowed |
|---|---|---|
| Design 2 contract missing or incompatible | `{:blocked, :design2_contract_unavailable}` | None |
| Non-`fix_in_current_pr` finding supplied | `{:blocked, {:invalid_finding_disposition, value}}` | None |
| Finding evaluated on another head | `{:blocked, :finding_evaluated_head_mismatch}` | None |
| No matching intent and eligible automatic slot | `{:ok, grant}` | One Design 2 intent/publish handoff |
| Pending or unknown intent | `{:reconcile, evidence}` | Same-operation reconciliation only |
| Contradictory identity, fingerprint, or native evidence | `{:blocked, :operation_fingerprint_conflict}` or specific conflict | None |
| Automatic slots unavailable, no active request | `{:authorization_required, request}` | One idempotent request comment |
| Approval command is not exact | `{:blocked, :invalid_authorization_command}` | None |
| Actor missing, unknown, or unauthorized | `{:blocked, reason}` | None |
| Request head changed | `{:blocked, :authorization_request_stale}` | None; new request required |
| FindingKey set changed | `{:blocked, :authorization_finding_set_changed}` | None; new request required |
| Approval comment already used | `{:blocked, :approval_comment_already_used}` | None |
| Human policy absent or unknown | `{:blocked, :authorization_policy_unavailable}` | None on human path |

The table is normative for implementation and tests. A new branch must be assigned to an existing
row or stop as an unverified blocker; it must not invent a permissive fallback.

## Required negative and state-transition fixtures

Before runtime integration, tests must cover at least:

- no intent → initial slot available;
- pending and unknown intent → same reconciliation result;
- native success → consumed;
- verified no-effect → same operation remains reserved;
- same operation ID with a different fingerprint → conflict;
- three nodes with identical evidence → identical projection;
- initial patch regression → correction slot eligible;
- missed original acceptance failure → correction slot eligible;
- new feature or new scope → correction slot unavailable;
- no active request → authorization required;
- multiple active requests → ambiguous and blocked;
- exact command succeeds; free-text synonym fails;
- missing, unknown, and unauthorized actor fail closed;
- stale request head fails closed;
- changed FindingKey set fails closed;
- reused approval comment fails closed;
- missing policy blocks human path but does not block an eligible automatic slot;
- inactive claim prevents ledger, GitHub, request, and publish calls;
- reconciliation never creates a second operation;
- blocked results never call raw GitHub create, publisher, merge, Resolve, or tracker mutation.

Each production behavior must be preceded by a focused failing test that demonstrates the missing
behavior. A test that passes before the implementation is not evidence of the new contract.

## Dependency gates

Design 3 may proceed with pure contract/projection work on the latest merged `main`, but the
following remain hard gates for runtime integration:

1. Design 2 PR #25 must merge and its canonical FindingKey, finding-set digest, managed publish
   identity/effect validation, correction verifier, reconciliation, publisher, and
   `EffectLedger.list_operations/2` must be present on the actual base tree.
2. Design 2's readback migration must be installed where integration is verified; Design 3 adds no
   replacement migration.
3. ARO-166/PR #23 and the merged retry follow-up are dependencies only as the opaque handoff hint;
   Design 3 does not reimplement or infer receipt authority.
4. Design 1 is not required to implement the pure authorization policy wrapper, but it later owns
   activation of `aroak_autonomous_v1` and selection/verification of the production human authority
   policy.
5. Until these gates pass, missing Design 2 owner APIs return blocked and no worker, shared staging,
   deployment, or Production action is allowed.

## Acceptance mapping

| Acceptance | Safety-model proof required |
|---|---|
| PR-scoped, worker-independent budget | Stable slot identity and three-node projection fixture |
| No mutable counter/service | Source scan plus projection type contains no counter |
| Two automatic slots, one operation each | Slot transition and duplicate-operation fixtures |
| Correction is bounded | Regression/missed-acceptance evidence matrix |
| Pending/unknown recovery | Reserved-state reconciliation fixture |
| Failed-no-effect cannot mint a batch | Same-operation continuation fixture |
| Plain human command | Exact command test and free-text rejection |
| Exact-head and FindingKey binding | Stale head and changed-set fixtures |
| One approval comment, one human slot | Reuse test with same comment ID |
| Claim fence | Inactive claim integration test |
| No merge or unrelated mutation authority | Capability-boundary source and runtime tests |
| Missing Design 2 API fails closed | Dependency-gate test |

## Explicit non-goals

Design 3 does not enable `aroak_autonomous_v1`, start workers, use shared staging credentials,
deploy, touch Production, merge PRs, resolve review conversations, mark Linear issues Done, or
authorize Design 4 settlement or Design 1 Landing. Those are separate owner decisions and gates.
