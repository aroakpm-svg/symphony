# ARO-197 GitHub App and node rollout

> **Windows rollout blocked (2026-09-16):** The currently implemented restricted LocalSystem
> broker is write-restricted, not a private-key read-isolation boundary. Its directly spawned
> child can read a key allowed to SYSTEM even without a service-SID grant. Do not provision
> production keys for this launcher, start Windows acceptance with real secrets, enable its
> runtime, or treat the steps below as authorization. First review a worker security context
> that excludes controller secrets and prove read-only denial from the actual spawned child
> against a synthetic fixture. See [security evidence](aro_197_windows_read_boundary.md).
> ACL-shape validation and passing CI do not satisfy that acceptance gate.

This runbook provisions the ARO-195-approved automation identity after ARO-196. It does not run the
ARO-285 fleet workload.

## GitHub App contract

Create one organization-owned GitHub App with Metadata read, Contents read/write, Pull requests
read/write, and Checks read. Install it only on `aroakpm-svg/symphony`,
`aroakpm-svg/aroak-central-brain`, and `aroakpm-svg/aroak-project-management`. Do not grant
Administration, Deployments, Issues, Members, Secrets, Actions administration, or Workflow write.

Generate a different private key from the operator session on Amy, Matt, and Han. Keep each key only
on its node, outside runtime checkouts, workspaces, logs, health roots, and Codex homes. Run Symphony
under a controller principal and Codex under a different, unprivileged principal. Grant the key only
to the controller and deny the Codex principal access to its directory and file. On Windows use a
trusted local service/launcher for the identity transition; do not store a password in the workflow
or launcher. On Han use a distinct WSL account and a passwordless rule restricted to the exact Codex
launcher. Never put a key, token, JWT, or its full local path in GitHub, Linear, a receipt, or another
machine.

Codex workspace policies do not replace this identity boundary. In particular, a policy with full
read access can read any file allowed to its OS principal even when the file is outside the
workspace. Do not start rollout while Symphony and Codex still report the same principal.

## Runtime configuration

The node launcher supplies `SYMPHONY_GITHUB_APP_ID`, `SYMPHONY_GITHUB_APP_INSTALLATION_ID`,
`SYMPHONY_GITHUB_APP_EXPECTED_ACTOR`, and `SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE` locally, without
placing their values in command arguments. Start Symphony with `--github-app`. The switch stores only
the source module and expected actor in application options. All other values are read afresh for each
token request.

Also set `SYMPHONY_ADMISSION_PAUSE_FILE` to an absolute path under a controller-only runtime-state
directory. Absence of the file admits work; an existing regular file pauses candidate fetch,
retries, claims, and post-claim dispatch while existing workers continue. The runtime revalidates
the gate and every ancestor on each observation. On Unix, the direct parent must be `0700`, the
gate must not be group/other-writable, owners must be the controller (or root for the gate and
higher ancestors), and `getfacl` must prove that no named or default ACL exists. On Windows, the
direct parent must have a protected DACL and only the controller, SYSTEM, and local Administrators
may receive access; untrusted ancestor rights that can replace or retarget the path are rejected.
The exact TrustedInstaller SID is trusted only as the owner or an allow principal on higher
ancestors, never on the gate/key or their immediate parents. Evaluate each ACE against the current
path component: an inherit-only ACE does not apply to that component, while generic rights on an
applicable ACE must be mapped to their file-system rights before evaluation. A higher ancestor may
allow an untrusted principal to create a subdirectory only when it grants no delete, delete-child,
DACL/owner mutation, generic-write/all, or other unrecognized right.
Missing ACL inspection support, an unreadable DACL, or any unverifiable path fails closed. Do not
place the gate under a workspace, `/tmp`, or any tree writable by Codex.

The App key is checked on every token request before it is read. On Unix, keep its immediate
directory controller-owned `0700` and the key controller-owned `0600`; install the `getfacl`
utility and remove named/default ACLs. On Windows, both the key and its immediate directory must be
controller-owned, with protected DACLs whose allow entries name only the controller, SYSTEM, or
local Administrators. A broker service SID is not a key principal. Higher ancestors must have
trusted owners and no untrusted path-takeover rights. These checks do not make a same-UID Unix
worker safe: root and any process running as the controller can still read `0600` material, so the
separate unprivileged Codex identity and namespace boundary remain mandatory prerequisites.
The Windows Codex principal must not be a member of local Administrators; otherwise the trusted
Administrators allow entry necessarily collapses the intended controller/worker boundary.
Windows key-read rollout approval remains blocked by the identity issue recorded in
`elixir/docs/aro_197_windows_read_boundary.md`; the path validator alone is not key-read isolation
proof.

