# ARO-197 GitHub App Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved node-local GitHub App credential source and produce a reversible three-node rollout package.

**Architecture:** An explicitly enabled module callback reads node-local configuration for each invocation, signs an App JWT, and requests a token narrowed to one fixed repository. The existing ARO-196 resolver and authority checks remain the only consumer and authorization gate.

**Tech Stack:** Elixir 1.19, OTP `:public_key`, Req, ExUnit, PowerShell/WSL operator procedures.

**Spec:** `docs/superpowers/specs/2026-09-07-aro-197-github-app-rollout-design.md`

## Global Constraints

- Only the two existing opaque credential references may mint worker tokens.
- Tokens, JWTs, private keys, authorization headers, and full secret paths never enter durable state or diagnostics.
- The GitHub App installation allowlist is exactly three repositories; the dispatch manifest remains exactly two profiles.
- Do not enable a Scheduled Task or create external credentials until the action-time approval gate.

---

### Task 1: Repository-scoped App token source

**Files:**
- Create: `elixir/lib/symphony_elixir/github_app_credential_source.ex`
- Test: `elixir/test/symphony_elixir/github_app_credential_source_test.exs`

**Interfaces:**
- Consumes: `resolve/1` opaque refs and node-local `SYMPHONY_GITHUB_APP_*` settings.
- Produces: `resolve(String.t()) :: {:ok, %{credential_ref: String.t(), token: binary(), expires_at: DateTime.t()}} | {:error, :missing | :conflict | :failed}`.

- [ ] Write failing tests for both exact ref mappings, one repository per POST body, fresh minting on every call, GitHub expiry preservation, invalid refs/config/key/responses, and secret-free errors.
- [ ] Run `mix test test/symphony_elixir/github_app_credential_source_test.exs` and confirm the module is missing.
- [ ] Implement JWT encoding/signing with `:public_key`, protected key-path validation, bounded Req POST, and strict response parsing.
- [ ] Run the focused test and confirm all cases pass.
- [ ] Commit the source and tests.

### Task 2: Explicit runtime enablement

**Files:**
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Test: `elixir/test/symphony_elixir/cli_test.exs`

**Interfaces:**
- Consumes: `--github-app` plus non-secret expected actor from the dedicated runtime environment.
- Produces: application source module and `expected_actor` option before OTP startup.

- [ ] Add failing CLI tests for explicit enablement, missing actor/config, existing conflicting source/actor, and unchanged legacy startup.
- [ ] Run the focused CLI tests and confirm the new switch is rejected.
- [ ] Add the switch and a pre-start configuration function that stores only the module and expected actor.
- [ ] Run the focused CLI and resolver suites.
- [ ] Commit the runtime wiring.

### Task 3: Operator contract and rollback package

**Files:**
- Create: `elixir/docs/aro_197_rollout.md`
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`

**Interfaces:**
- Consumes: merged source behavior and ARO-195 decisions.
- Produces: exact App settings, masked receipt schema, Amy/Matt/Han sequencing, smoke checks, stop conditions, and rollback steps.

- [ ] Document the exact permissions and three-repository installation allowlist without secret values or secret paths.
- [ ] Document separate per-node key creation, protected local storage requirements, two Codex profile homes, HTTPS/hook migration, and disabled-task dry preflight.
- [ ] Document actor/source, cross-repo denial, rotation/revocation, old-key rejection, and rollback receipt fields.
- [ ] Scan the diff for token/private-key literals and forbidden deployment or ARO-285 claims.
- [ ] Commit the operator contract.

### Task 4: Quality and review gate

**Files:**
- Modify only files required by findings from the exact changed scope.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: reviewable ARO-197 PR head; no external provisioning.

- [ ] Run focused resolver, authority, preflight, CLI, and new source tests.
- [ ] Run `mix format --check-formatted`, `mix specs.check`, `mix credo --strict`, `mix test --cover`, and `mix dialyzer` using Elixir 1.19.
- [ ] Fix only reproduced ARO-197 failures and rerun the affected gate.
- [ ] Push the branch, create the PR, and request latest-head review.
- [ ] Stop at the action-time gate before GitHub App/private-key creation or machine rollout.
