# Concurrent owners, repeated faults, and recovery

This lane adds `StoreConcurrentFaultDiscoveryTests`; it changes no production source or shared property runner. No independent new root cause was confirmed. It retains a composed witness: PR #86's overlapping successful inserts hide an otherwise committed record from memory; a later successful fused clear leaves that record persisted through the same unknown-record mechanism as PR #87. The reduced witness needs **zero faults**. Repeated-fault coverage comes from the passing controls, not from that reduced failure.

## Generated state space and oracle

Each concrete Codable scenario has 0–2 seeded records, 2–3 logical owners (`A`, `B`, `C`), a release permutation, owner-local before/after gate directives and fault prefixes, and 0–30 arbitrary recovery operations. Seven operation families include single/bulk insert and remove, direct clear, fused clear/insert, and fused selective-remove/insert. Bulk operands include duplicate IDs with unequal payloads and empty arrays. Two owners may throw: before any commit, after a proper committed prefix, or after their entire operation commits. Faults occur **inside the storage backend**, before Store returns; there is no invented atomic batch or failed-call rollback assertion.

The generator reconstructs owner-local directives together with the operations when shrinking raw arrays/operands. Logical owner names label task-local effects; there are no external index references that can survive removal as orphaned directives. Payloads and removal multiplicity are authored independently by the Array model. Loaded contents are first checked against seeded values; only identity ordering is adopted, using model-owned payloads.

Every nonempty operation first acknowledges a before-effect rendezvous. Second gates are installed before launch, at element boundary 1, either before or after commit. In the generated permutation, release each owner's first gate and await its second gate or completion before releasing the next owner. Release second gates in reversed permutation and await completion individually. Three owners exercise all six permutations; two exercise both orders. No sleeps decide correctness. Gates and completion waits have safety deadlines. An unreachable schedule is counted, all gates released, all tasks joined, and that history returns an explicit `histories.infeasible` outcome instead of asserting a guessed initial snapshot. Empty operations count unavailable storage rendezvous separately and still receive oracle checks. No actual deadline infeasibility occurred in acceptance; empty-operation infeasibility did occur.

For every owner, compare actual decoded commit entries to the **complete independently authored prefix**, including multiplicity and payloads, before replaying any ledger order. After this check, the ledger supplies owner/order only; expected writes come from the authored prefix, never actual decoded payloads. The ordered Array replay drives independently decoded persisted contents and reopened contents, with duplicate identities checked separately. Unexpected task errors are retained and rethrown only after all tasks join.

Passing lanes separate recovery from unspecified failed memory semantics:

- Reopen immediately after concurrent work, verify persisted contents, then execute arbitrary successful recovery tails.
- Successfully call direct `removeAll()` on the original instance after concurrent work, independently verify the reset, then execute the same arbitrary operation families on that original instance. Reconstruction checks do not replace that instance.

Opt-in memory checks apply only when every concurrent call succeeded. Opt-in unreconciled continuation checks persistence/reopen, avoiding any failed-call memory assertion; successful fused clear is required to remove all persisted records. These searches are separated so known memory races cannot prevent persistence/recovery exploration.

## Validation and retained findings

`controls-1000.log`: 1,000 complete generated histories in each passing lane, plus **588** finite histories. The finite matrix enumerates 2/3 owners × all 7×7 operation pairs × prefix requests 0/1/2 (clamped to authored length) × before/after second-gate phase, with its two declared release permutations. All matrix histories inject two failures. This is bounded enumeration of that declared product, not all schedules.

`controls-10000.log`: **10,000 complete generated histories per lane**, 20,000 total, and the 588-history matrix passed in 51.174 seconds. Generated histories reached 5,591 two-failure histories, 4,533 proper partial faults, 6,907 full-commit faults, 6,836 before-commit faults, 5,988 actual commit interleavings, 71,947 concurrent committed effects, 26,703 duplicate-operand commands, and 8,978 empty-operand commands. All seven concurrent/recovery operation families and all six three-owner permutations reached. Both passing searches had exactly 10,000 attempts, so no shrinking attempts inflate those counts.