Configure `codex.command` to enter the dedicated Codex principal through the trusted node-local
launcher and only then execute `codex app-server`. The launcher must pass the existing private
`CODEX_HOME` and sanitized worker environment, must not inherit any `SYMPHONY_GITHUB_APP_*` value,
and must fail closed rather than falling back to the controller principal.

Give both principals access only to the invocation paths they must share. On Windows, do not create
a shared workspace group or grant the broker broad Modify rights on a workspace or profile root.
The restricted LocalSystem broker uses its single service SID, and the controller grants that SID
Modify only on the selected invocation's workspace, issue-private home, and selected Codex home.
Remove those explicit grants when the brokered process exits. Keep the App-key directory outside
all worker and broker ACL trees.

Han MUST NOT use a shared group or default ACL for the workspace. Symphony deliberately creates
each issue-private `.symphony-subprocess` home as controller-owned `0700` and re-attests that exact
owner and mode. The trusted, root-owned launcher must therefore enter a private mount and user
namespace, expose separate identity-mapped bind mounts of only the current issue workspace, that
issue's exact `<workspace-root>/<profile>/.symphony-subprocess/<issue>-rN` private-home subtree, and
the selected profile authentication home at their original absolute paths, and then change to the
dedicated Codex UID. Never map the workspace or profile root: doing so exposes sibling issues or
profiles.
Inside that namespace the mapped paths must appear owned by the Codex UID while the host view keeps
the controller ownership and `0700` modes. The App-key, runtime, health, and launcher-configuration
trees must not be mounted into that namespace. Restrict passwordless elevation to this immutable
launcher and fixed roots; reject arbitrary path arguments, missing identity-mount support, a mount
whose host ownership or mode changes, or any fallback to an ordinary bind mount/shared ACL. Keep the
key directory controller-owned `0700` and the key `0600`.

Enable the complete two-profile block from `WORKFLOW.md`, remove `worker.ssh_hosts`, remove repository
cloning from `after_create`, and use canonical HTTPS origins. Provision separate protected Codex homes
for `central-brain` and `project-management`, then complete Codex-managed ChatGPT login in each home.

## Per-node sequence

### Windows administrator installer

Amy and Matt share `priv/install_aro_197_windows.ps1`. `Plan` is the only mode permitted without an
elevated token and emits a masked, non-mutating JSON receipt. `Install` and `Rollback` require a real
elevated token. The installer accepts only `Amy` or `Matt`, a full 40-character runtime commit, an
absolute clean source checkout at that exact commit, a reviewed broker publish directory, and plain
non-reparse roots. It clones the reviewed commit into an independent checkout beside legacy runtimes,
never into the legacy `runtime` directory and never with a worktree link back to the source. The
node controller account must already exist; account lifecycle remains an operator responsibility.
The one broker service runs as restricted LocalSystem with its node-specific service SID enabled;
there is no password-bearing broker account or second service identity.

The installer has one identity-transition path. It installs the immutable runtime, broker publish
artifacts, secret-free broker configuration, protected ACLs, and a Manual Windows service that stays
Stopped. It also copies and hash-verifies the selected `codex.exe` into that protected broker version,
so the service never depends on a user-profile executable. Before mutation it requires the App key to
have protected ACLs whose readable principals are limited to the controller, SYSTEM, and local
Administrators. It does not create a worker Scheduled Task, an S4U task, a PowerShell identity launcher, or
another scheduler. The existing Symphony Scheduled Task remains responsible for orchestration and
uses the existing `codex.command` extension point to invoke the installed broker executable in
`--client` mode. The generated `codex-command.example.txt` is an operator aid; applying it to the
reviewed runtime configuration remains part of node validation.

Run the non-mutating check first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\priv\install_aro_197_windows.ps1 `
  -Node Amy -RuntimeCommit <full-reviewed-sha> -Mode Plan
```

