# Unresolved lead: preview fixtures after asynchronous loading

**No defect was confirmed in a running preview Store.** Safe isolation failed before any preview API call, so this investigation stopped. The candidate harnesses are retained here outside the default test target. Prevented attempts are not passing tests, generated histories, or coverage evidence. No production file was changed, and the shared `Previews` directory was neither opened through the API, written, nor cleaned up.

## Source evidence

At the tested base revision `b7afaed`, `Sources/Boutique/Store.swift` has this sequence:

- Lines 100–107: synchronous initialization starts the lazy `loadStoreTask`.
- Lines 278–289: that task awaits storage reads, assigns decoded values to `items`, then sends `.loaded`.
- Lines 305–313: `previewStore(items:cacheIdentifier:)` initializes an ordinary Store with `SQLiteStorageEngine(directory: .temporary(appendingPath: "Previews"))`, then assigns supplied `items`.
- Lines 329–347: Identifiable String and UUID overloads delegate to that keypath path.

This suggests the later load task can replace supplied preview fixtures with backing-store contents. It is an inference from source, not a demonstrated fixture-loss counterexample. The API documentation promises supplied preview items and says it only holds items in memory. Bodega 2.1.3's SQLite initializer creates the directory and schema, so merely constructing the API can write to its chosen directory. The inline “No files are written to disk” comment is not an adequate isolation guarantee.

## Isolation failure

Candidate tests require `BOUTIQUE_PREVIEW_TEMP_ROOT` and verify `URL.temporaryDirectory` exactly equals the uniquely owned subprocess root before calling `previewStore`. The default target no longer contains these candidates. No environment mutation is attempted inside a test.

A fresh subprocess with `TMPDIR` set to `/private/tmp/BoutiquePreviewInvestigation.*` still resolves `URL.temporaryDirectory` and `NSTemporaryDirectory()` to the host's ordinary `/var/folders/7h/_kjv3v7x1p1dk9p_n_jrmgw00000gn/T` directory. `isolation-check.log` retains the exact guard failures. `foundation-isolation.log` proves the same behavior using a plain `swift -e` process, outside SwiftPM: the environment contains the isolated TMPDIR, while both Foundation APIs return the host directory. Thus this is not solely SwiftPM environment sanitization. Direct execution of the built `.xctest` bundle's Mach-O image failed with `exec format error`; it is a bundle rather than a standalone executable.

`run.sh` is now **diagnostic only**. It creates one uniquely owned root, launches a Foundation-only subprocess, prints these paths, then deletes only that root. It never calls Boutique or opens a Preview database:

```sh
Investigation/PreviewLifecycle/run.sh
```

No invasive interposition, global-state cleanup, production change, or shared-directory access is retained or required. The diagnostic uses this host's documented Swift 6.2.4 toolchain and Xcode SDK; other hosts should substitute their supported compiler.

## Candidate harnesses and next step

`StorePreviewLifecycleDiscoveryTests.swift` contains a proposed independent fixture Array oracle, generated nonempty value-type fixture arrays with distinct String identities and arbitrary integer payloads, immediate-construction checks, then one to three explicit `itemsHaveLoaded()` waits. Keypath and Identifiable String overloads have separate property names and a dedicated concrete keypath replay entrypoint. The intended immediate-control budget is 1,000 per overload; the intended finding budget is 100 per overload with first-failure shrinking. **Neither campaign ran past isolation.** Observation notification counts are characterization only; equal-value invalidation is unspecified.

`StorePreviewLifecycleReproductionTests.swift` is a minimal candidate without PropertyBased or shared discovery helpers. It covers keypath, Identifiable String, and Identifiable UUID overloads. All API calls remain behind the same isolation guard. These candidates compiled successfully before being moved outside the default target, but have not demonstrated their proposed invariant against a running preview instance.

A future investigator needs a supported isolated process environment in which Foundation's temporary directory points to an owned location, or an explicit authorized way to exercise the existing preview directory. Do not bypass the guard just to obtain a failure. If fixture loss is confirmed, a likely repair is a genuine in-memory preview initialization path that never starts ordinary persistence loading; this remains a proposal. No preview PR is warranted from the present evidence.
