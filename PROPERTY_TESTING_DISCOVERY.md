# Property-testing discovery

This branch holds broad investigative tests and independent reference models for Boutique. These tests increase confidence across bounded and generated input spaces; they do not constitute a formal proof of correctness. Any confirmed defect should be reduced to a focused deterministic regression test and fix on its own branch.

## Running and reproducing

Run the discovery suite with:

```sh
swift test
```

The generated tests use fixed SplitMix64 seeds. A failed expectation prints its seed and, for Store histories, the full operation prefix. Re-run the named test unchanged to reproduce the same trace. The bounded Store and Keychain retry checks enumerate their complete declared finite spaces.

Store traces use an explicit command AST: `insertOne`, `insertMany`, `removeOne`, `removeMany`, and `removeAll`. The generator keeps IDs in a small domain and chooses many operands from the independent model's current contents, while also producing absent IDs, stale payloads, duplicates inside batches, and fresh IDs when available. That makes overwrites and successful removals common in short traces. Operation-chain histories are first generated against a shadow model, then queued on the real Store and replayed only after `run()`. Collection-wrapper generators similarly bias replacement and dictionary updates toward current model keys while retaining misses and duplicate elements.

Other finite sweeps exhaust every length-four history over a seven-command Store alphabet (2,401 traces), every length-three history over the 9-command subject alphabet at each subscription point, and every three-status Keychain retry trace for both starting operations (128 traces). These bounded suites complement the longer seeded histories; they do not cover unbounded traces.

The suite builds with the repository's current Xcode 16.2 / Swift 6.0.3 toolchain. On 2026-10-12, `swift test` passed all 103 tests, including the generated discovery suites. Dependency resolution now works in this environment.

## Framework choice

Boutique's existing test target uses Swift Testing and needs async, actor-isolated model tests. The current discovery suite uses deterministic in-repository generators and bounded enumeration so it adds no dependency or toolchain floor. Its main limitation is the lack of automatic shrinking; failure output therefore records seeds and traces for manual reduction.

SwiftQC is the best candidate for a later smoke-tested integration because it offers seeded async properties and stateful command sequences with shrinking. Before adding it, verify that its Swift Testing package dependency can coexist with the toolchain-provided `Testing` module and that its concurrency constraints accept Boutique's `@MainActor` APIs. SwiftQC requires Swift tools 6.0 while Boutique currently declares tools 5.10. PropertyBased offers a close Swift Testing integration but currently requires Swift 6.2/Xcode 26 (with limited Swift 6.1 support). SwiftCheck is the mature option for synchronous properties and custom generators/shrinkers; its documented `forAll` closures return `Testable` values and fit pure helpers better than Boutique's async Store traces. These options do randomized search, not proof.

- [SwiftQC](https://github.com/Aristide021/SwiftQC)
- [PropertyBased](https://github.com/x-sheep/swift-property-based)
- [SwiftCheck](https://github.com/typelift/SwiftCheck)
- [Swift Testing asynchronous code](https://docs.swift.org/latest/documentation/testing/testing-asynchronous-code/)

## Coverage map

| Area | Independent oracle and current discovery coverage | Follow-up leads |
| --- | --- | --- |
| `Store` contents and persistence | Ordered `Array` model; explicit operation AST; model-aware operand generation for existing, absent, fresh, and stale IDs; single/batch insert and remove, clear, reload, event payloads, batch-vs-single metamorphism, deferred operation chains, 2,401 exhaustive four-step histories, malformed persisted-data load failures and recovery. Found a fused-removal cache-key mismatch that left stale persisted values; a deterministic empty-batch-after-clear regression now passes with the fix. | Load/mutation overlap; compare operation events around fused chains; extend generated fault schedules across bulk operations |
| `StoredValue` | Plain array/dictionary models; model-aware append/toggle/replace/set/reset/update histories; reopen checks; default/valid/malformed/wrong-shape initialization; nested optional dictionaries; integer boundaries; boxed Codable round trips; cache reads and replacements | Throwing encoders and documented failure behavior; observation event policy |
| `SecurelyStoredValue` | Generated set/remove/reopen and collection-helper histories against optional-value, array, and dictionary models; generated `refreshValue` success/nil/error traces; key-path and Binding laws; observation invalidation; all 128 three-status Keychain retry traces across both initial operations | Actual Keychain-backed runs need unique service/key isolation and Apple-host execution; clarify cross-wrapper cache visibility and initial read-failure behavior |
| `AsyncValueSubject` and streams | Generated and bounded exhaustive serialized `send`, direct assignment, and `inout` mutation traces; replay at every subscription point; multiple subscribers; bounded buffering | Check cancellation/termination cleanup and wrapper-level stream traces; concurrent send ordering is not asserted without a documented contract |
| Bindings and key paths | Generated `StoredValue` and secure-wrapper field setters preserve untouched fields; Binding get/set round trips; secure Binding's documented error suppression | Add nested key paths and reference-valued fields if their mutation semantics are intended to be supported |
| Observation and `Stored` projection | Generated Store-to-`@Stored` projection equivalence; fresh observation trackers verify invalidation after Store, StoredValue, and secure-wrapper mutations | Clarify whether equal-value writes should invalidate; test observation over batched Store chains after the contract is established |
| Serialization helpers | Generated boxed value round trips and invalid initial data fallback; malformed Store payload coverage | Add recursive nested Codable shapes and independent semantic checks for any normalization |

## Contract notes

Keep uncertain behavior separate from assertions. In particular, current docs do not clearly define whether equal-value writes count as stream changes, whether writes through a second wrapper refresh an existing `StoredValue` cache, or how initial Keychain read failures should be exposed. Generated tests should first record and investigate these behaviors rather than silently turning observations into promised contracts.
