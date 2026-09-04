# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls. For orchestrator-managed claim sessions, raw GraphQL
queries remain available, but raw mutations fail closed. Those sessions instead expose fixed
`linear_comment` and `linear_state` tools, which record stable operation IDs in the effect ledger
and use an attempt lease to prevent overlapping workers from applying the same effect twice.
Managed mode starts only when the staging database reports the `effect-ledger` contract as installed;
otherwise the claimed agent session fails closed until the ARO-165 migration is applied.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

Before `before_run` and Codex dispatch, Symphony runs a workspace preflight. The preflight verifies
that the issue workspace exists, is a Git work tree, has an origin remote, matches `SOURCE_REPO_URL`
when that environment variable is set, and can run non-interactive `git status` / `git fetch`.
It then runs a branch readiness gate. The gate resolves the live canonical default with
`git ls-remote --symref origin HEAD`, fetches that exact ref, and requires the fetched SHA to match
the advertised SHA. The tracker issue branch must differ from that canonical branch. A matching
branch in a reused issue workspace is preserved as continuation work when its same-name remote is
missing, equal, or an ancestor of local `HEAD`; a behind, diverged, or unrelated local branch blocks
without repair. A fresh independent issue branch is created only in a clean workspace at the
verified canonical SHA, and a fresh remote issue/PR branch is reused only from its verified remote SHA.
Explicit stacked work requires one typed upstream branch and head SHA in `Issue.readiness_base`;
descriptions, blocker prose, and PR prose are never interpreted as stack evidence.

Workspace preflight or readiness failures are treated as hard blockers rather than retryable agent
failures: Symphony keeps the issue claimed and exposes the blocker in memory, the JSON API, and the
dashboard. If `after_run` cleanup is configured, Symphony waits for that cleanup to finish before
reporting the blocker so worker capacity is not released while cleanup is still running.

When `review_convergence.enabled` is true, each poll also monitors issues in the configured review
state. The monitor resolves the PR from the issue branch, invalidates old-head reviews, requests one
`@codex review` per head, and requires a current-head clean review result, passing required checks,
and no unresolved P1-P4 review thread. Formal reviews are preferred; the restricted issue-comment
compatibility path also verifies the unique request, time ordering, immutable App/bot identities,
and reviewed commit. Actionable findings return the issue to the
configured in-progress state; unverifiable evidence and repeated non-convergence remain in review
for a deduplicated human decision. The monitor never merges or moves an issue to Done.
Rework uses Linear comment history as a scoped durable transition log: an operation intent is
persisted before the state change, each step is retry-safe, and an incomplete operation is resumed
even after the issue has entered In Progress or the runtime has restarted. A fix round is counted
only after the target state is observed and the completion marker is durable.
Each decision publishes the fixed GitHub commit status context `Review Convergence Gate`. Configure
that context as required only after the runtime change is deployed and live-smoked; keep existing
human approval protection until then.

## Design 2 finding disposition boundary

The Design 2 runtime keeps one canonical finding contract. `FindingKey` identifies a finding in the
current repository and pull request; `FindingLineageKey` follows that finding across head changes.
Every result records the source head, `evaluated_head_sha`, and the observed current head. Missing,
stale, conflicting, or unverified evidence fails closed.

