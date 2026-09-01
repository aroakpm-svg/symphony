# Task 6 Report: Windows Restart-Limit Notification

## Status

Complete. Restart-limit notification remains disabled unless both an operator-provided local command and an opaque receiver are configured. The notifier and Windows watchdog retain one explicit epoch through failed restarts, consume only the deterministic immutable `stop-<runtime_epoch>.json` receipt, deliver a fixed receiver-bound event on stdin under a bounded timeout, discard all child/notifier output, and record a separate immutable delivery receipt only after exit status zero.

## Commits

- `8e6216e1a3e9ae538bdd31f67020951ead1e3086` — `feat: notify on terminal Windows restart failure`
- This report is committed separately after recording the implementation hash.

## Files

Created:

- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`
- `elixir/bin/symphony-watchdog.ps1`
- `elixir/test/bin/symphony_watchdog_test.exs`

Modified:

- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/test/symphony_elixir/workspace_and_config_test.exs`

## RED Evidence

Initial required RED command:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

Observed corrected result before production implementation:

```text
Result: 58/74 passed
Failed: 16 tests
```

Fifteen failures were the intended feature RED: absent config fields and validation, absent `RuntimeNotifier`, and absent watchdog. One failure was an unrelated pre-existing Windows junction fixture collision.

Strengthened contract mutations were also demonstrated RED:

- Stdin EOF contract: `mix test test/symphony_elixir/runtime_notifier_test.exs` — `Result: 3/8 passed`, five valid commands timed out until stdin was closed deterministically.
- Runtime-state/workspace separation: targeted config test — `Result: 0/1 passed` before canonical separation validation.
- Relative watchdog state path: targeted watchdog test — `Result: 0/1 passed` when the fail-closed guard was intentionally removed; restoring it produced `1/1 passed`.
- Stable terminal replay: `mix test test/bin/symphony_watchdog_test.exs:108` — `Result: 0/1 passed`; replay timestamps differed until the terminal timestamp was persisted with the epoch.

## GREEN Evidence

Required focused command, after a forced test-environment compile beneath a unique process TEMP/TMP to avoid unrelated stale Windows test-junction names:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

Fresh final result:

```text
Finished in 27.0 seconds
Result: 75 passed
Failed: 0 tests
```

The focused result includes eight real-command `RuntimeNotifier` contracts, seven real PowerShell watchdog contracts, and the existing workspace/config regression suite. PowerShell parsing, retained epoch/attempt state, success reset, exact-once receiver+epoch delivery, failed-delivery replay, output suppression, and explicit state-path rejection all passed.

Related Task 5 health/status command after a normal test-environment forced compile:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Fresh final result:

```text
Finished in 20.4 seconds
Result: 65 passed
Failed: 0 tests
```

## Static Checks

- `mix format --check-formatted lib/symphony_elixir/config/schema.ex lib/symphony_elixir/runtime_notifier.ex test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs`: passed with no output.
- `mix specs.check`: passed (`specs.check: all public functions have @spec or exemption`).
- `mix compile --force`: passed (`1` Erlang file and `64` Elixir files compiled).
- `git diff --check` and the staged equivalent: passed; only Git's existing LF-to-CRLF notices were emitted.
- Real PowerShell parser coverage is included in the focused suite and passed.

## Self-Review

- Partial notification config fails closed; the default with neither command nor receiver has no notification side effect.
- Runtime-state root is absolute, non-root, non-Production, secret-shape rejected, canonically separated from an absolute workspace root, and revalidated before notifier use.
- The watchdog receives explicit state/root paths, generates one GUID epoch, retains it and the deterministic stop-receipt path across failed attempts, and never creates a mutable latest pointer.
- Watchdog state includes only bounded runtime identity, a full SHA-256 receiver hash, epoch, attempt count, and the stable terminal timestamp. Receiver text is absent from filenames.
- RuntimeHealth stop receipts and notifier delivery receipts are separate. Existing or colliding delivery receipts must be regular, valid receiver+epoch+category receipts; delivery publication is no-clobber and occurs only after a zero exit.
- Notification events contain exactly runtime identity, receiver, attempt count, `restart_limit`, UTC timestamp, runtime epoch, and deterministic stop receipt path.
- PowerShell and Elixir runners close stdin, drain both output streams directly to a null sink, enforce bounded notification timeouts, discard wrapper output, and return only bounded atoms/exit codes. They never log or return configured commands, receivers, child environment, or notifier output.
- Command, receiver, epoch, runtime identity, and paths are size/shape checked and conservatively reject credential-like values. State and receipt symlinks are rejected where consumed.
- Existing single-project behavior and Task 5 health behavior remain green. No Production path, deployment, secret, shared database, or external resource was touched.

