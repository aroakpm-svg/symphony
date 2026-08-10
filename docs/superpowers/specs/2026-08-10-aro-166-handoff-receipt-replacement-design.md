# ARO-166 Handoff Receipt Replacement Design

**Status:** Approved after independent first-principles review

**Date:** 2026-08-10

**Repository:** `aroakpm-svg/symphony`

**Work item:** ARO-166

**Supersedes after merge:** PR #19 and its helper PR #22

## 1. Decision

Replace PR #19 with a clean implementation based on current `main`, preserving
ARO-166's safety purpose while removing local-workflow state, runtime wiring,
and ARO-165 compatibility work that do not belong to the receipt contract.

`HandoffReceiptV1` is an append-only, non-authoritative hint about the latest
checkpoint that another machine can verify from native systems. It is not a
workflow engine, an authorization record, a workspace backup, or a merge gate.

The replacement has two implementation responsibilities:

1. `SymphonyElixir.HandoffReceipt` owns the V1 value contract and a pure resume
   decision.
2. `SymphonyElixir.HandoffReceipt.Store` owns PostgreSQL append/latest access
   and row decoding.

Everything that fetches live Git, GitHub, Linear, claim, or effect-ledger state
is an ARO-167 integration responsibility.

## 2. First-principles constraints

### 2.1 Only remotely verifiable progress belongs in a cross-machine receipt

Uncommitted implementation, local test state, and a local-only commit can be
lost with the machine. A receipt must not tell another machine to skip work on
the strength of local-only evidence.

V1 therefore recognizes only these durable checkpoint kinds:

- `pushed`: the exact head exists on the canonical remote branch;
- `pull_request`: the PR exists and its head is the recorded head;
- `reviewed`: an exact-head review has been observed for that PR head.

The older `preflight`, `branch`, `implementation`, `tests`, and `commit` progress
markers are not V1 checkpoints. A new machine reconstructs those states from
native systems when no durable receipt is available.

### 2.2 One fact has one representation

V1 does not persist `current_phase`, `completed_step_ids`, and
`pending_step_ids`. Those three fields represented the same linear state and
created avoidable consistency combinations. One `checkpoint_kind` determines
the next candidate action.

V1 also does not persist:

- a local worktree fingerprint;
- a copied remote branch SHA;
- a copied Linear revision;
- separate repository owner/name values;
- prompts, conversations, free-form instructions, workspace paths, secrets, or
  arbitrary metadata.

The canonical repository is one normalized `owner/name` string. Remote head,
Linear revision, and workspace readiness are read fresh during ARO-167
integration.

### 2.3 Receipt data never authorizes a mutation

The receipt may identify the next candidate action only after fresh truth has
been supplied. Claim fencing and the effect ledger remain the mutation safety
boundaries. A receipt cannot authorize comment, push, PR creation, Resolve,
merge, deployment, or a Linear state change.

## 3. Canonical V1 contract

The exact persisted fields are:

| Field | Type | Rule |
| --- | --- | --- |
| `receipt_schema_version` | integer | Exactly `1` |
| `issue_id` | non-empty text | Must match the claim issue |
| `repository` | non-empty text | Canonical lower-case `owner/name` |
| `claim_id` | UUID | Active claim at append time |
| `generation` | positive integer | Active generation at append time |
| `checkpoint_sequence` | positive integer | Assigned by PostgreSQL |
| `recorded_at` | timestamp | Assigned by PostgreSQL |
| `checkpoint_kind` | enum | `pushed`, `pull_request`, or `reviewed` |
| `branch` | non-empty text | Canonical remote branch name |
| `head_sha` | 40-character lower-case SHA | Native revision being handed off |
| `tested_head_sha` | 40-character lower-case SHA | Must equal `head_sha` |
| `pr_number` | positive integer or null | Required for `pull_request` and `reviewed`; null for `pushed` |
| `test_results` | fixed JSON array | Non-empty; only `name` plus `passed` or `skipped` |
| `effect_operation_ids` | text array | Database-derived complete same-issue ledger snapshot at append time |

Failed tests do not create a safe checkpoint. They remain ordinary execution
evidence and require more work before append. The test policy deciding which
tests are required remains outside ARO-166; ARO-167 must provide the complete
required set before requesting an append.

`tested_head_sha` is retained even though it equals `head_sha` because it is the
explicit binding between structured test evidence and the code revision. The
database rejects a mismatch.

### 3.1 Retry and regression amendment