`memory-search.log` stops at the first known PR #86 witness: 0 successful generated histories / 61 attempts including shrinking. `memory-search/store-concurrent-fault-memory.json` reduces to distinct-ID successful inserts; only memory differs after completeness/persistence pass. Concrete replay fails the same memory invariant (`memory-replay.log`).

`unreconciled-search.log` stops after 9 successful histories / 162 attempts including shrinking. The reduced scenario has seed `seed-0=0`; owner B inserts `key-0=0`, then owner A inserts `key-1=0`. Both backend calls succeed and both authored commits exist. Live memory omits B's record. A later successful fused clear with an empty insertion leaves `key-0=0` persisted, while the expected persisted set is empty. This is a **composition of existing causes**, distinct from asserting rollback of a failed call. JSON retains original and reduced histories; `unreconciled-replay.log` reproduces persistence divergence at recovery step 0. The searched original happens to have zero faults too; this witness is not evidence that repeated failures are necessary.

Two disabled-by-default mutation calibrations prove sensitivity:

- `BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_WRITE=1` omits actual backend writes while recording actual accepted write entries and keeping the independent oracle intact. It fails persistence, 0 successful histories / 21 attempts; JSON/logs under `calibration-write*` retain the reduction. The same concrete replay passes after the mutation is disabled.
- `BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_TAIL=1` omits successful recovery calls while preserving the model. It fails persistence, 0 successful histories / 42 attempts; JSON/logs under `calibration-tail*` retain the reduction. The same concrete replay passes after the mutation is disabled.

No production mutation was made; both mutation flags were removed for clean acceptance and restored replays. The final extended run uses the exact committed test implementation. No full repository suite was run in this lane.

## Commands

Use the toolchain environment from `PROPERTY_TESTING_DISCOVERY.md` on this host. Default cases are 1,000 per generated passing test.

```sh
Scripts/property-tests.sh --jobs 2 --filter StoreConcurrentFaultDiscoveryTests
BOUTIQUE_PROPERTY_CASES=10000 Scripts/property-tests.sh --jobs 2 --filter StoreConcurrentFaultDiscoveryTests

BOUTIQUE_CONCURRENT_FAULT_MEMORY=1 Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/successfulConcurrentMemorySearch
BOUTIQUE_CONCURRENT_FAULT_FUSED=1 Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/unreconciledFusedClearSearch

BOUTIQUE_CONCURRENT_FAULT_MEMORY=1 BOUTIQUE_PROPERTY_REPLAY=Investigation/ConcurrentFaults/memory-search/store-concurrent-fault-memory.json Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/successfulConcurrentMemorySearch
BOUTIQUE_CONCURRENT_FAULT_FUSED=1 BOUTIQUE_PROPERTY_REPLAY=Investigation/ConcurrentFaults/unreconciled-search/store-concurrent-fault-unreconciled.json Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/unreconciledFusedClearSearch

BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_WRITE=1 Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/persistenceAndReopenedRecoveryHistories
BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_TAIL=1 Scripts/property-tests.sh --filter StoreConcurrentFaultDiscoveryTests/directClearContinuedUseHistories
```

The opt-in searches/replays and calibration commands intentionally fail. Flags disabled, calibration JSON replays pass using their corresponding suite names.

## Limits

This is one Store with an instrumented deterministic backend; no real Disk/SQLite fault injection, cancellation, load overlap, cross-Store writers, failed-chain retry, or concurrent event-order promise is tested. Owner-local gates are limited to boundaries 0 and 1, so longer batches are not exhaustive schedules. Recovery tails are bounded to 30 operations; faults occur during the concurrent phase, not during recovery. Each owner has at most one injected fault; at most two owners throw. Immediate reopen/direct reset deliberately provide specified baselines for passing memory comparisons. Unreconciled memory after failures remains unspecified. Random searches stop at first divergence and are not 1,000 explored failing histories.