## Concerns

- The checkout runs Elixir `1.20.2`; `elixir/AGENTS.md` specifies Elixir `1.19.x` with OTP 28.
- Ordinary-TEMP focused reruns encountered unrelated stale Windows junction fixtures left by the existing workspace tests (`73/75`). A fresh isolated process TEMP/TMP plus forced test compile produced the required clean `75/75` result without weakening any test or timeout.
- Existing compilation still emits the unrelated `HttpServer.normalize_host/1` unreachable-clause warning and Phoenix LiveView's Windows symlink-permission warning.

---

## Fix Round 1 (2026-08-31)

### Status and Commit

Complete. Review findings were fixed at their root causes in implementation commit
`79f50da65b6adbaa16dea036379172c99f2a663d` (`fix: harden restart-limit notification`).

Changed files:

- `elixir/bin/symphony-watchdog.ps1`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/test/bin/symphony_watchdog_test.exs`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`
- `elixir/test/symphony_elixir/workspace_and_config_test.exs`

### RED Evidence

- `mix test test/symphony_elixir/workspace_and_config_test.exs:176` — `Result: 0/1 passed`; one-way absolute-only separation accepted relative workspace roots and reverse containment.
- `mix test test/symphony_elixir/runtime_notifier_test.exs` — `Result: 7/13 passed`; six intended failures exposed plaintext receiver persistence, weak receipt validation/identity validation, missing pre-side-effect claim reservation, unsafe retry ambiguity, and incomplete descendant timeout termination.
- `mix test test/bin/symphony_watchdog_test.exs` — `Result: 9/15 passed`; six intended failures exposed mandatory-parameter diagnostics in disabled mode, plaintext receiver delivery state, weak Task 5 receipt validation, absent crash claim suppression, secret-shaped runtime identity acceptance, and successful root replacement without a retained physical lease.

No PowerShell test process hung. The RED watchdog suite completed in 27.9 seconds; no timeout was weakened and no test-owned process required manual termination.

### GREEN Evidence

Targeted contracts during implementation:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs
Finished in 23.5 seconds
Result: 14 passed

mix test test/bin/symphony_watchdog_test.exs
Finished in 62.0 seconds
Result: 16 passed
```

Required focused command, run after `MIX_ENV=test mix compile --force` with one fresh process-scoped TEMP/TMP so existing stale Windows junction fixture names could not collide:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
Finished in 94.7 seconds
Result: 91 passed
```

