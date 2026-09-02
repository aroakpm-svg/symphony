# SDD ledger — plan: docs/superpowers/plans/2026-08-28-aro-286-project-workspace-isolation.md

Merge base: 98aa2f6
Spec: docs/superpowers/specs/2026-08-28-aro-286-project-workspace-isolation-design.md

## Pre-flight interface scan

| Tasks | Producer / consumer or self-consistency check | Finding |
| --- | --- | --- |
| Task 1 | Tests require `ProjectExecutionContext.from_issue/1`; implementation defines that function and safe metadata | Consistent |
| Task 2 | Tests require context-aware Workspace arities and durable fields; implementation preserves legacy arities | Consistent |
| Task 3 | Tests require injected provider and subprocess-only env; implementation defines provider boundary and propagation | Consistent |
| Task 4 | Tests classify live Linear viewer results; implementation reuses viewer query and gates startup | Consistent |
| Task 5 | Tests require typed health state and stage instrumentation; implementation defines one GenServer and existing-flow calls | Consistent |
| Task 6 | Tests require receiver-bound idempotent notification; implementation defines config, notifier, and watchdog | Consistent |
| Task 7 | Documentation and verification steps map to the implementation tasks and global gates | Consistent |
| Tasks 1 → 2 | Task 1 produces immutable context; Task 2 consumes it for path/readiness identity | Compatible |
| Tasks 1 → 3 | Task 3 consumes the Task 1 context for credential selection and AgentRunner propagation | Compatible |
| Tasks 1 → 5 | Task 5 consumes `safe_metadata/1`; credential reference remains excluded | Compatible |
| Tasks 2 ↔ 3 | Both modify `Workspace`; Task 2 establishes arities/state before Task 3 adds process env | Sequential, no contradiction |
| Tasks 2 ↔ 6 | Both touch workspace/config tests for different contracts | Sequential, no contradiction |
| Tasks 3 → 7 | Task 7 documents the default fail-closed provider and ARO-195/196 boundary | Compatible |
| Tasks 4 → 5 | Task 4 produces startup identity outcomes; Task 5 records their dependency health | Compatible |
| Tasks 4 ↔ 5 | Both modify `Orchestrator`; Task 5 instruments the Task 4 gate after it exists | Sequential, no contradiction |
| Tasks 5 → 6 | Task 6 consumes stop receipts/epochs and adds notification delivery | Compatible |
| Tasks 5 → 7 | Task 7 documents health state and surfaces | Compatible |
| Tasks 6 → 7 | Task 7 documents notifier config and watchdog | Compatible |

Ruling: The production multi-project credential provider remains fail closed until an approved host adapter is configured — ARO-286 may define and test isolation but ARO-195/196 owns canonical GitHub source selection — if wrong, ARO-286 will require a follow-up adapter change before ARO-285 live acceptance.

