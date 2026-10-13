# Property-testing discovery

This branch holds broad investigative tests and independent reference models for Boutique. These tests increase confidence across bounded and generated input spaces; they do not constitute a formal proof of correctness. Any confirmed defect should be reduced to a focused deterministic regression test and fix on its own branch.

## Running and reproducing

Run the discovery suite with:

```sh
swift test
```

The generated tests use fixed SplitMix64 seeds. A failed expectation prints its seed and, for Store histories, the full operation prefix. Re-run the named test unchanged to reproduce the same trace. The bounded Store and Keychain retry checks enumerate their complete declared finite spaces.

The local test environment currently cannot fetch the package's GitHub dependencies, so the full SwiftPM test run is blocked until dependency resolution works. Swift frontend parsing and `git diff --check` are still useful syntax and whitespace checks, but they do not replace a build or test run.

## Framework choice

Boutique's existing test target uses Swift Testing and needs async, actor-isolated model tests. The current discovery suite uses deterministic in-repository generators and bounded enumeration so it adds no dependency or toolchain floor. Its main limitation is the lack of automatic shrinking; failure output therefore records seeds and traces for manual reduction.

SwiftQC is the best candidate for a later smoke-tested integration because it offers seeded async properties and stateful command sequences with shrinking. Before adding it, verify that its Swift Testing package dependency can coexist with the toolchain-provided `Testing` module and that its concurrency constraints accept Boutique's `@MainActor` APIs. SwiftQC requires Swift tools 6.0 while Boutique currently declares tools 5.10. PropertyBased offers a closer Swift Testing integration but currently needs Swift 6.2/Xcode 26. SwiftCheck is more appropriate for synchronous pure helpers than Boutique's async Store. These options do randomized search, not proof.

- [SwiftQC](https://github.com/Aristide021/SwiftQC)
- [PropertyBased](https://github.com/x-sheep/swift-property-based)
- [SwiftCheck](https://github.com/typelift/SwiftCheck)
- [Swift Testing asynchronous code](https://docs.swift.org/latest/documentation/testing/testing-asynchronous-code/)

## Coverage map

| Area | Independent oracle and current discovery coverage | Follow-up leads |
| --- | --- | --- |
| `Store` contents and persistence | Ordered `Array` model; small ID domain; single/batch insert and remove, clear, reload, event payloads, batch-vs-single metamorphism, operation chains, 2,401 exhaustive four-step histories | Fault injection and failure recovery; load/mutation overlap; String/UUID `Identifiable` convenience initializers; compare operation events around fused chains |
| `StoredValue` | Plain array/dictionary models; generated append/toggle/replace/set/reset/update histories; reopen checks; default/valid/malformed/wrong-shape initialization; nested optional dictionaries; integer boundaries; boxed Codable round trips; cache reads and replacements | Key-path setter and binding laws; malformed/truncated data partitions; throwing encoders and documented failure behavior; observation event policy |
| `SecurelyStoredValue` | Existing deterministic tests cover CRUD, read fallback, collection helpers, observation, and selected retries; root discovery enumerates all 128 three-status retry traces across both initial operations | Generated wrapper histories and refresh-value traces are in a separate worker branch; actual Keychain runs need unique service/key isolation and Apple-host execution |
| `AsyncValueSubject` and streams | Separate worker branch models initial replay, serialized sends, `inout`, direct value assignment, multiple subscribers, and bounded buffering | Check cancellation/termination cleanup and wrapper-level stream traces; concurrent send ordering is not asserted without a documented contract |
| `Stored` projection | Thin view of `Store.items` | Metamorphic equality with the wrapped Store across generated histories; lower priority than Store itself |
| Serialization helpers | Generated boxed value round trips and invalid initial data fallback | Add recursive nested Codable shapes and independent semantic checks for any normalization |

## Contract notes

Keep uncertain behavior separate from assertions. In particular, current docs do not clearly define whether equal-value writes count as stream changes, whether writes through a second wrapper refresh an existing `StoredValue` cache, or how initial Keychain read failures should be exposed. Generated tests should first record and investigate these behaviors rather than silently turning observations into promised contracts.
