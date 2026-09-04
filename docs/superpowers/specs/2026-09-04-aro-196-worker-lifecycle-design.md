# ARO-196 worker-local lifecycle design

Date: 2026-09-04

Status: approach approved by the user; written specification awaiting review.

This supplements the 2026-09-03 canonical credential resolver design. Where that design
describes controller callbacks returning remote credentials or controller-built environments
for remote effects, this specification supersedes that mechanism. Its identity policy,
repository boundaries, fail-closed rules, and non-goals remain unchanged.

## Purpose and evidence

PR #48 review comment 3930363562 identifies a real integration failure at commit 4c3078c.
The actual AgentRunner entry point resolves authority and then passes a nonempty isolation
environment to Workspace, whose remote guard rejects it. Synthetic SSH and WSL-host-alias
reproductions both fail before the transport is reached. These are not live machine tests.

Removing that guard is unsafe and incomplete: Workspace serializes remote environment values
into shell commands, SSH carries those commands in argv, AppServer rejects nonempty remote
environments, and remote private-home preparation does not provide a local capability.
SubprocessEnvironment also uses the controller's OS and paths. The defect is therefore a
split lifecycle ownership boundary, not a malformed environment variable.

The required result is one supported worker-local lifecycle, with a regression that starts at
the real orchestration/AgentRunner boundary and reaches execution and cleanup safely.

## Scope

ARO-196 owns the repository implementation and tests. ARO-197 retains installation,
credential provisioning, host configuration, rotation/revocation smoke, and rollout.
ARO-285 retains live three-machine/two-project acceptance. ARO-286's existing ownership and
isolation protections are reused, not replaced or weakened.

No new scheduler, network daemon, generic remote shell API, credential cache, database schema,
deployment, or third dispatch profile is introduced. Existing legacy unprofiled execution
remains supported without being silently converted to the new credential policy.

## Chosen architecture

Use a trusted worker-side lifecycle entry point in the same Symphony codebase. The controller
starts a bounded worker process using the configured SSH target, including WSL reached via its
existing SSH target. This is an on-demand process, not another polling Symphony service.

The controller retains polling, routing, claim/lease ownership, capacity, retry decisions, and
the issue-state authority it already owns. The worker owns all host-dependent operations:
authority checks, environment construction, preparation, bootstrap, checkout, readiness,
hooks, Codex session, and workspace/private-home cleanup.

The worker invokes a shared local lifecycle implementation. Local profiled execution uses
that same implementation directly. Host selection is resolved before entering the lifecycle;
there is no recursive remote dispatch and no stage-by-stage fallback to controller execution.

Two alternatives were rejected:

- Removing guards or passing an empty environment would either leak credentials through
  command strings or disable required isolation and authentication.
- Forwarding a controller-built environment over a new secret-bearing protocol would retain
  the wrong OS/path authority and create unnecessary cross-machine credential exposure.

## Trusted launch and control channel

The launch command is selected only from trusted operator configuration, outside issue content
and outside the per-issue repository. It starts the installed worker entry point without
embedding tokens, environment maps, issue text, or arbitrary function names in argv. Existing
SSH host authentication is retained; no SSH configuration is changed by this implementation.

A versioned, bounded JSON control stream over the process pipes carries only validated data.
It is separate from Codex's JSON-RPC stream, which stays entirely inside the worker.
Supported operations are authority assessment, one issue attempt, cancellation, and retirement
of an attested workspace. This is not an arbitrary executable/command dispatch protocol.

Requests carry an attempt identifier, selected worker identity, immutable execution context,
opaque credential reference, and the minimum issue/claim metadata required by existing
lifecycle checks. They never serialize closures, Application configuration, runtime environment
maps, credentials, private-home capabilities, or arbitrary Erlang terms. Unknown fields,
operations, malformed messages, and incompatible versions fail closed before effects.

The worker validates the requested identity and profile against its own trusted configuration,
including repository, branch, namespace, credential reference, environment and routing revision.
An echoed identity alone is not proof: target selection is bound to the authenticated transport
and the configured worker identity. Controller filesystem evidence is not worker evidence.

The control protocol has explicit message-size, buffering, startup, operation, and shutdown
limits in the implementation contract. Tests must prove overflow, truncation, and timeout
behavior; unlimited buffering or silently ignored malformed frames is forbidden.

## Credential and environment ownership

