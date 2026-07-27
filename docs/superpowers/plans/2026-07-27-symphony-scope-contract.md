# Symphony Scope Contract and PR Lint Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task by task. Use `superpowers:test-driven-development` for every behavior change, record RED and GREEN evidence, and use `publishing-with-codex-review` before publishing or merging.

**Goal:** Add one typed, fail-closed pull-request scope contract and make the existing PR-description check validate it before later review-routing work consumes it.

**Architecture:** Introduce a pure `SymphonyElixir.ScopeContract` module that parses a structured Markdown section into a typed struct plus stable validation errors. Keep GitHub I/O and review routing out of this PR. The existing Mix task will call the shared parser after its generic template checks, so both humans and later runtime code use the same contract rather than parallel rules.

**Tech Stack:** Elixir 1.19, ExUnit, existing `Mix.Tasks.PrBody.Check`, GitHub pull-request template, Markdown documentation.

**Constraints:**

- Base is `aroakpm-svg/symphony` `main` at `7d802238c56e81d90b251a34e31223e33c058c59`.
- Scope is data contract plus static validation only; do not change review routing, Linear state transitions, merge behavior, repository settings, or runtime orchestration.
- Do not classify natural language with regex or add case-specific phrases. Parse only explicit structured headings and bullet values.
- Fail closed on missing, duplicate, malformed, or placeholder contract fields.
- `Dependencies` and `Follow-Ups` may explicitly contain `None`; `Invariants`, `Acceptance Criteria`, and `Non-Goals` may not be empty.
- Preserve the existing generic PR-body checks and error aggregation.
- New production behavior must follow RED -> GREEN -> REFACTOR with the failing-test output recorded in the task receipt.
- Run verification from `elixir/`; the final branch gate is `make all`.

---

### Task 1: Add the typed Scope Contract parser

**Files:**

- Create: `elixir/lib/symphony_elixir/scope_contract.ex`
- Create: `elixir/test/symphony_elixir/scope_contract_test.exs`

**Step 1: Write failing parser tests**

Add focused ExUnit cases that exercise the real parser API and independently authored Markdown fixtures:

- a complete contract returns `%SymphonyElixir.ScopeContract{}` with `work_item`, `invariants`, `acceptance_criteria`, `non_goals`, `dependencies`, and `follow_ups`;
- missing required sections return stable typed errors instead of a partial contract;
- duplicate section headings fail closed;
- blank bullets and remaining HTML placeholder comments fail closed;
- explicit `None` is accepted only for `Dependencies` and `Follow-Ups`;
- malformed acceptance criteria without a stable identifier fail closed.

Before each test body, name the production mutation it catches. Use literal expected values; do not reuse parser helpers to construct expectations.

**Step 2: Verify RED**

Run:

```bash
mix test test/symphony_elixir/scope_contract_test.exs
```

Confirm the tests fail because `SymphonyElixir.ScopeContract` or the requested behavior does not exist, not because of fixture or compilation mistakes. Save the relevant failing output in the task receipt.

**Step 3: Implement the minimal typed parser**

Create `SymphonyElixir.ScopeContract` with:

- `@enforce_keys` and a public struct for the six contract fields;
- public `@type t` and error types;
- `@spec parse_pr_body(String.t()) :: {:ok, t()} | {:error, [error()]}`;
- deterministic parsing of the following explicit headings inside `#### Scope Contract`: `##### Work Item`, `##### Invariants`, `##### Acceptance Criteria`, `##### Non-Goals`, `##### Dependencies`, and `##### Follow-Ups`;
- bullet normalization that retains human text while rejecting blank or placeholder values;
- acceptance-criteria entries with stable identifiers such as `AC-1: description`;
- aggregated, stable validation errors suitable for CLI display.

Keep this module pure. Do not read files, call GitHub, inspect Linear, infer semantic scope from prose, or alter review state.

**Step 4: Verify GREEN and refactor**

Run:

```bash
mix test test/symphony_elixir/scope_contract_test.exs
mix format --check-formatted
```

Refactor only after the targeted tests pass. Perform the mutation check: wrong heading, wrong field mapping, missing required list, and a permissive malformed-AC branch must each be caught by at least one test.