The classifier can return only `fix_in_current_pr`, `follow_up_required`, `blocked_unverified`, or
`rejected`.
Responsibility proof is `introduced_by_pr? == true OR invariant_violation? == true`; all safety
conditions remain AND-gated, and missing, malformed, or conflicting evidence stays blocked.
`in_scope?` cannot erase either positive responsibility proof. Before any autonomous effect, the
runtime authenticates the current claim and reads unresolved (`pending`/`unknown`) effects for the
same issue across older generations. Historical effects are recovery evidence only and cannot
authorize a current-generation mutation. After claim-bound readback and all snapshot hydration, the
monitor performs a dedicated lightweight live-head read immediately before authorization and fails
closed if it changed. Pending or unknown effects release claim capacity after
readback so a later generation can continue reconciliation. Releasing that claim also invalidates
any retained grant in the same state transition, so stale authorization cannot survive pending
effects, unavailable owner APIs, or a readback error. Fail-closed exits before claim acquisition
and ownership mismatches also invalidate the grant without releasing a claim they cannot prove
they own, while preserving the retained claim identity for later revalidation or conditional
release. If the identity exists only inside the grant, invalidation extracts it before clearing the
grant. A tracker-enumeration outage invalidates every cached grant under the same rule and clears
cached merge-ready candidates/blockers that cannot be revalidated. Disabling review convergence
suppresses the same terminal results instead of continuing to publish unmonitored proof. An unconsumed grant may retain the
same monitor-owned claim across invocations. When that entry becomes inactive, cleanup releases it
only if the live claim still has the retained identity and remains owned by the monitor with no
different worker; normal retained-claim reconciliation uses the same atomic conditional release, so
a concurrently transferred worker claim is left untouched. Transient or uncertain release failures
keep the ClaimService record and monitor retention identity for a later retry; confirmed release or
definitive ownership change clears them. Inactive entries follow the same transition and remain in
monitor state while release is uncertain. The global preflight requires explicit
`verified? == true` and `valid? == true`. Request fingerprints are immutable: decoding rebuilds
and compares canonical finding and lineage identities, including scope and digests; lock
reconciliation uses a deterministic fixed order.

Actionable routing first rebuilds and validates canonical finding and lineage identities. Missing,
partial, malformed, or conflicting identity, ownership, or preflight evidence remains
`blocked_unverified`; a caller-supplied digest is not enough. Follow-up routing uses the same
explicit boolean ownership gate as fix routing. Review comments with an unavailable or unsupported
author remain in the snapshot as untrusted evidence, so one malformed trust field cannot erase
other evidence. Raw actionable threads remain blocking even when an empty finding summary exists.
After a successful autonomous readback/reconciliation cycle, transient `global_blocker` state is
cleared before any newly observed blocker is applied.

Design 2 consumes the merged HandoffReceipt V1 dependency only. It does not add a second evaluator,
settlement engine, claim/ledger/receipt path, or coordinator, and it preserves ClaimService's
existing lease/renew/release lifecycle. Design 3 `authorize/5` and Design 4 `settle/2` are owner contracts; when either
is unavailable, execution fails closed rather than using a local stub. `aroak_autonomous_v1` stays
disabled by default, and this work does not start workers, use shared staging credentials, deploy,
or touch Production.

Design 3's owner runtime must provide the complete causal-attempt history from storage that survives
an orchestrator restart and mark it with `causal_history_complete?: true`. The monitor merges its
in-memory attempts only as a cache. Missing or unverified durable history returns
`causal_history_unverified` and cannot issue a new mutation grant.

`rejected` requires a verified exact-head Root-Cause Receipt and native readback that actually
contradict the review finding. It is distinct from `hypothesis_rejected`, remains merge-blocking
while classified, and cannot authorize a patch. Design 4 alone may later confirm the reply and
Resolve readback required for `rejected_settled`.

A technical pass, finding disposition, or `MergeReadyCandidate` does not authorize merge. Merge,
deployment, Linear `Done`, and Landing remain human/owner actions outside Design 2.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill uses `linear_comment` and `linear_state` for writes in managed claim
     sessions, while `linear_graphql` remains query-only there. Raw mutation workflows such as
     comment editing or uploads are available only in manual sessions.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## ARO-169 node-enrollment rollout postflight

This command requires `python3` and the PostgreSQL `psql` client. For an
ARO-169 node-enrollment rollout, a manager must enforce a DDL freeze
before preflight. Keep that freeze in place through the migration transaction,
its commit, and the fresh-connection catalog postflight:

```bash
ARO169_POSTFLIGHT_DATABASE_URL=... ./bin/node-enrollment-postflight
```