The receipt row shape remains V1-compatible; the installed contract registration
is version `2` because append behavior now has explicit same-generation retry
semantics:

- `(issue_id, claim_id, generation)` is bound to one repository, branch, and
  `head_sha`. A different head or branch requires a new claim generation and is
  rejected fail closed.
- The logical checkpoint identity is
  `(issue_id, claim_id, generation, head_sha, checkpoint_kind, pr_number)`.
  `pr_number` is null only for `pushed`.
- An identical checkpoint retry returns the original row without allocating a
  new database sequence. A retry with conflicting test results is rejected.
- Checkpoint rank is `pushed < pull_request < reviewed`. A delayed lower-ranked
  append returns the already recorded higher-ranked row and does not become the
  latest receipt.
- A generation cannot switch to a different pull-request identity after one is
  recorded; that change requires a new generation.

This amendment intentionally uses the existing claim lock and one unique
checkpoint-identity index. It does not add a retry ledger, caller-supplied
sequence, timestamp ordering, runtime workflow, or ARO-167 integration.

## 4. Domain API

```elixir
@type checkpoint_kind :: :pushed | :pull_request | :reviewed

@type receipt :: %{
  receipt_schema_version: 1,
  issue_id: String.t(),
  repository: String.t(),
  claim_id: String.t(),
  generation: pos_integer(),
  checkpoint_sequence: pos_integer(),
  recorded_at: DateTime.t(),
  checkpoint_kind: checkpoint_kind(),
  branch: String.t(),
  head_sha: String.t(),
  tested_head_sha: String.t(),
  pr_number: pos_integer() | nil,
  test_results: [%{name: String.t(), status: :passed | :skipped}],
  effect_operation_ids: [String.t()]
}

@type observation :: %{
  issue_id: String.t(),
  repository: String.t(),
  branch: String.t(),
  remote_head_sha: String.t(),
  pr_number: pos_integer() | nil,
  pr_head_sha: String.t() | nil,
  git_ready?: boolean(),
  linear_current?: boolean(),
  active_claim?: boolean(),
  exact_head_review_passed?: boolean(),
  effect_statuses: %{
    optional(String.t()) => :succeeded | :pending | :failed_no_effect | :unknown
  }
}

@spec resume(receipt() | nil, observation()) ::
        {:ok, :pull_request | :review | :complete}
        | {:safe_recheck, atom()}
```

`resume/2` is deterministic and performs no I/O. When native state has not
advanced beyond the receipt, it returns:

- `pushed` -> `{:ok, :pull_request}`;
- `pull_request` -> `{:ok, :review}`;
- `reviewed` -> `{:ok, :complete}`.

The `:complete` result means only that the ARO-166 handoff sequence has no later
checkpoint. It is not merge readiness or merge authority.

## 5. Resume validation

Before returning an `:ok` result, `resume/2` requires all applicable checks:

1. The decoded receipt has the exact V1 shape and satisfies all field
   invariants.
2. Observation issue, repository, and branch match the receipt.
3. `active_claim?`, `linear_current?`, and `git_ready?` are all true.
4. The native remote head equals `head_sha`.
5. For `pull_request` and `reviewed`, the native PR number and PR head equal the
   receipt.
6. For `reviewed`, `exact_head_review_passed?` is true.
7. The keys in `effect_statuses` exactly equal the receipt effect-operation
   snapshot and every status is `:succeeded`.
8. Fresh native state has not advanced beyond the receipt. A `pushed` receipt
   with an already-existing PR, or a `pull_request` receipt with an already
   completed exact-head review, returns safe recheck so the caller reconstructs
   the newer state instead of duplicating an action.

The function fails closed with one stable reason, including:

- `:receipt_missing`;
- `:receipt_incompatible`;
- `:observation_incompatible`;
- `:identity_changed`;
- `:claim_inactive`;
- `:linear_changed`;
- `:git_unready`;
- `:remote_head_changed`;
- `:pull_request_changed`;
- `:review_stale`;
- `:native_state_advanced`;
- `:effect_unsettled`.

Missing, pending, failed-no-effect, unknown, or unrecognized effect status is
unsettled. The caller must reconstruct progress from authoritative systems and
must not infer completion from the receipt.

## 6. Store and PostgreSQL boundary

`HandoffReceipt.Store` exposes only:

