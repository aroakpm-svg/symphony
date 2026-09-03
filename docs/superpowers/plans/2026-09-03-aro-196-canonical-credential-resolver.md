# ARO-196 Canonical Credential Resolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one fail-closed GitHub credential resolver and authority-preflight path that validates the approved automation identity before claim and again inside the actual worker before effects.

**Architecture:** A trusted host callback resolves an opaque approved reference into a short-lived credential. A credential-scoped GitHub client validates actor, repository, permissions, branch, and head without ambient `gh`; Orchestrator discards the credential before claim, while AgentRunner resolves a fresh credential and validates the actual checkout before starting hooks or Codex.

**Tech Stack:** Elixir 1.19/OTP 28, Req, ExUnit, existing Symphony ProjectProfiles/ProjectExecutionContext/Workspace/Orchestrator boundaries.

**Spec:** `docs/superpowers/specs/2026-09-03-aro-196-canonical-credential-resolver-design.md`

## Global Constraints

- Do not create a GitHub App, installation, private key, token, credential file, Scheduled Task, or machine rollout; ARO-197 owns those actions.
- `WORKFLOW.md` contains only opaque `credential_ref` values and cannot select a source, actor, token path, executable, or permission override.
- The trusted source and expected actor come only from application/runtime options.
- Never place a token, authorization header, raw API body, credential path, or secret-derived detail in state, retry entries, health, logs, receipts, exceptions, or durable files.
- Resolve a fresh credential at the pre-claim boundary and again at the worker boundary; never retain or reuse the first credential.
- Preserve legacy single-project behavior and existing claim/capacity/retry semantics.
- Every public `def` in `elixir/lib` has an adjacent `@spec`.
- Use only the three ARO-195-approved repositories; no Production, deployment, billing, permission mutation, or workflow-write authority.
- Write each regression first, observe the intended failure, implement the smallest boundary, rerun focused tests, review the diff, and commit.
- Windows full-suite baseline on unmodified `main`: 1059/1076 passed, 13 skipped, 17 known CRLF/WSL/watchdog failures. Authoritative final gate is Linux `make all`.

## File Structure

- Create `elixir/lib/symphony_elixir/github_credential_resolver.ex`: canonical trusted-source contract and secret-safe normalization.
- Create `elixir/lib/symphony_elixir/github_authority_client.ex`: credential-scoped GitHub HTTP validation with typed safe failures.
- Create `elixir/lib/symphony_elixir/git_checkout_preflight.ex`: actual worker checkout, remote/head, and Git metadata capability checks.
- Modify `elixir/lib/symphony_elixir/project_credential_provider.ex`: consume the canonical resolver and emit only the immediate subprocess environment.
- Modify `elixir/lib/symphony_elixir/project_repo_preflight.ex`: replace ambient `gh` authority evidence with resolver/client evidence while retaining quality-contract validation.
- Modify `elixir/lib/symphony_elixir/orchestrator.ex`: invoke canonical preflight before capacity/claim and classify new failures explicitly.
- Modify `elixir/lib/symphony_elixir/agent_runner.ex`: perform fresh worker-side resolution and checkout preflight before effects.
- Create focused tests matching each new module; extend existing provider, repo-preflight, AgentRunner, and multi-project lifecycle suites.
- Update `README.md`, `SPEC.md`, `elixir/README.md`, and `elixir/docs/aro_196_acceptance.md` with the implemented contract and ARO-197 handoff.

---

### Task 1: Canonical Trusted-Source Resolver

**Files:**
- Create: `elixir/lib/symphony_elixir/github_credential_resolver.ex`
- Create: `elixir/test/symphony_elixir/github_credential_resolver_test.exs`

**Interfaces:**
- Consumes: opaque references `github-central-brain` and `github-project-management`; trusted option `:credential_source` or application `:github_credential_source`.
- Produces: `resolve/2 :: {:ok, Credential.t()} | {:error, reason()}` where `Credential` contains only `credential_ref`, private `token`, and optional `expires_at` for the current call stack.

- [ ] **Step 1: Write failing resolver-contract tests**