The command accepts only `ARO169_POSTFLIGHT_DATABASE_URL`; it does not fall
back to `DATABASE_URL`. It opens its own read-only, repeatable-read transaction
and exits non-zero when the committed v3 manifest or exact pgcrypto identity and
ACL cannot be verified. A failure stops the rollout and does not undo the
committed migration. Keep the freeze in place while the result is investigated;
create a separately reviewed forward reconciliation only when shared staging
actually contains drift. Release the DDL freeze only after postflight succeeds.

## ARO-166 handoff receipt retry semantics

Handoff receipt contract version 2 keeps the append-only, staging-only V1 shape
and makes same-generation retries deterministic. A generation is bound to one
branch and head; identical logical checkpoints are idempotent, late lower-ranked
checkpoints do not become latest, and a new head requires a new generation. ARO-167
runtime integration remains a separate contract and is not enabled by this migration.

This is an offline upgrade contract, not a live V1-to-V2 cutover. Stop every
handoff-receipt V1 writer and wait for all already-started V1 calls to finish.
Keep that write freeze in place while applying the migration from an isolated
session with `symphony.handoff_v1_writes_drained=on`. The migration fails closed
when that explicit drain attestation is absent; setting it without actually
quiescing writers violates the upgrade contract. Release the write freeze only
after the V2 transaction commits successfully.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

For multiple Symphony machines polling the same Linear project, enable the staging-backed claim
coordinator only after the ARO-164 claim migration, ARO-165 effect-ledger migration, ARO-169 node
enrollment, and ARO-288 node-capacity schema migration are complete, and ARO-287's separate rollout
has set and verified each node's `claim_capacity` row:

```yaml
claim:
  enabled: true
  database_url: "$SYMPHONY_CLAIM_DATABASE_URL"
  ca_cert_file: "$SYMPHONY_CLAIM_CA_CERT_FILE"
  node_id: "$SYMPHONY_NODE_ID"
  node_instance_id: "$SYMPHONY_NODE_INSTANCE_ID"
  lease_ms: 60000
  heartbeat_ms: 20000
  fallback_grace_ms: 30000
```

Keep the database URL, CA path, and node identity values outside the repository. Long-lived Supabase
connections should use the official Session Pooler endpoint on port 5432. The CA file must be an
absolute path to the certificate downloaded from the project's Dashboard. Claim connections always
use peer verification, SNI, and HTTPS hostname matching; missing or invalid TLS inputs fail closed,
and there is no `verify_none` fallback. The enrolled node login may
call the claim functions but cannot directly read or mutate claim tables. Symphony obtains a claim
before starting a worker, renews it using the database clock, and stops the worker if renewal can no
longer prove ownership. Leave `claim.enabled: false` for single-machine operation or until shared
staging has been migrated; opening or merging this PR does not apply the migration to staging.

### Node-wide claim capacity contract

When `claim.enabled` is true, `claim_capacity` belongs to the enrolled node and must equal `3`.
Startup validates capacity before registering the one-time node instance, so a rejected capacity
cannot strand a phantom session. Central-Brain and Project-Management workers on that node
share those three claims, and project profiles cannot define or override capacity. Local Elixir slot
checks may avoid unnecessary work, but only the atomic database claim transaction authorizes a
slot.

Lowering a node's capacity preserves its existing active claims and their lease/generation
lifecycle; it blocks only new claims until usage falls below the new limit. With Amy, Matt, and Han
each configured for three claims, the fleet can hold nine active claims and a tenth must wait.
Installing this code or its migration does not update those node rows. ARO-287 remains the separate
operator rollout that sets and verifies each node's value before its claim-enabled runtime starts.

### Workflow format and options

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `review_convergence.enabled` defaults to `false`. When enabled, `repository` is required in
  `owner/name` form. `review_state`, `in_progress_state`, `max_fix_rounds`, and `human_owner`
  configure monitoring, rework, and escalation without changing merge authorization.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- After workspace creation and before `hooks.before_run`, Symphony verifies the existing workspace
  with a non-interactive Git preflight. If `SOURCE_REPO_URL` is set, the remote comparison ignores
  credentials embedded in the URL so tokens are not exposed in logs or SSH command arguments.
