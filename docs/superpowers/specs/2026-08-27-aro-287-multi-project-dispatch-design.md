# ARO-287 Multi-Project Polling and Exclusive Dispatch Design

## Goal

Allow each approved Symphony node to poll the Central-Brain and Project-Management Linear projects
in one runtime, then dispatch an issue only when its refreshed project identity resolves to exactly
one approved ARO-289 profile and shared routing exclusively targets the current node. The selected
profile supplies the repository context for the existing preflight, claim, capacity, and worker
pipeline.

## Scope boundary

ARO-287 extends the existing polling-to-dispatch path. It does not add another scheduler, queue,
claim implementation, capacity counter, worker pool, database schema, deployment path, or Production
authority. ARO-164 remains the sole claim and lease authority, and ARO-288 remains the sole node-wide
capacity contract.

ARO-286 owns per-project workspace namespaces, credential resolution, credential isolation, and
expanded observability. ARO-287 passes the selected approved profile through dispatch and proves the
repository identity before claim, but does not resolve or install credentials or redesign workspace
storage.

## Selected architecture

Keep the single `SymphonyElixir.Orchestrator` polling cycle and insert one deterministic
multi-project selection boundary before the existing claim path. The alternatives—one orchestrator
per project or project-specific claim queues—would duplicate scheduling and claim behavior and are
therefore rejected.

The boundary has three responsibilities:

1. independently fetch candidates for every enabled approved profile;
2. normalize and deduplicate candidates by Linear issue UUID while preserving their profile source;
3. refresh and authorize each candidate against current issue identity, shared routing, node identity,
   and the selected approved profile before passing it to the existing preflight and claim path.

The orchestrator remains responsible for ordering candidates, enforcing node capacity, acquiring the
ARO-164 claim, and starting workers. An ineligible candidate produces a secret-safe skip result and
iteration continues, so the first bad candidate cannot block a later eligible candidate.

## Candidate and profile identity

`SymphonyElixir.Linear.Issue` gains normalized project evidence returned by both candidate and
refresh queries:

- `project_id`: immutable Linear project UUID;
- `project_slug`: query identity used only for polling;
- `project_profile_key`: derived locally after exact ARO-289 lookup;
- `repository`: the approved profile repository attached after authorization, never accepted from
  Linear text or labels.

Linear queries must request the issue project UUID and slug. A candidate is usable only when the
refreshed project UUID maps to exactly one enabled `ProjectProfiles` entry. The original polling
profile and refreshed project must agree. Missing, unknown, duplicate, or changed identity fails
closed.

Issue deduplication is global for the poll cycle and keyed by Linear issue UUID. If the same UUID is
returned by more than one profile, it is not dispatched; the result is an ambiguous-source skip.
This prevents duplicate claim attempts without relying on candidate ordering. The existing database
claim remains the final cross-node race guard.

## Multi-project polling

The tracker boundary accepts an approved profile for project-scoped reads rather than reading one
global `tracker.project_slug`. A small polling coordinator enumerates the enabled ARO-289 profiles in
stable key order and invokes the existing Linear pagination logic once per profile.

Each profile fetch has its own timeout and result. Successful results are retained even when another
profile times out or fails. The aggregate result therefore contains candidates plus per-profile
outcomes rather than collapsing the entire round into one error. Errors expose only the profile key
and a stable reason category; API tokens, credential references, response bodies, and raw profile
maps are excluded.

Transient Linear failures use bounded exponential backoff with jitter at the profile boundary. A
failed round schedules a later retry and never exits the orchestrator. Backoff state is independent
per profile, so one unhealthy project cannot delay a healthy project's normal polling cadence.

The existing single-project behavior remains available when `project_profiles` is absent. When the
approved profile set is present, multi-project polling is mandatory and the global project slug is
not used as a substitute for a failed profile.

## Exclusive routing authorization

Dispatch authorization uses the shared `symphony_staging.routing_assignments` authority already
consumed atomically by ARO-164 claims. A read-only routing check is added before repository preflight
and claim acquisition. It must return current routing policy, target node, and revision for the issue.

Only `routing_policy = 'exclusive'` with `target_node_id` equal to the authenticated current node is
eligible. Missing routing, `unassigned`, `preferred-with-fallback`, a different node, malformed data,
or a transient routing read failure all skip dispatch. The later ARO-164 claim still revalidates the
same routing state atomically; the pre-check improves selection and forward progress but never
replaces the claim's race protection.

Candidate authorization order is:

1. require active Linear state and `symphony-worker` label;
2. refresh the issue by UUID;
3. verify the refreshed project maps to the same unique approved profile;
4. read shared routing and require exclusive ownership by this node;
5. verify the selected repository with the existing read-only project repo preflight;
6. check existing node-wide capacity;
7. acquire the existing ARO-164 claim and dispatch through the existing worker path.

Every check fails closed. Skips continue candidate iteration. Claim rejection also continues
iteration where capacity remains.

## Repository dispatch contract

The authorized candidate carries its approved profile through the orchestrator as dispatch context.
Repository selection comes only from `ProjectProfiles`; Linear descriptions, labels, branch names,
and repository-like URLs cannot override it.

ARO-253's read-only repo preflight is parameterized with the approved profile and verifies that the
target checkout remote matches that profile's repository. A mismatch prevents claim and worker
startup. ARO-287 does not create a new clone mechanism or inject credentials; those concerns remain
with ARO-286. Until ARO-286 lands, tests use explicit profile-specific checkout fixtures and dispatch
context rather than claiming credential isolation.

## Failure handling and runtime liveness

- Linear timeout, transport error, rate limit, or transient GraphQL failure: classify, back off that
  profile, and keep the runtime and other profiles running.
- Shared routing or Supabase/PostgreSQL transient failure: skip the affected candidate, use bounded
  retry scheduling, and keep the runtime alive.
- Unknown or changed project identity: skip without profile substitution.
- Wrong node or non-exclusive routing: skip and continue to the next candidate.
- Duplicate issue across profile polls: mark ambiguous and do not claim it.
- Wrong repository: fail preflight before claim and worker startup.
- Stale issue after refresh: skip using refreshed state.

Diagnostics include issue identifier/UUID, profile key when known, node ID, operation, and stable
reason. They exclude secrets, credential references, raw database errors containing connection
details, and raw API bodies.

## Interfaces and expected code ownership

- `ProjectProfiles`: add exact lookup by Linear project UUID and stable enabled-profile enumeration.
- `Linear.Client` and `Linear.Adapter`: accept project-scoped candidate reads and include project
  identity in candidate and refresh payloads.
- `Tracker`: expose profile-scoped fetch while preserving the legacy single-project adapter path.
- New focused polling/selection module: aggregate per-profile outcomes, deduplicate, bind profiles,
  and return structured candidates/skips without owning scheduling or claims.
- A focused routing reader beside `ClaimService`: perform read-only exclusive-node eligibility checks
  using the existing claim connection/authority; do not create a second connection owner when the
  claim service already owns one.
- `Orchestrator`: replace the single fetch call with aggregate selection, continue past skips, and
  pass authorized profile context into existing preflight and claim dispatch.
- `ProjectRepoPreflight`: accept the selected approved profile as expected repository evidence.

Exact module boundaries may follow existing test seams, but ownership rules above are mandatory.

## Testing

Tests are primarily deterministic unit/integration tests with injected Linear and routing readers:

- Amy, Matt, and Han each aggregate candidates from both approved projects;
- one project timeout/error still allows the other project's eligible issue to dispatch;
- Linear and routing transient failures back off and recover without terminating the runtime;
- active-state and `symphony-worker` filters apply after refresh;
- wrong node, missing routing, unassigned, preferred-with-fallback, unknown project, changed project,
  stale issue, and wrong repo never dispatch;
- the first ineligible candidate does not block a later eligible candidate;
- duplicate UUID across profiles produces no duplicate candidate or claim;
- unique project UUID resolves to exactly one approved profile and repository;
- preflight runs before claim, and existing claim/capacity behavior is reused unchanged;
- errors and logs are profile-specific and secret-safe;
- legacy single-project mode remains compatible when profiles are absent.

Targeted tests run during implementation, followed by `mix specs.check` and the full `make all`
quality gate.

## Documentation

Update root and Elixir README documentation to describe multi-project polling, exclusive-only routing,
repository selection, partial poll failure behavior, and the explicit ARO-286 isolation boundary.
Update `SPEC.md` if its current single-project polling contract would otherwise conflict.

## Acceptance mapping

- Both-project aggregation on three nodes: profile-scoped polling and node-parameterized tests.
- Wrong routing/project/repo and stale issue: refresh-plus-authorization negative matrix.
- No duplicate dispatch: global UUID ambiguity rejection plus existing atomic claim.
- Partial polling failure: structured per-profile outcomes and independent backoff.
- Runtime survives Linear/Supabase interruption: retry state tests and orchestrator liveness tests.
- Later eligible candidates progress: skip-and-continue selection tests.
- No second scheduler/queue/claim: one orchestrator cycle and unchanged ARO-164 acquisition path.
- No Production or ARO-286 scope: no deployment, schema, credential installation, or workspace
  isolation changes.