Related Task 5 health/status and single-project regressions:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
Finished in 29.0 seconds
Result: 116 passed
```

### Static Checks

- Focused `mix format --check-formatted` over all changed Elixir sources/tests: passed with no formatter findings.
- `mix specs.check`: passed — `specs.check: all public functions have @spec or exemption`.
- `mix compile --force`: passed — one Erlang file and 64 Elixir files compiled.
- Real PowerShell parser coverage is part of the 16-test watchdog suite and passed.
- `git diff --check` and `git diff --cached --check`: passed; only Git's existing LF-to-CRLF notices were emitted.
- Debug probes and the prior plaintext `.restart-limit-input-*` disk spool are absent.

### Self-Review

- The watchdog rejects missing, Production-shaped, secret-shaped, or reparse-point runtime roots before creating state. It rejects every reparse ancestor/target, acquires a directory handle without `FILE_SHARE_DELETE`, verifies volume/file identity after acquisition and before/after state operations, retains the handle for its full lifecycle, and uses relative .NET file operations from the pinned directory. Junction and concurrent replacement tests pass.
- Both runners assign a nonce-gated PowerShell process to a kill-on-close Windows Job Object before releasing the operator command. Timeout/nonzero handling terminates the complete job tree, bounds process and drain waits, verifies zero active processes, and clears retry claims only after verified termination. A notifier-spawned descendant cannot outlive return.
- Receiver+epoch idempotence uses the same full SHA-256 receiver hash and exact hash-only claim/delivery JSON schemas in Elixir and PowerShell. Atomic no-clobber claims precede the side effect. Orphan claims preserve crash ambiguity for at-most-once delivery; zero exit publishes delivery before removing the claim; verified explicit failures may safely clear it.
- No retained state, claim, delivery receipt, filename, or notifier scratch file contains the plaintext receiver. The opaque receiver exists only in the transient fixed event handed to the configured command's stdin; Elixir supplies it through a short-lived runner environment and removes that variable before starting the operator command.
- Task 5 receipts are required at the exact deterministic epoch path and must be bounded, regular, non-reparse immutable files with exact required/allowed keys, exact stop/failure categories, and the same field type/shape/secret checks as `RuntimeHealth`. Test fixtures publish them by synced no-clobber hard link and never overwrite them.
- Runtime identities now use the same conservative secret-bearing rejection as all other event strings, including `token:canary` and common credential prefixes.
- Notification parameters are optional only as a pair: both absent is silent disabled behavior; exactly one present exits 2 through controlled validation without parameter-binding output or child/notifier side effect.
- Relative workspace roots are expanded using Config's process base semantics; canonical separation rejects both containment directions and symlink aliases.
- No Production path, deployment, secret, shared database, external resource, or multi-project behavior was introduced.

### Concerns

- The checkout remains on Elixir `1.20.2` although `elixir/AGENTS.md` specifies Elixir `1.19.x` with OTP 28.
- Existing compilation still emits the unrelated `HttpServer.normalize_host/1` unreachable-clause warning and Phoenix LiveView Windows symlink-permission warning.
- Existing workspace tests leave Windows junction directories under the ordinary system TEMP across separate BEAM runs. The required final suite was therefore run with a fresh isolated TEMP/TMP and forced test compile; no production path or timeout behavior was changed.

---

## Fix Round 2 (2026-08-31)

### Status and Commit

Complete. The exact Task 5 receipt-consumption and unconditional runner-cleanup findings were fixed in implementation commit `17933c6779a4d16c1a74fbd744ddaa1f1bc7518f` (`fix: pin restart receipt consumption`).

Changed files:

- `elixir/bin/symphony-watchdog.ps1`
- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/test/bin/symphony_watchdog_test.exs`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`

### RED Evidence

Command:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs
```

Observed result before production changes:

```text
Finished in 99.9 seconds
Result: 30/35 passed
Failed: 5 tests
```

The five intended failures were:

- Elixir rejected an immutable receipt actually emitted by `RuntimeHealth` with 256 fire-emoji graphemes (`1,024` UTF-8 detail bytes).
- PowerShell rejected the same real `RuntimeHealth` receipt because it counted UTF-16 code units.
- PowerShell accepted a malformed canonical branch of 65 fire emoji (`260` UTF-8 bytes) because it used `.Length` instead of UTF-8 bytes.
- Elixir accepted and notified while another process retained a writable handle and actively mutated the receipt during consumption.
- Injected port-open failure/exception hooks were ignored, so the command ran instead of exercising cleanup and fail-closed behavior.

### GREEN Evidence

Targeted notifier/watchdog command after implementation:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs
Finished in 128.4 seconds
Result: 35 passed
```

Required focused command after a forced test compile with fresh process-scoped TEMP/TMP:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
Finished in 132.3 seconds
Result: 96 passed
```