- The tracker-provided issue `branchName` must be one exact valid branch. Symphony creates a missing
  independent issue branch itself from the verified live default; `after_create` should not reset,
  rebase, or force-create that branch.
- Existing matching issue branches are continuation state and are never reset merely because the
  default branch advanced. If a same-name remote exists, it must equal local `HEAD` or be its
  ancestor; behind, diverged, unrelated, detached, or differently checked-out state blocks for
  manual inspection. Every ready path re-reads branch and `HEAD`, and materialized branches must
  still be clean after switching.
- Stacked readiness is an internal typed seam: `:canonical` is the default, while
  `{:stacked, [%Issue.StackedBase{branch: branch, head_sha: sha}]}` is accepted only when that one
  remote branch and full SHA verify exactly. No current adapter derives this value from free-form
  Linear or GitHub text.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Approved project repository preflight

`SymphonyElixir.ProjectRepoPreflight.check/2` accepts one complete profile map from the validated
`project_profiles` contract plus trusted runtime options. It resolves a short-lived credential
through `SymphonyElixir.GitHubCredentialResolver`, verifies the configured dedicated actor and
repository read/push authority through `SymphonyElixir.GitHubAuthorityClient`, then verifies the
`main` default branch, exact head, and approved quality-script contract at that immutable head. It
does not invoke ambient `gh` or Git credential discovery. The supported
profiles are:

- `aroakpm-svg/aroak-central-brain`: `typecheck`, `build`, and `test`
- `aroakpm-svg/aroak-project-management`: `typecheck`, `build`, and `db:test`

Run the dry check without starting a worker:

```elixir
settings = SymphonyElixir.Config.settings!()

settings.project_profiles
|> SymphonyElixir.ProjectProfiles.list()
|> Enum.map(&SymphonyElixir.ProjectRepoPreflight.check(&1,
     credential_source: trusted_source,
     expected_actor: "configured-dedicated-bot[bot]"))
```

Each result is either `{:ok, receipt}` or `{:blocked, reason}` with one minimal human next step.
Preflight is a necessary dispatch gate, but success is readiness evidence rather than authorization:
it does not independently enable polling, dispatch, credentials, deployment authority, or automatic
pickup permission. The credential is discarded before capacity and claim; only the secret-free
authority receipt continues with the selected ARO-286 execution context.

## Approved multi-project profile contract

The optional `project_profiles` WORKFLOW setting enables the existing orchestrator's
approved multi-project path and defines the complete Central-Brain and Project-Management
mapping. Version `1` must exactly match the profile identities compiled into this Symphony
release. The parser rejects the whole candidate when a profile is missing or extra, an
identity is duplicated, or any approved field differs. Failed reloads preserve the previous
valid value.

Profiles contain a credential reference name, not credential material. Validation
errors identify the profile or field without echoing submitted values. With the setting
present, every poll cycle uses this order:

1. Aggregate every enabled approved profile independently.
2. Filter candidates and re-fetch each issue by UUID.
3. Resolve the refreshed project UUID to the same unique approved profile.
4. Require shared routing to be `exclusive` for the authenticated current node.
5. Run the approved profile's read-only repository preflight.
6. Check the existing node-wide capacity.
7. Acquire the existing ARO-164 claim.
8. Continue through the existing worker dispatch path.

A profile timeout or error is retried independently: it cannot contribute substitute identity
evidence and does not stop another profile's candidates. Unknown, duplicated, changed, stale,
wrong-node, non-exclusive, or repository-mismatched candidates fail closed and iteration continues.
When `project_profiles` is absent, Symphony retains the legacy single-project tracker path.

