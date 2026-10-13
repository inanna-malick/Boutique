# Confirmed: preview loading discards supplied fixtures

On unchanged production at `ced150e9`, each original overload returns the supplied nonempty fixture Array immediately, then replaces it with `[]` when its ordinary asynchronous storage load completes. The standalone witness confirms keypath, Identifiable String, and Identifiable UUID paths. This is one new correctness defect, separate from concurrent mutation races: construction and one explicit loading wait suffice, with no user mutation or competing Store.

The API documentation promises preview items held only in memory. The invariant here is preservation of supplied preview fixtures across read-only lifecycle operations. It does not assume persistence ordering, automatic cross-Store refresh, or observation invalidation counts.

## Generated histories and independent oracle

`Tests/BoutiqueTests/StorePreviewLifecycleDiscoveryTests.swift` generates 1–12 independently authored fixtures, arbitrary integer payloads, and 0–12 read-only operations (`inspect`, `yield`, `awaitLoaded`). Every history ends with a required `awaitLoaded`, so arbitrary prefix shrinking cannot remove the triggering lifecycle boundary. The independent Array model retains the supplied identities, payloads, and order; read-only operations leave it unchanged. Fixtures have distinct deterministic String or UUID identities. Each task is drained before its attempt exits, including failing attempts.

All three immediate-construction controls completed 1,000 cases each in `owned-controls.log`. They assert before suspension, then drain loading without checking the known failure. These are 3,000 construction controls, not 3,000 passing full lifecycle histories. The opt-in searches stop at their first failure and executed **zero successful histories**, with 15, 4, and 12 total attempts including shrinking for keypath, String, and UUID respectively. `owned-findings.log` retains native seeds and original/reduced inputs; three versioned JSON artifacts retain the independent concrete scenarios.

Each generated failure reduced to `payloads: [0], commands: []`, interpreted as construction with one item followed by the required loading wait. All report `preview.loaded-fixtures` at step 1, observed `[]`. `replay-keypath.log` independently replays the concrete keypath JSON and fails that exact invariant. `standalone.log` shows all three deterministic overload witnesses failing after loading; their immediate assertions pass. The standalone test uses only Foundation, Testing, and Boutique, without PropertyBased or shared discovery helpers.

## Guarded host experiment

Prior attempts stopped before any preview call because Foundation ignored subprocess `TMPDIR`; `foundation-isolation.log`, `isolation-check.log`, and diagnostic `run.sh` retain that history. This was an isolation-method failure, not a fundamental blocker.

Before the new experiment, the actual Foundation path `/var/folders/7h/_kjv3v7x1p1dk9p_n_jrmgw00000gn/T/Previews` was inspected and absent. `run-owned.sh` queries Foundation in a subprocess and exclusively creates that directory with `mkdir` without `-p`. Any existing directory, file, or symlink causes an immediate stop before a Boutique preview call. Tests verify the actual path and randomly generated ownership marker before construction. Cleanup occurs after the test process exits and accepts only the marker and known SQLite filenames, refusing changed ownership, unexpected artifacts, and symlinks. It does not remove preexisting data or recursively remove directories. This is bounded exclusive ownership, not an OS sandbox against unrelated concurrent applications.

The original production preview constructor creates `data.sqlite3`; every run logs that artifact, then cleans it and the marker. This supports the same ordinary-persistence initialization mechanism and contradicts the source comment “No files are written to disk”; it is not counted as another bug. The generated operations do not insert, remove, or otherwise persist fixture records. No production source, host configuration, or interposition was changed.

## Reproduce

On a supported compiler, the runner defaults to `swift`. On this host set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `BOUTIQUE_SWIFT` to the documented Swift 6.2.4 executable before these commands.

```sh
# 3,000 immediate construction controls pass; loaded findings skip.
Investigation/PreviewLifecycle/run-owned.sh

# Intentionally failing generated searches and deterministic witnesses.
BOUTIQUE_PREVIEW_FINDINGS=1 Investigation/PreviewLifecycle/run-owned.sh

# Standalone deterministic test only: three expected fixture-loss failures.
BOUTIQUE_PREVIEW_FINDINGS=1 \
BOUTIQUE_PREVIEW_TEST_FILTER=StorePreviewLifecycleReproductionTests \
  Investigation/PreviewLifecycle/run-owned.sh

# One concrete replay, independent of random generation.
BOUTIQUE_PREVIEW_FINDINGS=1 BOUTIQUE_PREVIEW_OVERLOAD=keypath \
BOUTIQUE_PREVIEW_TEST_FILTER=StorePreviewLifecycleDiscoveryTests/loadedFixturesSearch \
BOUTIQUE_PROPERTY_REPLAY=Investigation/PreviewLifecycle/preview-loaded-keypath.json \
  Investigation/PreviewLifecycle/run-owned.sh
```

The default test run skips both preview suites unless ownership setup is explicitly supplied. The runner directly calls `swift test` and has no `Scripts/property-tests.sh` dependency: a focused upstream reproduction needs only the standalone test in `Tests/BoutiqueTests` and this runner at `Investigation/PreviewLifecycle/run-owned.sh`. Set the standalone filter as above. The runner refuses existing preview data; if the guard stops, use a clean host/account rather than deleting that data.

## Repair proposal and limits

The keypath preview implementation initializes an ordinary Store (which starts its lazy loading task), then assigns fixtures. The eventual task replaces `items` with decoded storage values. String and UUID overloads delegate to this path. A minimal semantic repair should provide an initially loaded preview path backed by genuine in-memory storage, avoiding ordinary persistence loading over the supplied items. Merely assigning fixtures later, canceling an unstructured task, or persisting fixtures into the shared database introduces lifecycle or cross-preview behavior that needs design review.

This lane includes failing repros only. No production fix, public PR, or push was made. Nonempty fresh-directory fixture preservation is confirmed; shared persisted preview contamination, mutations within previews, equal-value observation notifications, and the repair design remain outside these assertions.
