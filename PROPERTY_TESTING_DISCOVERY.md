# Property-testing discovery

This branch contains investigative property tests, independent models, and replayable findings. These are randomized and bounded exhaustive checks, not a formal proof. Production fixes and their small deterministic regressions belong in separate PRs; PR #84 remains independent of this expansion.

## Framework and toolchain

The discovery test target now depends on **PropertyBased 2.0.1**, pinned in Package.swift and Package.resolved. The library owns composable generation, automatic shrinking, failure detection, and seed replay. Boutique-specific reference models, operation interpreters, fixture isolation, and concrete JSON artifacts are test code in this repository. Swift 5 language mode is preserved; the discovery manifest requires Swift tools 6.2.

Xcode 26 is the straightforward supported development setup. This host has Xcode 16.2/macOS 15.1, so validation uses an isolated, signature-verified Swift.org 6.2.4 toolchain with the installed macOS 15.2 SDK. No global Xcode selection or OS setting was changed. The compiler executable used here is:

```
/private/tmp/boutique-swift-6.2.4-expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift
```

That temporary path is local setup, not a portable requirement. On an Xcode 26 host, use the normal `swift` executable. With an alternate toolchain, set `BOUTIQUE_SWIFT` to its executable and `DEVELOPER_DIR` to the intended Xcode's Developer directory.

## Run and reproduce

```sh
# Thorough default, including the original tests and new property suites.
Scripts/property-tests.sh

# New property suites only.
Scripts/property-tests.sh --filter Discovery

# Short development run; this is not the acceptance budget.
BOUTIQUE_PROPERTY_CASES=20 BOUTIQUE_BACKEND_CASES=5 BOUTIQUE_PROPERTY_STEPS=20 \
  Scripts/property-tests.sh --filter Discovery

# Extend searches with fresh library-generated seeds.
BOUTIQUE_PROPERTY_CASES=10000 BOUTIQUE_BACKEND_CASES=1000 \
  Scripts/property-tests.sh --filter Discovery

# Replay a concrete failure independently of the generator.
BOUTIQUE_PROPERTY_REPLAY=.build/property-artifacts/wrapper-records.json \
  Scripts/property-tests.sh --filter WrapperDiscoveryTests/recordHistories
```

Default budgets are 1,000 cases for inexpensive model suites and 100 for backend suites. Random history lengths range up to 100 commands (40 for real-backend histories); some suites add targeted interaction suffixes. Counts are cases/histories, not individual operations. Wire-format cases are fixtures rather than histories. Actual executed operations and interactions are printed as `PROPERTY` counters.

`DiscoveryProperty` records versioned JSON with suite, tested revision (including a dirty marker), original scenario, reduced scenario, invariant, and first-divergence step. Failure files go to `.build/property-artifacts`, configurable with `BOUTIQUE_PROPERTY_ARTIFACTS`. Each suite has its own filename; independent processes sharing an output directory should use separate artifact directories. Library seeds are printed in the native failure log, so retain that log alongside the JSON.

PropertyBased's `.fixedSeed` is a debugging trait: it deliberately reports an issue even when the repaired case passes. Do not commit it as a passing regression. Use the printed seed for temporary reproduction, then retain the concrete scenario. Passing corpus artifacts in `PropertyTesting/Corpus/<suite>.json` replay before fresh generation. Known failing investigations are stored separately and run explicitly.

The shared adapter preserves the first `DiscoveryFailure.invariant` while shrinking. Expected checks in property bodies must use `discoveryRequire`, not direct `#expect` calls that bypass this filtering. Never label unrelated mechanisms with the same invariant. Constructed interaction suffixes survive shrinking: these reduce the generated prefix and operands, not necessarily the globally shortest concrete history. Save and manually reduce confirmed defects for focused regression tests.

## Library acceptance and calibration

The async `@MainActor` acceptance suite exercises a real Disk Store with a fresh directory on every attempt. A deliberate adapter mutation that ignores overwrites failed, reduced a 13-operation history to `put(2, 0); put(2, 1)`, and reproduced identical original/reduced traces with the library seed. All 51 generation/shrink fixtures were removed. Concrete replay failed with the mutation and passed with it disabled. Cancellation and subscriber cleanup also passed.