Amy, Matt, and Han each run their own node-local Symphony. Han runs Symphony locally inside WSL,
not as Amy's SSH worker. Enabled `project_profiles` requires absent/empty `worker.ssh_hosts`.
Startup and new-work poll/dispatch/retry admission reject nonempty hosts with
`profiled_ssh_topology_unsupported`; direct profiled runner remote-host overrides fail before
credential resolution. Runtime settings remain readable after a topology-invalid reload for
active local reconciliation, lease, and cleanup obligations. Legacy unprofiled SSH is unchanged.
Lower-level remote defensive/test seams do not prove supported profiled remote execution.

This contract selects an approved repository but does not install credentials, clone repositories,
grant deployment authority, or operate in Production. ARO-286 consumes the selected profile for
workspace and subprocess isolation; ARO-196 defines the host-source interface, while ARO-197 owns
provisioning and machine rollout.

See the commented example in [`WORKFLOW.md`](WORKFLOW.md). Remove the comment
markers only when intentionally configuring the exact approved set.

## Project workspace, credentials, and runtime observability

The multi-project execution path accepts only the complete approved profile set and the environment
`local_non_production`. Each authorized issue becomes one immutable
`SymphonyElixir.ProjectExecutionContext`. Workspace paths use the validated namespace plus the
sanitized issue identifier, so the same identifier does not collide across projects:

```text
C:/symphony/workspaces/central-brain/ARO-286
C:/symphony/workspaces/project-management/ARO-286
```

The corresponding configuration is:

```yaml
project_profiles:
  version: 1
  profiles:
    - key: central-brain
      linear_project_id: d0acfb71-f68c-4a9f-8a1a-477265d3c3ec
      repository: aroakpm-svg/aroak-central-brain
      canonical_branch: main
      workspace_namespace: central-brain
      credential_ref: github-central-brain
      environment: local_non_production
    - key: project-management
      linear_project_id: 708053e0-f42c-4e93-bec4-7abbb37e74af
      repository: aroakpm-svg/aroak-project-management
      canonical_branch: main
      workspace_namespace: project-management
      credential_ref: github-project-management
      environment: local_non_production
workspace:
  root: C:/symphony/workspaces
observability:
  runtime_state_root: C:/symphony/health/runtime-state
  notification_command: "pwsh -NoLogo -NoProfile -File C:/symphony/notify-restart-limit.ps1"
  notification_receiver: "on-call:platform"
  restart_limit: 3
  notification_timeout_ms: 5000
```

`credential_ref` is an opaque approved handle, not a token, path, command, or environment value.
Only `github-central-brain` and `github-project-management` are accepted, for the two repositories
listed above; these are the complete ARO-196 multi-project dispatch manifest. Separately, the
ARO-195-approved GitHub App installation allowlist also includes `aroakpm-svg/symphony`, for a total
of three repositories. That installation scope does not define or add a `symphony` dispatch
profile. Trusted application configuration supplies `:github_credential_source`; runtime
options supply the expected dedicated actor and may inject the same source explicitly for packaging
or tests. Configuring both same-runtime sources is a conflict. `WORKFLOW.md`, issue text, environment variables,
ambient `gh`, Git Credential Manager, and other profiles cannot select or replace the source.

The source returns exactly one reference-bound credential for the current call. Before claim,
`ProjectRepoPreflight` resolves it, validates actor/repository/pull/push/default branch/head, reads
the quality contract at that verified head, and discards it. After claim,
`SymphonyElixir.AgentRunner` resolves a second fresh credential and repeats full authority
validation before `SymphonyElixir.GitCheckoutPreflight` checks that node-local runtime's namespaced
checkout, origin, branch, remote head, and safe writable `.git` metadata. This includes Symphony
running locally inside WSL; another runtime's credential evidence cannot authorize it.

Actor evidence uses the installation-token-compatible, fixed GraphQL `viewer.login` read; GraphQL
errors (including partial responses) fail closed. Missing or hidden repositories/refs (HTTP 404)
are permanent authority blockers, not transport retries.