After exact-head review, invoke `Install` from an administrator prompt and supply `-RuntimeSource`
as the clean reviewed checkout, `-BrokerArtifacts` as the reviewed `dotnet publish` output, and
absolute values for `-CodexExe`, `-WorkspaceRoot`, `-PrivateHomeRoot`, and `-CodexHomeRoot`. The
broker configuration contains only the controller SID, pipe name, executable and allowed roots. It
contains no App credential, token, installation identifier, password, or authentication material.
The broker fixes the executable to `codex --config shell_environment_policy.inherit=all app-server`; client requests may select only an allowed profile, canonical paths beneath those configured roots, the call-local `GH_TOKEN`, and the validated Codex model selected by the existing launch inputs. The token and model are forwarded only
to that brokered `codex app-server` process and are not stored in the service configuration or
machine environment. The generated command derives the profile from the current workspace namespace with Windows PowerShell 5.1-compatible path logic and grants the broker service Modify rights only to that invocation's workspace, private home, and Codex home, removing those explicit grants after the brokered Codex process exits. Symphony acquires a node-local broker launch lock before starting the app-server port. The generated command also uses a fail-fast node-global mutex around grant, broker call, and grant removal for cross-process protection; the installed broker service accepts one session at a time. Additional simultaneous Windows slots require separate reviewed service identities rather than overlapping ACL grants under one service SID.

Rollback requires the same node and commit. It reads the protected state manifest and removes only
the runtime directory, broker directory, configuration, service, and manifest recorded as created
by that install, and restores the exact prior ACLs for pre-existing workspace and profile roots.
It never disables, stops, rewrites, or removes any Scheduled Task, legacy runtime, dirty checkout,
pre-existing account, or pre-existing service. Installation leaves the broker Manual and Stopped.
After separate operator approval, start it and verify broker readiness before dry worker validation;
the Symphony Scheduled Task remains disabled until every acceptance gate passes. Repository scripts
are unsigned development artifacts; Authenticode-sign the reviewed release copy before an
`AllSigned` production invocation.

Keep the Scheduled Task disabled. Install a clean immutable build beside the previous runtime; never
overwrite a dirty checkout. Capture the prior task action, enabled state, runtime version, and a
secret-free configuration fingerprint.

Run dry preflight for both profiles. On Han, first prove from both namespace views that a synthetic
controller-owned `0700` issue-private home remains controller-owned `0700` on the host and appears
Codex-owned `0700` only inside the worker namespace. Prove a sibling issue and sibling profile are
absent from that namespace. Require the expected bot actor, exact repository, canonical main
branch, pull/push authority, singleton token scope, and quality contract. Probe an unauthorized repo
and require fail-closed denial. From an actual Codex turn, record the worker principal, verify it is
different from the controller, require both directory listing and direct key reads to fail, and
create, edit, then remove a sentinel inside that issue's workspace. Require the controller to
re-attest the workspace after the write. Only then may the operator switch the task to the new
runtime and enable it. Roll out Amy, then Matt, then Han inside WSL.

Stop on a 401/403, unexpected actor, source conflict, broader repository scope, wrong remote, missing
Codex login, health final-stop, or any secret appearing in output.

For rotation, create a replacement key on the same node, then atomically create the configured
admission-pause file. Wait until runtime status reports `polling.admission_paused?: true` and no poll
is in progress. Let existing work finish and require both `running` and `claimed` to be empty; any
post-gate claim must be released by the runtime. Stop the Scheduled Task and confirm the old BEAM
process has exited. Switch the task's local environment to the replacement key, restart the task with
the gate still present, and run both dry preflights through that exact restarted process. Confirm its
runtime version, controller/Codex principals, singleton token scope, and key-read denial before
revoking the old key at GitHub. Prove the old key cannot mint a credential for new work, then remove
the gate and require a successful poll. Do not simulate revocation by changing local expiry metadata
or validate only through a separate shell.

For rollback, disable the task, restore its prior action and configuration, revoke the new node key,
remove only the new immutable runtime and newly created empty workspaces, and restore the captured task
state. Preserve dirty legacy checkouts and pre-existing homes.

## Masked receipt

Record node name, controller principal, Codex principal, key-read denial, Han identity-mount host and
worker ownership/mode proof, workspace write/re-attest
result, admission-paused observation, zero-running/zero-claimed drain, OS/runtime boundary, App slug and bot actor, source type, installation repository names,
runtime commit, dry-preflight result classes, denied-repo result, restarted-process identity during
rotation, rotation/revocation result, rollback result, task state, and timestamps. Record no secret
values, JWTs, tokens, private-key fingerprints, or full secret paths.
