# ARO-286 final whole-branch fix report

Date: 2026-08-31

Reviewed base: `27d94a89f95229c1d9b5a97665ec11f505c49acb`

Review package: `review-98aa2f6..27d94a8.diff`

Execution boundary: local deterministic fixtures only. No network, external provider, Production,
deployment, push, or merge was used.

## Outcome

All six final-review findings were addressed as one integration wave. The two previously deferred
minor findings remain deferred and unchanged: the legacy non-context remote remove hook ordering
(Task 2), and the direct-Orchestrator rather than full-supervisor default-wiring test (Task 4).

## 1. Critical — lifecycle cleanup retains project context

Design: the validated `ProjectExecutionContext` and workspace attestation now remain attached to
running, blocked, retry, startup-terminal, and terminal-cleanup state. Cleanup calls the
context-aware workspace API and startup deduplication keys on `{linear_project_id, identifier}`.
Terminal cleanup stops a running worker before removing its exact workspace.

Files: `elixir/lib/symphony_elixir/orchestrator.ex`,
`elixir/lib/symphony_elixir/agent_runner.ex`, `elixir/lib/symphony_elixir/workspace.ex`, and
`elixir/test/symphony_elixir/core_test.exs`.

RED:

```text
mix test test/symphony_elixir/core_test.exs:500 \
  test/symphony_elixir/core_test.exs:542 \
  test/symphony_elixir/core_test.exs:579 \
  test/symphony_elixir/core_test.exs:1079 --seed 0
```

The startup case raised an arity mismatch at the context-aware cleanup seam, and the
running/blocked cases left the namespaced target behind. The adversarial set covers four lifecycle
paths.

GREEN: the same four-case command completed `4 passed`. It proves two profiles with the same issue
identifier remove both namespaced targets while leaving the legacy target, and proves the
running/blocked/retry/terminal paths retain context.

## 2. Critical — exact local and remote issue-directory authority

Design: context execution now requires both the exact lexical issue path and its physical directory
identity. Local issue leaves reject symlink/reparse aliases; local identity is pinned with native
file identity (trusted `fsutil` on Windows, device/inode elsewhere). Remote preparation returns a
physical path plus directory identity bound to the original lexical path. Remote commands repeat
root, namespace, issue-leaf, link, and identity checks immediately before hooks, Git, Codex, and
cleanup. AppServer consumes the exact context and attestation instead of accepting any descendant
of the global workspace root. Cleanup revalidates before and after `before_remove`.

Files: `elixir/lib/symphony_elixir/workspace.ex`,
`elixir/lib/symphony_elixir/codex/app_server.ex`, `elixir/lib/symphony_elixir/ssh.ex`,
`elixir/test/symphony_elixir/workspace_and_config_test.exs`,
`elixir/test/symphony_elixir/app_server_test.exs`, and
`elixir/test/symphony_elixir/ssh_test.exs`.

RED:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs \
  test/symphony_elixir/app_server_test.exs --seed 0
```

Four new same-namespace alias/link cases reached the sibling or attempted the unsafe effect.
Follow-up RED showed a plain rename/recreate passed on Windows because Erlang reported inode zero,
and remote physical paths were rejected against their lexical `~` form.

GREEN:

```text
mix test test/symphony_elixir/app_server_test.exs:44 \
  test/symphony_elixir/workspace_and_config_test.exs:649 \
  test/symphony_elixir/workspace_and_config_test.exs:712 --seed 0
