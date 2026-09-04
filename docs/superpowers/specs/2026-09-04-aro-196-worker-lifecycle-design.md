# ARO-196 topology decision — superseded remote lifecycle proposal

Date: 2026-09-04

Status: superseded by the user's clarification: 「三台本機可以自己執行自己的」.

Amy, Matt, and Han each run their own node-local Symphony. Han runs Symphony locally inside WSL,
not as Amy's SSH worker. Enabled `project_profiles` requires absent/empty `worker.ssh_hosts`.
Startup and new-work poll/dispatch/retry admission reject nonempty hosts with
`profiled_ssh_topology_unsupported`; direct profiled runner remote-host overrides fail before
credential resolution. Runtime settings remain readable after a topology-invalid reload for
active local reconciliation, lease, and cleanup obligations. Legacy unprofiled SSH is unchanged.
Lower-level remote defensive/test seams do not prove supported profiled remote execution.

The earlier remote lifecycle adapter proposal is preserved in Git history, but is not an active
implementation requirement or deployment authorization. ARO-196 does not implement that adapter.

PR #48 comment 3930363562 and the synthetic SSH/WSL-alias reproduction remain valid: the existing
remote path cannot safely carry the profiled environment through preparation, hooks, Codex, and
cleanup. The correction is an explicit capability boundary, not a claim that SSH support is fixed.
No guard is weakened, credential exported through SSH argv, or unsupported host silently changed
to local execution.

The canonical resolver design governs node-local double validation, isolated child environments,
attested workspace/private-home lifecycle, cleanup, and retries. ARO-197 owns provisioning and
three-machine rollout. ARO-285 owns live acceptance. Synthetic tests imply no live machine result.
A future need for profiled cross-host execution requires a separate explicit scope and security
design decision.