Related Task 5 and single-project regressions:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
Finished in 26.3 seconds
Result: 116 passed
```

### Static Checks

- Focused `mix format --check-formatted` over all changed Elixir sources/tests: passed.
- `mix specs.check`: passed — `specs.check: all public functions have @spec or exemption`.
- `mix compile --force`: passed — one Erlang file and 64 Elixir files compiled.
- Real PowerShell parser coverage remained green in the focused suite.
- `git diff --check` and staged diff checks passed; only existing LF-to-CRLF notices were emitted.

### Self-Review

- Elixir now validates emitted `detail` using the producer's actual `String.slice/3` grapheme semantics, accepting 256 multibyte graphemes rather than incorrectly imposing a 256-byte post-truncation limit.
- PowerShell uses `Encoding.UTF8.GetByteCount` for every byte-bounded Task 5 string and `StringInfo.ParseCombiningCharacters` for emitted detail. A real `RuntimeHealth` receipt is consumed by both implementations, while a 260-byte Unicode branch is rejected.
- On Windows, both consumers open the exact receipt with a retained `FileStream` that grants only read sharing, thereby denying concurrent write/delete. They record volume/file-index identity and length, read twice from the retained handle, compare the content copies, recheck handle identity/length, and verify the current path opens to the same identity before accepting JSON.
- A live adversary test holds a read/write handle and repeatedly mutates the first receipt byte during consumption. Both consumers fail closed with no notification or delivery receipt.
- The Elixir non-Windows fallback opens one file handle, performs handle/path `fstat` identity checks before and after one bounded read, and rejects identity/size changes. Public OTP still cannot prevent a same-user namespace relocation after its final path check; this limitation is not represented as provenance or signature assurance.
- `RuntimeNotifier` now places command-port opening and waiting inside `try/after`, so `.restart-limit-runner-*` is removed after normal completion, timeout, nonzero result, port-open failure, and opener exception. Injected failure/exception tests assert no runner and no command canary remains on disk.
- No notification command, receiver, notifier output, child environment, credential value, Production path, deployment, database, or external resource is persisted or logged.

### Concerns

- The inherited Elixir `1.20.2` versus specified `1.19.x` mismatch remains.
- Existing compile output still contains the unrelated `HttpServer.normalize_host/1` warning and Phoenix LiveView Windows symlink-permission warning.
- The existing stale Windows junction-fixture issue remains isolated by a fresh TEMP/TMP plus forced test compile for the exact focused suite.

---

## Fix Round 3 (2026-08-31)

### Status and Commit

Complete. Task 5 producer/consumer size parity and independent dual-PowerShell coverage were fixed in implementation commit `ce269cc` (`fix: align restart receipt size contract`).

Changed files:

- `elixir/bin/symphony-watchdog.ps1`
- `elixir/lib/symphony_elixir/runtime_receipt_contract.ex`
- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/test/bin/symphony_watchdog_test.exs`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`

### RED Evidence

The initial targeted maximum-ZWJ and producer-boundary selection completed with `4/6 passed`. The two intended failures were:

- the `pwsh` watchdog rejected the real `RuntimeHealth` receipt containing 256 family/ZWJ graphemes (`6,400` UTF-8 detail bytes) at the old 4 KiB receipt-read cap;
- `RuntimeHealth` accepted and published a receipt over the intended bounded producer contract when `detail` was one oversized combining-character grapheme.

A second targeted command selecting the Elixir consumer and Windows PowerShell family/ZWJ cases completed with `0/2 passed`: Elixir rejected the same real receipt at its 4 KiB cap, while `powershell.exe` was initially prevented from entering the runtime contract by the host's unsigned-script execution policy. The test-only process invocation was then made explicit with `-ExecutionPolicy Bypass`; no product timeout, validation, or fail-closed behavior was weakened.

The feature RED invocations used ExUnit line selection over
`test/symphony_elixir/runtime_notifier_test.exs`,
`test/bin/symphony_watchdog_test.exs`, and
`test/symphony_elixir/runtime_health_test.exs`. The preserved output recorded the exact
`4/6` and `0/2` results above but did not retain the expanded line-number arguments; no
passing result is claimed for that pre-implementation state.

### GREEN Evidence

Combined notifier, watchdog, and producer contract command:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/runtime_health_test.exs
Finished in 145.6 seconds
Result: 52 passed
```

Both installed PowerShell implementations were selected separately rather than through a fallback. The focused suite passed the `pwsh` parser and ZWJ runtime tests and the `powershell.exe` parser and ZWJ runtime tests; neither runtime was skipped.

Required focused command, after `MIX_ENV=test mix compile --force` with one fresh process-scoped TEMP/TMP:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
Finished in 144.3 seconds
Result: 98 passed
```

Related Task 5 and single-project regressions:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
Finished in 25.5 seconds
Result: 117 passed
```

### Static Checks