# Result: 3 passed
```

The complete affected integration run below adds the local sibling alias, local post-readiness
replacement, remote replacement, cleanup, hook, Git, and AppServer cases (`235 passed`).

## 3. Important — minimal subprocess environment, no ambient credentials or profiles

Design: `SubprocessEnvironment` builds a deny-by-default child environment from a small
cross-platform runtime allowlist, then applies only the credential adapter's explicit contract.
Each context receives private `HOME`, `USERPROFILE`, `GH_CONFIG_DIR`, XDG, and Codex roots.
Unknown keys, Linear/npm/Node values, shell profile injectors, ambient GH/Git/SSH credential paths,
and agent sockets are removed. Local hooks and Codex use non-login `sh -c`; Git receives explicit
non-interactive credential defaults. Post-parse output sanitization remains in place.

Files: `elixir/lib/symphony_elixir/subprocess_environment.ex`,
`elixir/lib/symphony_elixir/project_credential_provider.ex`,
`elixir/lib/symphony_elixir/agent_runner.ex`, `elixir/lib/symphony_elixir/workspace.ex`,
`elixir/lib/symphony_elixir/codex/app_server.ex`, `elixir/lib/symphony_elixir/ssh.ex`, and their
focused tests.

RED:

```text
mix test test/symphony_elixir/project_credential_provider_test.exs \
  test/symphony_elixir/subprocess_environment_test.exs \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs --seed 0
```

The provider accepted a Linear key, the environment builder did not exist, and the malicious
profile/ambient secret fixture was observable in the child.

GREEN: provider/environment focused tests completed `6 passed`; the end-to-end AgentRunner child
fixture completed `1 passed`. The combined affected run completed `235 passed`.

## 4. Important — RuntimeHealth and watchdog share one crash contract

Design: application startup validates an all-or-none watchdog contract containing the exact
runtime-state root, epoch, receipt path, and positive signed-64-bit restart attempt. RuntimeHealth
uses those values in its snapshot and receipt. At restart limit, the watchdog preserves a valid app
receipt or atomically writes a minimal `restart_limit` receipt through the same exact path contract
before notification; malformed, unstable, or unwritable receipt state exits with the bounded
configuration/state failure code and never notifies. It does not fabricate successful app stages.

Files: `elixir/lib/symphony_elixir.ex`, `elixir/lib/symphony_elixir/runtime_health.ex`,
`elixir/lib/symphony_elixir/runtime_receipt_contract.ex`,
`elixir/lib/symphony_elixir/runtime_notifier.ex`, `elixir/bin/symphony-watchdog.ps1`, and the
RuntimeHealth/notifier/watchdog tests.

RED:

```text
mix test test/symphony_elixir/runtime_health_test.exs \
  test/symphony_elixir/runtime_notifier_test.exs \
  test/bin/symphony_watchdog_test.exs --seed 0
```

RuntimeHealth omitted watchdog contract fields, application setup did not consume the environment,
the real crashing child produced no terminal receipt, and notifier validation rejected a real
RuntimeHealth receipt carrying `restart_attempt`.

GREEN: RuntimeHealth focused suite `25 passed`; application contract `1 passed`; real child
crash-to-limit `1 passed`; notifier contract `2 passed`; full watchdog default/pwsh suite
`29 passed`; full generic watchdog suite forced to Windows PowerShell `23 passed, 6 skipped`
(the six are explicitly pwsh-only mirrors).

## 5. Important — Linear configured-project authority

Authority adjudication: the approved design's immutable context contains `linear_project_id`,
requires issue/profile project equality, and says no downstream component re-resolves a project.
The plan explicitly tests mismatched `project_id` and defines Task 4's interface as a viewer
identity check. Neither document defines a separate Linear organization/workspace identifier.
Adding one would invent configuration outside the approved contract.

Implementation: after validating the viewer, startup performs a real read-only GraphQL lookup for
every exact configured profile project UUID and requires the returned UUID to match. Missing access
or mismatch is the bounded `linear_workspace_mismatch` result. Per-issue routing separately binds
the issue to the same configured project UUID.

Files: `elixir/lib/symphony_elixir/linear/client.ex`,
`elixir/lib/symphony_elixir/tracker.ex`, `elixir/lib/symphony_elixir/orchestrator.ex`, and
`elixir/test/symphony_elixir/linear_startup_identity_test.exs`.

RED: the wrong-project fixture passed after only the viewer query. GREEN:

```text
mix test test/symphony_elixir/linear_startup_identity_test.exs --seed 0
# Result: 3 passed
```

Adjudication request: accept exact configured-project UUID access plus existing issue routing as the
design-authorized Linear boundary; do not require an unplanned organization-ID setting.

## 6. Important — receipt publication resists copied-token relocation

Design: the writer holds a managed guard handle and records the initial current-directory identity,
directory identity, guard-handle identity, guard-path identity, and token. Immediately before
publication it compares all of them; a copied token cannot authorize a renamed/recreated directory.
The receipt is created and hard-linked only by relative name under the attested directory, so no
receipt can escape the configured root/workspace.

Files: `elixir/src/symphony_runtime_receipt_writer.erl`,
`elixir/lib/symphony_elixir/runtime_health.ex`, and
`elixir/test/symphony_elixir/runtime_health_test.exs`.

RED: the rename/recreate/copied-token test either published into the replacement directory or, after
the first guard implementation, every publication failed because a raw Erlang file handle was used
from the monitored worker process. GREEN:

```text
mix test test/symphony_elixir/runtime_health_test.exs --seed 0
# Result: 25 passed
```

The adversarial case proves no receipt appears in the replacement, displaced directory, or outside
the runtime-state root.

## Aggregate verification

```text
mix test <11-file combined affected set> --seed 0
# Result: 235 passed