```elixir
assert {:ok, %Credential{credential_ref: "github-central-brain"}} =
         Resolver.resolve("github-central-brain", credential_source: source)
assert {:error, :credential_source_unconfigured} = Resolver.resolve("github-central-brain", [])
assert {:error, :credential_source_conflict} = Resolver.resolve("github-central-brain", credential_source: conflict)
assert {:error, :credential_reference_mismatch} = Resolver.resolve("github-central-brain", credential_source: wrong_ref)
assert {:error, :credential_expired} = Resolver.resolve("github-central-brain", credential_source: expired)
```

Also assert a credential-shaped sentinel never appears in `inspect(reason)`, captured logs, or raised text for missing, malformed, exception, and conflict cases.

- [ ] **Step 2: Run the focused test and prove RED**

Run: `mix test test/symphony_elixir/github_credential_resolver_test.exs --trace`
Expected: FAIL because the module/struct is undefined.

- [ ] **Step 3: Implement the resolver and bounded result types**

```elixir
@approved_refs ~w(github-central-brain github-project-management)
@spec resolve(String.t(), keyword()) :: {:ok, Credential.t()} | {:error, reason()}
def resolve(ref, opts) do
  with :ok <- approved_ref(ref),
       {:ok, source} <- source(opts),
       {:ok, result} <- invoke_source(source, ref),
       {:ok, credential} <- normalize(result, ref),
       :ok <- unexpired(credential) do
    {:ok, credential}
  end
end
```

Accept only `{:ok, %{credential_ref: ^ref, token: binary, expires_at: DateTime.t() | nil}}`; collapse exceptions and malformed values to `:credential_resolver_failed`. Never implement environment fallback.

- [ ] **Step 4: Run focused tests and public-spec check**

Run: `mix test test/symphony_elixir/github_credential_resolver_test.exs --trace && mix specs.check`
Expected: all focused tests pass and specs check exits 0.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github_credential_resolver.ex elixir/test/symphony_elixir/github_credential_resolver_test.exs
git commit -m "Add canonical GitHub credential resolver"
```

### Task 2: Credential-Scoped GitHub Authority Client

**Files:**
- Create: `elixir/lib/symphony_elixir/github_authority_client.ex`
- Create: `elixir/test/symphony_elixir/github_authority_client_test.exs`

**Interfaces:**
- Consumes: `Credential.t()`, approved profile, trusted `expected_actor`, injected `request_fun` for tests.
- Produces: `verify/3 :: {:ok, receipt()} | {:error, reason()}` with only actor, repository, pull/push booleans, default branch, and head SHA.

- [ ] **Step 1: Write failing HTTP/identity/authority tests**

```elixir
assert {:ok, %{actor: "aroak-symphony[bot]", push?: true}} = Client.verify(profile, credential, opts)
assert {:error, :github_unauthorized} = Client.verify(profile, credential, request_fun: status(401), expected_actor: actor)
assert {:error, :github_forbidden} = Client.verify(profile, credential, request_fun: status(403), expected_actor: actor)
assert {:error, :github_unexpected_actor} = Client.verify(profile, credential, request_fun: actor("human"), expected_actor: actor)
assert {:error, :github_repository_not_allowed} = Client.verify(unapproved, credential, opts)
assert {:error, :github_push_authority_missing} = Client.verify(profile, credential, request_fun: push(false), expected_actor: actor)
```

Record request headers inside the fake and assert authorization is supplied only to the request function and absent from the receipt/error/log.

- [ ] **Step 2: Run and prove RED**

Run: `mix test test/symphony_elixir/github_authority_client_test.exs --S --trace`
Expected: FAIL because the client is undefined.

- [ ] **Step 3: Implement fixed-host Req calls and strict parsers**

Use `GET /user`, `GET /repos/{owner}/{repo}`, and `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` against fixed `https://api.github.com`. Parse only `login`, `full_name`, `default_branch`, `permissions.pull`, `permissions.push`, `ref`, and `object.sha`; do not return raw bodies.

- [ ] **Step 4: Run focused tests**

Run: `mix test test/symphony_elixir/github_authority_client_test.exs --trace`
Expected: all tests pass with no sentinel in output.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github_authority_client.ex elixir/test/symphony_elixir/github_authority_client_test.exs
git commit -m "Validate GitHub automation authority"
```

### Task 3: Pre-Claim Canonical Repository Preflight

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_repo_preflight.ex`
- Modify: `elixir/test/symphony_elixir/project_repo_preflight_test.exs`
- Modify: `elixir/test/symphony_elixir/multi_project_poll_test.exs`

