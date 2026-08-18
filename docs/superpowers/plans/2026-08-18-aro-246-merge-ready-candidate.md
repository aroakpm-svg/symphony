# ARO-246 MergeReadyCandidate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fail-closed, exact-head `MergeReadyCandidate` that tells a human when a Symphony PR is safe to merge without performing the merge, changing Linear, deploying, or activating a worker.

**Architecture:** A new pure `MergeReadyCandidate` module owns validation, blocker ordering, candidate identity, and live-snapshot matching. A separate `MergeReadyEvidence` boundary performs the final GitHub/Linear reads, while `ReviewMonitor` invokes both only after the existing Design 4 settlement flow completes. Configuration supports only the default `landing.mode: human`; all unsupported or incomplete inputs block.

**Tech Stack:** Elixir 1.19, OTP 28, Ecto embedded configuration schemas, ExUnit, GitHub/Linear readback adapters, Credo, Dialyzer.

**Spec:** `docs/superpowers/specs/2026-08-18-aro-246-merge-ready-candidate-design.md`

## Global Constraints

- Landing mode is `:human`; ARO-246 must not implement or accept automatic landing.
- No code path may merge a PR, enqueue a merge, mark Linear Done, deploy, modify branch protection, or activate a worker.
- Missing, malformed, contradictory, stale, pending, failed, and unknown evidence all fail closed.
- A candidate is immutable, not persisted, and never substitutes for a final native read.
- Candidate identity is bound to repository, PR, Linear issue, base SHA, and exact head SHA.
- Public functions require adjacent `@spec` declarations.
- Keep Design 2 classification, Design 3 authorization, and Design 4 settlement ownership unchanged.
- The required repository gate is `make all`; GitHub Actions is authoritative where the local Windows environment lacks `make` or the Elixir toolchain.
- Update `SPEC.md`, `README.md`, and `elixir/README.md` whenever runtime behavior or configuration changes.

---

## File Structure

- Create `elixir/lib/symphony_elixir/merge_ready_candidate.ex`: pure contracts, validation, blocker ordering, canonical digest, and live-snapshot matching.
- Create `elixir/lib/symphony_elixir/merge_ready_evidence.ex`: final authoritative GitHub/Linear readback and evidence normalization; no mutations.
- Create `elixir/test/symphony_elixir/merge_ready_candidate_test.exs`: pure success, failure, identity, recurrence, and determinism matrix.
- Create `elixir/test/symphony_elixir/merge_ready_evidence_test.exs`: provider availability, native re-read, Linear mapping, and fail-closed normalization tests.
- Modify `elixir/lib/symphony_elixir/config/schema.ex`: add the closed `landing.mode` configuration with human default.
- Modify `elixir/test/symphony_elixir/workspace_and_config_test.exs`: parse/default/rejection tests for landing mode.
- Modify `elixir/lib/symphony_elixir/review_monitor.ex`: invoke candidate derivation only at the terminal settlement seam and store a truthful result without mutation.
- Modify `elixir/test/symphony_elixir/review_convergence_test.exs`: terminal integration, no-rerun, no-mutation, restart, and drift tests.
- Modify `SPEC.md`, `README.md`, and `elixir/README.md`: document proof semantics, invalidation, human handoff, and non-goals.
- Modify `docs/superpowers/specs/2026-08-18-aro-246-merge-ready-candidate-design.md` only if implementation discovers a genuine contract discrepancy; do not silently diverge.

### Task 1: Pure candidate contract and canonical identity

**Files:**
- Create: `elixir/lib/symphony_elixir/merge_ready_candidate.ex`
- Create: `elixir/test/symphony_elixir/merge_ready_candidate_test.exs`

**Interfaces:**
- Consumes: normalized `final_evidence` and `native_snapshot` maps defined below; no external clients.
- Produces: `MergeReadyCandidate.derive/3`, `MergeReadyCandidate.matches_live_snapshot?/2`, `candidate`, and canonical blocker receipts used by Tasks 2 and 4.

