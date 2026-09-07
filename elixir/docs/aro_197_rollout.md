# ARO-197 GitHub App and node rollout

This runbook provisions the ARO-195-approved automation identity after ARO-196. It does not run the
ARO-285 fleet workload.

## GitHub App contract

Create one organization-owned GitHub App with Metadata read, Contents read/write, Pull requests
read/write, and Checks read. Install it only on `aroakpm-svg/symphony`,
`aroakpm-svg/aroak-central-brain`, and `aroakpm-svg/aroak-project-management`. Do not grant
Administration, Deployments, Issues, Members, Secrets, Actions administration, or Workflow write.

Generate a different private key from the operator session on Amy, Matt, and Han. Keep each key only
on its node, outside runtime checkouts, workspaces, logs, health roots, and Codex homes. Restrict
Windows ACLs to the Scheduled Task principal. On Han, store the key inside WSL with owner-only read
access. Never put a key, token, JWT, or its full local path in GitHub, Linear, a receipt, or another
machine.

## Runtime configuration

The node launcher supplies `SYMPHONY_GITHUB_APP_ID`, `SYMPHONY_GITHUB_APP_INSTALLATION_ID`,
`SYMPHONY_GITHUB_APP_EXPECTED_ACTOR`, and `SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE` locally, without
placing their values in command arguments. Start Symphony with `--github-app`. The switch stores only
the source module and expected actor in application options. All other values are read afresh for each
token request.

Enable the complete two-profile block from `WORKFLOW.md`, remove `worker.ssh_hosts`, remove repository
cloning from `after_create`, and use canonical HTTPS origins. Provision separate protected Codex homes
for `central-brain` and `project-management`, then complete Codex-managed ChatGPT login in each home.

## Per-node sequence

Keep the Scheduled Task disabled. Install a clean immutable build beside the previous runtime; never
overwrite a dirty checkout. Capture the prior task action, enabled state, runtime version, and a
secret-free configuration fingerprint.

Run dry preflight for both profiles. Require the expected bot actor, exact repository, canonical main
branch, pull/push authority, singleton token scope, and quality contract. Probe an unauthorized repo
and require fail-closed denial. Only then may the operator switch the task to the new runtime and
enable it. Roll out Amy, then Matt, then Han inside WSL.

Stop on a 401/403, unexpected actor, source conflict, broader repository scope, wrong remote, missing
Codex login, health final-stop, or any secret appearing in output.

For rotation, create a replacement key on the same node, switch its local launcher, repeat both dry
preflights, then revoke the old key at GitHub. Prove the old key cannot mint a credential for new work;
do not simulate revocation by changing local expiry metadata.

For rollback, disable the task, restore its prior action and configuration, revoke the new node key,
remove only the new immutable runtime and newly created empty workspaces, and restore the captured task
state. Preserve dirty legacy checkouts and pre-existing homes.

## Masked receipt

Record node name, runtime principal, OS/runtime boundary, App slug and bot actor, source type,
installation repository names, runtime commit, dry-preflight result classes, denied-repo result,
rotation/revocation result, rollback result, task state, and timestamps. Record no secret values,
JWTs, tokens, private-key fingerprints, or full secret paths.
