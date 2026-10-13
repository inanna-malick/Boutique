# Successful fused clear after a partial backend failure

A later **successful** `store.removeAll().insert(replacement).run()` can retain records committed by an earlier throwing insertion. The original Store shows only the replacement, but reopening resurrects the retained record. Both single-item and array replacement overloads reproduce this. No production change is included.

The standalone test starts with an empty Store. Its private StorageEngine writes the first of two batch records and throws an exact, one-shot error. The test independently decodes that committed record, performs the later clear+insert, and checks memory, independently decoded persistence, and a reopened Store against the explicit replacement. Direct `removeAll()` followed by `insert` passes with the same backend and both overloads. The test does not assert failed-call memory rollback or reconciliation.

## Root cause and distinction

The fused removal strategy `.all` selects keys from `Store.items` inside `performInsert`, then removes only those keys from storage. Inserts publish memory only after the awaited backend write succeeds. A record committed before a backend throws can therefore be absent from memory and omitted by the later fused clear. In the empty-store witness, the later clear issues no removals at all.

This is distinct from PR #85's Unicode identity equivalence and PR #86's overlapping mutations: identifiers are ASCII and every call is awaited sequentially. It is also independent of PR #84's key construction defect: the empty-store witness does not attempt existing-key removal. The violated contract is the successful later clear, not atomic rollback of the earlier failure. Choosing recovery/reconciliation behavior after failures remains a design question; no repair is inferred here.

## Histories and oracles

`StorePartialFailureHistoryTests` uses PropertyBased generation and shrinking with the existing invariant-preserving concrete-artifact adapter. Generated prefixes and up to 100 generated continuation commands use five reused keys, unequal overwrites, duplicate and empty batches, single/batch removal, queued chains of lengths 1–6, selective fusion, direct/fused clears, delayed reads, and reopen. A constructed fused-clear suffix survives shrinking; the result is not claimed globally minimal.

Nine fault families cover single/batch insertion and removal, direct clear, and insertion/removal phases of fused clear/selective removal. Generated fault positions include zero commit, a proper committed prefix, and full commit before the error. Expected backend effects come from an independent ordered Array model and independently normalized insertion operands; they do not come from storage call/commit logs or decoded actual bytes. Memory and persisted models remain separate.

Failed-call memory semantics are intentionally unconstrained. For continuing on the original Store, the harness adopts the observed selection and order of independently authored record versions. It never obtains an expected payload from the Store getter. Subsequent successful operations are interpreted against that concrete baseline, while persistence continues from the independently modeled committed prefix. After reopen, identities, payloads, and multiplicity are verified before adopting observed load ordering. This approach detects later successful-call defects while leaving failed-call rollback, observation, and reconciliation unspecified.

The direct control preserves unreconciled continuation and selective fusion but executes chains containing clear as separate direct commands. The reopen control reconstructs the Store immediately after the injected error, then permits arbitrary fusion. Queue construction must have no effects; running a successfully completed chain twice must have no further effects. Retrying a failed chain is not specified or tested.

## Evidence and validation

- Small development run: 20 histories in each control passed.
- Acceptance: 1,000 direct-control histories and 1,000 reopen-control histories passed in 10.608 seconds, alongside both standalone direct controls. All nine fault families and all generated chain lengths 1–6 were reached. The controls exercised 624 proper partial commits, 608 full commits before errors, and 45,370 persistence-read checkpoints (`controls-1000.log`).
- The direct control continued on 667 memory/persistence disagreements. Across both controls: 38,185 unequal overwrites, 30,083 duplicate-operand commands, and 8,281 continuation reopens.
- The opt-in search, budgeted at 1,000 histories, stopped at its first finding after 52 successful histories and 301 attempts including shrinking. `generated.json` retains the original and library-reduced scenarios; `generated.log` retains the native replay seed. The reduced case is a throwing fully committed single insert, a queued overwrite, and a successful fused clear+batch insertion. Its first checked divergence is persistence at continuation step 2.
- `partial-batch-reduced.json` is a manually authored proper partial-batch variant with a single continuation step. Concrete replay fails at that successful fused clear with `fault0(payload: 3)` remaining. Copies under `PropertyTesting/Corpus` replay the same scenario as passing direct and reopen controls; the final 20-case run verified both corpus replays (`corpus-controls.log`).
- The independent standalone regression fails for both fused replacement overloads in persisted bytes and reopened contents, while current memory contains the replacement as expected (`standalone.log`).
- Sensitivity calibration deliberately drops successful continuation insertions in the test interpreter, preserving the reference model. The passing direct control then fails and shrinks on `partial.successful.memory`; disabling the opt-in calibration restores the passing behavior (`calibration.json`, `calibration.log`). No production mutation was made.

Validation uses the documented Swift 6.2.4 toolchain. No full repository suite was run for this investigation.

## Run

Use `DEVELOPER_DIR` and `BOUTIQUE_SWIFT` from `PROPERTY_TESTING_DISCOVERY.md` on this host.

```sh
# Default controls, 1,000 histories each; known defects remain skipped.
Scripts/property-tests.sh --filter StorePartialFailure

# Minimal standalone regression: expected to fail for both overloads.
BOUTIQUE_PARTIAL_FAILURE_FINDINGS=1 Scripts/property-tests.sh \
  --filter StorePartialFailureClearReproductionTests/successfulFusedClearRemovesPartiallyCommittedRecord

# Fresh generated search: expected to fail on the first detected counterexample.
BOUTIQUE_PARTIAL_FAILURE_FINDINGS=1 Scripts/property-tests.sh \
  --filter StorePartialFailureHistoryTests/fusedClearContinuationSearch

# Concrete proper-partial-batch replay: expected to fail, no RNG needed.
BOUTIQUE_PARTIAL_FAILURE_FINDINGS=1 \
BOUTIQUE_PROPERTY_REPLAY=Investigation/PartialFailure/partial-batch-reduced.json \
  Scripts/property-tests.sh --filter StorePartialFailureHistoryTests/fusedClearContinuationSearch

# Sensitivity calibration: expected to fail; direct-control corpus is bypassed.
BOUTIQUE_PARTIAL_FAILURE_CALIBRATE_DROP_INSERT=1 \
BOUTIQUE_PROPERTY_CORPUS=/tmp/boutique-no-partial-corpus \
BOUTIQUE_PROPERTY_ARTIFACTS=/tmp/boutique-partial-calibration \
  Scripts/property-tests.sh --filter StorePartialFailureHistoryTests/directClearContinuationControls
```

## Remaining limits

The fault backend models deterministic committed prefixes, not every real backend failure mode or actual disk/SQLite fault injection. Histories have one injected failure; repeated failures, encoding failures, shared Store instances, event ordering after errors, cancellation, reference-valued aliasing, arbitrary failed-chain retry, and concurrent linearizability remain outside this check. Random search stops at its first invariant failure; the passed controls do not prove every successful continuation or the absence of other clusters. Memory adoption only handles versions authored by these scenarios and intentionally cannot establish the failed-call memory contract.