Task 1: base 24ea8f5
Task 1: complete (commits 24ea8f5..30a6579, review clean)
Task 2: base 30a6579
Task 2: fix round 1/5 (3 addressed, 1 open — remote before_remove hook executes before namespace physical validation; commits a2b57a7..4a0e829)
Task 2: fix round 2/5 (1 addressed, 0 open — remote hook now follows exact physical validation; commits 4a0e829..38c2382)
Task 2: minor (deferred): unchanged legacy non-context remote remove/2 invokes hook before generic path validation; outside ARO-286 context-aware path.
Task 2: complete (commits 30a6579..38c2382, review clean)
Task 3: base 38c2382
Task 3: Ruling: add `elixir/lib/symphony_elixir/codex/app_server.ex` and its focused test to Task 3 — the spec requires credential material to reach only the immediate subprocess environment, and the listed files stop one boundary too early — if wrong, this adds a narrowly scoped AppServer option outside the original task file list.
Task 3: fix round 1/5 (3 addressed, 3 open — remote check trusts caller redaction list; repo-local credential helper remains active; pre-parse JSON redaction can corrupt protocol; commits e54e494..f6dcfe9)
Task 3: fix round 2/5 (3 addressed, 0 open — actual-env remote gate, local-helper reset, post-parse sanitization; commits f6dcfe9..b5815a7)
Task 3: complete (commits 38c2382..b5815a7, review clean)
Task 4: base b5815a7
Task 4: fix round 1/5 (3 addressed, 0 important open — release-safe default validator, closed outcome vocabulary, GraphQL error precedence; commits 4143120..371c55b)
Task 4: minor (deferred): default-wiring regression starts Orchestrator directly rather than exercising the full CoreSupervisor → Orchestrator → Tracker → Linear client chain; implementation forwarding is statically correct.
Task 4: complete (commits b5815a7..371c55b, review clean except deferred minor)
Task 5: base 371c55b
Task 5: fix round 1/5 (5 addressed, 1 open — secret formats, lifecycle timing, typed fields, dependency/stop idempotence, immutable Windows receipts; receipt-directory TOCTOU remained; commits 091150f..d68ec3f)
Task 5: fix round 2/5 (final publication pinned, but 3 open — capability acquisition TOCTOU, bundled release launcher discovery, writer timeout lifecycle; commits d68ec3f..2586712)
Task 5: fix round 3/5 (3 addressed, 0 open — post-acquisition OS identity attestation, trusted bundled launcher discovery, correlated timeout retirement; commits 2586712..7872dab)
Task 5: complete (commits 371c55b..7872dab, review clean)
Task 6: base 7872dab
Task 6: Ruling: restart-limit notification is disabled unless both an operator command and opaque receiver are configured; partial configuration fails closed, and delivery receipts use only a bounded non-reversible receiver hash plus epoch — this keeps the default local runtime side-effect free — if wrong, operators expecting implicit notifications must add explicit config.
Task 6: fix round 1/5 (7 addressed, 2 open — pinned root, secret-safe/hash-only persistence, disabled config, tree timeout, atomic claims, canonical separation, strict receipt shape; Unicode/immutable read and wrapper cleanup remained; commits 62ded0f..6de02a8)
Task 6: fix round 2/5 (wrapper cleanup addressed, 1 open — producer/consumer Unicode and total-size parity; commits 6de02a8..a519d3a)
Task 6: fix round 3/5 (cross-PowerShell Unicode handling improved, 1 open — producer field bounds still unprovable and consumers accepted outside-schema detail; commits a519d3a..840fadd)
Task 6: fix round 4/5 (portable byte bounds and int64 routing added, 2 open — generated timestamp bypass and legacy durable filename compatibility; commits 840fadd..de385f0)
Task 6: fix round 5/5 (timestamp addressed, 1 open — unsafe/overlong legacy path is treated as missing and can permit duplicate notification; commits de385f0..aa84564)
Task 6: Ruling: carry the load-bearing legacy-path ambiguity into Task 7 before acceptance — an unrepresentable legacy claim/delivery path must suppress notification rather than mean absent — this is the smallest fail-closed change after the five-round breaker — if wrong, unusually long runtime roots may suppress a notification that had no legacy artifact.
Task 6: complete (commits 7872dab..aa84564, 1 load-bearing finding carried to Task 7 by ruling)
Task 7: base aa84564
Task 7: fix round 1/5 (5 addressed, 0 open — Dialyzer path branch, coverage writer discovery, ReadinessState fixtures, branch diff whitespace, report provenance; commits f1142b4..27d94a8)
Task 7: complete (commits aa84564..27d94a8, review clean)
Final review: initial whole-branch review found 2 Critical and 4 Important integration findings; one coherent fix wave committed as 8ef1f25.
Final review: scoped re-review addressed lifecycle context cleanup, watchdog↔RuntimeHealth contract, configured-project Linear authority, and receipt copied-token relocation.
Final review: residual load-bearing Important — local workspace attestation compares mutable directory size/mode/link count, so legitimate POSIX workspace mutation can invalidate the same inode.
Final review: residual load-bearing Important — SubprocessEnvironment creates private HOME/GH/Codex directories before Workspace validation and follows symlink/reparse components, allowing cross-project/outside-root aliasing.
Final review: Ruling: do not merge or claim ARO-286 complete; preserve branch/worktree and require a new explicitly reviewed remediation cycle for the two residual isolation boundaries — a second unreviewed fix wave would violate the final-review breaker — if wrong, delivery is delayed despite 296/296 focused acceptance.

Final whole-branch review: base 27d94a8
Final whole-branch review: all six findings addressed in one integration wave — lifecycle cleanup
retains the validated context and workspace attestation; local and remote effects require the exact
context-derived issue directory and reject replacement; subprocesses use a non-login shell and a
minimal isolated environment; RuntimeHealth and watchdog share the exact root/epoch/receipt/attempt
contract and the watchdog writes a bounded restart-limit receipt after a real child crash; Linear
startup validates access to every exact configured project UUID; and receipt publication reattests
the pinned directory/guard handle/guard path before publishing.
Final whole-branch review: Linear authority ruling — the approved design and plan define authority
with each profile's exact `linear_project_id` and independently bind every routed issue to that UUID.
They do not define a separate Linear organization identifier, so no new out-of-scope organization
configuration was invented.
Final whole-branch review: documentation evidence narrowed to the exact cleanup, watchdog,
credential-inheritance, and relocation regressions. The Task 2 legacy non-context remote cleanup
minor and Task 4 direct-Orchestrator default-wiring minor remain deferred and unchanged.
