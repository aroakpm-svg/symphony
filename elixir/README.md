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
skills can make raw Linear GraphQL calls.

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
`review_convergence.finding_router_mode` adds an opt-in ownership step: `disabled` preserves the
legacy behavior, `shadow` verifies and logs the Central Brain plan without changing effects, and
`enforce` performs only the exact routed action. The receipt must come from the unique latest
completed `Work Routing / Readiness` check on the current head, published by GitHub Actions App ID
15368 from `.github/workflows/work-routing-readiness.yml` at the exact live base policy SHA. The
check run and workflow run must share the same immutable check-suite ID; `details_url` alone is not
trusted, and the workflow event must be exactly `pull_request_target`. Check runs are ordered only
by their immutable `created_at`; a newer in-progress run therefore blocks an older completed result.
For `pull_request_target`, the bound workflow run's `head_sha` is the exact receipt base SHA while
the check run and receipt remain bound to the PR head SHA.
Missing, ambiguous, stale, wrong-workflow, or malformed evidence remains in review. Symphony never
recomputes Central Brain diff, scope, digest, review, or classification policy.
It accepts both the V2 classification receipt and the V3 receipt that adds Central's merge
decision; Symphony never executes or recomputes that merge decision.
Every unresolved normalized P1-P4 thread must have one disposition whose `findingCommentId` and
`findingCommentDigest` match the selected GitHub review comment ID and exact body bytes. Missing
coverage, an edited or mismatched comment, or a malformed digest fails closed. Before Symphony
writes a follow-up or resolves a thread, GitHub must return the
exact pending `Review Convergence Gate` status for the current head.
Immediately before Resolve, Symphony refetches every page of the thread and requires its latest
P1-P4 comment to still match both receipt fields. Routed rework still honors the existing retry
ceiling and structural-risk escalation gate.
Immediately before each follow-up comment or Resolve mutation, Symphony refetches the latest
Central receipt and requires the same routing identity, then re-reads the open PR and requires its
current base and head to remain the receipt's exact `baseSha` and `headSha`. Before posting a
follow-up, it also refetches every page of that thread and requires the selected P1-P4 comment to
remain unresolved with the same ID and body digest.
Before routed rework, it refetches the full PR snapshot, the Central receipt, and the live PR
identity, then reroutes the current threads. The exact unresolved finding bindings and action set
must remain unchanged. Routed rework fingerprints include the bound thread and finding comment IDs,
so two textually identical findings cannot share one durable transition key.

Settlement uses the same guarded-operation boundary before every comment or Resolve write: refetch
the complete snapshot, verify the exact receipt and PR identity, reroute every actionable thread,
and require the same complete settlement action-and-binding set. After a confirmed follow-up write, the same
guard accepts only that finding's explicit `comment_then_resolve` to `resolve` transition. The GitHub comment gateway independently
validates the marker body and authenticated actor node ID before POST, so direct callers cannot
bypass the guard.

In enforce mode, `blocked_unverified` holds the whole PR, `fix_in_current_pr` returns only that
finding for repair, and pending `remove_out_of_scope_change` requires removal without resolving the
thread. A verified removal or `suggest_follow_up` may resolve only after any required follow-up
comment is durable. Runtime authority comes solely from actor node ID `U_kgDOEDjIhA` plus the exact
`findingId`, `sourceHeadSha`, and `receiptDigest` hidden marker fields; visible prose and labels are
not authority. The dedicated token must appear exactly once at byte zero, before the visible
template. This fixed protocol position cannot be nested in Markdown code or a raw HTML block. Symphony
still never merges.
Rework uses Linear comment history as a scoped durable transition log: an operation intent is
persisted before the state change, each step is retry-safe, and an incomplete operation is resumed
even after the issue has entered In Progress or the runtime has restarted. A fix round is counted
only after the target state is observed and the completion marker is durable.
Each decision publishes the fixed GitHub commit status context `Review Convergence Gate`. Configure
that context as required only after the runtime change is deployed and live-smoked; keep existing
human approval protection until then.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
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
- `review_convergence.finding_router_mode` accepts `disabled` (default), `shadow`, or `enforce`.
  Start with `shadow`; change to `enforce` only after the exact receipt and planned actions are
  observed on a non-merged test PR. There is no fallback from missing trusted evidence.
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