- Focused `mix format --check-formatted` over all changed Elixir sources/tests passed.
- `mix specs.check` passed: `specs.check: all public functions have @spec or exemption`.
- `mix compile --force` passed: one Erlang file and 65 Elixir files compiled.
- Both real PowerShell parsers passed in the 98-test focused suite.
- `git diff --check` and `git diff --cached --check` passed; only the checkout's existing LF-to-CRLF notices were emitted.

### Self-Review

- `RuntimeReceiptContract` defines one 16 KiB encoded Task 5 receipt ceiling. `RuntimeHealth` now enforces it before immutable publication, so every receipt the producer can successfully emit is consumable within that finite bound. Both Elixir and PowerShell consumers use the same bound and continue to reject oversized total input before JSON acceptance.
- The 16 KiB contract covers the producer's 256-grapheme family/ZWJ boundary (`6,400` detail bytes) plus the bounded receipt schema and JSON overhead. A deliberately unbounded single combining grapheme is rejected at publication, preventing grapheme composition from bypassing total resource safety.
- Neither Task 6 consumer attempts to reproduce Elixir grapheme segmentation. Post-publication `detail` validation is limited to cross-runtime invariants: string/UTF-8 decoding, conservative secret rejection, control-character rejection, exact schema, and the producer-enforced total receipt cap.
- Every other bounded Task 5 string remains checked in UTF-8 bytes. The 260-byte Unicode canonical branch is rejected by both consumers, and the 17,000-byte synthetic receipt is rejected by both bounded readers.
- The real family/ZWJ fixture is always generated through `RuntimeHealth`; it is not overwritten or synthesized after publication. Elixir, PowerShell 7 (`pwsh`), and Windows PowerShell 5 (`powershell.exe`) each consume that artifact successfully.
- No notifier command/receiver, child environment, notifier output, secret, Production path, external resource, deployment, or database behavior changed.

### Concerns

- The inherited Elixir `1.20.2` versus specified `1.19.x` mismatch remains.
- Existing compilation still emits the unrelated `HttpServer.normalize_host/1` warning and Phoenix LiveView Windows symlink-permission warning.
- Two pre-final focused attempts reproduced the known Windows test-environment issue: an ordinary run was `96/98` because of a stale junction plus a previously compiled TEMP default, and a development-environment forced compile was `97/98` because it did not rebuild the test schema. The final test-environment forced compile with fresh process TEMP/TMP was clean at `98/98`; production logic and timeout semantics were unchanged.

---

## Fix Round 4 (2026-08-31)

### Status and Commit

Complete. The remaining producer/consumer receipt-field mismatch was fixed in implementation commit `37c015be1ef487e528d37fe4495dba9006686074` (`fix: define portable restart receipt contract`).

Changed files:

- `elixir/bin/symphony-watchdog.ps1`
- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/lib/symphony_elixir/runtime_receipt_contract.ex`
- `elixir/test/bin/symphony_watchdog_test.exs`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`

### Root Cause and Contract

The 16 KiB total receipt ceiling did not define the fields that contributed to it. `RuntimeHealth` truncated `detail` by Elixir graphemes, accepted arbitrary positive integers for `routing_revision`, and could accept a stop before discovering that its encoded receipt was too large. The Elixir and PowerShell consumers then removed the grapheme constraint and relied on the aggregate ceiling, which admitted forged details that the producer would not have emitted.

`RuntimeReceiptContract` now defines one portable contract: every receipt string has an explicit UTF-8 byte maximum, `detail` is at most 8,192 bytes, and `routing_revision` is in `1..9_223_372_036_854_775_807` (the positive signed-64-bit range shared by Elixir, PowerShell 7, and Windows PowerShell 5). Producer detail normalization removes only an incomplete UTF-8 suffix and occurs before state storage or receipt encoding; secret and control-character checks still inspect the complete submitted value before truncation.

The total encoded ceiling is now 96 KiB. The raw string maxima sum to 13,529 bytes; a conservative sixfold JSON-escape expansion plus 1 KiB for keys, delimiters, null values, and the 19-digit integer is 82,198 bytes, below the 98,304-byte ceiling. A compile-time assertion fails if future field maxima outgrow that proof. The producer also rejects a generated receipt path beyond its 4,096-byte field contract during startup rather than after accepting a stop.