**Interfaces:**
- Consumes: `Resolver.resolve/2`, `GitHubAuthorityClient.verify/3`, approved profile.
- Produces: existing `{:ok, receipt} | {:blocked, blocker}` shape with secret-free actor/permission evidence added.

- [ ] **Step 1: Add failing tests proving canonical ordering and no ambient `gh`**

Assert source resolution occurs before any repository request; no `gh` executable runner is invoked; the credential is absent from the returned receipt; source/actor/permission errors map to exact blocker codes; quality-script validation remains bound to the verified head.

- [ ] **Step 2: Run and prove RED**

Run: `mix test test/symphony_elixir/project_repo_preflight_test.exs test/symphony_elixir/multi_project_poll_test.exs --trace`
Expected: failures show current ambient `gh` path and missing credential evidence.

- [ ] **Step 3: Refactor preflight around canonical resolver/client**

```elixir
with {:ok, credential} <- Resolver.resolve(profile.credential_ref, opts),
     {:ok, authority} <- Authority.verify(profile, credential, opts),
     {:ok, scripts} <- quality_contract(profile, authority.head_sha, credential, opts) do
  {:ok, secret_free_receipt(profile, authority, scripts)}
end
```

Use the credential-scoped client for `package.json`; remove production ambient `gh` execution. Retain injected fakes only through keyword options.

- [ ] **Step 4: Run focused suites**

Run: `mix test test/symphony_elixir/project_repo_preflight_test.exs test/symphony_elixir/multi_project_poll_test.exs --trace`
Expected: all focused tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/project_repo_preflight.ex elixir/test/symphony_elixir/project_repo_preflight_test.exs elixir/test/symphony_elixir/multi_project_poll_test.exs
git commit -m "Use canonical credentials before project claim"
```

### Task 4: Actual Worker Checkout and Git-Metadata Gate

**Files:**
- Create: `elixir/lib/symphony_elixir/git_checkout_preflight.ex`
- Create: `elixir/test/symphony_elixir/git_checkout_preflight_test.exs`

**Interfaces:**
- Consumes: `ProjectExecutionContext`, workspace path, credential, worker-aware injected command runner.
- Produces: `check/4 :: {:ok, receipt()} | {:error, reason()}` with repository, branch, and head only.

- [ ] **Step 1: Write failing checkout tests**

Cover approved workspace, wrong origin, wrong branch, changed remote head, `.git` missing/reparse/unwritable, local vs worker-host runner selection, and cleanup of the reversible metadata probe. Assert no credential appears in args, output, receipts, or logs.

- [ ] **Step 2: Run and prove RED**

Run: `mix test test/symphony_elixir/git_checkout_preflight_test.exs --trace`
Expected: FAIL because the worker gate is undefined.

- [ ] **Step 3: Implement composed workspace/Git checks**

Reuse existing path-safety and workspace attestation helpers. Canonicalize HTTPS/SSH GitHub origins to `owner/repo`; compare branch and SHA with the immutable context; use an atomic create/delete capability probe under `.git` with a random bounded name and guaranteed cleanup, never a commit or index mutation.

- [ ] **Step 4: Run focused tests**

Run: `mix test test/symphony_elixir/git_checkout_preflight_test.exs test/symphony_elixir/workspace_readiness_state_test.exs --trace`
Expected: new tests pass; existing relevant readiness tests retain their platform baseline.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/git_checkout_preflight.ex elixir/test/symphony_elixir/git_checkout_preflight_test.exs
git commit -m "Validate worker Git checkout authority"
```