mix test <original 13-file ARO-286 acceptance set> --seed 0
# Result: 296 passed

mix test --seed 0
# Result (reproduced twice): 1000/1015 passed, 13 skipped, 15 unrelated failures
```

Both full runs had the identical 15 failures: four CRLF-sensitive SQL migration assertions and
eleven Scope Contract/PR-body cases in files untouched by this wave. The second run followed an
explicit restore of every formatter-only file from the captured pre-format clean set, confirming
that this is the Windows checkout/runtime baseline rather than a final-wave regression. No ARO-286
test failed in either run. Full coverage was not reported as passing because it would execute the
same failing full-suite boundary.

Static gates:

- `mix format --check-formatted <all changed .ex/.exs files>`: passed. The exact whole-tree check
  remains environment-blocked by the repository's CRLF checkout: it reports pre-existing,
  unrelated files as unformatted for line endings. No whole-tree formatter output was retained.
- `mix specs.check`: passed (`all public functions have @spec or exemption`).
- forced `MIX_ENV=test mix compile --force --warnings-as-errors`: project sources passed; Phoenix
  emitted its known Windows `node_modules` symlink warning (`:eperm`).
- `mix dialyzer --format short`: initially found one covered Erlang fallback; after removal the
  gate passed with `Total errors: 0`.
- `mix credo --strict`: environment-blocked under the available Elixir 1.20.2 because Credo 1.7.16
  crashes in `Credo.Check.Consistency.SpaceAroundOperators` while decoding Elixir 1.20 sigil
  tokens. A compatibility run excluding only that crashing check completed and reported advisory
  readability/complexity and mixed-line-ending findings. The requested Elixir 1.19 runtime was not
  already installed; no runtime or dependency was installed and no network was used.
- `git diff --check`: passed.

Runtime used: Erlang/OTP 28 (erts-16.4), Elixir 1.20.2. Elixir 1.19 was unavailable locally.

## Remaining concerns

1. The two explicitly deferred minors listed at the top remain unchanged.
2. The built-in multi-project credential provider still intentionally fails closed until the
   ARO-195/ARO-196 adapter exists; this is the approved design boundary, not an ARO-286 defect.
3. No live Linear/GitHub/provider or Production validation was run; ARO-285 owns that acceptance.
4. Credo's Elixir 1.20 token incompatibility and the whole-tree CRLF formatting baseline are
   environment/tooling gates, not suppressed findings. Changed-file formatting, specs, compiler,
   Dialyzer, deterministic tests, and diff checks remain the evidence available without installing
   another runtime or rewriting unrelated files.