The maximum 128-byte epoch exposed a Windows path-length issue in the prior raw receiver-hash-plus-epoch claim filename. Both notification implementations now derive the same full SHA-256 filename key from `receiver_hash + ":" + runtime_epoch`; the claim and delivery JSON still retain and validate the full receiver hash and epoch, so collision resistance, audit identity, and at-most-once semantics remain intact while maximum valid epochs no longer make temporary filenames unpublishable.

### RED Evidence

Initial boundary command:

```text
mix test test/symphony_elixir/runtime_health_test.exs:96 test/symphony_elixir/runtime_health_test.exs:116 test/symphony_elixir/runtime_health_test.exs:137 test/symphony_elixir/runtime_health_test.exs:164 test/symphony_elixir/runtime_notifier_test.exs:164 test/symphony_elixir/runtime_notifier_test.exs:195 test/bin/symphony_watchdog_test.exs:214 test/bin/symphony_watchdog_test.exs:219 test/bin/symphony_watchdog_test.exs:246 test/bin/symphony_watchdog_test.exs:251
Finished in 30.3 seconds
Result: 0/10 passed
Failed: 10 tests
```

The failures showed the oversized single-grapheme stop returning `receipt_write_failed`, grapheme rather than byte truncation, producer acceptance of `routing_revision = 9_223_372_036_854_775_808`, forged 8,193-byte details accepted by all consumers, and maximum fixtures remaining only about 2.3-2.5 KiB because the producer retained only 256 graphemes.

After strengthening the real producer fixture to the existing 128-byte epoch maximum, the pre-fix cross-runtime command completed with `1/3 passed`: Elixir consumed the receipt, while both PowerShell implementations failed before notification because the raw epoch made claim temporary filenames exceed the Windows path limit. That RED led to the shared hashed idempotency filename key described above.

### GREEN Evidence

Final ten-boundary selection:

```text
mix test test/symphony_elixir/runtime_health_test.exs:96 test/symphony_elixir/runtime_health_test.exs:116 test/symphony_elixir/runtime_health_test.exs:137 test/symphony_elixir/runtime_health_test.exs:165 test/symphony_elixir/runtime_notifier_test.exs:164 test/symphony_elixir/runtime_notifier_test.exs:195 test/bin/symphony_watchdog_test.exs:214 test/bin/symphony_watchdog_test.exs:219 test/bin/symphony_watchdog_test.exs:246 test/bin/symphony_watchdog_test.exs:251
Finished in 31.5 seconds
Result: 10 passed, 47 excluded
```

This selection independently executed the maximum receipt and forged-receipt cases under both `pwsh` and `powershell.exe`; neither runtime was skipped.

Required Task 6 focused command, after `MIX_ENV=test mix compile --force` with a fresh process-scoped TEMP/TMP:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
Finished in 161.9 seconds
Result: 100 passed
```

Related Task 5 and single-project regressions:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
Finished in 29.4 seconds
Result: 120 passed
```

### Static Checks

- Focused `mix format --check-formatted` over all changed Elixir sources/tests passed with no output.
- `mix specs.check` passed: `specs.check: all public functions have @spec or exemption`.
- `mix compile --force` passed: one Erlang file and 65 Elixir files compiled.
- Both real PowerShell parsers passed in the 100-test focused suite.
- `git diff --check` and the staged equivalent passed; only the checkout's existing LF-to-CRLF notices were emitted.

### Self-Review

- Every string in the exact stop-receipt schema has one named UTF-8 byte maximum. The producer and Elixir consumer call the same contract; the watchdog declares and enforces the identical values. Enum-constrained strings remain exact-domain checked as well as byte bounded.
- The maximum fixture uses every optional producer field at its maximum, the signed-64-bit revision maximum, a 128-byte epoch, and an exact 8,192-byte detail containing a family/ZWJ sequence plus JSON-escaping backslashes. Its encoded receipt exceeds the old 16 KiB ceiling, publishes immutably, and is consumed successfully by Elixir, `pwsh`, and `powershell.exe`.
- An 8,193-byte forged ASCII detail, a revision one above signed-64-bit maximum, and an extra out-of-schema key are rejected by both consumers before command execution or delivery publication. Exact-boundary values are accepted.
- A deliberately oversized single combining grapheme is now truncated on a valid UTF-8 codepoint boundary and published successfully, eliminating the prior field-size-only `receipt_write_failed` path. Stage snapshots and stop receipts store only the normalized bounded value.
- Full SHA-256 notification keys keep claim/delivery basenames bounded without weakening the validated receiver-hash-plus-epoch identity stored in each receipt. Existing collision, orphan-claim, concurrent-reservation, timeout, descendant-termination, and retry cleanup tests remain green.
- No notification command, receiver, notifier output, child environment, secret, Production path, deployment, external resource, database, or claim authorization behavior changed.

