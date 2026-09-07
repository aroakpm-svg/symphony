# ARO-197 GitHub App and node rollout

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
directory. The parent must already be a real, non-reparse directory. Absence of the file admits work;
an existing regular file pauses candidate fetch, retries, claims, and post-claim dispatch while
existing workers continue. Invalid configured paths fail closed. Do not place the gate under a
workspace or any tree writable by Codex.

Configure `codex.command` to enter the dedicated Codex principal through the trusted node-local
launcher and only then execute `codex app-server`. The launcher must pass the existing private
`CODEX_HOME` and sanitized worker environment, must not inherit any `SYMPHONY_GITHUB_APP_*` value,
and must fail closed rather than falling back to the controller principal.

Give both principals access only to the workspace and Codex-home roots they share. On Windows,
create a node-local workspace group, grant that group Modify on the workspace root, grant each
profile home only to the controller and Codex principals, and keep the App-key directory outside
both ACL trees.

Han MUST NOT use a shared group or default ACL for the workspace. Symphony deliberately creates
each issue-private `.symphony-subprocess` home as controller-owned `0700` and re-attests that exact
owner and mode. The trusted, root-owned launcher must therefore enter a private mount and user
namespace, expose identity-mapped bind mounts of only the selected workspace root and selected
profile Codex home at their original absolute paths, and then change to the dedicated Codex UID.
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

Keep the Scheduled Task disabled. Install a clean immutable build beside the previous runtime; never
overwrite a dirty checkout. Capture the prior task action, enabled state, runtime version, and a
secret-free configuration fingerprint.

Run dry preflight for both profiles. On Han, first prove from both namespace views that a synthetic
controller-owned `0700` issue-private home remains controller-owned `0700` on the host and appears
Codex-owned `0700` only inside the worker namespace. Require the expected bot actor, exact repository, canonical main
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
