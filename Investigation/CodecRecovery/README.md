# Codec failure and recovery

`CodecRecoveryDiscoveryTests` adds independent authored-byte load scenarios and Array-modeled encoding/recovery histories. No production change or new confirmed production defect is included. ASCII IDs and sequential awaits distinguish this lane from Unicode identity PR #85 and scheduling PR #86. Fused removal before rejected encoding is a phase-order observation, not a rollback assertion. The successful fused clear after a backend partial commit remains the separate PR #87 finding.

Three cheap property entrypoints generate malformed loads, corrupt read snapshots, and encoding histories. Disk and SQLite each exercise the malformed-load reconstruction scenario. The authored JSON mixes one valid record with malformed, truncated, or wrong-shape bytes. The failed load must preserve raw persistence; replacing the damaged bytes and reconstructing must recover both independently authored values. DecodingError categories are checked against independent JSONDecoder decoding of the exact corrupt input. Subsequent waits on the original failed load Task are counted as characterization, with no retry promise asserted.

StorageEngine reads are nonthrowing. The corrupt-read backend returns invalid bytes once while leaving storage intact; this checks decoder recovery after read disruption. Actual backend I/O errors cannot propagate through this API and are not invented by the fixture.

Encoding scenarios vary rejecting payload position, duplicate operands before/after the rejection, selective rejection masked by a later accepted same-ID value, direct/fused removal, and one to four repeated rounds. The independent Array model performs last-writer normalization before deciding whether encoding must reject. Accepted batches compare complete contents and multiplicity. Rejected direct writes preserve raw records; fused clear may remove the loaded records before encoding rejects. No failed-operation memory/rollback contract is assumed.

Each round performs a successful insertion on the original Store, followed by independently generated command structs (kind, ASCII key, payload) interpreted against a complete persistence model before any forced reconstruction. Commands include insert/overwrite, removal, direct clear, reconstruction, and further exact encoding rejection. After recovery, a second command history checks both memory contents and raw decoded persistence. Explicit direct/fused clear and reopen verify successful recovery. The bounded matrix covers 18 encoding parameter combinations and 49 two-command histories over two identities and two payload versions; it is not exhaustive over all operands.

## Validation

Default budgets passed: 1,000 cases each for load, corrupt read, and encoding; 100 each for Disk and SQLite; and the finite matrix (`default.log`). Extended validation passed 10,000 cases in each of the three cheap entrypoints and 1,000 each on Disk/SQLite, plus the matrix, in 74.114 seconds (`extended.log`). Encoding reached 25,044 continued-use insertions/reopens, 16,783 rejected batches, 8,261 masked rejecting duplicates, and every generated command kind both before and after reconstruction. Passing-case counters exclude shrinking attempts.

Two deliberate SUT adapter mutations were detected and automatically shrunk, while expected models remained unchanged:

- Skip the successful recovery insertion: `codec.recovery.mutation`, 27 attempts, zero successful cases (`calibration-mutation.log` and JSON).
- Delete the unrelated valid record immediately before reconstruction: `codec.load.reconstruct`, 23 attempts, zero successful cases (`calibration-load.log` and JSON).

To reproduce the negative checks, temporarily replace `try await store.insert(recovered) as Void` with an empty statement in `encoding`, run only `encodingRecoveryHistories` with `BOUTIQUE_PROPERTY_CASES=20 BOUTIQUE_PROPERTY_ARTIFACTS=/tmp/codec-negative`, then restore the line. This skips the actual SUT write and preserves the complete expected model.

For the load mutation, temporarily insert this exact line in `load`, immediately before `let reopened = try await Store<CodecRecord>(...)`:

```swift
try await storage.remove(key: CacheKey("good"))
```

Run only `authoredRawLoadRecovery` with the same 20-case/artifact settings, expect `codec.load.reconstruct`, then remove the added line. Neither calibration modifies the oracle. Both mutation code blocks were removed. The saved reduced scenarios replay against the restored implementation (`replay-mutation.log`, `replay-load.log`). JSON records original/reduced inputs, invariant, divergence step, and revision; native logs retain seeds. These artifacts are sensitivity evidence, not production defects.

Run with the toolchain environment documented in PROPERTY_TESTING_DISCOVERY.md:

```sh
Scripts/property-tests.sh --jobs 2 --filter CodecRecoveryDiscoveryTests
BOUTIQUE_PROPERTY_CASES=10000 BOUTIQUE_BACKEND_CASES=1000 \
  Scripts/property-tests.sh --jobs 2 --filter CodecRecoveryDiscoveryTests
BOUTIQUE_PROPERTY_REPLAY=Investigation/CodecRecovery/calibration-mutation/codec-encoding.json \
  Scripts/property-tests.sh --jobs 2 --filter CodecRecoveryDiscoveryTests/encodingRecoveryHistories
```

Limits: no real disk/SQLite I/O fault injection, concurrency, cancellation, event-after-error contract, arbitrary failed-operation rerun, duplicate identities in loaded raw records, or unbounded history proof. Raw loaded IDs are unique, so no trap-prone duplicate-load mutation is attempted inside the runner. Backend reconstruction creates a new Store over the same backend instance; backend-object reopen is outside this lane. Commands after errors use direct clear unless a Store has been reconstructed; this avoids conflating unknown memory after a failed fused removal with the established partial-write fused-clear cluster. Only the focused suite was run.
