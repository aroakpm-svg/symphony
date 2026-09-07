# ARO-197 GitHub App Rollout Design

**Work item:** ARO-197 / ARO-171C

## Goal

Provide the host-side implementation and operator procedure that let Amy, Matt, and Han resolve
fresh GitHub App installation tokens for the two approved project profiles, then roll the merged
ARO-196 runtime out with reversible, secret-safe evidence.

## Ticket and ownership check

ARO-195 approved one dedicated GitHub App/Bot identity, the three-repository installation allowlist,
and the minimum permissions. ARO-196 implemented the fail-closed consumer but deliberately left the
host source unconfigured. ARO-197 exclusively owns the source, App provisioning, three-node rollout,
rotation, revocation, rollback, and masked receipts. ARO-171 is a parent receipt and ARO-285 owns the
later live two-project and nine-slot acceptance. No open PR, remote branch, or separate ticket was
found that implements the ARO-197 host source.

## Required design

`SymphonyElixir.GitHubAppCredentialSource` is a persistent module callback accepted by the ARO-196
resolver. It maps only `github-central-brain` and `github-project-management` to their fixed approved
repositories. On every call it reads node-local App configuration, signs a short-lived RS256 App JWT,
and requests an installation token narrowed by GitHub's `repositories` field to exactly one target.
It returns GitHub's token and parsed `expires_at` without caching either value.

The operator enables this source with a non-secret CLI switch. App ID, installation ID, expected bot
actor, and the absolute private-key file location come from dedicated `SYMPHONY_GITHUB_APP_*`
environment variables owned by the local runtime launcher. The switch copies only the source module
and expected actor into application options; IDs, paths, private-key bytes, JWTs, tokens, and raw
responses never enter Orchestrator state, command arguments, logs, health, receipts, or workspaces.
Missing, conflicting, malformed, redirected, or inaccessible configuration fails before startup or
returns the existing secret-safe resolver failure.

ARO-197 additionally configures one controller-only `SYMPHONY_ADMISSION_PAUSE_FILE`. Missing gate
files admit work; an existing regular file stops fetch, retry, claim, and post-claim dispatch without
terminating active workers. An invalid configured path fails closed, and runtime status exposes the
observed pause so rotation can prove admission is frozen before waiting for zero active claims.

The private key must be a real regular file outside every workspace. All existing path components
must be real directories, and Windows reparse points and Unix symlinks are rejected through the
shared workspace path checks. The Symphony controller and the Codex worker MUST use different OS
security principals. Only the controller principal may read the key; the Codex principal must be
denied the key directory and file. A workspace sandbox with full filesystem read access is not this
boundary. Windows therefore needs a trusted service/launcher that starts Codex under a dedicated
unprivileged account; Han uses a distinct WSL user through a passwordless, command-restricted
launcher. Each node receives its own App private key so one node can be revoked without distributing
the same secret between machines. The App identity and installation remain common across all nodes.

GitHub responses are accepted only for HTTP 201 with exactly a nonblank token and a valid future
`expires_at`. Authentication, authorization, rate-limit, transport, malformed-response, key, and
configuration failures collapse to the resolver's existing secret-safe contract. The source never
returns an installation-wide token: every request contains one approved repository name.

## Rollout

Create one GitHub App with Metadata read, Contents read/write, Pull requests read/write, and Checks
read, and install it only on `aroakpm-svg/symphony`, `aroakpm-svg/aroak-central-brain`, and
`aroakpm-svg/aroak-project-management`. Generate a distinct private key from each node's operator
session and keep it only on that node.

Deploy a clean immutable runtime directory rather than modifying Amy's dirty legacy checkout.
Provision the controller/Codex principal split and make the configured `codex.command` enter the
Codex principal through the trusted launcher before executing `codex app-server`.
Provision a narrowly scoped shared group/ACL on the workspace and per-profile Codex-home roots so
controller-created descendants remain writable by Codex, while the key and runtime trees remain
controller-only.
Create protected, separate Codex homes for `central-brain` and `project-management`, complete the
chosen ChatGPT login in each home, remove legacy clone hooks, migrate reused origins to canonical
HTTPS, and keep the existing tasks disabled while dry preflight runs.

Roll out Amy, then Matt, then Han/WSL. For each node, record only actor, source type, repository,
success/failure class, version, and timestamps. Prove both profile tokens are singleton-scoped,
cross-repository access fails, the expected bot actor is seen inside the actual worker environment,
the Codex worker reports a different principal from the controller and cannot list or read the key,
the worker can create/edit/remove a workspace sentinel and the controller can re-attest afterward,
old key material cannot start new work after revocation, and rollback restores the prior disabled
runtime. ARO-285, not this work item, starts the live fleet workload and proves nine-slot capacity.

Rotation must create the gate, observe the paused status with no poll in flight, drain to zero
running and claimed work, stop the old BEAM process, switch the task environment, restart that exact
task behind the still-present gate, and validate both profiles through the restarted process before
the old key is revoked. A dry shell using the replacement key does not prove that the active runtime
inherited it. The gate is removed only after old-key rejection is proven.

## Non-goals

- No third `symphony` dispatch profile.
- No remote token broker, shared secret store, or second scheduler. A local isolated Codex launcher
  is part of the required host security boundary.
- No change to ARO-196 resolver, authority, retry, or fail-closed policy.
- No Production access, billing, automatic merge, Linear state mutation, or ARO-285 workload.

## Acceptance

- Unit tests prove exact ref-to-repository binding, per-call token minting, JWT signing, expiration
  parsing, singleton repository requests, secret-safe failures, and absence of caching.
- CLI tests prove explicit enablement, missing/conflicting configuration rejection, expected-actor
  wiring, and unchanged legacy startup.
- Path tests cover symlink/reparse and non-regular private-key rejection.
- Linux `make all` and latest-head review pass before any rollout artifact is used.
- Three masked node receipts prove principal separation, key-read denial from the actual Codex
  worker, provisioning, dry preflight, rotation/revocation, and rollback.