### Concerns

- The checkout remains on Elixir `1.20.2` although `elixir/AGENTS.md` specifies Elixir `1.19.x` with OTP 28.
- Existing compilation still emits the unrelated `HttpServer.normalize_host/1` warning and Phoenix LiveView Windows symlink-permission warning.
- The known stale Windows junction-fixture issue remains isolated by a fresh TEMP/TMP and forced test-environment compile for the exact focused suite; no production path or timeout behavior was changed.

---

## Fix Round 5 (2026-08-31)

### Status and Commit

Complete. The producer clock contract and backward-compatible durable idempotency lookup were fixed in implementation commit `456fa05582eddd7d3c263126d60150c91066eca3` (`fix: preserve restart receipt contracts`).

Changed files:

- `elixir/bin/symphony-watchdog.ps1`
- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/lib/symphony_elixir/runtime_receipt_contract.ex`
- `elixir/test/bin/symphony_watchdog_test.exs`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`

### Root Cause and Contract

`RuntimeHealth.timestamp/1` trusted every binary returned by the injected clock and converted every unsupported type to the literal `unknown`. The mutation handlers treated that adapter as infallible, so a stop could be accepted and published with an `at` value that both Task 6 consumers correctly rejected. Because the stop receipt is immutable and a successful stop replay never republishes it, later calls could not repair the invalid evidence.

`RuntimeReceiptContract` now owns the exact producer/Elixir-consumer timestamp contract. A clock may return only a `DateTime` or a bounded ISO8601 string of at most 64 UTF-8 bytes. The instant is converted to UTC, truncated to whole seconds, and accepted only when the result is the exact 20-byte `YYYY-MM-DDTHH:MM:SSZ` form. Invalid strings, unsupported values, oversized strings, clock exceptions, and out-of-domain dates return only the bounded atom `:invalid_clock`. Stage, dependency, poll, and first-stop handlers obtain that result before changing health state or accepting a receipt. A successful stop therefore always contains a consumer-valid `at`; its idempotent replay still cannot recreate a deleted receipt.

Round 4 replaced the original `restart-limit-{claim,delivery}-<receiver_hash>-<runtime_epoch>.json` names with a SHA-256 key but did not probe existing files under the durable old names. Both implementations now construct an optional legacy path only from an exact lowercase 64-hex receiver hash and validated epoch, require a portable filename of at most 255 bytes, require the joined path to remain under 4,096 bytes with the runtime root as its exact parent, and never include the plaintext receiver. Existing legacy claim/delivery files are stable-read within a 1,024-byte ceiling and must match the exact five-field schema plus receiver hash, epoch, and restart-limit category. A valid legacy delivery suppresses notification; a valid orphan claim preserves crash ambiguity. Malformed, oversized, reparse/non-regular, and colliding entries fail closed before command execution. Legacy artifacts are never removed, rewritten, migrated, or copied; every new claim and delivery still uses `SHA256(receiver_hash <> ":" <> runtime_epoch)`.

### RED Evidence

Producer clock selection before implementation:

```text
mix test test/symphony_elixir/runtime_health_test.exs:96 test/symphony_elixir/runtime_health_test.exs:128 test/symphony_elixir/runtime_health_test.exs:159
Finished in 1.2 seconds
Result: 0/3 passed, 18 excluded
Failed: 3 tests
```

The failures showed invalid/unknown/oversized clock output returning `:ok`, mutable stage state accepting an invalid clock, and the offset timestamp remaining `2026-08-29T14:00:00.999999+08:00` instead of canonical UTC.

