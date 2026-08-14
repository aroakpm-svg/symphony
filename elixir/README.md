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

The classifier can return only `fix_in_current_pr`, `follow_up_required`, or `blocked_unverified`.
Responsibility proof is `introduced_by_pr? == true OR invariant_violation? == true`; all safety
conditions remain AND-gated, and missing, malformed, or conflicting evidence stays blocked.
`in_scope?` cannot erase either positive responsibility proof. Before any autonomous effect, the
runtime authenticates the current claim and reads unresolved (`pending`/`unknown`) effects for the
same issue across older generations. Historical effects are recovery evidence only and cannot
authorize a current-generation mutation. Pending or unknown effects release claim capacity after
readback so a later generation can continue reconciliation. Releasing that claim also invalidates
any retained grant in the same state transition, so stale authorization cannot survive pending
effects, unavailable owner APIs, or a readback error. An unconsumed grant may retain the
same monitor-owned claim across invocations. When that entry becomes inactive, cleanup releases it
only if the live claim still has the retained identity and remains owned by the monitor with no
different worker; a transferred worker claim is left untouched. The global preflight requires explicit
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
coordinator only after the ARO-164 claim migration, ARO-165 effect-ledger migration, and ARO-169
node enrollment are complete:

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

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