```elixir
@type claim_context :: %{
  issue_id: String.t(),
  claim_id: String.t(),
  generation: pos_integer(),
  node_id: String.t(),
  node_instance_id: String.t()
}

@type append_attrs :: %{
  repository: String.t(),
  checkpoint_kind: HandoffReceipt.checkpoint_kind(),
  branch: String.t(),
  head_sha: String.t(),
  tested_head_sha: String.t(),
  pr_number: pos_integer() | nil,
  test_results: [HandoffReceipt.test_result()]
}

@spec append(Postgrex.conn(), claim_context(), append_attrs()) ::
        {:ok, HandoffReceipt.receipt()} | {:error, term()}

@spec latest(Postgrex.conn(), claim_context()) ::
        {:ok, HandoffReceipt.receipt() | nil} | {:error, term()}
```

`HandoffReceipt.append/3` and `HandoffReceipt.latest/2` are thin public
delegates to the store. This preserves one caller-facing namespace while
keeping SQL, parameter ordering, and row decoding out of the domain logic.

The forward migration creates only:

- `symphony_staging.handoff_receipts`;
- `symphony_staging.append_handoff_receipt(...)`;
- `symphony_staging.latest_handoff_receipt(...)`;
- the minimum grant helper and trigger needed to grant those two functions to
  present and future enrolled node login roles;
- the contract-version record and the minimum grants needed by enrolled node
  login roles.

Database rules:

- append locks and verifies the matching active claim generation, node, and
  node instance before insertion;
- sequence and recorded time are database generated;
- runtime and ordinary API roles have no direct table privileges;
- append validates exact V1 shape and derives the complete, ordered
  `effect_operation_ids` snapshot from existing ARO-165 rows for the same issue;
  the caller cannot omit IDs and ARO-165 records are never rewritten;
- contract version 2 binds one head to a generation, returns existing rows for
  identical retries, and prevents lower-ranked late appends from becoming the
  latest receipt;
- latest requires a new active claim for the same issue and selects by
  generation descending, then checkpoint sequence descending;
- rows are never updated or deleted by runtime functions;
- the migration is confined to `symphony_staging` and never references
  `symphony_production`.

The scoped down migration removes only ARO-166 objects and its contract-version
row. ARO-167 owns the combined apply/reapply/rollback/reapply procedure and
shared-staging operator receipt.

## 7. Explicit ownership boundaries

### ARO-166 replacement owns

- the V1 domain contract;
- pure receipt validation and resume decision;
- PostgreSQL append/latest store;
- the scoped staging migration and down migration;
- focused Elixir, migration-contract, and disposable PostgreSQL tests;
- concise handoff-contract documentation.

### ARO-167 owns later

- AgentRunner and Orchestrator integration;
- Codex tool exposure and checkpoint timing;
- Git workspace and canonical-remote evidence collection;
- GitHub PR and exact-head review reads;
- Linear revision refresh;
- ClaimService integration adapters;
- EffectLedger readback API and normalized statuses;
- complete migration ordering and staging-ready handoff;
- shared-staging execution and operator receipts.

### The replacement must not modify

- `agent_runner.ex`, `orchestrator.ex`, `codex/app_server.ex`,
  `codex/dynamic_tool.ex`, `workspace.ex`, or `github_review_client.ex`;
- ARO-164 claim migration or behavior;
- ARO-165 effect-ledger migration, operation IDs, markers, or reconciliation;
- GitHub rules, branch protection, deployments, production, or secrets;
- Design 1–4 finding, settlement, authorization, or landing behavior.

### Expected replacement file manifest

- Create `elixir/lib/symphony_elixir/handoff_receipt.ex`.
- Create `elixir/lib/symphony_elixir/handoff_receipt/store.ex`.
- Create the ARO-166 forward and scoped down migrations under
  `elixir/priv/symphony_migrations/`.
- Create focused domain, store, and migration-contract tests under
  `elixir/test/symphony_elixir/`.
- Create `elixir/docs/handoff_receipts.md`.
- Modify `.github/scripts/test-cross-machine-claims.sh` only to add the bounded
  disposable ARO-166 contract exercise described below.
- Retain this design spec as the decision record.

Any additional file requires a written-spec amendment before implementation;
it must not be justified as incidental cleanup.

### Replacement publishing boundary

The original ARO-166 ticket assigned construction to PM AROAK and prohibited a
DT fork. That transport rule cannot produce the user-authorized replacement in
the current environment: live GitHub permissions on 2026-08-10 show
`digitaltriumphs-tw` has read-only access to `aroakpm-svg/symphony` and write
access to its existing fork.