Evidence is retained in `PropertyTesting/Acceptance`. To repeat the negative check:

```sh
BOUTIQUE_ACCEPTANCE_IGNORE_OVERWRITE=1 \
BOUTIQUE_ACCEPTANCE_ARTIFACT=/tmp/boutique-acceptance.json \
  Scripts/property-tests.sh --filter PropertyLibraryAcceptanceTests/asyncStoreHistoriesShrinkAndReplay

BOUTIQUE_ACCEPTANCE_REPLAY=PropertyTesting/Acceptance/overwrite-reduced.json \
  Scripts/property-tests.sh --filter PropertyLibraryAcceptanceTests/asyncStoreHistoriesShrinkAndReplay
```

The first command must fail; the second must pass. Additional calibrations temporarily restored PR #84's bad key construction, omitted the StoredValue cache update, and omitted subject publication. Each mutation must be detected, reverted, and followed by a clean run. Missing stream values use bounded collection and cancellation rather than hanging on `next()`.

## Coverage map

| Mechanism | Expanded properties and observable evidence |
| --- | --- |
| Store histories | Independent ordered Array model; state-aware operands; direct and arbitrary queued operations; clear/selective removal fusion; duplicate and empty batches; stale removal payloads; repeated chain execution; explicit reopen and delayed persistence inspection. Fresh-biased growth and overwrite/removal mixes exercise different histories. Compare memory order, persisted contents and multiplicity, and reloaded contents without assuming backend load order. |
| Operation lifecycle | Generated accepted command queues, 750 finite queue/state/run combinations, explicit overlapping run gates, a waiting-follower control, storage effect traces, deferred codecs, and opt-in post-start append/failed-run reuse characterization. See [lifecycle contract notes](Investigation/OperationLifecycle/README.md). |
| Identifier equivalence | Generated Unicode canonical-equivalence families, prefixes/suffixes, payloads, and single/batch insert/remove histories against Disk and SQLite. Exact-spelling controls pass; alternate representations expose persisted multiplicity disagreements. |
| Backend equivalence | The same successful scenario interpreter runs against the instrumented actor, Disk, and SQLite. Decode persisted bytes independently with JSONDecoder and reject duplicate identities explicitly. |
| Fault schedules | Generated operation kinds, bulk sizes, and committed-prefix failure positions. Check exact injected errors, observable persisted partial effects, reopen, continued use, and explicit reset/recovery. No invented transaction rollback guarantee. |
| Overlap schedules | Explicit gate acknowledgements and bounded cleanup replace timing luck. Generated configuration covers load/mutation overlap and competing mutations, with serialized controls. Original and reduced failing scenarios are retained separately. |
| StoredValue and bindings | Mixed full writes, binding writes, nested keypaths, reset, reconstruction, cold/warm reads, observation arming/re-arming, rejected encoding, and recovery. Independent retained models and independently decoded bytes. |
| Collections and serialization | Array helper histories include duplicates and present/missing replacement return values. Optional dictionaries distinguish missing keys, nil payloads, and removal. Independently authored nested Unicode JSON fixtures cover malformed/truncated/wrong-shape inputs and recovery. |
| Secure wrappers | Isolated real-Keychain histories include peer writes/removals, reconstruction, keypath updates on absent/present values, rejected encoding, and binding error suppression. Existing read-failure and bounded retry tests remain. |
| Streams | Independent per-subscriber queues across unbounded/oldest/newest buffering, zero/positive capacities, send/assignment/inout, consumption, cancellation, and resubscription. Wrapper histories add rejected writes and reconstruction. Sentinel checks expose extra events where buffering retains them; bounded waits expose missing events. |

The original finite sweeps remain: 2,401 four-command Store histories, 216 short queued chains, subject three-command histories at every subscription point, and 128 Keychain retry-status histories. Legacy seeded sweeps now use a shared library RNG rather than duplicated SplitMix implementations. Their seed mapping changed; historical seeds alone are not promised to reproduce pre-migration input streams.

Legacy oracle repairs remove decoding-error-to-empty-dictionary fallbacks and expected values sourced from the production getter. Legacy subject collection is bounded. Existing Keychain tests now use per-test service namespaces with cleanup, avoiding access prompts for records owned by older test executables.

