# Windows Codex broker

`Symphony.WindowsBroker.exe` is the single Windows controller-to-worker identity boundary used by
Symphony. It does not schedule, claim, retry, route, or track work.

The installer registers one node-specific service and leaves it Manual and Stopped:

```text
Service: AROAKSymphonyCodexAmy
Account: NT SERVICE\AROAKSymphonyCodexAmy
Command: Symphony.WindowsBroker.exe --service --config <protected-broker-settings.json>
```

Matt uses the corresponding `AROAKSymphonyCodexMatt` names. The virtual service account has no
stored password. `SERVICE_SID_TYPE_RESTRICTED` remains enabled as write hardening, but it is not the
read boundary; the separate virtual-account primary token is the read boundary. Service startup
fails before the pipe opens unless the current token user is the exact virtual account, is not
SYSTEM, is not elevated, and has neither enabled nor deny-only Administrators membership.

The generated `codex.command` wrapper invokes the client with only the selected profile and current
absolute issue workspace:

```text
Symphony.WindowsBroker.exe --client --pipe aroak-symphony-codex-amy --profile central-brain --workspace <absolute-issue-workspace>
```

The JSON pipe request contains exactly `protocol_version`, `request_id`, `profile`, and `workspace`.
Protocol version is 1, request IDs are 32 lowercase hexadecimal characters, and unknown JSON members
are rejected. The request cannot select an executable, arguments, private home, Codex home, model,
credential, token, or environment entry.

The protected schema-1 configuration maps `central-brain` and `project-management` to fixed workspace,
private-home, and Codex-home profile roots and pins the copied Codex executable. The broker rejects
relative, UNC, device, missing, out-of-profile, traversal, and reparse-point workspace paths. It maps
HOME, USERPROFILE, and CODEX_HOME from protected configuration only.

The pipe DACL permits the controller, broker account, SYSTEM, and local Administrators and denies
network tokens. DACL access is not application authorization: the server impersonates every client
and requires the exact configured `SymphonyCtl{Node}` SID before reading a request. Frames have a
fixed 5-byte header and a 1 MiB payload limit.

The broker starts only the configured executable with these fixed arguments:

```text
codex --config shell_environment_policy.inherit=all app-server
```

It constructs the child environment from the operating-system allowlist plus fixed HOME/Codex/Git
hardening entries. It does not forward `GH_TOKEN`, model selection, Linear values, GitHub App values,
JWTs, claims, controller settings, passwords, private-key settings, or ambient Git helpers. The
child is created with `CreateProcessW`, so it inherits the already-attested virtual-service-account
primary token. There is no `LogonUser`, `CreateProcessAsUser`, token duplication, or identity fallback.

The child is created suspended, assigned to a kill-on-close Job Object, and then resumed with only
the session's stdio handles. Client disconnect, service stop, idle timeout, and absolute timeout
terminate the process tree. Each service accepts one session at a time.

The installer applies protected DACLs. Administrators and the controller retain full control of the
approved worker roots; the service can traverse the top-level roots and has Modify only on the two
approved profile directories. The GitHub App key file and its containing directory must have
protected ACLs whose readers/owners are limited to the controller, SYSTEM, and Administrators. The
service account receives no key-directory or key-file access.

The `windows-broker` workflow publishes a test-only child probe and runs it through the installed
wrapper and real SCM service. The test reads the live service process token, checks the spawned child
token, requires synthetic-key directory listing and direct read to fail, requires an outside-root
read to fail, and requires workspace create/edit/delete to succeed. It then stops and rolls back the
service. The probe is CI test infrastructure and is not a production Codex executable.

Passing unit or hosted-runner tests does not authorize a Matt installation. Keep the Symphony task
disabled and admission paused. Matt installation with a synthetic fixture and live enablement are
separate authorization gates documented in `elixir/docs/aro_197_rollout.md`.

Run local broker tests with:

```powershell
dotnet test elixir\priv\windows-service\Symphony.WindowsBroker.Tests\Symphony.WindowsBroker.Tests.csproj --configuration Release
```