The user's explicit authorization to replace PR #19 and revise the ARO-166 spec
supersedes that ticket clause only for this replacement:

- develop on the independent local `codex/aro-166-replacement` branch created
  from canonical `main`;
- reverify GitHub identity and permissions immediately before publishing;
- push the branch to `digitaltriumphs-tw/symphony` if canonical upstream push
  remains unavailable;
- open the replacement PR from that fork into `aroakpm-svg/symphony:main`;
- do not change repository rules, branch protection, credentials, or any other
  ticket's execution ownership.

Unexpected identity, loss of fork write access, or inability to target the
canonical upstream fails closed before push. The fork is publishing transport,
not a new source of truth or a transfer of runtime authority.

## 8. Treatment of PR #19 and PR #22

PR #19 and PR #22 remain frozen until the replacement is proven safe. Their
diffs and review threads are evidence, not implementation bases.

The replacement retains these validated safety properties:

- active-generation-only append;
- append-only ordering;
- V1 fail-closed decoding;
- exact test-to-head binding;
- no trust in a receipt without fresh native evidence;
- effect IDs must refer to real same-issue ledger operations;
- scoped staging-only rollback.

It deliberately excludes:

- local worktree fingerprinting and Git command parsing;
- AgentRunner, tool, and orchestrator wiring;
- copied Linear and remote-SHA fields;
- duplicated phase/completed/pending progress;
- ARO-165 primary-key rewrites, canonicalization, and legacy marker recovery;
- helper changes whose only purpose was repairing the over-broad PR #19
  integration.

Only after the replacement is merge-ready may the maintainer post one concise
superseded comment on each old PR and close them. Neither old branch is deleted,
merged, or further patched.

## 9. Design 1–4 compatibility

Design 1–4 require a receipt to remain an opaque, non-authoritative recovery
hint. This design preserves that invariant.

Before Design 2 implementation starts, its prerequisite wording must stop
requiring PR #19's exact API. The canonical dependency becomes:

- the merged replacement's `HandoffReceipt.receipt()` type;
- `HandoffReceipt.latest/2` for receipt readback;
- EffectLedger-owned status readback supplied by Design 2/ARO-167, not
  `HandoffReceipt.effect_statuses/3`.

No Design 1–4 behavior is otherwise changed by ARO-166.

## 10. Verification strategy

### Post-approval source synchronization

Written-spec approval must be reflected in the planning sources before the
implementation plan is written:

1. Revise ARO-166's Linear description so its purpose, exact V1 fields, three
   durable checkpoint kinds, ARO-167 ownership boundary, replacement branch,
   and authorized-fork publishing rule match this design. Preserve existing
   comments as history; do not rewrite ARO-165, ARO-167, or ARO-143.
2. Update the local Design 1 implementation plan references that currently say
   PR #19 owns the exact receipt type. They must consume the merged replacement
   `HandoffReceipt.receipt()` and retain fresh native revalidation.
3. Update the local Design 2 implementation plan to replace the PR #19 exact-API
   prerequisite, remove the `HandoffReceipt.effect_statuses/3` dependency, and
   use the existing/planned EffectLedger-owned readback seam.
4. Update the local Design 3 and Design 4 implementation-plan prerequisites so
   the implementation sequence waits for the merged replacement rather than PR
   #19. Their authorization and settlement behavior does not change.

These synchronization edits are planning/source-of-truth corrections, not part
of the Symphony replacement PR file manifest. If any plan needs a behavioral
change beyond dependency naming and ownership alignment, stop for a separate
design review.

### Pure Elixir tests

- exact V1 shape and unknown-key rejection;
- all three checkpoint kinds;
- SHA, repository, branch, PR, test-result, and effect-ID validation;
- test evidence must be non-empty, non-failed, and bound to `head_sha`;
- conditional PR-number requirement;
- missing/incompatible receipt safe recheck;
- each fresh-truth mismatch reason;
- pending, unknown, failed-no-effect, missing, and extra effect-status cases all
  fail closed;
- no `resume/2` result grants mutation or merge authority.

### Store and migration tests

- append/latest parameter and row decoding boundaries;
- schema and function signatures;
- table and function privilege boundaries;
- `symphony_staging`-only references;
- absence of ARO-164/165 alteration statements;
- down migration removes only ARO-166 objects.

### Disposable PostgreSQL lifecycle

