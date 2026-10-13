# Store.Operation lifecycle investigation

No violation of the established lifecycle contract was confirmed. The additions are test infrastructure and contract notes; production code is unchanged.

## Contract used

- `Store.Operation.run()` documentation explicitly requires manually invoking `run()` before queued actions execute. `StoreTests.testChainedOperationsDontExecuteUnlessRun` already checks deferred memory changes.
- The chained-operation tests establish sequential insertion/removal behavior. `PropertyBasedStoreTests.operationExecutionLifecycle` establishes that a successfully completed chain runs only once.
- The new oracle therefore checks accepted pre-run commands against an independent ordered Array model, checks independently decoded persistence, verifies that queuing does not call storage or codecs, and checks repeated successful runs for zero additional effects.
- Two overlapping calls for the same already-accepted queue must produce the same effects as one serial run. Their completion order is unspecified. A second caller may return early or wait for the first. The harness releases the first storage gate before requiring either task to finish. `waitingFollowerHarnessControl` deliberately waits in the follower adapter to verify that this alternative policy is accepted.

No documentation or existing test establishes whether a started/completed Operation remains appendable, whether `run()` retries after failure, or whether concurrent callers share a thrown error. Successful appending calls after execution starts are therefore observations, not promises that their commands will execute. No retry, atomic rollback, or post-start mutable-chain guarantee is asserted.

## Harness and bounds

`OperationLifecycleDiscoveryTests.acceptedQueueHistories` uses PropertyBased generation and shrinking through `DiscoveryProperty`. Scenarios hold an initial state, a generated command AST, a never/serial/concurrent run schedule, and a repeated-run count. The queue is interpreted independently through `StoreDiscoveryModel`, with insertion order, overwrite, deletion by identity, duplicate batch IDs, stale deletion payloads, and empty operands. Default generation is 1,000 histories of 1–50 commands. `BOUTIQUE_PROPERTY_STEPS` can lower that maximum. The 750-case finite matrix enumerates every three-command history over five representative commands, two initial states, and all three run schedules.

A storage gate acknowledges the first actual mutation, rather than a logical command that may have been fused. The concurrent effect trace is compared to a single serial control, including remove/clear calls whose final state is idempotent. Independently calculated insertion commit counts also expose duplicate insertion effects. Each gate/completion wait has a two-second bound. Error cleanup releases storage gates, cancels the owned tasks, and joins them. The codec fixture queues a rejecting item without invoking its encoder/decoder, then verifies that encoding rejection surfaces at `run()`.

The opt-in probes generate 1,000 insertion-only schedules across append-during-run, append-after-run, and retry-after-failure; a 24-case matrix guarantees both failure sides of the first write commit. Completion flags and outcome counters describe behavior without requiring post-start appends or retries to execute. Generated faults affect the first write; other fault positions and concurrent appends of removal/fusion commands remain outside this bounded investigation.

## Observed behavior at e717aa5

The retained `probe-validation.log` records all 1,000 probe schedules:

- 337 append-during-run, 321 append-after-run, and 342 failed-run reuse schedules.
- All second callers completed before the gated first caller in this implementation.
- All later run calls produced no additional backend effects. None of the 2,473 post-start appended items persisted.
- 184 failures occurred after a commit, leaving one queued item persisted; 158 failed before a commit, leaving none. The queued tail did not run or retry.

`run()` sets `operationsHaveRun` before its first awaited command. Its `for` loop creates an Array iterator over the accepted actions; later appends mutate the stored Array while the iterator retains the original sequence. These mechanics explain the observations. They do not establish that retry or mutable-chain behavior is intended. Such behavior requires a design decision before a production change or bug claim.

## Run independently

On the toolchain used for these logs:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export BOUTIQUE_SWIFT=/private/tmp/boutique-swift-6.2.4-expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift

# Established contract checks, 1,000 generated histories + 750 finite histories.
Scripts/property-tests.sh --filter OperationLifecycleDiscoveryTests

# Characterization only: 1,000 generated + 24 finite schedules.
BOUTIQUE_OPERATION_PROBES=1 Scripts/property-tests.sh --filter OperationLifecycleDiscoveryTests/ambiguous

# Alternative follower-completion harness control.
Scripts/property-tests.sh --filter OperationLifecycleDiscoveryTests/waitingFollowerHarnessControl
```

Both main and probe generators use the existing versioned JSON artifact runner. If an invariant fails, it writes the original/reduced scenario and preserves that invariant during library shrinking. Replay with `BOUTIQUE_PROPERTY_REPLAY=/path/to/operation-lifecycle.json` and filter `OperationLifecycleDiscoveryTests/acceptedQueueHistories`; use `BOUTIQUE_OPERATION_PROBES=1` and filter `ambiguousLifecycleProbes` for `operation-lifecycle-probes.json`. No failure JSON is retained because neither generated search found a supported invariant violation.

The logs are focused runs, not a full-suite validation or proof. All five command kinds and all initial-state/run partitions were reached by default generation. The suite covers one chain per history, up to two overlapping callers, value-type items, and an instrumented backend. Real backend overlap, reference-valued Codable items, longer caller races, and cancellation policy remain untested here.
