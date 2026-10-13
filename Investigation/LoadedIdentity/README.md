# Loaded identities: bounded controls and a migration contract question

No new supported correctness bug was confirmed. Store.swift lines 44–50 describe a stable, unique cache identifier. Holding one ASCII identity keypath fixed, generated histories containing ordinary insert, remove, reconstruction, and mutation after reconstruction passed against Disk and SQLite. Each backend completed 100 histories: Disk executed 1,846 steps and SQLite 2,237 steps. Each step checks an independent ordered Array memory model, independently decoded persisted values and identity multiplicity, then reconstructs and checks values again. Reload order is unspecified; only the observed ordering is adopted while retaining model-owned values. These bounded controls do not prove all valid histories safe.

There is a concrete contract-dependent migration sequence using individually stable and unique keypaths:

1. Construct with `\.id`; insert `(id: old-0, alternate: new-0, payload: 0)`.
2. Reconstruct the same storage with `\.alternate` and overwrite that item with payload 1.
3. Reconstruct with `\.alternate` again.

The first reconstruction has one unique loaded identity. Overwrite writes under physical key `new-0`, leaving the prior physical `old-0` record. The second reconstruction loads two items with identical decoded `alternate` identities. Both Disk and SQLite exhibit this multiplicity. Removing the item empties memory but leaves the old physical record, which can reappear on reconstruction. These are assertions of observed characterization, not claims about a promised migration policy.

An isolated Disk follow-up inserting a distinct ordinary item traps at `OrderedDictionary(uniqueKeys:values:)` with `Precondition failed: Duplicate keys`. The child exited 1; `Isolated/child.log` retains the diagnostic (no stack was printed). Store.swift lines 367 and 402 construct the unique-key dictionary from loaded items. The child stops at the first Disk case, so the SQLite fatal path was not independently executed. Nonfatal duplicate-load and removal characterizations did execute on both backends. The shell parent copies the concrete input into original/reduced artifacts before launching the child; those files survive a fatal assertion. The input is hand-authored and minimal for this characterization, not an automatically shrunk generated failure or an input consumed by the shared replay adapter.

Whether changing the keypath on existing persistence is supported is undocumented. Both keypaths are stable within each item, but the persistence identity policy changes between instances. Do not count this as a new valid-history defect without a migration contract. A repair would need decisions about old physical keys and migration, so no production patch is included.

Other suspected triggers have the same contract boundary: arbitrary physical-key/decoded-identity mismatches require direct backing-store writes or a custom adapter; schema/codec changes that collapse IDs violate decoded uniqueness or stable identity unless an explicit migration policy allows them. No arbitrary duplicate injection is presented as a valid Store history. The canonical Unicode overwrite history already retained in Investigation/Identity is a separate valid source of duplicate loads and is a consequence of PR #85, not a fourth defect family. It was not reclassified or newly counted here.

Validation used revision `ced150e` plus this test-only change, Swift 6.2.4, and Bodega 2.1.3. No shared runner or production source changed. Exact commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export BOUTIQUE_SWIFT=/private/tmp/boutique-swift-6.2.4-expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift
Scripts/property-tests.sh --jobs 2 --filter LoadedIdentityDiscoveryTests
BOUTIQUE_LOADED_IDENTITY_MIGRATION=1 Scripts/property-tests.sh --jobs 2 --filter LoadedIdentityDiscoveryTests/migrationCharacterization
BOUTIQUE_LOADED_IDENTITY_ARTIFACTS=Investigation/LoadedIdentity/Isolated Investigation/LoadedIdentity/run-isolated-trap.sh
```

The first command passes with migration disabled; the second passes assertions describing current behavior. The third intentionally fails in a separate child test process. Do not enable the trap flag in a generator or a full test run. `controls.log`, `migration.log`, and `Isolated/` retain the observed evidence. Fatal termination bypasses the Swift fixture's deferred temporary-directory cleanup; fixtures use fresh UUID names under the system temporary directory and do not touch user persistence.