## Contracts and remaining limits

- Concurrent event ordering, failed-write observation, and equal-value invalidation remain unspecified; generated assertions do not manufacture promises for them.
- Secure wrapper reads across shared keys have existing tests establishing current persisted-value visibility. StoredValue cross-wrapper cache refresh does not have that established contract.
- A backend can partially commit before throwing. The fault model verifies the chosen backend schedule, not unsupported rollback behavior.
- Reload ordering is unspecified. Verify identities/payloads first, then preserve model-owned payloads while adopting only observed ordering for subsequent ordered operations.
- Buffer-dropped events are inherently unobservable. Zero-capacity waiting-reader behavior needs explicit rendezvous tests rather than a buffered queue oracle alone.
- Reference-valued Codable aliasing and unbounded concurrent linearizability remain future work. The current stream model asserts sequential publication semantics.
- Random search stops at its first failure. Split invariant families or replay parameters to continue exploring independent mechanisms; longer runs alone cannot fix missing generator support.

## Validation and findings

The integrated run passed **130 tests in 23 suites in 64.334 seconds**, with code coverage enabled on Swift 6.2.4. It executed **9,700 new generated cases** through the shared discovery runner, plus the library acceptance cases, original seeded/exhaustive checks, calibration matrices, and two passing corpus replays. This includes wire fixtures as well as operation histories. The subsequent backend entrypoint split was checked with the focused identity controls and a failing concrete replay.

Observed behavioral counts include 19,196 Store overwrites, 8,927 removals of existing items, 1,233 Store reopens, all queued chain lengths 1–8, 4,057 empty batches, 4,366 armed observation mutations, and partial stream reads across subject, wrapper, and Store event suites. These counts demonstrate reached interactions; they do not establish exhaustive state-space coverage.

The full run executed **92.80% of production lines and 91.93% of regions**. This combines original and discovery tests; no pre-expansion percentage was measured, so it is not a coverage-delta claim. Store.swift reached 93.75% line coverage; AsyncValueSubject, StoredValue, collection helpers (except the Bool helper), and bindings reached 100%. SwiftUI view-loading helpers in Store+Observation.swift remain unexecuted. The production-source report and generated-case counters are retained in `PropertyTesting/Validation/`. Swift's report supplied no branch counts.

Generated searches confirmed three retained failure families: competing mutations lose in-memory updates, loading overlaps lose loaded/new items, and canonically equivalent Unicode IDs disagree between memory and persistence on both real backends. See [Store schedule findings](Investigation/StoreDiscoveryFindings.md) and [identity findings](Investigation/Identity/README.md) for models, reduced artifacts, and runnable opt-in commands. These known-failing searches remain explicitly runnable; their production repairs are separate work.

Mutation calibrations detected a removed cache update, omitted subject publication, and PR #84's original key-construction defect. Their deliberate production changes were reverted. This expansion changes test infrastructure and the discovery manifest, not production implementation.

## Partial-failure continuation investigation

[Partial-failure findings](Investigation/PartialFailure/README.md) adds 1,000-case direct-clear and reopen controls over generated long continuations after nine fault families. Independent memory and persistence models avoid asserting atomic rollback or failed-call memory semantics. An opt-in search and standalone regression show a successful fused clear retaining records committed by an earlier throwing insertion; reopening resurrects those records. This cluster is independent of the Unicode and overlap findings. Known-failing cases require `BOUTIQUE_PARTIAL_FAILURE_FINDINGS=1`; default controls and retained corpus replays pass.

## Three-target follow-up

All three bounded follow-ups are retained on this branch:

- [Element interleavings](Investigation/Interleavings/README.md): 1,000 serialized and 1,000 same-ID before-commit control histories; independent per-owner commit completeness and an Array replay of actual commit order. After-commit same-ID and multi-item batch searches retain additional variants of the existing mutation race. They show why merely rebuilding from current memory after an await is insufficient.
- [Partial failure continuations](Investigation/PartialFailure/README.md): 1,000 direct-clear and 1,000 reopen histories across nine fault families, plus passing concrete corpus cases. The successful fused-clear defect is a distinct cluster.
- [Operation lifecycle](Investigation/OperationLifecycle/README.md): 1,000 generated contract histories, 750 bounded exhaustive histories, and deferred-codec/waiting-follower checks. A separate opt-in 1,000-case/24-case characterization run observed post-start append and failed-run retry behavior; no established-contract violation was confirmed.

