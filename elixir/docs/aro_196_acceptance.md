# ARO-196 acceptance map

ARO-196 implements the consuming side of the canonical GitHub credential and authority boundary.
It does not provision credentials or claim that a live three-machine deployment has passed.

## Contract

Amy, Matt, and Han each run their own node-local Symphony. Han runs Symphony locally inside WSL,
not as Amy's SSH worker. Enabled `project_profiles` requires absent/empty `worker.ssh_hosts`.
Startup and new-work poll/dispatch/retry admission reject nonempty hosts with
`profiled_ssh_topology_unsupported`; direct profiled runner remote-host overrides fail before
credential resolution. Runtime settings remain readable after a topology-invalid reload for
active local reconciliation, lease, and cleanup obligations. Legacy unprofiled SSH is unchanged.
Lower-level remote defensive/test seams do not prove supported profiled remote execution.

ARO-197 owns provisioning and rollout; ARO-285 owns live acceptance. Synthetic tests do not prove
live WSL or three-machine acceptance.

- Trusted application/runtime configuration selects one credential source and the expected
  dedicated automation actor. Workflow and issue content contain only an approved opaque reference.
- Duplicate same-runtime credential sources conflict. No fallback to another runtime is allowed.
- The complete ARO-196 dispatch manifest has two mappings: `github-central-brain` to
  `aroakpm-svg/aroak-central-brain` and `github-project-management` to
  `aroakpm-svg/aroak-project-management`.
- The distinct ARO-195 GitHub App installation allowlist has three repositories: the two dispatch
  targets plus `aroakpm-svg/symphony`. Installation access to `symphony` does not create a third
  dispatch profile.
- There is no fallback to environment tokens, ambient `gh`, Git credential helpers, repository
  state, controller credentials for remote workers, or another profile.
- A fresh credential validates actor, repository pull/push authority, default branch, exact head,
  and the quality contract before claim and is discarded. A second fresh credential repeats full
  authority validation inside the selected worker before checkout validation or lifecycle effects.
- Actor evidence is the fixed installation-compatible GraphQL `viewer.login` read. Partial/errors
  responses fail closed, and missing/hidden repositories or refs (404) are permanent blockers.
- Newly-created profiled workspaces must first use the selected worker seam to bootstrap only the
  approved repository/canonical branch at the freshly verified head; partial attempts are removed
  through exact attested cleanup and arbitrary `after_create` runs only after validation.
- Each node-local runtime, including Symphony inside WSL, must validate its exact namespaced
  checkout, canonical origin, branch and head, remote head, and safe writable Git metadata.
- Origins must be canonical HTTPS GitHub URLs, never SSH. The fixed credential-protocol helper
  accompanies the validated credential through readiness, hooks, and Codex while HOME stays isolated.
  Checkout failure rolls back only fresh attested workspaces, preserving reused work and existing homes.
- Credentials, headers, raw bodies, paths, and secret-derived details are excluded from state,
  retries, health, logs, receipts, commands, workspace artifacts, and durable files.

## Acceptance criteria and evidence

`local_profile_topology_test.exs` covers Config/startup admission, poll and both retry paths,
active-local reconciliation after reload, explicit runner rejection, and legacy SSH compatibility.

