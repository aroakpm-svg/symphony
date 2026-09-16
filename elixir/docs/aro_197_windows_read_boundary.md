# Restricted Windows service: private-key read boundary

Research date: 2026-09-16. Read-only source/document review; no service, credential, ACL, or live-key operations were performed. Repository HEAD observed: `4d4ebbe3a2506fdf47952090521de0ba308f6b4e`; the child-launch implementation was also read at base `77e7dbf` and uses the same `CreateProcessW` path.

## Conclusion

**P1 / rollout blocker:** `SERVICE_SID_TYPE_RESTRICTED` does not prevent a LocalSystem broker or its directly spawned Codex process from reading a private-key file whose DACL grants SYSTEM read access. The service restriction applies to write checks. Omitting the service SID from the allowlist does not subtract SYSTEM's ordinary read permission. This invalidates the claimed read boundary for the accepted SYSTEM-readable ACL configuration.

This conclusion assumes the stated DACL has no applicable read-deny ACE and that no additional encryption or independently restricted execution token supplies another boundary. No live exploit or actual key disclosure is claimed.

## Documented facts

1. Microsoft describes `SERVICE_SID_TYPE_RESTRICTED` as adding the service SID, World SID, service logon SID, and write-restricted SID to the restricting SID list. The SID's presence alone does not mean all reads receive a second restricting-SID check. [SERVICE_SID_INFO API reference](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/ns-winsvc-service_sid_info).

2. Microsoft's service-hardening explanation connects that exact service setting to a write-restricted token. Its operative phrase is: “the write-restricted token is used only when evaluating write-access checks.” This is the decisive distinction from fully restricted tokens. [Windows Services Enhancements, Protecting Others with Restricted Tokens](https://learn.microsoft.com/en-us/archive/msdn-magazine/2008/launch/windows-with-c-windows-services-enhancements).

3. The API reference independently defines `WRITE_RESTRICTED`: “The new token contains restricting SIDs that are considered only when evaluating write access.” The general restricted-token rule performs ordinary and restricting-SID checks, requiring both to allow access; the flag limits when the restricting check applies. Treating the general rule as unconditional for a write-restricted service would be incorrect. [CreateRestrictedToken](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken).

4. LocalSystem tokens include both SYSTEM and BUILTIN\\Administrators. Microsoft documents substantial default privileges, including enabled debug and impersonation privileges and disabled backup/restore privileges. Actual token privileges can be separately reduced; a service SID setting is not evidence of that reduction. [LocalSystem Account](https://learn.microsoft.com/en-us/windows/win32/services/localsystem-account).

5. `CreateProcessW` states: “The new process runs in the security context of the calling process.” Even thread impersonation does not change that default to the impersonated token. Restricting inherited handles is independent from selecting a restricted primary token. [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).

6. Ordinary DACL evaluation grants requested access when applicable allow ACEs cover the rights, subject to deny ACE ordering. It does not require an allow ACE for every SID in the token. [How AccessCheck Works](https://learn.microsoft.com/en-us/windows/win32/secauthz/how-dacls-control-access-to-an-object).

## Repository evidence and inference

- `elixir/priv/install_aro_197_windows.ps1:104` accepts controller, SYSTEM and Administrators as key readers. Line 114 rejects the explicit service-account grant. Lines 266–269 create the default service account and configure `sidtype restricted`; `elixir/docs/aro_197_rollout.md:98` explicitly identifies it as LocalSystem.
- `elixir/priv/windows-service/Symphony.WindowsBroker/ProcessHost.cs:107` invokes `CreateProcessW`. Its startup attributes supply the session stdio handle list, then assign the suspended child to a kill-on-close job and resume it. The inspected launch path does not call `CreateRestrictedToken` or select a different primary token. Repository search found no `CreateRestrictedToken`, `CreateProcessAsUser`, `AdjustTokenPrivileges`, or `reqprivs` in the broker and installer paths.
- `elixir/lib/symphony_elixir/protected_path.ex:123` includes SYSTEM and Administrators in `trusted_sids`, and line 129 validates ACL entries against that list. This is ACL-shape validation, not an effective-access check using the worker's token. An owner of controller plus a SYSTEM allow-read ACE satisfies the intended accepted form while admitting the LocalSystem worker's reads.
- **Inference supported by these facts:** a read-only open by the directly launched Codex process is allowed through SYSTEM's ACE; the absence of a service-SID allow ACE does not block it. A failed read/write open would not establish read confidentiality because a read-only open evaluates different rights. No privilege escalation or ACL modification is needed for this failure.
- **Privilege caution, separately scoped:** inheriting a privileged LocalSystem token also defeats the stated premise that the worker is unprivileged. This research does not claim or demonstrate a particular privilege-based escape. Removing one allow ACE or adding one deny ACE alone is not established here as a complete privileged-process isolation fix.

## Minimum safe next step

Keep the Windows rollout / key-read-denial gate closed and report this as a security-boundary failure. Do not accept the static ACL allowlist test or service-SID presence as proof that the worker cannot read the key. Before reopening the gate, require a reviewed worker security context that actually excludes the controller secret, plus a direct read-only denial test from the actual broker-spawned child against a synthetic nonsecret fixture reproducing the production ACL. No large alternative or implementation is proposed in this bounded research task.