Elixir notifier legacy/parity selection before implementation:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs:90 test/symphony_elixir/runtime_notifier_test.exs:109 test/symphony_elixir/runtime_notifier_test.exs:128 test/symphony_elixir/runtime_notifier_test.exs:307
Finished in 12.1 seconds
Result: 0/4 passed, 17 excluded
Failed: 4 tests
```

The valid old delivery and claim were ignored and the command ran; malformed/colliding/oversized old artifacts were also bypassed; the real producer receipt retained its noncanonical offset timestamp.

Independent PowerShell legacy/parity selection before implementation:

```text
mix test test/bin/symphony_watchdog_test.exs:282 test/bin/symphony_watchdog_test.exs:287 test/bin/symphony_watchdog_test.exs:353 test/bin/symphony_watchdog_test.exs:358
Finished in 6.7 seconds
Result: 0/4 passed, 22 excluded
Failed: 4 tests
```

Both `pwsh` and `powershell.exe` created a new hashed delivery despite a valid legacy delivery, and both observed the noncanonical producer timestamp. Neither runtime was skipped.

### GREEN Evidence

The same three targeted selections passed after implementation:

```text
RuntimeHealth clock contract: 3 passed, 18 excluded (2.3 seconds)
Elixir notifier legacy/parity: 4 passed, 17 excluded (20.9 seconds)
Dual-PowerShell legacy/parity: 4 passed, 22 excluded (18.6 seconds)
```

The producer suite additionally passed a non-UTC `DateTime` fixture, an ISO8601 offset/fraction fixture, and the exact `9999-12-31T23:59:59Z` 20-byte boundary. The Elixir notifier and both PowerShell implementations consumed a real receipt generated from the offset clock.

Required Task 6 focused command, after `MIX_ENV=test mix compile --force` with a fresh process-scoped TEMP/TMP:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs test/bin/symphony_watchdog_test.exs test/symphony_elixir/workspace_and_config_test.exs
Finished in 202.5 seconds
Result: 108 passed
```

Related Task 5 and single-project regressions:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
Finished in 28.7 seconds
Result: 123 passed
```

### Static Checks

- Focused `mix format --check-formatted` over every changed Elixir source/test passed with no output.
- `mix specs.check` passed: `specs.check: all public functions have @spec or exemption`.
- `mix compile --force` passed: one Erlang file and 65 Elixir files compiled.
- The final 108-test suite included and passed the `pwsh` parser/runtime and the independent `powershell.exe` parser/runtime; the targeted four-test command also proved neither was skipped.
- `git diff --check` and `git diff --cached --check` passed; only the checkout's existing LF-to-CRLF notices were emitted.

### Self-Review

- Invalid clock evidence is rejected before any health mutation. Idempotent transitions that make no change do not consume a clock tick, preserving deterministic injected clocks.
- UTC generation and Elixir receipt consumption share the same exact contract rather than parallel regexes. PowerShell retains the identical exact raw timestamp pattern and field ceiling.
- The regression suite covers invalid ISO8601, an unsupported term, a 65-byte oversized source, non-UTC `DateTime`, offset ISO8601 normalization, fractional-second truncation, the exact 20-byte UTC boundary, consumer parity, and post-success receipt-loss replay without restoration.
- Legacy lookup is read-only and ordered delivery before claim, matching the existing new-key semantics when a delivery exists after a crash but claim cleanup did not complete.
- Exact legacy identity validation prevents a filename collision from satisfying another receiver or epoch. Directory/reparse collisions, malformed JSON/schema/identity, and an over-ceiling artifact all suppress command execution.
- Normal success tests assert the exact new SHA-256 delivery basename and the absence of the old basename. No plaintext receiver, notification command/output, child environment, secret, Production path, deployment, database, or external resource was introduced or touched.

### Concerns

- The checkout remains on Elixir `1.20.2` although `elixir/AGENTS.md` specifies Elixir `1.19.x` with OTP 28.
- Existing compilation still emits the unrelated `HttpServer.normalize_host/1` warning and Phoenix LiveView Windows symlink-permission warning.
- The known stale Windows junction-fixture issue remains isolated by a fresh TEMP/TMP and forced test-environment compile for the exact focused suite; no production path, notification timeout, or fail-closed behavior was weakened.
