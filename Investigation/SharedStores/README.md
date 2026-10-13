# Shared persistence across multiple Store instances

A stale Store's successful fused `removeAll().insert(...)` retains records inserted by a peer. This is the same memory-selected `.all` omission as PR #87, now reached without a throwing write. Every operation is awaited sequentially, identifiers are ASCII, and no cross-instance cache refresh is asserted. No production changes are included.

## Contract and oracle

`StoreSharedPersistenceDiscoveryTests` constructs two or three Stores before or after writes, alternates writers, uses duplicate/empty batches, unequal overwrites, stale removal operands, direct clears, selective removal/insertion fusion, and arbitrary drop/reconstruct checkpoints. A global independent ordered Array represents persistence; each instance has its own independently interpreted Array history. Peer writes do not update another instance's expected cache. A fresh construction verifies identities, payloads and multiplicity before adopting only observed load ordering from independently authored versions. Persistence is decoded independently at every successful operation, then a fresh Store is checked against the global model. No failed-call, cache refresh, reload order, or concurrent linearizability guarantee is invented.

Instrumented storage shares one actor. Disk and SQLite each run both one shared engine and independently constructed engines at one isolated location. Separate mock engines intentionally resolve to the same actor; the duplicate mock finding is a topology control, not a separate backend result. Real fixtures are removed after every attempt.

Passing controls execute all clears directly; selective fusion remains enabled on stale instances. Thus the known fused-clear failure cannot mask independent insertion, overwrite, selective removal, direct clear, reconstruction, or fresh reopen disagreements. Opt-in searches separately permit fused clears. A paired witness repeats identical construction and operation histories in independently isolated direct and fused fixtures and compares actual persisted outputs; the fused leg deliberately omits its global persistence assertion so the pair reaches the equivalence assertion.

## Finding

The original library campaign reduced all six enabled backend/topology searches to two Stores constructed empty, owner A inserting `key0`, then stale owner B executing fused clear plus replacement. B's cache contains only replacement; independently decoded persistence contains key0 and replacement. Direct clear plus insertion from the identical initial state removes key0. Six paired witnesses fail equivalence as well. This is a generalization of PR #87's root cause, not a new independent defect cluster. The searches stop at their first invariant failure; success counts before failure and shrinking attempts are separate in `findings.log`.

## Evidence and commands

`run.sh` sets this host's documented Swift 6.2.4 toolchain and uses `--jobs 2`. It accepts `BOUTIQUE_SHARED_FILTER` for a focused entrypoint. Use the normal documented toolchain on other hosts.

```sh
# Passing default controls: 1,000 cheap / 100 per real configuration.
Investigation/SharedStores/run.sh

# Extended passing controls.
BOUTIQUE_PROPERTY_CASES=10000 BOUTIQUE_BACKEND_CASES=1000 \
  Investigation/SharedStores/run.sh

# Opt-in generated and paired findings: expected failure.
BOUTIQUE_SHARED_STORES_FINDINGS=1 \
BOUTIQUE_PROPERTY_ARTIFACTS=Investigation/SharedStores \
  Investigation/SharedStores/run.sh

# Concrete finding replay: expected failure, no RNG needed.
BOUTIQUE_SHARED_STORES_FINDINGS=1 \
BOUTIQUE_SHARED_FILTER=StoreSharedPersistenceDiscoveryTests/instrumentedFusedClearReplay \
BOUTIQUE_PROPERTY_REPLAY=Investigation/SharedStores/shared-stores-mock-shared-fused.json \
  Investigation/SharedStores/run.sh

# Identical history through direct control: expected pass.
BOUTIQUE_SHARED_FILTER=StoreSharedPersistenceDiscoveryTests/instrumentedControls \
BOUTIQUE_PROPERTY_REPLAY=Investigation/SharedStores/direct-control-replay.json \
  Investigation/SharedStores/run.sh
```

`controls-1000-100.log` retains 1,000 instrumented and 100 each Disk shared/separate, SQLite shared/separate histories, plus 336 finite histories: all pass in 12.667 seconds. The finite matrix enumerates 288 two-step histories over two owners, two identities, unequal payload versions, insertion/batch/removal prefixes and six continuations; 48 additional patterns vary 2/3 instances, early/late construction and reconstruction. Reachability assertions require stale selective removal, stale direct clear, late construction and reconstruction.

`controls-10000-1000.log` retains the extended clean campaign: **10,000 instrumented plus 1,000 each of four real configurations**, all passing in 145.671 seconds, plus the 336 finite histories. The retained logs normalize trailing whitespace only. `counts.json` summarizes the exact per-suite counters, successful campaign counts, and attempts including shrinking.

Two temporary SUT adapter mutations skipped actual insertion or removal while leaving both models unchanged. They failed on `shared.writer-memory` and shrank to one insertion or insertion followed by removal. `calibration-{insert,remove}.log` and corresponding JSON retain evidence; `calibration-*-reverted.log` retain passing concrete replays. Mutation hooks were removed before the extended clean run; no production mutation occurred. `replay-mock.log` independently reproduces the retained failing JSON; `direct-control-replay.log` passes the identical history with direct clear. `final-controls.log` validates the final committed suite including its dedicated replay entrypoint.

## Limits

Histories are bounded to 100 commands for the instrumented backend and 40 for real backends. They do not cover concurrent calls, observations, cancellation, reference aliasing, fault injection, repeated execution of operation chains, or every possible chain shape. This suite checks successful persisted effects and writer-local semantics; it does not establish automatic cache refresh of old instances. No full repository suite or code coverage measurement is claimed.

To repeat calibrations, temporarily change the interpreter's `case 0` from `try await store.insert(item)` to an empty statement, retaining `commands = [.init(kind: .insert, items: [item])]`. For removal, temporarily change `case 2` from `try await store.remove(item)` to an empty statement, retaining the corresponding `commands` assignment. Apply one mutation at a time, then run:

```sh
BOUTIQUE_SHARED_FILTER=StoreSharedPersistenceDiscoveryTests/instrumentedControls \
BOUTIQUE_PROPERTY_ARTIFACTS=/tmp/shared-calibration \
  Investigation/SharedStores/run.sh
```

The command must fail and persist a shrinking artifact. Revert the changed interpreter line, then replay `/tmp/shared-calibration/shared-stores-mock-shared-direct.json` with `BOUTIQUE_PROPERTY_REPLAY` and the same filter; it must pass. The retained original experiments used equivalent conditional guards controlled by `BOUTIQUE_SHARED_CALIBRATE=insert` or `remove`, now removed. Neither calibration modifies the expected model, generator, or production code.
