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
preserved. Credential resolution and per-project workspace isolation remain out of scope here and
remain ARO-286 work.

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
