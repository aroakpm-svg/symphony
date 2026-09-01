# ARO-286 Project Workspace and Runtime Observability Design

## Purpose

ARO-286 closes the execution-layer gap left after ARO-289 and ARO-287. ARO-289 defines the
approved project profiles, and ARO-287 binds an authorized issue to exactly one profile through
polling, routing, preflight, claim, and dispatch. The current worker path then discards that
project-scoped execution context: `AgentRunner` asks `Workspace` for a directory keyed only by the
issue identifier. Runtime diagnostics are likewise spread across free-form logs rather than one
secret-safe stage model.

This change makes the selected approved profile mandatory execution context for multi-project
workers. It derives a deterministic project-and-issue workspace, preserves the selected repository,
branch, and credential reference through readiness, and exposes enough structured health evidence to
locate a failure without changing the running service.

## Ticket Boundary

The implementation covers the ARO-286 requirements:

- workspace paths contain project identity and issue identifier;
- checkout, continuation branch reuse, canonical-head evidence, and credential reference remain
  bound to the selected profile;
- Linear credentials are validated by a real read-only request at startup rather than by string
  presence;
- candidate fetch, issue refresh, routing, profile resolution, preflight, claim, and dispatch expose
  secret-safe stage status;
- diagnostics expose the last successful poll, Linear and claim-store connectivity, and the final
  runtime stop reason;
- repeated Windows restart failure produces one idempotent, secret-safe notification through an
  injected local notification boundary;
- 401, missing or changed mapping, workspace collision, wrong repository, head drift, and
  Production-like paths fail closed.

The implementation does not create or modify credentials, deploy, touch Production, create an
external notification service, or introduce a second scheduler, claim path, capacity store, lease,
or workspace manager.

## Related Tickets and Ownership

- ARO-289 owns the versioned approved profile schema and allowlist.
- ARO-288 owns node-wide capacity.
- ARO-287 owns multi-project polling, exclusive routing, repository preflight, atomic claim, and
  dispatch authorization.
- ARO-195 owns the three-machine GitHub credential inventory and automation identity decision.
- ARO-196 owns the canonical GitHub credential-source resolver and GitHub authority preflight.
- ARO-285 owns the final non-Production end-to-end acceptance.
- ARO-295, ARO-296, and ARO-298 are duplicates of the ARO-285 workstream and add no independent
  implementation authority.

ARO-286 therefore consumes a profile-scoped credential boundary but does not implement the generic
GitHub credential resolver owned by ARO-196. Tests use opaque credential handles and injected
resolvers; no secret value is stored in a profile, workspace state, health record, log, or fixture.

## Design Decisions

### 1. One immutable execution context

Introduce a typed `ProjectExecutionContext` created only from an already-authorized issue and its
approved profile. It contains the issue identity, profile key, Linear project identity, repository,
canonical branch, workspace namespace, credential reference, environment, and routing revision.

Construction validates that the issue still carries the same repository and project identity as its
profile. Missing, malformed, contradictory, or Production-like values return a stable fail-closed
reason. The context has a secret-safe projection for logs and status; it never contains credential
material.

`Orchestrator` passes this context to `AgentRunner`. `AgentRunner`, `Workspace`, readiness checks,
hooks, and Codex startup consume the same value. No downstream component re-resolves a project from
display names, issue identifiers, repository names, or ambient credentials.

The legacy single-project path remains unchanged and may continue without a project execution
context.

### 2. Project-and-issue workspace namespace

For a multi-project issue, the local path is:

```text
<workspace.root>/<workspace_namespace>/<sanitized_issue_identifier>
```

Both path segments are validated before joining, and the final canonical path must remain beneath
the configured workspace root. Remote workers use the same relative namespace. The workspace
readiness state records the profile key, Linear project identity, repository, canonical branch,
workspace namespace, and credential reference in addition to the existing issue and checkout
evidence.

Reusing a directory requires exact equality between its durable context and the selected execution
context. A legacy directory, another project's directory, a symlink escape, a Production-like root,
or any mismatched repository, branch, or credential reference is rejected rather than migrated or
silently reused. Cleanup computes the same context-bound target and never recursively targets the
workspace root.

### 3. Credential isolation without a second resolver

`credential_ref` remains an opaque approved identifier. ARO-286 adds a narrow execution boundary
that accepts the selected reference and returns process-local Git/application environment for that
one worker attempt. The boundary must reject a missing mapping, ambiguous mapping, wrong profile,
or secret-bearing diagnostic.

The resolver implementation is injectable. Until ARO-195 and ARO-196 define the canonical GitHub
source, the default runtime remains fail closed when a multi-project credential reference cannot be
resolved by an approved provider. ARO-286 does not fall back to ambient `GH_TOKEN`, `GITHUB_TOKEN`,
keyring state, or another profile's result.

Resolved values are passed only to the specific subprocess environment. They are not written to
workspace state, application state, command arguments, logs, status surfaces, exceptions, or
notifications. Sanitization occurs before truncation.

The Linear tracker credential is a separate node-level credential. Startup performs an actual
read-only identity query through the existing tracker client. Missing credentials, 401/403, an
unexpected workspace identity, or an unclassifiable response blocks startup. A transient connection
failure is reported distinctly from authentication failure and follows the existing retry policy
after a previously valid startup.

### 4. Runtime health is one state model

Add a `RuntimeHealth` process as the single owner of current diagnostic state. It records bounded,
secret-safe facts only:

