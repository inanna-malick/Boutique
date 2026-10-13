# Canonically equivalent Store identifiers disagree across memory and persistence

Confirmed against Boutique discovery production code at `59b1a0461622b2dadb6c31a6d781d6842e6a9754` using Swift 6.2.4, Bodega 2.1.3, and the accompanying investigative tests.

Swift compares canonically equivalent Strings equally. Store's ordered in-memory identifier map therefore treats `"é"` and `"e\u{301}"` as one identifier. Both real Disk and SQLite engines retain separate physical records for the two spellings.

Minimal overwrite history: insert `(id: "é", payload: 0)`, then insert `(id: "e\u{301}", payload: 1)`. Memory contains one item with payload 1; persistence contains two records with payloads 0 and 1. Alternate-spelling removal similarly empties memory while leaving the first persisted item behind. These are observed memory/persistence disagreements; no claim is made that Bodega's byte-oriented key behavior alone violates its own contract.

The grammar generates four equivalence families (acute e, ring a, Hangul syllable, tilde n), prefixes/suffixes, unequal payloads, and single/batch insert/remove histories. Composed PropertyBased generators shrink all operands and histories. Both backends reduced to the overwrite history above. Multiplicity is checked before reopening or mutating a reopened Store, avoiding a potential duplicate-identifier precondition failure; that crash has not been executed or claimed as a reproduced result.

- `DiskFailure.json` and `SQLiteFailure.json` retain original and reduced scenarios.
- Native library seeds were `CeJfU4unBbk6XpXeUvC780I9pN70wJ6ZD1PcuZfiuMI=` (Disk) and `M3lt2o9wJJH08xxZYjVdO2uErheItMXvKPoqg9anDlA=` (SQLite).
- All 32 deterministic combinations (4 equivalence families × 4 entrypoints × 2 backends) fail `identity.persisted-multiplicity`.
- Exact-representation controls pass 100 generated histories per backend.

Commands (set `BOUTIQUE_SWIFT`/`DEVELOPER_DIR` for the discovery toolchain as documented):

```sh
Scripts/property-tests.sh --filter StoreIdentityDiscoveryTests
BOUTIQUE_STORE_IDENTITY_SEARCH=1 Scripts/property-tests.sh --filter equivalentRepresentation.*Histories
BOUTIQUE_STORE_IDENTITY_WITNESSES=1 Scripts/property-tests.sh --filter equivalentRepresentationWitnesses
```

The generated failing search and deterministic witnesses are opt-in. Controls remain enabled. No production repair is included; a repair needs one consistent identifier equivalence policy across writes, removals, reloads, and existing persisted data.

Replay a preserved concrete failure independently of generation or library seeds:

```sh
BOUTIQUE_STORE_IDENTITY_SEARCH=1 BOUTIQUE_PROPERTY_REPLAY=Investigation/Identity/DiskFailure.json Scripts/property-tests.sh --filter equivalentRepresentationDiskHistories
BOUTIQUE_STORE_IDENTITY_SEARCH=1 BOUTIQUE_PROPERTY_REPLAY=Investigation/Identity/SQLiteFailure.json Scripts/property-tests.sh --filter equivalentRepresentationSQLiteHistories
```

Each replay intentionally exits unsuccessfully at `identity.persisted-multiplicity` until repaired. Separate backend test entry points prevent an unrelated suite/schema mismatch during replay.
