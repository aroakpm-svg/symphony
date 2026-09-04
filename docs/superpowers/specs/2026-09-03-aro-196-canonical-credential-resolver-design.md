# ARO-196 Canonical Credential Resolver and GitHub Preflight Design

**Date:** 2026-09-03
**Status:** Proposed for human review
**Work item:** ARO-196 / ARO-171B

## Purpose

Topology clarified 2026-09-04:

Amy, Matt, and Han each run their own node-local Symphony. Han runs Symphony locally inside WSL,
not as Amy's SSH worker. Enabled `project_profiles` requires absent/empty `worker.ssh_hosts`.
Startup and new-work poll/dispatch/retry admission reject nonempty hosts with
`profiled_ssh_topology_unsupported`; direct profiled runner remote-host overrides fail before
credential resolution. Runtime settings remain readable after a topology-invalid reload for
active local reconciliation, lease, and cleanup obligations. Legacy unprofiled SSH is unchanged.
Lower-level remote defensive/test seams do not prove supported profiled remote execution.

This user-confirmed topology supersedes earlier broad profiled SSH claims and the speculative
2026-09-04 worker-lifecycle proposal. No remote credential transport is implemented.

Implement one canonical, fail-closed GitHub credential-resolution and authority-preflight path for
Symphony's approved multi-project workers. The implementation consumes the ARO-195 decision: a
dedicated GitHub App/Bot identity, short-lived installation credentials, an explicit repository
allowlist, and least-privilege permissions.

This work does not create a GitHub App, installation, private key, token, machine credential, or
scheduled task. ARO-197 owns provisioning, three-machine rollout, rotation/revocation smoke, and
rollback. ARO-285 owns the final live multi-project acceptance.

## Confirmed Problem

The current multi-project dispatch path performs `ProjectRepoPreflight.check/1` before claim and
workspace creation, but that preflight invokes ambient `gh`. The selected project credential is not
resolved until `AgentRunner` starts after claim. This ordering has three consequences:

1. preflight can prove the human desktop credential rather than the background worker identity;
2. competing `GH_TOKEN`, `GITHUB_TOKEN`, Git Credential Manager, GitHub CLI, or WSL sources are not
   rejected by one canonical policy; and
3. a successful Windows `gh` probe can be incorrectly treated as evidence for Han's WSL runtime.

Passing a credential through orchestrator state would fix the ordering symptom but violate the
secret-lifetime boundary. The root correction is to resolve and validate a fresh credential at each
effect boundary without retaining it.

## ARO-195 Decision Consumed by This Design

- Canonical automation identity: dedicated GitHub App/Bot, distinct from the human
  `aroakpm-svg` identity.
- Approved repositories:
  - `aroakpm-svg/symphony`
  - `aroakpm-svg/aroak-central-brain`
  - `aroakpm-svg/aroak-project-management`
- Baseline permissions: Metadata read, Contents read/write, Pull requests read/write, Checks read.
- Administration, Deployments, Issues, Members, Secrets, and Actions administration are denied by
  default. Workflow write is not assumed.
- Installation credentials are short-lived and resolved on demand.
- Ambient or competing credential sources fail closed.
- Credential identity and authority are proven inside the actual worker environment.

## Scope

### In scope

- A canonical source contract that accepts only an approved `credential_ref` and returns one
  short-lived credential result.
- A concrete runtime resolver boundary selected by trusted application configuration, not by
  `WORKFLOW.md` or issue content.
- Secret-safe validation of credential source uniqueness, validity, expected actor, repository
  allowlist, read/push authority, canonical repository/default branch/head, checkout remote, and
  writable Git metadata.
- Pre-claim credential/authority validation using a fresh credential that is discarded immediately.
- Post-claim worker preparation using a newly resolved credential; no credential crosses the claim
  or orchestrator-state boundary.
- Explicit typed outcomes for 401, 403, unexpected actor, source conflict, missing source, wrong
  repository/remote, insufficient authority, remote-head drift, and unwritable Git metadata.