- last successful poll timestamp;
- Linear connectivity and last failure category;
- claim-store connectivity and last failure category;
- current stage per profile or issue;
- final runtime stop category and correlation context;
- Windows restart attempt count and terminal notification status.

The stage enum is fixed to `candidate_fetch`, `issue_refresh`, `routing`, `profile_resolution`,
`preflight`, `claim`, and `dispatch`. Transitions include profile key and, when available, both
`issue_id` and `issue_identifier` as required by `elixir/docs/logging.md`. Raw payloads, URLs with
userinfo, credential references, command output, stack dumps containing environment values, and
secret values are never accepted as health fields.

Existing logs and the status dashboard read from or mirror this model; ARO-286 does not introduce a
new dashboard or persistent database. A bounded local receipt records the final stop category so an
unexpected process exit is not silent. Writes are atomic and remain below a dedicated runtime-state
directory, never inside a project workspace.

### 5. Windows restart-limit notification

The Windows launcher reports each failed restart to the same health boundary. At the configured
limit, it emits one stable notification event keyed by runtime identity and failure epoch. Delivery
uses an injected notifier interface so tests can prove receipt without creating an external
resource. The runtime invokes an explicitly configured local notification command with a bounded
secret-safe JSON event on standard input; configuration must identify the intended human receiver
without containing a credential value. Missing command or receiver configuration fails the restart
notification gate closed. The default diagnostic path also writes a local receipt and emits a
high-severity operator log, but those local records do not count as successful human delivery.

Repeated launcher invocations with the same epoch are idempotent. Notification content contains the
runtime identity, opaque receiver identifier, attempt count, stop category, timestamp, and receipt
path only. A zero exit status from the configured command records delivery; timeout, non-zero exit,
or malformed configuration records an undelivered terminal notification without exposing command
output that may contain secrets.

## End-to-End Flow

1. Startup validates config and performs the real read-only Linear identity check.
2. Polling records `candidate_fetch`; a successful complete cycle updates `last_successful_poll_at`.
3. ARO-287 performs refresh, routing, profile resolution, repository preflight, capacity, and claim,
   recording the corresponding bounded stage outcome.
4. Immediately before spawning, `ProjectExecutionContext` is built from the authorized issue and
   profile. Failure releases or retains the claim according to the existing ARO-287 ownership state
   machine; it does not create a workspace.
5. `AgentRunner` passes the context to `Workspace`, which computes and validates the namespaced path,
   creates or verifies durable context state, and resolves only the selected credential reference.
6. Readiness and Codex startup use the same context and subprocess environment. A mismatch stops the
   attempt before Codex runs.
7. Completion and cleanup use the same context-derived workspace target.
8. Runtime shutdown records a final bounded stop category. The Windows launcher escalates only when
   its retry limit is reached.

## Failure Semantics

Deterministic authorization or isolation failures are permanent for that attempt and fail closed:

- profile missing, changed, duplicated, or inconsistent with the issue;
- workspace namespace collision or path escape;
- durable workspace context mismatch;
- wrong repository, canonical branch, head, or credential reference;
- Production-like environment or path;
- Linear 401/403 or unexpected identity;
- missing or ambiguous profile credential mapping.

Temporary network or dependency failures retain the existing ARO-287 ownership and retry semantics.
Health recording must never change whether a claim is retained, released, or retried. Failure to
write diagnostic state is logged and surfaced but cannot turn an unauthorized issue into an
authorized one.

## Testing Strategy

Tests are written before implementation and cover:

- deterministic paths for both approved projects and the same issue identifier;
- cross-project workspace collision, symlink escape, and Production-like root rejection;
- durable context equality and rejection of repository, branch, project, head, workspace namespace,
  or credential-reference drift;
- one profile's resolver result never being visible to the other profile's command environment;
- missing, ambiguous, and wrong-profile credential mappings;
- Linear startup validation success, 401/403, missing mapping, wrong workspace identity, and
  transient connectivity;
- every required health stage, last successful poll, dependency state, final stop reason, and
  secret rejection/sanitization;
- runtime crash receipt and idempotent restart-limit notification delivery;
- legacy single-project behavior;
- ARO-287 retry, claim ownership, capacity, and cleanup regressions.

The fresh Windows baseline is recorded as 843 of 884 tests passing with 41 pre-existing failures
caused by the local Bash/Codex/line-ending test environment. ARO-286 development must introduce no
additional failures: all new focused tests, all related existing suites, formatter, specs check,
Credo, Dialyzer, and available repository quality gates must pass. Final reporting keeps any
unchanged environmental baseline failures explicit.

## Acceptance Mapping

| ARO-286 acceptance | Evidence produced by this design |
| --- | --- |
| Cross-repo/workspace/credential isolation | Typed execution context, namespaced paths, durable context equality, subprocess-only credential environment |
| Head drift and wrong repo fail closed | Existing readiness evidence bound to the same execution context |
| 401 and missing mapping regressions | Real Linear startup identity check and injected profile credential boundary tests |
| Observable poll/dispatch stop point | Fixed `RuntimeHealth` stage enum and bounded status records |
| Last poll and dependency state | Runtime health snapshot |
| Explicit runtime stop reason | Atomic local shutdown receipt |
| Windows restart-limit human notification | Idempotent configured-command notifier, local receipt, and receiver-bound delivery test |
| No secrets in diagnostics | Typed allowed fields, sanitization-before-truncation, secret rejection tests |
| No deployment/Production/external resources | Explicit fail-closed environment/path rules and local-only test fixtures |