Only canonical HTTPS GitHub origins are accepted, preventing ambient SSH-key authentication.
ARO-197 owns migration of legacy SSH origins and cloning hooks; the runtime does not rewrite reused
repository configuration. Fresh workspaces that fail checkout validation are rolled back through
their exact ownership attestation; reused workspaces and pre-existing private homes are preserved.

Only after these gates may `SymphonyElixir.ProjectCredentialProvider` produce the call-local
`GH_TOKEN` plus fixed HTTPS-GitHub-only Git credential helper environment for readiness, hooks,
and Codex. Isolated HOME and ambient credential denial remain active. Credentials and authorization headers never enter
arguments, orchestrator state, retries, workspace state, health, logs, receipts, notifications, or
durable files. `:github_unavailable` and repository transport/timeout blockers are transient.
Source, expiry, 401/403, actor, allowlist, authority, checkout, remote-head, and Git-metadata
failures are permanent until configuration changes; unknown failures fail closed. When
`project_profiles` is absent, the legacy single-project path remains unchanged.

ARO-196 does not create an App, key, token, credential file, or Scheduled Task and does not perform
machine rollout. ARO-197 owns provisioning, installation on Amy/Matt/Han, rotation, revocation, and
rollback for the three-repository App allowlist; it must preserve ARO-196's two-profile dispatch
manifest. ARO-285 owns the live two-project acceptance. See
[`docs/aro_196_acceptance.md`](docs/aro_196_acceptance.md) for the evidence map.

Startup calls the existing Linear endpoint with the real read-only
`query SymphonyLinearViewer { viewer { id } }` request before terminal cleanup or the first poll.
The safe startup outcomes are `:linear_unauthorized`, `:linear_forbidden`,
`:linear_identity_missing`, `:linear_response_invalid`, and `:linear_unavailable`; response bodies,
headers, raw GraphQL errors, and the API key are not returned or logged.

`SymphonyElixir.RuntimeHealth` owns one bounded snapshot with `last_successful_poll_at`, `linear` and
`claim_store` dependency status, the latest typed stages, `final_stop`, and bounded `history`. The
fixed stage names are `candidate_fetch`, `issue_refresh`, `routing`, `profile_resolution`,
`preflight`, `claim`, and `dispatch`. An immutable `stop-<runtime_epoch>.json` receipt records one of
`normal_shutdown`, `startup_failure`, `unexpected_exit`, or `restart_limit` beneath the dedicated
runtime-state directory. Unknown evidence is rendered as `unknown`; credential references and
credential-like values are rejected.

`observability.runtime_state_root` must name that actual `runtime-state` directory. RuntimeHealth
derives it as `<receipt_root>/runtime-state`; the built-in defaults align. If a local packaging layer
overrides application `:runtime_health_opts`, its `:receipt_root` must therefore be the parent of the
configured workflow path, and its `:workspace_root` must remain disjoint.

Restart notification is optional. Omitting both `notification_command` and
`notification_receiver` disables it; configuring only one is invalid. Both values are
operator-provided and must be nonblank and secret-free. The command receives exactly one bounded
JSON object on stdin:

```json
{
  "runtime_identity": "symphony-local",
  "receiver": "on-call:platform",
  "attempt_count": 3,
  "stop_category": "restart_limit",
  "timestamp": "2026-08-29T06:00:00Z",
  "runtime_epoch": "example-epoch",
  "receipt_path": "C:/symphony/health/runtime-state/stop-example-epoch.json"
}
```

Command stdout/stderr is always discarded. A zero exit status publishes one delivery receipt keyed
by SHA-256 of the receiver hash plus epoch; a timeout, non-zero exit, crash-ambiguous claim, malformed
receipt, or unrepresentable legacy path publishes no delivery. Existing valid legacy
`receiver_hash-epoch` delivery receipts still suppress duplicates, and a valid legacy claim remains
ambiguous. Only a representable path whose entry is genuinely absent is treated as absent.

