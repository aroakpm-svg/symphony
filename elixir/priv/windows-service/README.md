# Windows Codex broker

`Symphony.WindowsBroker.exe` is the single Windows identity boundary used by Symphony. The same
binary runs as the Windows Service and as the `codex.command` client shim. It does not schedule,
claim, retry, or track work.

The installer starts the service with:

```text
Symphony.WindowsBroker.exe --service --config C:\ProgramData\AROAK\Symphony\broker-settings.json
```

For foreground diagnostics, `--server --config <absolute-path>` uses the same server code. Symphony
connects through the existing `codex.command` extension point:

```text
Symphony.WindowsBroker.exe --client --pipe aroak-symphony-codex-amy --profile central-brain --workspace <absolute-issue-workspace> --private-home <absolute-issue-private-home> --codex-home <absolute-profile-codex-home>
```

The schema-1 JSON configuration is secret-free and matches the Windows installer:

```json
{
  "schema": 1,
  "node": "Amy",
  "pipe_name": "aroak-symphony-codex-amy",
  "controller_sid": "S-1-5-21-...",
  "workspace_root": "C:\\ProgramData\\AROAK\\Symphony\\workspaces",
  "private_home_root": "C:\\ProgramData\\AROAK\\Symphony\\private-homes",
  "codex_home_root": "C:\\ProgramData\\AROAK\\Symphony\\codex-homes",
  "codex_exe": "C:\\ProgramData\\AROAK\\Symphony\\broker-<commit>\\codex.exe"
}
```

Only `Amy` and `Matt` nodes and the `central-brain` and `project-management` profiles are accepted.
The workspace must be below `<workspace_root>/<profile>`, the private home must be either `<private_home_root>/<profile>` or a descendant, and the Codex auth home must be either `<codex_home_root>/<profile>` or a descendant. The client derives the profile from the workspace namespace, not from
the Codex home leaf. Every existing path component is checked for reparse points before Codex starts.

The pipe DACL permits only SYSTEM and the configured controller SID and explicitly denies network
tokens. The server also impersonates every connected client and compares its SID with the configured
controller SID. Frames have a fixed 5-byte header and a 1 MiB payload limit. Standard input, output,
and error are proxied without interpreting app-server messages.

The broker starts the configured executable as `codex --config shell_environment_policy.inherit=all app-server`, adding only the validated model argument selected by Symphony launch inputs. It rebuilds the environment from a small
operating-system allowlist, sets the selected HOME, USERPROFILE, and CODEX_HOME values, and forwards
only the call-local `GH_TOKEN` carried by that broker request. It does not inherit Linear, GitHub
App, JWT, claim, controller, password, or key variables from the service process. Codex is created suspended, assigned to a kill-on-close Job Object, and only then resumed; the child process inherits only that session's stdio handles. Client
disconnect, service stop, idle timeout (default 15 minutes), and absolute timeout (default 4 hours)
terminate that entire tree. The generated command holds a node-global mutex across temporary ACL grant, broker call, and grant removal; each installed broker service also accepts one session at a time so service-SID ACL grants cannot overlap across workspaces or profiles.

Run the Windows integration suite with:

```powershell
.tools\dotnet\dotnet.exe test elixir\priv\windows-service\Symphony.WindowsBroker.Tests\Symphony.WindowsBroker.Tests.csproj --configuration Release
```