- [ ] **Step 1: Write the success, determinism, and exact-identity failing tests**

Create fixtures whose exact public shapes are:

```elixir
defp valid_evidence do
  %{
    repository: "aroakpm-svg/symphony",
    pull_request_number: 42,
    linear_issue_id: "issue-246",
    linear_issue_identifier: "ARO-246",
    linear_revision: "2026-08-18T00:00:00Z",
    base_sha: sha("b"),
    evaluated_head_sha: sha("a"),
    tested_head_sha: sha("a"),
    handoff_receipt: %{status: :verified, head_sha: sha("a"), contract_version: 2},
    compatibility_receipts: %{
      aro_143: receipt(:aro_143),
      aro_170: receipt(:aro_170),
      aro_171: receipt(:aro_171),
      aro_167: receipt(:aro_167),
      aro_135: receipt(:aro_135)
    },
    settled_findings: [%{finding_key_digest: digest("finding-1"), status: :settled}],
    pending_effects: [],
    unknown_effects: [],
    blocked_findings: [],
    stale_evidence: [],
    conflicts: [],
    safety_stops: [],
    acceptance: %{status: :complete, evidence_refs: ["test:merge-ready"]},
    review_policy: %{status: :satisfied, reviewed_head_sha: sha("a")},
    evidence_refs: ["receipt:design4"],
    derived_at: ~U[2026-08-18 00:00:00Z]
  }
end

defp valid_snapshot do
  %{
    repository: "aroakpm-svg/symphony",
    pull_request_number: 42,
    linear_issue_id: "issue-246",
    linear_issue_identifier: "ARO-246",
    linear_revision: "2026-08-18T00:00:00Z",
    state: :open,
    draft?: false,
    mergeable?: true,
    conflict?: false,
    base_sha: sha("b"),
    current_head_sha: sha("a"),
    required_checks: [
      %{name: "make-all", status: :completed, conclusion: :success},
      %{name: "validate-pr-description", status: :completed, conclusion: :success}
    ],
    exact_head_review: %{status: :accepted, head_sha: sha("a")},
    trusted_actionable_threads: []
  }
end
```

Assert `derive(valid_evidence(), valid_snapshot(), landing_mode: :human)` returns
`{:ok, candidate}` with schema version `1`, exact identities, sorted checks and
findings, and a 64-character lowercase SHA-256 digest. Reorder every input map
and list and assert the semantic candidate and digest remain identical.

- [ ] **Step 2: Run the focused test and verify the RED state**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/merge_ready_candidate_test.exs
```

Expected: compilation fails because `SymphonyElixir.MergeReadyCandidate` does
not exist.

- [ ] **Step 3: Implement the minimal public types, derive success path, and canonical digest**

Implement adjacent public specs:

```elixir
@spec derive(final_evidence(), native_snapshot(), keyword()) ::
        {:ok, candidate()} | {:blocked, [blocker_receipt()]}
def derive(evidence, snapshot, opts)