Run the local Windows watchdog from a trusted operator wrapper, substituting only local
non-Production paths and secret-free commands/identifiers:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File ./bin/symphony-watchdog.ps1 `
  -ChildCommand '& C:/symphony/start-local.ps1' `
  -RuntimeIdentity 'symphony-local' `
  -RuntimeStateRoot 'C:/symphony/health/runtime-state' `
  -StatePath 'C:/symphony/health/runtime-state/watchdog-state.json' `
  -RestartLimit 3 `
  -NotificationTimeoutMs 5000 `
  -NotificationCommand '& C:/symphony/notify-restart-limit.ps1' `
  -NotificationReceiver 'on-call:platform'
```

The watchdog exits `0` after child success, `1` after reaching the restart limit, and `2` for an
invalid or unsafe configuration/state boundary. The runtime-state root must be an absolute existing
non-Production directory, and the state file must be directly below it. This is a local boundary:
no external notification service, deployment, database mutation, Production access, or live
customer message is created by Symphony. ARO-285 owns live non-Production end-to-end acceptance.
See [`docs/aro_286_acceptance.md`](docs/aro_286_acceptance.md) for failure and test mapping.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

### Pull-request scope contract lint

PR descriptions must use the structured `Scope Contract` in
[`../.github/pull_request_template.md`](../.github/pull_request_template.md). Check a description
locally with:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

The lint statically validates the contract; it does not classify review findings or move tracker
issues. Severity and ownership are separate. Later routing may consume the typed contract only
under its own policy; unknown ownership must remain in review for follow-up or human disposition.
When this lint applies to an existing PR, update its description to the structured contract.

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## Human merge-ready boundary

After the autonomous Design 4 flow has no remaining finding, an owner may supply the complete
landing evidence contract. Symphony reads GitHub and Linear twice around pure
`MergeReadyCandidate.derive/3` evaluation. Matching exact-head evidence becomes
`{:merge_ready_candidate, candidate}`; incomplete or changing evidence becomes
`{:merge_ready_blocked, blockers}`. Candidates are process state only and are never persisted as a
new authority.

The production poll consumes this contract from the owning issue's runtime entry or its explicit
`finding_complete` handoff. It does not accept one process-global evidence map or manufacture
missing compatibility receipts.
The contract includes the complete canonical finding digest inventory. `settled_findings: []` is
accepted only with an explicitly empty inventory; otherwise every inventory digest must have one
matching settlement. A repository, PR, Linear revision, base, or head change invalidates and clears
the stored handoff before the monitor resumes the claimed convergence flow.

The Design 4 owner submits the completed per-issue contract with
`SymphonyElixir.Orchestrator.finding_complete/3`. The handoff is stored on that issue's runtime
entry for the next poll; replacement evidence clears any older merge-ready result immediately but
preserves claim identity needed for conditional release. Missing handoff data fails closed. Handoff, acceptance, and compatibility proof are
accepted only when their repository, PR, Linear, base, and exact-head identity matches the candidate.
Every nested receipt also matches the current Linear revision, and the verified handoff receipt binds
a canonical digest of the complete finding inventory and a separate canonical digest of the settled
finding projection rather than trusting handoff-controlled collections or statuses.
Top-level and acceptance evidence reference lists must be non-empty, contain unique non-empty values,
and both appear in candidate identity, preserving canonical proof identity across retries and replacements.
Completed handoffs are revalidated before claim acquisition. Candidate output retains the verified
receipt contract versions and uses collision-safe, length-prefixed list encoding in its digest.
Any retained claim is conditionally released before claim-free terminal derivation. Maintainers can
observe the resulting candidate or blockers in `Orchestrator.snapshot/2` under
`review_convergence`; this surface still performs no merge or other landing mutation.
An uncertain conditional release keeps the per-issue handoff and retained identity for retry but
withholds the terminal result. Publishing a verified terminal result clears older transient
blockers so the owner surface cannot expose contradictory current and stale states.

Configure the boundary explicitly:

```yaml
landing:
  mode: human
```

`human` is the default and only accepted value. It performs no merge, Linear transition,
deployment, permission change, or worker activation. There is no automatic fallback.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