| Criterion | Implementation | Focused evidence |
| --- | --- | --- |
| AC-1: exactly one trusted source; competing and ambient sources fail closed | `GitHubCredentialResolver`, `ProjectCredentialProvider` | `github_credential_resolver_test.exs`: “resolves an approved reference through the trusted source”, “fails closed when no trusted source is configured”, “rejects competing source results”; `project_credential_provider_test.exs`: “resolves only the context reference through the canonical source” |
| AC-2: actor and read/push authority before claim and again in the worker | `GitHubAuthorityClient`, `ProjectRepoPreflight`, `AgentRunner` | `github_authority_client_test.exs`: “returns only verified actor and repository authority evidence”; `project_repo_preflight_test.exs`: “resolves before GitHub requests and returns only secret-free authority evidence”; `readiness_gate_agent_runner_test.exs`: “post-claim gate freshly verifies authority before checkout and only then returns child env” |
| AC-3: repository bootstrap, checkout, origin, branch, remote head, and Git metadata stay bound | `RepositoryBootstrap`, `GitCheckoutPreflight`, `ProjectExecutionContext` | `repository_bootstrap_test.exs`: bounded bootstrap, worker seam, credential sink, and cleanup; `git_checkout_preflight_test.exs`: exact new checkout, exact reused issue branch, wrong origin/branch/head drift, metadata safety/writability, remote attestation, and cleanup |
| AC-4: secrets do not enter state, observability, failures, or files | Resolver/client/preflight bounded errors, `SubprocessEnvironment`, Orchestrator | `github_authority_client_test.exs`: header/body containment; `project_repo_preflight_test.exs`: secret-safe failures; `orchestrator_status_test.exs`: “an actual preclaim credential is absent from live state health logs and serialized state”; `readiness_gate_agent_runner_test.exs`: hook-output redaction |
| AC-5: multi-project policy fails closed and legacy single-project behavior is unchanged | `Orchestrator`, optional `project_profiles` branch | `core_test.exs`: canonical blocker classifications and post-claim dispositions; existing legacy lifecycle tests in `core_test.exs`; `multi_project_poll_test.exs` profile isolation tests |
| AC-6: focused suites and quality gates converge; host provisioning needs no policy change | Public resolver/source contract and injected worker-local seams | All ARO-196 created/modified focused tests plus `mix specs.check`, compiler, Credo, Dialyzer, diff, and scope/leak scans recorded below |

## Verification boundary

The unmodified Windows baseline recorded before ARO-196 was 1059 of 1076 tests passing, 13
skipped, and 17 failures. Those failures were pre-existing CRLF-sensitive parser cases,
WSL-dependent cases, and a watchdog timeout; they are not evidence for or against ARO-196.

Local focused and quality-gate results must be recorded against the exact branch head. The
authoritative merge gate remains Linux `make all` (or the repository's GitHub `make-all` check) on
the exact pushed head. A Windows-only baseline comparison cannot replace that Linux result.

Local verification on 2026-09-03 covered implementation head `3f26611` plus documentation-only
working-tree changes:

- The 10 ARO-196 created/modified focused suites passed: 199 tests, 0 failures.
- `mix compile --warnings-as-errors`, `mix specs.check`, and `mix dialyzer` passed; Dialyzer reported
  zero errors.
- `git diff --check` and credential-literal, authorization/logging, deployment, and changed-file
  scope scans found no leak or unauthorized operational change.
- The repository-wide formatter remains blocked by pre-existing Windows LF/CRLF differences in
  unrelated files. The focused formatter check is affected by the same existing line-ending state.
- Credo 1.7.16 crashes while tokenizing existing files under local Elixir 1.20.2; the project target
  is Elixir 1.19. This is a tool/runtime failure, not a reported ARO-196 finding.
- No installed WSL Linux distribution was available, so Linux `make all` was not run locally. The
  GitHub `make-all` check on the exact pushed head remains mandatory before merge.

## Ownership handoff

ARO-197 may implement the approved host source and provision the dedicated GitHub App/Bot on Amy,
Matt, and Han for the three-repository installation allowlist, then validate rotation, revocation,
rollback, and actual runtime identity. It must not weaken the resolver, expected-actor, allowlist,
double-validation, worker-local, or secret-lifetime boundaries, and it must not add a `symphony`
dispatch profile. ARO-285 performs the final live two-project acceptance. Neither activity is
completed or authorized by this document.

ARO-197 also owns explicit legacy SSH-origin and cloning-hook migration; runtime validation does
not rewrite a reused repository's configuration automatically.
