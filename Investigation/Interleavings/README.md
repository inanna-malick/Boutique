# Same-ID and element-level overlap investigation

These are additional witnesses for PR #86's competing-mutation race, not an
independently established production defect. This branch changes test machinery
and retains reproductions; it contains no production fix.

`StoreDiscoveryInterleavingTests` adds a Codable initial-state / two-operation /
schedule AST. PropertyBased owns generation, shrinking, and replay through
`DiscoveryProperty`. Operations include single/batch insert, single/batch remove,
clear, fused clear/insert, and fused selective-remove/insert. Generated payloads
are unequal, and key sets can be equal, partially overlapping, or disjoint.

The instrumented storage actor pauses before or after individual committed
elements. Task-local owner labels and independently JSON-decoded actual write
bytes identify each commit. An independent Array checks every accepted operation's
expected writes after deduplication, explicit clears, and removal multiplicity;
actual commits supply order only. Loaded order is unspecified, so completeness
uses a multiset and final state comparisons use sorted complete values. Removal
keys are mapped against model-owned ASCII identities using CacheKey; Unicode
identity behavior is outside this suite.

Every gate acknowledgement and completion wait has a deadline. A requested
schedule that a serializing implementation cannot reach is counted as infeasible,
then all gates are released and tasks joined. Timeouts do not decide correctness:
the actual commit ledger drives final memory, independent persisted-byte decoding,
and reopened-store comparisons. A default control deliberately makes the second
operation wait for the first, validating this fallback and its accounting. All
normal and error-path task joins occur after releasing test-owned gates.

## Confirmed witnesses and repair constraint

The same-ID reduced counterexample starts with `key-0=0`:

1. A commits `key-0=1`, then pauses before returning from storage.
2. B commits `key-0=2` and publishes its memory.
3. A returns and publishes `key-0=1`.

Both operations' accepted writes are complete. Persistence and reopening contain
`2`, while live memory contains `1`. The extracted standalone witness also starts
from an empty store, showing that initial state is unnecessary.

The reduced equal-keyset batch counterexample commits in this actual order:
`A(key-0=1), B(key-0=2), B(key-1=2), A(key-1=1)`. Persistence and reopening contain
`{key-0:2, key-1:1}`, while memory contains `{key-0:1, key-1:1}`. No atomic-batch
promise is assumed: the ledger explicitly models the mixed committed result.

The first checked divergence is after both operations finish, at the memory
comparison. JSON `failure.step` counts committed elements, not operation indices.
Completeness, persisted-byte, duplicate-identity, and reopen assertions pass before
that failure. Logs retain the full commit trace and the library's native replay
seed; JSON retains original and reduced concrete scenarios.

The root cause remains Store's reentrancy across persistence awaits: insertion
constructs a memory replacement before awaiting storage and publishes it after
the await. After-commit gates additionally separate backend commit order from
Store return/publication order. A repair that merely rebuilds from the latest
`self.items` after `await` is insufficient: in the same-ID witness A would still
replace B's newer committed payload with A's older payload. A repair needs a
consistent policy for persistence and memory ordering; this investigation does
not choose or implement that policy.

Eight extracted witnesses cover same-ID overwrite, equal/overlapping/disjoint
multi-item batches, insert/remove, insert/clear, and both fused removals. All eight
reach the requested schedule and fail only the final memory assertion. Five
actually interleave committed owner segments (`A,B,A`); these counters are printed
in `witnesses.log`. These outcomes extend the existing race evidence rather than
justify separate production PRs.

## Run

Use the toolchain setup documented in `PROPERTY_TESTING_DISCOVERY.md`. Defaults
run 1,000 serialized histories and 1,000 same-ID concurrent controls gated before
commit. Known-fault searches and witnesses are opt-in.

```sh
Scripts/property-tests.sh --filter StoreDiscoveryInterleavingTests

BOUTIQUE_STORE_ELEMENT_SEARCH=1 Scripts/property-tests.sh \
  --filter StoreDiscoveryInterleavingTests/sameIdentityCommitReturnSearch
BOUTIQUE_STORE_ELEMENT_SEARCH=1 Scripts/property-tests.sh \
  --filter StoreDiscoveryInterleavingTests/interleavedBatchSearch

BOUTIQUE_STORE_ELEMENT_SEARCH=1 \
BOUTIQUE_PROPERTY_REPLAY=Investigation/Interleavings/same-id-commit-return.json \
  Scripts/property-tests.sh --filter StoreDiscoveryInterleavingTests/sameIdentityCommitReturnSearch
BOUTIQUE_STORE_ELEMENT_SEARCH=1 \
BOUTIQUE_PROPERTY_REPLAY=Investigation/Interleavings/interleaved-batches.json \
  Scripts/property-tests.sh --filter StoreDiscoveryInterleavingTests/interleavedBatchSearch

BOUTIQUE_STORE_ELEMENT_WITNESSES=1 Scripts/property-tests.sh \
  --filter StoreDiscoveryInterleavingTests/extractedElementWitness
```

The opt-in commands fail intentionally on the current implementation. A separate
broad generated search, `generatedElementInterleavings`, uses the same flag and
explores arbitrary allowed operation pairs and both release orders; targeted
searches prevent shrinking everything back to a simpler distinct-ID witness.

## Limits

Final default verification passed 2,000 generated histories and the infeasible
schedule control in 0.713 seconds on Swift 6.2.4. It executed 6,772 commits and
2,993 actual same-ID unequal-payload overwrites. Serialized controls reached 495
disjoint, 267 equal, and 238 partially overlapping operand sets, with every
operation family represented. The eight extracted failing witnesses executed
29 commits and 15 unequal-payload overwrites, including five actual element
interleavings. Both retained concrete JSON replays reproduced their final-memory
failure. `controls.log`, search/replay logs, and `witnesses.log` retain this evidence.

Two tasks, one suspension per owner, one Store, and the instrumented backend are
covered. The default atomic same-ID controls gate before commit; they do not prove
real-backend serialization. The generated initial state has 1–4 ASCII identities,
batches have 1–3 unique operands, and targeted interleaved batches have 2–3.
Empty/duplicate batches, loads, faults, more tasks, more gates per task, cross-Store
writers, and concurrent event ordering remain outside this harness. Existing
suites cover several of those sequential or distinct-race families. Known-fault
random searches stop at the first failure and then shrink; their requested 1,000
case budget is not a claim that 1,000 failing interactions were explored.
