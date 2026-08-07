# Safe checkpoint and handoff receipts

`HandoffReceiptV1` records the last durable, verified safe point for a claimed
Linear issue. It is deliberately small and structured; it is not a workspace
backup, workflow graph, prompt store, or guarantee that uncommitted local work
survives a machine change.

Only the active claim generation can append a receipt. Runtime roles have no
direct table access, so existing rows cannot be updated or deleted. PostgreSQL
assigns both `checkpoint_sequence` and `recorded_at`; the latest hint is selected
by generation and then sequence.

The fixed step IDs are `preflight`, `branch`, `implementation`, `tests`, `commit`,
`push`, `pull_request`, and `review`. Completed and pending lists must be unique,
disjoint subsets of that list. Test results contain only a name and one of
`passed`, `failed`, or `skipped`.

## Resume contract

A new owner first obtains an active claim. It may then read the latest receipt,
but must freshly verify all of the following before selecting the first pending
step:

- canonical repository, remote branch, commit SHA, PR number, PR head, and the
  repository readiness gate;
- current Linear revision and active claim;
- latest ledger status for every recorded effect operation ID.

Missing receipts, schema versions other than V1, mismatched Git or Linear state,
inactive claims, non-ready PR state, and missing, pending, or unknown ledger
operations all return a safe-recheck result. The caller must reconstruct progress
from authoritative systems and must not guess from local files.

The migration only targets `symphony_staging`. Its rollback removes the receipt
contract and ARO-166 objects without touching the production schema or the claim
and effect-ledger contracts.