@spec matches_live_snapshot?(candidate(), native_snapshot()) :: boolean()
def matches_live_snapshot?(candidate, snapshot)
```

Use a private versioned projection such as:

```elixir
[
  "merge-ready-candidate-v1",
  candidate.repository,
  Integer.to_string(candidate.pull_request_number),
  candidate.linear_issue_id,
  candidate.linear_revision,
  candidate.base_sha,
  candidate.head_sha,
  Enum.join(candidate.required_checks, ","),
  Enum.join(candidate.settled_finding_digests, ","),
  Enum.join(candidate.evidence_refs, ",")
]
|> Enum.map_join("\n", &encode_component/1)
|> then(&:crypto.hash(:sha256, &1))
|> Base.encode16(case: :lower)
```

`encode_component/1` must length-prefix binary values so delimiter characters
cannot create ambiguous identities. `derived_at` is included as evidence but
excluded from the digest so identical proof inputs are retry-idempotent.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same focused test. Expected: success and no warnings.

- [ ] **Step 5: Add the fail-closed blocker matrix tests**

Use `Enum.each/2` table tests for:

```elixir
[
  {:unsupported_landing_mode, [landing_mode: :automatic]},
  {:identity_changed, put_in(valid_snapshot(), [:repository], "other/repo")},
  {:head_changed, put_in(valid_snapshot(), [:current_head_sha], sha("c"))},
  {:pull_request_not_open, put_in(valid_snapshot(), [:state], :closed)},
  {:pull_request_draft, put_in(valid_snapshot(), [:draft?], true)},
  {:merge_conflict, put_in(valid_snapshot(), [:conflict?], true)},
  {:required_check_unsettled, pending_check_snapshot()},
  {:review_stale, put_in(valid_snapshot(), [:exact_head_review, :head_sha], sha("c"))},
  {:actionable_review_remaining, put_in(valid_snapshot(), [:trusted_actionable_threads], ["thread-1"])},
  {:finding_unsettled, put_in(valid_evidence(), [:settled_findings], [])},
  {:effect_unknown, put_in(valid_evidence(), [:unknown_effects], ["operation-1"])},
  {:safety_stop_present, put_in(valid_evidence(), [:safety_stops], [:operator_stop])},
  {:acceptance_incomplete, put_in(valid_evidence(), [:acceptance, :status], :incomplete)},
  {:linear_mapping_unverified, put_in(valid_snapshot(), [:linear_revision], "later")}
]
```

Also test nil, missing keys, strings replacing booleans/atoms, malformed SHA,
unknown check conclusions, duplicate/conflicting checks, stale handoff, each
missing compatibility receipt, and contradictory settled/unsettled finding
identities. Assert blockers use the precedence and canonical ordering in the
design spec.

- [ ] **Step 6: Implement strict validation and blocker collection**

Build small private validators by responsibility:

```elixir
defp contract_blockers(evidence, snapshot, mode)
defp identity_blockers(evidence, snapshot)
defp pull_request_blockers(snapshot)
defp compatibility_blockers(evidence)
defp check_blockers(snapshot)
defp review_blockers(evidence, snapshot)
defp settlement_blockers(evidence)
defp acceptance_blockers(evidence, snapshot)
```

Each returns blocker receipts; concatenate in the specified precedence. Do not
coerce truthy values, turn nil into empty lists, or accept unrecognized atoms.
Only create a candidate when the final blocker list is empty.

- [ ] **Step 7: Add live drift, recurrence, and restart tests**

Assert `matches_live_snapshot?/2` becomes false for head/base movement, PR
state change, check-set change, reopened/new actionable thread, stale review,
and Linear revision change. Reconstruct the candidate from reordered fixtures
and assert the digest matches after a simulated process restart.

- [ ] **Step 8: Implement live-snapshot matching and run quality checks**

Implement matching through the same normalized canonical projection used by
derivation; do not patch candidate fields in place.

Run:

```powershell
mix format --check-formatted lib/symphony_elixir/merge_ready_candidate.ex test/symphony_elixir/merge_ready_candidate_test.exs
mix test test/symphony_elixir/merge_ready_candidate_test.exs
mix specs.check
mix credo --strict lib/symphony_elixir/merge_ready_candidate.ex test/symphony_elixir/merge_ready_candidate_test.exs
```

Expected: all commands pass.

- [ ] **Step 9: Commit the pure domain component**

```powershell
git add elixir/lib/symphony_elixir/merge_ready_candidate.ex elixir/test/symphony_elixir/merge_ready_candidate_test.exs
git commit -m "feat: derive exact-head merge-ready candidates"
```

### Task 2: Final authoritative evidence provider

**Files:**
- Create: `elixir/lib/symphony_elixir/merge_ready_evidence.ex`
- Create: `elixir/test/symphony_elixir/merge_ready_evidence_test.exs`

**Interfaces:**
- Consumes: `Linear.Issue.t()`, Design 4 `landing_evidence`, review settings, and explicit read-only dependencies.
- Produces: `MergeReadyEvidence.read/4 :: {:ok, final_evidence, native_snapshot} | {:error, blocker_atom}` for Task 4.

- [ ] **Step 1: Write failing provider contract tests**

Define fake review and tracker modules. The review fake must record a fresh
`snapshot(repository, branch)` call. The tracker fake must record a fresh
`fetch_routed_issues_by_states(states)` call and return the current issue.

Test this public boundary:

```elixir
@spec read(Issue.t(), map(), map(), keyword()) ::
        {:ok, MergeReadyCandidate.final_evidence(), MergeReadyCandidate.native_snapshot()}
        | {:error, atom()}
