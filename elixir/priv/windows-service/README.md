# Windows Codex broker

`Symphony.WindowsBroker.exe` is the single Windows identity boundary used by Symphony. The same
binary runs as the Windows Service and as the `codex.command` client shim. It does not schedule,
claim, retry, route, or track work.

The installer registers one node-specific Manual service and leaves it stopped:

```text
Service: AROAKSymphonyCodexAmy
Account: NT SERVICE\AROAKSymphonyCodexAmy
Command: Symphony.WindowsBroker.exe --service --config <protected-broker-settings.json>
```

Matt uses the corresponding `AROAKSymphonyCodexMatt` names. The virtual service account has no
stored password. `SERVICE_SID_TYPE_RESTRICTED` remains enabled as write hardening, but it is not the
read boundary; the separate virtual-account primary token is the read boundary. Before opening the
pipe, service startup requires the current token user to be that exact virtual account and rejects
SYSTEM or any other SID.

For foreground diagnostics, `--server --config <absolute-path>` uses the same server code. Symphony
connects through the existing `codex.command` extension point:

```text
Symphony.WindowsBroker.exe --client --pipe aroak-symphony-codex-amy --profile central-brain --workspace <absolute-issue-workspace> --private-home <absolute-issue-private-home> --codex-home <absolute-profile-codex-home>
```

The schema-1 JSON configuration is secret-free and pins the node, service and pipe names,
controller SID, workspace/private-home/Codex-home roots, and copied Codex executable. Only `Amy` and
`Matt` nodes and the `central-brain` and `project-management` profiles are accepted. Request paths
must be canonical descendants of their configured profile roots; relative, UNC, device, traversal,
missing, and reparse-point paths are rejected.

`--private-home` is the issue-scoped subprocess `HOME`; its protected `gh`, `xdg-config`,
`xdg-cache`, `xdg-data`, and `codex` children receive the same temporary service-SID grant for one
serialized broker call. `--codex-home` is the separately provisioned profile authentication home.

The pipe DACL permits only SYSTEM, the configured controller SID, and the service identity, and
explicitly denies network tokens. The server also impersonates every connected client and requires
the exact configured controller SID before reading a request. Frames have a fixed 5-byte header and
a 1 MiB payload limit.

The broker starts only the configured executable as
`codex --config shell_environment_policy.inherit=all app-server`, adding the validated model selected
by the existing Symphony launch inputs. It rebuilds the environment from a small operating-system
allowlist, sets HOME, USERPROFILE, and CODEX_HOME, and forwards only the call-local `GH_TOKEN` carried
by that broker request. It does not inherit Linear, GitHub App, JWT, claim, controller, password, or
private-key variables from the service process.

The child is created with `CreateProcessW`, so it inherits the virtual-service-account primary
token. It is created suspended, assigned to a kill-on-close Job Object, and resumed with only the
session's stdio handles. Client disconnect, service stop, idle timeout, and absolute timeout
terminate the process tree. Each service accepts one session at a time.

The controller grants the service SID Modify rights only on the selected invocation's workspace,
private home, and Codex home, then removes those explicit grants after the brokered process exits.
The generated wrapper holds a fail-fast node-global mutex across grant, broker call, and removal so
temporary grants cannot overlap. No permanent service Modify grant is placed on a profile root.
The GitHub App key and its containing directory stay outside those ACL trees and grant no access to
the service identity.

The `windows-broker` workflow publishes a test-only child probe and runs it through the installed
wrapper and real SCM service. It verifies that the live service process and spawned child use the
expected virtual-account SID, that the child cannot list or read a synthetic key, and that it can
create, edit, and delete a workspace file. It then stops and rolls back the service. The probe is CI
test infrastructure and is not a production Codex executable.

Passing unit or hosted-runner tests does not authorize a Matt installation or live enablement. Those
remain separate approval gates documented in `elixir/docs/aro_197_rollout.md`.

Run local broker tests with:

```powershell
dotnet test elixir\priv\windows-service\Symphony.WindowsBroker.Tests\Symphony.WindowsBroker.Tests.csproj --configuration Release
```