Reuse the existing cross-machine claims PostgreSQL harness rather than adding a
second database workflow. Add one bounded ARO-166 section proving:

- an active generation can append;
- a stale generation cannot append;
- runtime cannot update or delete rows directly;
- sequence/latest ordering works across generations;
- malformed checkpoint/test/PR/effect evidence is rejected;
- latest requires a current claim for the same issue;
- ARO-166 rollback leaves ARO-164 claims and ARO-165 effects intact.

ARO-167 will later own the combined migration-order and staging-ready lifecycle;
this focused test proves the ARO-166 contract itself is executable.

### Final branch gates

- targeted HandoffReceipt tests;
- `mix format --check-formatted`;
- `mix specs.check`;
- strict Credo and Dialyzer through `make -C elixir all`;
- disposable PostgreSQL claims/effects/handoff check;
- `git diff --check`;
- full diff review confirming no forbidden owner file changed;
- one substantive latest-head `@codex review` and disposition of every current
  P1-P4 finding without patch looping.

## 11. Acceptance criteria

The replacement is ready to supersede PR #19/#22 only when all are true:

1. It starts from current canonical `main` and contains no old PR commit
   history.
2. Its runtime contract has exactly the fields and checkpoint kinds in this
   design.
3. Receipt validation and resume are pure and free of external-system clients.
4. Store access is limited to append/latest and is active-claim fenced.
5. No ARO-164/165 behavior or migration is rewritten.
6. No ARO-167 runtime integration is included.
7. Focused unit and disposable PostgreSQL tests prove every ARO-166 acceptance
   condition.
8. Repository gates and latest-head Codex review pass.
9. The PR is mergeable with no unresolved actionable current-head thread.
10. Only then are PR #19 and PR #22 commented as superseded and closed.
11. Publishing follows the narrow authorized-fork boundary when upstream push
    remains unavailable; no GitHub administrative setting changes.

## 12. Written-spec self-review receipt

- **Source check:** Compared against the current ARO-166 description and latest
  comments, ARO-165 and ARO-167 ownership, ARO-143's live-smoke boundary,
  current `main@eba99b7c28349a313df60e3493513d33dddc89f2`, and the final PR
  #19/#22 diffs.
- **Cohesion check:** Domain validation, persistence, and later runtime
  integration have separate owners; the replacement has no external-system
  collector.
- **Coupling check:** Receipt persistence reads existing claim/effect rows but
  does not alter their schemas or APIs. Effect status readback remains owned by
  EffectLedger integration.
- **Lightweight check:** One checkpoint enum replaces three progress fields;
  only remotely verifiable checkpoints remain.
- **Modularity check:** One domain module and one store module expose the whole
  ARO-166 API. ARO-167 consumes them without shadow types or a second receipt
  path.
- **Safety check:** Active-generation append, exact test/head binding,
  append-only rows, fresh native revalidation, strict effect-set matching, and
  fail-closed fallback are explicit acceptance criteria.
- **Scope check:** The expected file manifest is closed; any additional file
  requires a written-spec amendment.
- **Open-marker check:** No TODO, TBD, placeholder, or unresolved design choice
  remains. Implementation is intentionally pending an approved implementation
  plan.

## 13. Independent approval review

The user authorized source synchronization and plan writing if an independent
review confirmed the design met the four requested architecture standards. The
2026-08-10 review passed:

- **High cohesion:** Receipt value semantics and pure resume rules live in one
  domain module; SQL and row decoding live in one store. Runtime evidence
  collection remains wholly in ARO-167.
- **Low coupling:** The domain consumes normalized observations and imports no
  Git, GitHub, Linear, ClaimService, EffectLedger, or workspace client. The
  store reads existing claim/effect tables without changing their contracts.
- **Lightweight:** Three remotely verifiable checkpoint kinds replace eight
  local workflow steps and three overlapping progress fields. The design adds
  no coordinator, workflow engine, new CI workflow, or compatibility layer.
- **Modular:** Public types and append/latest/resume seams are explicit, the
  file manifest is closed, and Design 1–4 consume the receipt without copying
  its implementation.

`head_sha` and `tested_head_sha` are intentionally separate evidence facts:
the former identifies the remote revision and the latter identifies the tested
revision. Requiring equality prevents an untested remote head from becoming a
safe checkpoint; it is not duplicated workflow state.

Written-spec approval is therefore complete. The next authorized actions are
the source synchronization in section 10 and a Superpowers implementation
plan. Implementation remains pending that plan.