```

The dependency keyword is exactly:

```elixir
[
  review_client: FakeReviewClient,
  tracker: FakeTracker,
  required_compatibility_receipts: [:aro_143, :aro_170, :aro_171, :aro_167, :aro_135],
  now: fn -> ~U[2026-08-18 00:00:00Z] end
]
```

Assert it re-reads both systems, selects the same Linear issue ID, preserves
`updated_at` as the Linear revision, and binds all landing evidence to the
fresh snapshot's repository/PR/base/head.

- [ ] **Step 2: Run the provider test and verify RED**

```powershell
mix test test/symphony_elixir/merge_ready_evidence_test.exs
```

Expected: missing-module compilation failure.

- [ ] **Step 3: Implement the read-only provider and normalization boundary**

`read/4` must:

1. validate the issue ID, identifier, branch, and `updated_at`;
2. call the review client for a fresh native snapshot;
3. call the tracker for a fresh issue list using review and in-progress states;
4. find exactly one current issue with the same ID and identifier;
5. reject duplicate, absent, changed, unroutable, or malformed issue results;
6. normalize GitHub check/review/thread facts without manufacturing defaults;
7. merge only allowlisted Design 1-4 landing evidence keys;
8. return bounded blocker atoms such as `:github_readback_unavailable`,
   `:linear_readback_unavailable`, `:linear_mapping_unverified`, and
   `:landing_evidence_incompatible`.

Do not call `create_comment/2`, `update_issue_state/2`, `publish_status/5`, or
any GitHub mutation method.

- [ ] **Step 4: Add provider failure and identity-fence tests**

Cover unavailable provider, malformed response, timeout/error tuple, zero or
duplicate Linear matches, changed identifier/revision, head drift, base drift,
PR number drift, absent required-check fields, nil review evidence, malformed
settlement lists, and missing compatibility receipt. Assert no mutation fake
receives a call.

- [ ] **Step 5: Run focused checks and commit**

```powershell
mix format --check-formatted lib/symphony_elixir/merge_ready_evidence.ex test/symphony_elixir/merge_ready_evidence_test.exs
mix test test/symphony_elixir/merge_ready_candidate_test.exs test/symphony_elixir/merge_ready_evidence_test.exs
mix specs.check
mix credo --strict lib/symphony_elixir/merge_ready_evidence.ex test/symphony_elixir/merge_ready_evidence_test.exs
git add elixir/lib/symphony_elixir/merge_ready_evidence.ex elixir/test/symphony_elixir/merge_ready_evidence_test.exs
git commit -m "feat: collect final merge-ready evidence"
```

Expected: all checks pass and the commit contains no external mutation call.

### Task 3: Closed human-only landing configuration

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: optional `landing.mode` from `WORKFLOW.md` front matter.
- Produces: `settings.landing.mode == :human` for Task 4; all other values are invalid.

- [ ] **Step 1: Write failing default and validation tests**

Add assertions:

```elixir
assert Config.settings!().landing.mode == :human
assert {:ok, settings} = Schema.parse(%{"landing" => %{"mode" => "human"}})
assert settings.landing.mode == :human