### Task 5: Fresh Post-Claim Resolution in AgentRunner

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_credential_provider.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/project_credential_provider_test.exs`
- Modify: `elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs`

**Interfaces:**
- Consumes: canonical resolver and `GitCheckoutPreflight.check/4`.
- Produces: minimal `%{"GH_TOKEN" => token}` only after worker validation; typed secret-safe hard blockers otherwise.

- [ ] **Step 1: Add failing lifecycle tests**

Assert the source is called a second time after pre-claim, a new token sentinel is used, the first token is unavailable, WSL/SSH checks use worker runtime options, and no hook/Codex/effect runs before checkout verification. Cover every safe error mapping.

- [ ] **Step 2: Run and prove RED**

Run: `mix test test/symphony_elixir/project_credential_provider_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs --trace`
Expected: failures show the current direct provider callback and missing checkout authority gate.

- [ ] **Step 3: Wire canonical resolver and worker gate**

Resolve into a local variable, validate authority and checkout, derive the minimal child environment, then allow existing readiness/hooks/Codex flow. Do not add credential fields to structs or messages.

- [ ] **Step 4: Run focused tests and leak scans**

Run: `mix test test/symphony_elixir/project_credential_provider_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs test/symphony_elixir/subprocess_environment_test.exs --trace`
Expected: all focused tests pass and sentinels appear only in test-local assertions.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/project_credential_provider.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/project_credential_provider_test.exs elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs
git commit -m "Revalidate credentials inside project workers"
```

### Task 6: Orchestrator Failure Classification and State Secrecy

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/multi_project_poll_test.exs`

**Interfaces:**
- Consumes: new preflight blocker codes.
- Produces: explicit transient/permanent dispositions without credentials in state or observability.

- [ ] **Step 1: Write failing disposition/state tests**

Classify transport/timeouts as transient; policy, identity, source conflict, repository, and authority failures as permanent until configuration changes. Assert a credential sentinel is absent from `:sys.get_state`, retry entries, runtime-health snapshots, logs, and blocker messages.

- [ ] **Step 2: Run and prove RED**

Run: `mix test test/symphony_elixir/multi_project_poll_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs --trace`
Expected: new blocker categories are unclassified before implementation.

- [ ] **Step 3: Add exhaustive classifications and trusted option wiring**

Extend the fixed blocker lists and `@agent_runner_option_keys`; pass only resolver/client callbacks, expected actor, and worker runner—not resolved credentials. Preserve current release/retry semantics.

- [ ] **Step 4: Run focused lifecycle tests**

Run the command from Step 2 again.
Expected: all related tests pass with no state leak.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/core_test.exs elixir/test/symphony_elixir/orchestrator_status_test.exs elixir/test/symphony_elixir/multi_project_poll_test.exs
git commit -m "Classify GitHub authority blockers"
```

### Task 7: Contract Documentation and Final Verification

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `elixir/README.md`
- Create: `elixir/docs/aro_196_acceptance.md`

**Interfaces:**
- Consumes: completed resolver/preflight behavior and exact tests.
- Produces: operator contract and ARO-197 provisioning handoff without secret paths or values.

- [ ] **Step 1: Document exact configuration and ownership boundary**

Document application-only source/actor configuration, approved references/repositories, typed failures, double-resolution lifecycle, worker-local validation, legacy behavior, and the explicit prohibition on provisioning/rollout in ARO-196.

- [ ] **Step 2: Create acceptance mapping**

Map AC-1 through AC-6 to exact modules and test names. Record the Windows baseline separately from authoritative Linux validation.

- [ ] **Step 3: Run formatter and focused ARO-196 suite**

Run: `mix format --check-formatted` followed by all test files created/modified in Tasks 1-6.
Expected: formatter exits 0 and focused tests have zero failures, excluding only documented pre-existing platform cases.

- [ ] **Step 4: Run quality and security gates**

Run: `mix compile --warnings-as-errors`, `mix specs.check`, `mix credo --strict`, `mix dialyzer`, `git diff --check`, and searches for credential-shaped literals, raw authorization logging, Production/deployment changes, and files outside this plan.
Expected: zero new warnings/errors/leaks and no scope expansion.

- [ ] **Step 5: Run authoritative repository gate**

Run Linux `make -C elixir all` locally where available or push the branch and require the GitHub `make-all` check on the exact head. Compare Windows-only failures to the recorded zero-change baseline; do not repair unrelated tests in ARO-196.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md SPEC.md elixir/README.md elixir/docs/aro_196_acceptance.md
git commit -m "Document canonical GitHub credential preflight"
```

- [ ] **Step 7: Request review and converge**

Push the exact tested head, open an ARO-196 PR with the repository scope contract, request Codex review, require passing checks and no unresolved P1-P4 threads, and address only findings proven to violate this plan/spec or introduced by the PR. Do not merge automatically or move Linear to Done.