- Regression tests and secret-leak tests for local and worker-host-aware execution boundaries.
- Operator and specification documentation for the resolver interface and ARO-197 handoff.

### Out of scope

- GitHub App/Bot creation, installation, private-key generation, credential storage, or token
  persistence.
- Selecting or implementing a vendor-specific secret manager.
- Machine rollout, scheduled-task changes, WSL package installation, worker startup, rotation,
  revocation, rollback, or live smoke.
- Production, deployment, billing, repository-administration changes, or workflow permission.
- A second scheduler, claim service, capacity pool, or durable secret cache.

## Architecture

### 1. Canonical source boundary

Add a `GitHubCredentialResolver` domain boundary. It receives an immutable
`ProjectExecutionContext` (or the equivalent approved profile inputs) and trusted runtime options.
The trusted source is configured outside `WORKFLOW.md` as a module/function supplied by the host
packaging layer.

The source contract returns exactly one result bound to the requested reference:

```elixir
{:ok, %{credential_ref: ref, token: opaque_binary, expires_at: datetime_or_nil}}
```

or a typed non-secret error. The resolver rejects missing sources, multiple/competing sources,
reference mismatch, blank/NUL-bearing material, expired material, and unapproved references. It
never returns the token inside an error or receipt.

`expires_at` is optional source metadata, not an assertion of GitHub's actual token lifetime.
When present, an expired timestamp causes early rejection; `nil` does not authorize a permanent
credential, and a future timestamp does not extend the bearer token's server-enforced expiry.
Resolution alone never authorizes child delivery. Both pre-claim and post-claim gates must verify
the same resolved bearer through GitHub's installation-repositories endpoint, requiring exactly
the selected repository, before worker preparation or child environment construction.
[GitHub installation access tokens expire after one hour](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
The [installation-repositories endpoint](https://docs.github.com/en/rest/apps/installations#list-repositories-accessible-to-the-app-installation)
supports installation access tokens. Local expiry metadata cannot replace this authority check.
Making the metadata mandatory or imposing an additional local lifetime limit would be a separate
source-contract change, not a substitute for server-side validation.

ARO-197 may later install a source implementation that exchanges GitHub App material for a
short-lived installation token. ARO-196 defines and tests the consuming contract but does not
perform that provisioning.

### 2. Credential-scoped GitHub client

Add a small GitHub authority client that receives the resolved credential only as a call argument.
It sends the credential in the immediate request authorization header, disables ambient `gh`/Git
credential discovery, parses only the required fields, and drops response bodies from failures.

The client verifies:

- authenticated actor equals the configured expected automation actor;
- target repository is in the compiled/trusted allowlist and matches the approved profile;
- repository metadata matches the canonical full name and default branch;
- repository permission proves pull and push without performing a write;
- default-branch head is a valid SHA and matches the head used by subsequent preparation.

HTTP 401 and 403 remain distinct typed outcomes. Malformed responses, redirects to an unexpected
host, timeouts, and transport failures are non-secret typed failures.

### 3. Pre-claim authority gate

Replace the ambient `gh` portion of multi-project preflight with a credential-scoped authority gate:

```text
approved profile
  -> fresh canonical resolve
  -> actor validation
  -> repository allowlist and permission validation
  -> canonical default-branch HEAD and quality-contract validation
  -> discard credential
  -> existing capacity and atomic claim
```

Only secret-free receipt fields may flow back to Orchestrator: profile key, repository, actor label,
permission booleans, branch, head SHA, and checked contract names. The credential and authorization
header must never enter the issue, dispatch candidate, retry entry, health event, log, or process
dictionary.

Transient transport/unavailability failures retain retry behavior. Policy/identity/authority
failures release or block according to explicit classification; unknown errors fail closed.

### 4. Post-claim execution gate

After claim, `AgentRunner` resolves a new short-lived credential for the selected immutable
execution context. It does not reuse the preflight credential. Before hooks or Codex start, the
worker-side gate revalidates reference, actor, repository authority, canonical checkout, origin,
remote HEAD, and `.git` writability in the actual node-local environment, including WSL.

On success, the existing `ProjectCredentialProvider` converts the validated material into the
call-local subprocess environment (`GH_TOKEN` plus the fixed HTTPS-GitHub credential helper) and the existing
`SubprocessEnvironment` isolation passes it only to the selected Git/readiness/hook/Codex child
processes. On failure, no effect starts and the hard blocker contains only a typed safe reason.

Each runtime uses its own trusted local source. Lower-level remote defensive/test seams do not
authorize profiled SSH or prove a complete remote lifecycle.

### 5. Codex authentication compatibility

Codex authentication compatibility clarification (2026-09-04): the strict GitHub credential result
does not carry OpenAI credentials. The final Codex launcher resolves a separate trusted
`:codex_auth_home_root/<profile_key>` binding outside the workspace tree. ARO-197 provisions and
protects each dedicated profile home and its Codex-managed ChatGPT or API-key login; Symphony does
not read/copy authentication files or pass tokens through its scheduler. This explicit external
authentication store is distinct from the prohibition on Symphony persisting resolved credentials.
After initialization, a bounded `account/read` with managed refresh must succeed before thread
creation. No login is an operator blocker; account-service/transport failure remains retryable.
Git/hooks retain issue-private homes, and thread shell policy restores that private `CODEX_HOME`
for Codex-launched commands. This does not promise filesystem isolation between processes sharing
an OS principal. Legacy unprofiled startup remains unchanged.

### 6. Checkout and Git metadata validation

For a newly-created profiled workspace, the worker first performs a bounded trusted bootstrap. This
is not a second arbitrary clone hook: it accepts only the repository and canonical branch from the
approved execution context and the immutable head from fresh authority verification, passes the
credential only to the immediate worker command environment, and leaves `origin` canonical and
the checkout at that exact head. A partial bootstrap is removed through the attested, exact
workspace cleanup boundary. Profiled bootstrap runs locally on the owning Symphony instance.

The worker-side preflight then composes with the existing workspace/readiness checks. It verifies:

- checkout is the expected namespaced project workspace;
- `origin` is canonical HTTPS GitHub for the approved repository; SSH is rejected before network use;
- a newly-created checkout is on the canonical branch at the verified default-branch head;
- a reused checkout is either still on that exact canonical head or on the exact tracker issue
  branch; readiness remains authoritative for continuation cleanliness and divergence;
- `.git` is a real, non-reparse metadata location under the approved workspace;
- the runtime principal can write Git metadata using a reversible/no-content probe or an existing
  platform capability check that leaves no artifact.

Any head change between authority receipt and workspace readiness invalidates the receipt and fails
closed; it is not silently rebound.

Only after this validation may the arbitrary `after_create` hook run. Its failure or timeout is
fatal to fresh workspace preparation: the worker uses the same attested repository rollback and
private-home rollback as earlier preparation failures. A cleanup failure blocks retry; successful
cleanup permits a fresh attempt that must run the creation hook again. A reused workspace is never
removed by this preparation rollback, and external hook side effects are not transactionally undone. Profiled deployments must
remove repository cloning from `after_create` as an ARO-197 configuration migration; legacy
non-profiled workspace behavior remains unchanged.

## Error Model

The public error surface is bounded and secret-safe. Proposed categories:

- `credential_source_unconfigured`
- `credential_source_missing`
- `credential_source_conflict`
- `credential_reference_mismatch`
- `credential_expired`
- `github_unauthorized`
- `github_forbidden`
- `github_identity_missing`
- `github_unexpected_actor`
- `github_repository_not_allowed`
- `github_repository_mismatch`
- `github_read_authority_missing`
- `github_push_authority_missing`
- `github_default_branch_mismatch`
- `github_remote_head_invalid`
- `github_remote_head_changed`
- `git_checkout_mismatch`
- `git_remote_mismatch`
- `git_metadata_unwritable`
- `credential_resolver_failed`

No category includes raw response bodies, headers, token fragments, credential paths, command
output, or exception text. Secret-safety filtering occurs before logging, truncation, and receipt
construction.

## Configuration and Trust Boundary

`WORKFLOW.md` continues to contain only approved opaque `credential_ref` values. It must not select
an executable, token variable, key path, secret manager, actor override, or repository permission.

Trusted application configuration supplies:

- resolver implementation;
- expected automation actor;
- approved repository allowlist;
- request timeout and GitHub API base fixed to `https://api.github.com` in normal operation.

The built-in default remains fail closed. Test-only callbacks remain injectable through explicit
options, but production startup must not silently fall back to ambient `gh`, environment tokens,
Git Credential Manager, or another profile's result.

## Testing

Use test-driven development for each boundary.

1. Resolver contract tests: exact reference, missing/conflicting sources, expiry, malformed results,
   exceptions, and secret non-disclosure.
2. GitHub authority client tests: 401, 403, malformed responses, expected/unexpected actor,
   allowlist, read/push permissions, branch/head validation, and header containment.
3. Orchestrator tests: canonical preflight occurs before capacity/claim; credentials are absent from
   state, retry, health, and logs; transient/permanent classifications are explicit.
4. AgentRunner tests: fresh post-claim resolution, no reuse of preflight material, worker-host-aware
   resolution, no hooks/Codex before validation, and immediate subprocess-only injection.
5. Workspace tests: checkout, origin, head, and `.git` writability checks fail closed without leaving
   probe artifacts.
6. Secret safety tests: credential-shaped values across every source/client failure never appear in
   messages, receipts, logs, diagnostics, state inspection, or persisted files.
7. Compatibility tests: legacy single-project operation remains unchanged; approved multi-project
   behavior retains existing claim/capacity/retry semantics.

Run focused tests during implementation, then `mix specs.check`, compile with warnings as errors,
Credo, Dialyzer, diff/secret scans, and authoritative Linux `make all`. The current Windows baseline
on unmodified `main` is 1059/1076 passed, 13 skipped, and 17 failures due to known CRLF-sensitive,
WSL-dependent, and watchdog-timeout cases; those failures are not accepted as regressions or as
evidence of ARO-196 correctness.

## Acceptance Criteria

- AC-1: An approved reference resolves through exactly one trusted source; ambient or competing
  sources fail closed.
- AC-2: The credential is validated against the expected automation actor and approved repository
  read/push authority before claim and again inside the actual worker boundary before effects.
- AC-3: Repository, checkout, origin, branch, remote head, and writable Git metadata remain bound to
  the approved project execution context.
- AC-4: No credential, header, raw failure body, or secret-derived detail enters application state,
  retries, health, logs, workspace state, receipts, or durable files.
- AC-5: Legacy single-project behavior is unchanged, while unauthorized or ambiguous multi-project
  execution fails closed with typed non-secret outcomes.
- AC-6: Focused regression suites and repository quality gates converge on the latest head; ARO-197
  can provide a host source without changing Symphony's resolver/preflight policy.

## Rollout Handoff

After ARO-196 merges, ARO-197 may provision the approved GitHub App/Bot and install one canonical
host source on Amy, Matt, and Han. It must verify actual runtime actor/source consistency,
rotation/revocation, old-credential rejection, rollback, and masked receipts. No provisioning action
is authorized by this design or by ARO-196.

The source must obtain short-lived installation tokens on demand under the ARO-195 decision.
If it supplies `expires_at`, use the expiry returned by GitHub's token-issuance response rather
than synthesizing a local lifetime. ARO-197's existing old-credential rejection smoke must prove
that rotation/revocation prevents new work; changing local expiry metadata is not that proof.