assert {:error, {:invalid_workflow_config, message}} =
         Schema.parse(%{"landing" => %{"mode" => "automatic"}})

assert message =~ "landing.mode"
```

Also reject nil-after-explicit-key, booleans, maps, lists, blank strings, and
unknown modes. Confirm an omitted landing block remains human.

- [ ] **Step 2: Run focused config tests and verify RED**

```powershell
mix test test/symphony_elixir/workspace_and_config_test.exs
```

Expected: `settings.landing` is undefined.

- [ ] **Step 3: Implement the embedded Landing schema**

Add a focused embedded module:

```elixir
defmodule Landing do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false

  embedded_schema do
    field(:mode, Ecto.Enum, values: [human: "human"], default: :human)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:mode], empty_values: [])
    |> validate_required([:mode])
  end
end
```

Embed it with `defaults_to_struct: true` and cast it in the root changeset. Do
not add an automatic enum value or an environment override.

- [ ] **Step 4: Run config checks and commit**

```powershell
mix format --check-formatted lib/symphony_elixir/config/schema.ex test/symphony_elixir/workspace_and_config_test.exs
mix test test/symphony_elixir/workspace_and_config_test.exs
mix specs.check
git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: default landing to human mode"
```

Expected: focused tests pass and unsupported modes fail during configuration parsing.

### Task 4: Terminal ReviewMonitor integration with no mutation

**Files:**
- Modify: `elixir/lib/symphony_elixir/review_monitor.ex`
- Modify: `elixir/test/symphony_elixir/review_convergence_test.exs`

**Interfaces:**
- Consumes: Task 2 `MergeReadyEvidence.read/4`, Task 1 `derive/3` and `matches_live_snapshot?/2`, and Task 3 `settings.landing.mode`.
- Produces: terminal entry result `{:merge_ready_candidate, candidate}` or `{:merge_ready_blocked, blockers}`; never an external mutation.

- [ ] **Step 1: Write the failing terminal success integration test**

Construct an autonomous issue whose current Design 4 path returns complete
settlement evidence. Inject:

```elixir
options = %{
  profile: :aroak_autonomous_v1,
  merge_ready_evidence: FakeMergeReadyEvidence,
  merge_ready_candidate: MergeReadyCandidate,
  landing_mode: :human,
  # existing claim/effect/settlement dependencies remain explicit
}
```

Assert one poll stores:

```elixir
assert {:merge_ready_candidate, candidate} = state[issue.id].terminal_result
assert candidate.head_sha == exact_head
```

Assert no `create_comment`, `update_issue_state`, review request, publish
status, PR update, merge, claim reacquisition, or Design 2/3 rerun message is
received after Design 4 completion.

- [ ] **Step 2: Run the focused integration test and verify RED**

```powershell
mix test test/symphony_elixir/review_convergence_test.exs --only merge_ready
```

Expected: the terminal result remains the pre-ARO-246 settlement shape.

- [ ] **Step 3: Add one terminal helper and minimal aliases**

Add a private helper with a focused runtime map rather than more high-arity
parameters:

```elixir
defp derive_merge_ready(entry, landing_evidence, %{
       issue: issue,
       settings: settings,
       review_client: review_client,
       tracker: tracker,
       options: options
     }) do
  provider = Map.get(options, :merge_ready_evidence, MergeReadyEvidence)
  candidate_module = Map.get(options, :merge_ready_candidate, MergeReadyCandidate)
  mode = Map.get(options, :landing_mode, Config.settings!().landing.mode)
  deps = [
    review_client: review_client,
    tracker: tracker,
    required_compatibility_receipts: [:aro_143, :aro_170, :aro_171, :aro_167, :aro_135],
    now: Map.get(options, :now, &DateTime.utc_now/0)
  ]

  with {:ok, evidence, snapshot} <- provider.read(issue, landing_evidence, settings, deps),
       {:ok, candidate} <- candidate_module.derive(evidence, snapshot, landing_mode: mode),
       {:ok, _fresh_evidence, fresh_snapshot} <- provider.read(issue, landing_evidence, settings, deps),
       true <- candidate_module.matches_live_snapshot?(candidate, fresh_snapshot) do
    {:ok, %{entry | terminal_result: {:merge_ready_candidate, candidate}}}
  else
    {:blocked, blockers} -> {:ok, %{entry | terminal_result: {:merge_ready_blocked, blockers}}}
    {:error, reason} -> {:ok, %{entry | terminal_result: {:merge_ready_blocked, [%{code: reason}]}}}
    false -> {:ok, %{entry | terminal_result: {:merge_ready_blocked, [%{code: :live_snapshot_changed}]}}}
  end
