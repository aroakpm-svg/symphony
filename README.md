# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

#### Project repository readiness boundary

Before dispatching a multi-project candidate, Symphony runs an explicitly approved, read-only
repository preflight using that candidate's validated profile map. The two approved mappings are
`aroakpm-svg/aroak-central-brain` (`typecheck`, `build`, and `test`) and
`aroakpm-svg/aroak-project-management` (`typecheck`, `build`, and `db:test`), both on `github.com`
with canonical branch `main`. The preflight verifies repository identity, default branch and exact
head, and the profile's required quality-script contract. Missing, unreadable, mismatched, or
malformed evidence fails closed with a human next step.

The preflight is a required dispatch gate, but passing it does not itself authorize polling,
dispatch, credentials, deployment, or automatic issue pickup; the other profile, routing, capacity,
and claim gates still apply. See the
[Elixir preflight documentation](elixir/README.md#approved-project-repository-preflight) for the
profile-map API and dry-check example.

Symphony also accepts an optional, versioned `project_profiles` contract for the complete approved
Central-Brain and Project-Management mapping. The contract is validated as one unit against the
mapping compiled into this release; missing, extra, duplicated, or changed identities fail closed.
It stores credential references only, never credentials. When the contract is present, the existing
orchestrator polls every enabled approved profile independently and dispatches only refreshed issues
whose unique approved profile, exclusive current-node route, and repository preflight all pass.
One project's polling failure neither substitutes another project's identity nor stops healthy
projects from progressing. Without `project_profiles`, the existing single-project tracker path is
preserved.

#### Project workspace and runtime isolation

For an authorized multi-project issue, Symphony carries one validated project execution context
through workspace preparation, readiness, hooks, Git, and Codex startup. The same issue identifier
is isolated by its approved namespace, for example:

```text
<workspace.root>/central-brain/ARO-286
<workspace.root>/project-management/ARO-286
```

The approved profiles contain only the opaque references `github-central-brain` and
`github-project-management`; they never contain credential material. The built-in default
credential resolver deliberately fails closed until a trusted application-level source and the
expected dedicated automation actor are configured. It never falls back to environment tokens,
GitHub CLI, Git credential helpers, or another profile. A fresh short-lived credential validates
actor, repository read/push authority, default branch, and exact head before claim; a second fresh
credential repeats authority validation inside the same node-local runtime before its
checkout, origin, branch, remote head, and Git metadata are accepted. Resolved values are limited
to immediate request or subprocess boundaries and are excluded from commands, orchestrator state,
retries, workspace state, runtime health, logs, receipts, and notifications.

Amy, Matt, and Han each run their own node-local Symphony. Han runs Symphony locally inside WSL,
not as Amy's SSH worker. Enabled `project_profiles` requires absent/empty `worker.ssh_hosts`.
Startup and new-work poll/dispatch/retry admission reject nonempty hosts with
`profiled_ssh_topology_unsupported`; direct profiled runner remote-host overrides fail before
credential resolution. Runtime settings remain readable after a topology-invalid reload for
active local reconciliation, lease, and cleanup obligations. Legacy unprofiled SSH is unchanged.
Lower-level remote defensive/test seams do not prove supported profiled remote execution.

ARO-196 defines and verifies this consuming contract only. ARO-197 owns GitHub App/Bot
provisioning and rollout to the three machines. Canonical HTTPS-only Git authentication and
installation-compatible actor verification apply before effects; ARO-197 owns legacy SSH-origin
migration. Its ARO-195-approved App installation allowlist is
`aroakpm-svg/symphony`, `aroakpm-svg/aroak-central-brain`, and
`aroakpm-svg/aroak-project-management`; this does not add `symphony` as a third dispatch profile.
ARO-196's dispatch manifest remains the two mappings above. ARO-285 owns live multi-project
acceptance.

Startup performs the real read-only Linear `viewer { id }` request before cleanup or polling. The
runtime then exposes typed, secret-safe stage/dependency health and an immutable final-stop receipt.
On Windows, the optional local watchdog can bound restart attempts and invoke one explicitly
configured local notification command per receiver and epoch. Both the command and receiver are
operator-provided, must be secret-free, and are disabled when both are omitted. These controls
accept only `local_non_production` project profiles and absolute non-Production runtime paths; they
do not deploy, contact an external notification service by default, or authorize Production use.
See the [Elixir operating contract](elixir/README.md#project-workspace-credentials-and-runtime-observability)
and [ARO-286 acceptance map](elixir/docs/aro_286_acceptance.md).

#### Distributed claim safety

Multi-worker deployments use the database-backed claim service to ensure that only one enrolled
node owns an issue at a time. When `claim.enabled` is `true`, operators must provide the approved
PostgreSQL connection, an absolute path to the official CA certificate, and the enrolled node and
instance identities through machine-local configuration. The claim service verifies the TLS peer
and hostname, authenticates the node before accepting work, and fails closed when any required
connection or identity input is missing or invalid. See the
[Elixir claim configuration](elixir/README.md#configuration) for the complete
runtime contract and environment variables.

## Human merge-ready boundary

ARO-246 adds a final, read-only `MergeReadyCandidate` proof after Design 4 settlement. The proof is
bound to the repository, PR, Linear issue, base SHA, and exact latest head. Required checks, the
exact-head Codex result, actionable review threads, settlements, effects, acceptance evidence, and
compatibility receipts must all be explicit and consistent. Missing, stale, pending, unknown, or
conflicting evidence blocks.
The handoff also carries the complete canonical finding inventory; an empty settlement set is valid
only when that inventory is explicitly empty. If repository, PR, Linear revision, base, or head
changes, Symphony discards the stale handoff and resumes convergence for the new identity.

The only supported landing configuration is `landing.mode: human`. A successful candidate means a
maintainer may recheck GitHub and press Merge. Symphony does not merge, enqueue a merge, mark Linear
Done, deploy, or activate a landing worker. Any later head, review, check, thread, PR, or Linear drift
invalidates the candidate and requires complete fresh derivation.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