**Step 5: Commit**

Commit only Task 1 files with a message such as:

```text
feat: add typed PR scope contract
```

Record the commit SHA and RED/GREEN commands in the SDD ledger.

---

### Task 2: Enforce the contract in PR template and lint

**Files:**

- Modify: `.github/pull_request_template.md`
- Modify: `elixir/lib/mix/tasks/pr_body.check.ex`
- Modify: `elixir/test/mix/tasks/pr_body_check_test.exs`

**Step 1: Write failing integration tests**

Update the test template and valid body to include a real Scope Contract. Add behavior tests proving:

- `mix pr_body.check --file ...` succeeds for a complete contract;
- a body that satisfies generic headings and bullets but omits one required contract field fails with the shared parser's error;
- duplicate Scope Contract subheadings fail;
- `None` in `Invariants`, `Acceptance Criteria`, or `Non-Goals` fails;
- multiple contract errors are printed in one run rather than stopping at the first error;
- generic existing errors remain present when the scope contract is also invalid.

Do not assert only that source text contains headings. Run the Mix task and assert its observable success/failure and errors.

**Step 2: Verify RED**

Run:

```bash
mix test test/mix/tasks/pr_body_check_test.exs
```

Confirm at least the new contract-enforcement case fails for the expected missing behavior. Save the relevant failing output in the task receipt.

**Step 3: Integrate the shared contract**

- Extend the repository PR template with the exact structured contract headings consumed by `SymphonyElixir.ScopeContract`.
- Provide concise HTML comments that explain each field without becoming data after authors remove template placeholders.
- Call `ScopeContract.parse_pr_body/1` from the existing lint flow and append every typed contract error to the existing generic errors.
- Preserve one final `PR body format invalid` failure and the existing successful `PR body format OK` output.
- Do not duplicate parsing or validation rules inside the Mix task.

**Step 4: Verify GREEN and compatibility**

Run:

```bash
mix test test/mix/tasks/pr_body_check_test.exs
mix test test/symphony_elixir/scope_contract_test.exs
mix format --check-formatted
```

Confirm the old generic heading, order, placeholder, bullet, and checkbox tests still pass after fixtures are migrated.

**Step 5: Commit**

Commit only Task 2 files with a message such as:

```text
feat: enforce PR scope contracts
```

Record the commit SHA and RED/GREEN commands in the SDD ledger.

---

### Task 3: Document the contract boundary and verify the branch

**Files:**

- Modify: `SPEC.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Modify: `docs/superpowers/plans/2026-07-27-symphony-scope-contract.md` only if implementation details required an explicit plan correction; do not rewrite history silently.

**Step 1: Document the runtime boundary**

Add concise documentation that states:

- scope severity and scope ownership are separate concepts;
- this PR only defines and statically validates the contract;
- later routing may consume the typed contract, but this PR does not move issues or classify findings;
- a finding may return to the same PR only after later policy proves it violates an invariant/acceptance criterion or was introduced by the PR;
- unknown ownership must fail closed and remain in review for follow-up or human disposition;
- existing PRs must update their descriptions to the structured contract when this lint runs against them.

Keep normative behavior in `SPEC.md`, operator instructions in `elixir/WORKFLOW.md`, and usage instructions in `elixir/README.md`.

**Step 2: Run targeted verification**

From `elixir/`, run:

```bash
mix test test/symphony_elixir/scope_contract_test.exs test/mix/tasks/pr_body_check_test.exs
mix format --check-formatted
mix specs.check
mix credo --strict
```

Fix only regressions introduced by this plan.

**Step 3: Run the full branch gate**

From `elixir/`, run:

```bash
make all
```

Record the exact command, exit status, and any environment caveat. Do not claim success from an older run.

**Step 4: Commit documentation**

Commit Task 3 documentation with a message such as:

```text
docs: define the PR scope contract boundary
```

Record the final commit SHA in the SDD ledger. The controller will then run a whole-branch review from the recorded merge base, publish one PR to `aroakpm-svg/symphony`, request exactly one Codex review for the current head, and address all actionable latest-head threads before merge or permission handoff.