end
```

Use the helper only after a complete settlement result. Preserve claim release
semantics and do not call it for grants, pending effects, blocked findings,
invalid settlement, or incomplete evidence.

- [ ] **Step 4: Add terminal blockers, drift, restart, and no-rerun tests**

Cover provider unavailable, candidate blockers, second-read head drift,
second-read new thread, second-read check change, human mode default,
unsupported injected mode, and restart from durable Design 4 evidence. Count
calls to Design 2 classifier, Design 3 authorizer, and Design 4 settlement so a
completed terminal entry does not rerun them on the next poll unless native
evidence invalidates the candidate.

On invalidation, assert the result becomes `{:merge_ready_blocked, blockers}`;
never retain a stale candidate.

- [ ] **Step 5: Run integration and regression tests**

```powershell
mix format --check-formatted lib/symphony_elixir/review_monitor.ex test/symphony_elixir/review_convergence_test.exs
mix test test/symphony_elixir/review_convergence_test.exs
mix test test/symphony_elixir/merge_ready_candidate_test.exs test/symphony_elixir/merge_ready_evidence_test.exs
mix specs.check
mix credo --strict lib/symphony_elixir/review_monitor.ex
```

Expected: all tests pass, no existing grant/settlement/release behavior regresses,
and no test observes an external mutation from landing.

- [ ] **Step 6: Commit terminal integration**

```powershell
git add elixir/lib/symphony_elixir/review_monitor.ex elixir/test/symphony_elixir/review_convergence_test.exs
git commit -m "feat: expose human merge-ready results"
```

### Task 5: Contract documentation and acceptance mapping

**Files:**
- Modify: `SPEC.md`
- Modify: `README.md`
- Modify: `elixir/README.md`
- Verify: `docs/superpowers/specs/2026-08-18-aro-246-merge-ready-candidate-design.md`

**Interfaces:**
- Consumes: the implemented public API and terminal result shapes from Tasks 1-4.
- Produces: operator-facing truth about proof, invalidation, human action, and explicit non-authorization.

- [ ] **Step 1: Add the normative SPEC section**

Document the exact predicate, schemas, blocker precedence, canonical digest,
two-read live fence, recurrence invalidation, and terminal results:

```text
{:merge_ready_candidate, candidate}
{:merge_ready_blocked, blocker_receipts}
```

State that neither result is merge authority and that a candidate is invalid
after any native drift.

- [ ] **Step 2: Add concise README operator guidance**

In both READMEs, document:

```yaml
landing:
  mode: human