Final integration passed **150 tests in 27 suites in 83.412 seconds**, including **14,700 generated discovery cases**, original checks, finite matrices, and four passing corpus replays. The command was `Scripts/property-tests.sh --enable-code-coverage` with known-failing searches disabled. `PropertyTesting/Validation/followup-run.txt` retains case counters and the summary. A subsequent concrete same-ID replay still failed exactly `store.element.memory`, confirming the scheduling harness corrections retain sensitivity.

Integration also repaired two test assumptions: initial scheduling acknowledgements need room for a loaded MainActor executor, and a forced serial follower must await the first task without a competing deadline. The overlap itself still has an explicit bounded deadline and actual commit-order oracle. Legacy event tests now subscribe before their producers start and compare event payloads rather than classifying buffered events using later Store state. Production source is unchanged.

Focused, intentionally failing repro-only drafts are [#85 (Unicode IDs)](https://github.com/mergesort/Boutique/pull/85), [#86 (Store overlaps)](https://github.com/mergesort/Boutique/pull/86), and [#87 (fused clear after a partial write)](https://github.com/mergesort/Boutique/pull/87). Each is based on upstream main with standalone tests and no discovery dependency. Complex repairs remain design work rather than included production patches.

## Interacting histories: concurrency, codecs, and shared persistence

The next round adds separate searches so an existing memory race cannot prevent checks of persistence completeness and successful recovery:

- [Concurrent faults](Investigation/ConcurrentFaults/README.md) generates two or three owners, zero to two faults, seeded states, duplicate/empty operands, causal gate-release permutations, and arbitrary recovery tails. Independently authored complete effect prefixes are checked before ledger order drives the persisted Array model. Passing continuations use either verified reopen or successful direct clear on the original Store. Separate opt-in searches retain memory races and their composition with the fused-clear omission.
- [Codec recovery](Investigation/CodecRecovery/README.md) generates malformed raw records, corrupt read snapshots, rejecting and overwritten batch operands, repeated failures, and arbitrary original-instance continuations. Complete independent persisted-value models check continued use before reconstruction. A separate adapter control encodes before removing, proving the failed-fused oracle permits both retained and removed preexisting records. Storage reads are nonthrowing; these tests do not invent backend read-error propagation.
- [Shared Stores](Investigation/SharedStores/README.md) generates two or three independent instance histories against one persisted Array model. Instrumented storage and shared/separate Disk and SQLite engines exercise stale writers, direct clears, selective fusion, and reconstruction. Existing instances are not required to refresh automatically. Finite reachability checks complement random histories.

Shared-store search generalizes #87 without failures or concurrency: construct two empty Stores, insert through A, and successfully run fused clear-and-insert through B. Persistence retains A's item. The two-step reduced histories and paired direct/fused witnesses are retained; the standalone real-backend reproduction is also on #87. Both replacement overloads fail persistence and reload checks on Disk and SQLite, while all four direct controls pass on upstream main `3474aa1`. This is the same memory-selected clear mechanism, not a separate bug count.

New calibrations modify executed adapter behavior while leaving expected models unchanged. Each lane retains exact negative-check instructions, shrinking artifacts, native seed logs, and clean replay evidence. Failing generated searches remain opt-in; success counts before first failure must not be reported as completed search budgets. The older source-coverage percentages above describe their historical run, not this expansion.

Integrated validation at `43c677c` passed **169 tests in 31 suites in 114.846 seconds**, with **22,300 generated discovery cases**, the existing corpus checks, and finite matrices. The three new matrices add 588 concurrent schedules, 336 shared-store histories, and 67 codec scenarios. Both concurrent control lanes completed every history without a deadline-infeasible skip in this run; empty operations still receive oracle checks. `PropertyTesting/Validation/interactions-run.txt` retains counters and the full-run summary, and `interactions-source-coverage.json` freezes the production-source coverage from this run before subsequent focused replays replace the build profile. Known-failing searches and mutation flags were disabled. Each lane's README records its separate extended campaigns and precise bounds.