Both pre-claim authority assessment and post-claim execution use credentials resolved on the
selected worker. Pre-claim returns only safe authority evidence; post-claim resolves afresh.
No token or credential-bearing request header is returned to the controller.

The worker builds its environment using its own OS, runtime paths, null device and approved
profile. It creates and validates its own namespaced private HOME and metadata capabilities.
Canonical Git credentials enter only immediate local child environments, using the existing
fixed HTTPS-GitHub helper and ambient-credential denial policy.

Raw credentials remain call-local on the worker. They do not enter control frames, argv,
shell command strings, files, workflow documents, receipts, retry state or controller logs.
Missing worker configuration is a typed blocker, never permission to use controller credentials.

## Lifecycle and cleanup

Execution order remains: fresh authority -> attested workspace/private-home preparation ->
bounded bootstrap when new -> checkout validation -> deferred after_create -> readiness and
before_run -> Codex -> after_run. Existing lifecycle rules determine which stages run and
which outcomes are retried; the adapter does not introduce a second retry policy.

Worker-local path and private-home capabilities never become portable authorization tokens.
Before effects, paths are checked against the worker's configured root and current ownership.
Failure rollback removes only resources created by the failed attempt. Reused workspaces and
pre-existing private homes are preserved according to existing ownership rules.

Terminal reconciliation and before_remove also execute on the selected worker through the
same local isolation boundary. A later retirement process revalidates durable non-secret
ownership evidence; it cannot trust a stale in-memory capability or an arbitrary controller path.
Cleanup must not reuse expired/retired credentials. If a hook needs authentication, current
worker-local policy must authorize it; failure follows the existing documented hook/cleanup
semantics without ambient fallback.

## Cancellation and failure reporting

Attempt completion, cancellation, transport loss and process exit have distinct outcomes.
Cancellation and channel loss stop the worker's child process tree, not only its controller
proxy. The controller must not treat transport failure as proof that remote effects stopped.
Unconfirmed shutdown remains an explicit uncertain outcome under existing reconciliation and
lease rules; no new attempt may be authorized by fabricating a successful stop receipt.

Worker output is filtered before crossing the boundary. Only allowlisted lifecycle events,
bounded diagnostics and typed failure reasons are returned. Raw exceptions, HTTP bodies,
environment maps and unfiltered child stdout/stderr are not control messages. Unexpected worker
output fails safely without echoing potentially sensitive content into controller logs.

Controller issue-state and claim decisions needed during a turn are represented by bounded
control messages; worker execution does not acquire independent polling, tracker credentials,
or authority to create a second scheduler. Existing continuation and claim checks must not be
silently skipped during extraction of the local lifecycle.

## Verification and completion criteria

All credential fixtures are synthetic. Tests disable real credential helpers/stores, external
network and unintended host execution. No test assertion prints credential-bearing output.

Required evidence:

1. Real AgentRunner/Orchestrator entry path reaches the worker-local lifecycle, not only a
   helper such as post_claim_gate_for_test. Local and remote paths share lifecycle behavior.
2. A process-backed synthetic worker test covers protocol framing and preparation through
   bootstrap, checkout, hooks, readiness Git, Codex events, completion and retirement.
3. Controller/worker OS mismatch demonstrates that worker paths and isolation policy win.
   A WSL alias fixture is labeled simulated; it is not claimed as live WSL acceptance.
4. Fresh/reused workspaces, head drift, source absence/conflict, worker/profile mismatch,
   malformed protocol, lost connection, cancellation and partial preparation failures preserve
   authority and ownership boundaries. Unsupported workers fail before side effects.
5. Sentinel credentials are absent from captured argv, scripts, protocol frames, controller
   state/events/logs and files. Native Git receives the canonical synthetic credential only
   through its approved worker-local environment.
6. Existing claim, retry, continuation, local/legacy behavior and cleanup tests remain valid.
7. Serial affected tests, independent security/integration review and exact-head Linux make-all
   pass with the existing 100% coverage requirement and unchanged exclusion policy.

Passing repository tests does not prove deployment or live E2E. PR completion still requires
latest-head review convergence; no automatic merge, Linear completion or rollout is authorized.

## Written-spec review

This document records the approved architectural direction and makes its lifecycle obligations
explicit. Implementation planning begins after the user reviews this written specification.
The remaining work is implementation, verification and PR review, not deployment.