```

Explain in plain language: green candidate means a maintainer may recheck the
GitHub UI and press Merge; Symphony does not press it and does not mark Linear
Done. Blocked means inspect blocker atoms and refresh evidence rather than
bypass rules.

- [ ] **Step 3: Add the ARO-246 acceptance receipt table**

Map each acceptance criterion to concrete evidence:

| Criterion | Source | Test |
| --- | --- | --- |
| exact-head candidate | `merge_ready_candidate.ex` | success and H1->H2 tests |
| fail-closed evidence | candidate/evidence modules | malformed/unknown matrix |
| final live re-read | `review_monitor.ex` | second-read drift tests |
| human-only landing | config and monitor | no-mutation tests |
| restart/idempotency | pure digest and monitor | restart tests |

Do not claim Production, deployment, auto-merge, or Linear state-transition
evidence.

- [ ] **Step 4: Verify documentation consistency and commit**

```powershell
rg -n "MergeReadyCandidate|merge_ready_candidate|landing:|mode: human|does not merge|Linear Done" SPEC.md README.md elixir/README.md docs/superpowers/specs/2026-08-18-aro-246-merge-ready-candidate-design.md
rg -n "TODO|TBD|implement later|automatic landing is enabled" SPEC.md README.md elixir/README.md
git diff --check
git add SPEC.md README.md elixir/README.md
git commit -m "docs: define the human landing boundary"
```

Expected: all four sources agree and no unsupported capability is documented.

### Task 6: Full verification and truthful handoff

**Files:**
- Verify all files changed by Tasks 1-5.
- Modify only directly failing ARO-246 files when a gate exposes a defect; no unrelated cleanup.

**Interfaces:**
- Consumes: completed implementation and documentation.
- Produces: a clean, reviewable branch with an evidence-backed verification receipt.

- [ ] **Step 1: Inspect scope before running full gates**

```powershell
git status --short
git diff origin/main...HEAD --stat
git diff origin/main...HEAD --name-only
```

Expected: only the closed file set in this plan plus the approved design and
implementation plan. Stop if migrations, deployment files, GitHub settings,
or unrelated runtime modules appear.

- [ ] **Step 2: Run the complete repository verification**

From `elixir/`:

```powershell
mix format --check-formatted
mix test --cover
mix specs.check
mix credo --strict
mix dialyzer
```

From repository root, where available:

```powershell
make all
git diff --check
```

Expected: all tests pass, coverage is 100%, Dialyzer reports zero errors, and
all repository gates pass. If local Windows lacks `make` or Elixir, record that
exact environment limitation and use GitHub Actions after publishing; do not
describe an unrun command as passing.

- [ ] **Step 3: Audit for forbidden mutations and automatic landing**

```powershell
rg -n "mergePullRequest|gh pr merge|update_issue_state|Done|deploy|Production|mode: :automatic|automatic.*landing" elixir/lib/symphony_elixir/merge_ready_candidate.ex elixir/lib/symphony_elixir/merge_ready_evidence.ex elixir/lib/symphony_elixir/review_monitor.ex
```

Expected: no new automatic merge, Linear Done, deployment, Production, or
automatic-mode path. Existing unrelated tracker calls elsewhere in
`review_monitor.ex` must not be reachable from `derive_merge_ready/3`; confirm
this with the no-mutation tests rather than deleting existing behavior.

- [ ] **Step 4: Review the full diff against the approved design**

Check every design section against a concrete source/test/doc location. Verify
public specs are adjacent, evidence keys are consistent, blocker ordering is
stable, and no candidate store was added.

- [ ] **Step 5: Commit any direct verification corrections**

Only if the preceding gates required an ARO-246 correction:

```powershell
git add <only-the-directly-corrected-ARO-246-files>
git commit -m "fix: satisfy ARO-246 verification gates"
```

Re-run the failed gate and every downstream gate before continuing.

- [ ] **Step 6: Prepare the publishing and review receipt**

Record:

- final full head SHA;
- focused and full test counts;
- coverage percentage;
- formatter, specs, Credo, and Dialyzer results;
- `make all` local result or exact environment limitation;
- confirmation that no auto-merge/Linear/deploy mutation exists;
- confirmation that the worktree is clean.

Do not push, open a PR, merge, change Linear, or alter repository rules unless
the user separately authorizes that publication step.
