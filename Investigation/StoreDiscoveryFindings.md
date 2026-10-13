# Store discovery expansion

The default `Scripts/property-tests.sh --filter StoreDiscovery` runs 1,000 mock
histories (up to 100 generated steps), 100 histories per Disk/SQLite backend (up
to 40 steps), 1,000 fault schedules, 1,000 serialized schedule controls, six fusion
matrix cases, and 49 fault-boundary matrix cases. Case counts use shared runner
environment settings. History lengths count generated draws; explicit fusion
patterns can add a second logical command. Existing tests are preserved.

Generation uses PropertyBased 2.0.1 composition and shrinking. Concrete Codable
scenarios replay independently of PRNG/generator changes. Swarms include fresh,
no-clear growth; overwrite-heavy; removal-heavy; and broad histories. Queued
chunks contain up to eight commands. Small domains force identity collisions;
growth mode creates fresh identities. Empty and duplicate batches, stale removal
payloads, delayed persistence reads, queue-before-run checks, repeated run, and
fresh-backend reopen are covered. The oracle is an ordered Array, independent
JSONDecoder, and sorted full-value persistence comparison with explicit duplicate
identity rejection. Reopen ordering is adopted only after value/multiplicity
verification, and payloads remain model-owned.

Default verification: 3,200 generated cases plus matrices passed in 5.5s
on Swift 6.2.4/Xcode 16.2 SDK, base revision b740dd5. One run reached 96–103 live
items, all chain lengths 1–8, 17,994 overwrites, 8,350 existing removals, 3,961 empty
batches, 1,166 reopens, and 23,796 delayed persistence reads in mock histories.
These are observed counts, not exhaustive coverage claims.

## Controlled schedules and findings

`StoreDiscoveryStorage` exposes bounded continuation acknowledgements and FIFO
release gates. It can pause read snapshots and mutation commits. Teardown releases
all gates and awaits outstanding operations. Schedules contain initial size,
payload, single/batch choices, insert/remove/clear choice, and completion order.
Both operations can start before either completes; both completion orders are
representable. Serialized controls pass by default. Completion waits are bounded
while another gate is held; a repaired implementation that serializes operations
is classified explicitly as an infeasible requested overlap. All gates are then
released, both tasks joined, and the oracle uses recorded backend commit order.
Requested, reached, and infeasible scheduling counters are separate. Twelve
calibration cases deliberately make the second operation wait for the first;
both requested orders finish and validate serialized outcomes (including clear).

The opt-in generated overlap search currently fails:

```sh
BOUTIQUE_STORE_OVERLAP_SEARCH=1 Scripts/property-tests.sh --filter StoreDiscoveryScheduleTests/generatedOverlaps
```

Confirmed memory/persistence divergences:

- Two distinct inserts snapshot the same old memory. Either completion order
  leaves only the last completed insertion in memory, while persistence retains
  both. `StoreDiscoveryOverlapFailure.json` preserves a generated original and
  reduced mutation failure.
- A suspended initial read can overwrite a completed insertion with stale memory.
  Conversely, an insertion started during loading can later overwrite newly
  loaded initial items. `StoreDiscoveryLoadOverlapFailure.json` preserves a
  generated original and reduced load failure.

Four extracted witnesses (load/mutation × both completion orders) all fail the
memory assertion, after persistence assertions pass:

```sh
BOUTIQUE_STORE_OVERLAP_WITNESSES=1 Scripts/property-tests.sh --filter StoreDiscoveryScheduleTests/extractedOverlapWitness
```

Replay a saved generated counterexample without generation:

```sh
BOUTIQUE_STORE_OVERLAP_SEARCH=1 BOUTIQUE_PROPERTY_REPLAY=Investigation/StoreDiscoveryOverlapFailure.json Scripts/property-tests.sh --filter StoreDiscoveryScheduleTests/generatedOverlaps
```

These searches are opt-in to keep passing exploration reusable while retaining
explicitly failing findings. No production fixes are included. Load and mutation
failure invariant IDs differ so shrinking cannot switch between these mechanisms.

## Fault semantics and calibration

Seven named families cover direct single/bulk insertion, bulk removal, clear,
fused insertion failure, and both clear/selective fused removal failure. Failures
occur before a commit or after selected committed elements, including the final
element. Assertions cover propagation, exact resulting bytes, reopening, further
use, and reset recovery. No transactional rollback is assumed. Reads cannot throw
in StorageEngine; malformed load bytes remain covered by existing discovery tests.

Restoring PR #84's original `CacheKey(verbatim:)` line temporarily made both the
fusion matrix and generated mock histories fail. The library reduced the generated
failure to two steps/three commands, recorded in `StoreDiscoveryPR84Mutation.json`.
After restoring the fix, replay passed:

```sh
BOUTIQUE_PROPERTY_REPLAY=Investigation/StoreDiscoveryPR84Mutation.json Scripts/property-tests.sh --filter StoreDiscoveryHistoryTests/mockHistories
```

## Remaining bounds

Schedules explore two concurrent operations, not arbitrary multi-task interleavings.
Generated overlap runs stop at their first failure and shrink it; the four extracted
witnesses cover the confirmed mechanisms across completion order. Array order after
backend reload and concurrent event publication order are not assumed. Failed-chain
retry atomicity is not promised and is not asserted. Fault schedules inspect a
controlled test backend, not injected real filesystem/SQLite failures. Cross-Store
concurrent writers sharing one engine remain a separate target.
