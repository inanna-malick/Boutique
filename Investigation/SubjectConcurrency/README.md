# Concurrent subject publication and subscriber lifecycle

No new supported-contract violation is confirmed. These checks use internal `AsyncValueSubject` directly. Public Store and StoredValue owners are MainActor-isolated; direct concurrent subject calls do not establish a reachable public wrapper defect.

The independent oracle permits each subscriber its own permutation of overlapping publications. Unique integer events make loss and duplication observable. Generated waves contain 1–12 workers and histories contain 1–12 waves. Two subscribers drain replay, receive concurrent sends or lock-protected increments, partially consume the result, then cancel and resubscribe. A send after every worker returns is a real-time sentinel: it must follow every retained wave publication. Increment values must cover the independent arithmetic interval, and final state must equal the independently calculated sum. Concurrent sends only require final state membership, not agreement with the last published event.

A finite stress matrix uses 1, 2, 4, 8, 16, and 32 increments, 50 attempts each. Subscription and cancellation of a separate retired subscriber race with those increments. If subscription replays k, its remaining events must contain exactly k+1 through the final increment, in any order, followed by a post-join sentinel. This follows from atomic replay/registration under the same lock as updates; no expected tail is obtained from the production getter.

Task-group joins control real-time boundaries. Scheduler choices within a wave are nondeterministic: neither generated inputs nor seeds replay the exact operating-system schedule. Existing APIs provide no gate between the subject's unlock and yield; no production hook was introduced. This campaign cannot prove all interleavings, subscriber reclamation, bounded-buffer retention under overlap, or a global linearization order shared by subscribers. Concurrent publication ordering and agreement of the final getter with the last event remain unspecified. Equal-value invalidation is not asserted.

Run with the normal discovery toolchain:

```sh
Scripts/property-tests.sh --jobs 2 --filter SubjectConcurrencyDiscoveryTests
```

Default generated budget is 1,000 histories. `BOUTIQUE_PROPERTY_CASES` changes it. The shared adapter retains failing generated inputs as `subject-concurrency-waves.json`; `BOUTIQUE_PROPERTY_REPLAY` replays that input, with fresh scheduler choices. The finite matrix is deterministic in its inputs but not its task execution order.

The initial observed-copy oracle calibration is retained in `calibration-run.txt` and `Calibration` as historical harness evidence; its hook was removed after review because it does not exercise actual publication. The stronger adapter calibration, `BOUTIQUE_SUBJECT_DUPLICATE_SEND=1`, sends a duplicate value instead of the first authored value in a multi-worker send wave. Expected intervals and observed-event checks remain unchanged. It fails `subject.concurrent.membership` and shrinks an eleven-wave history to one two-worker wave, observed `[2, 2, 3]` instead of publications 1 and 2 followed by sentinel 3. `publication-calibration.txt` and `PublicationCalibration` retain native seed and concrete JSON. With the flag absent, the reduced input passes in `publication-clean-replay.txt`.

```sh
BOUTIQUE_SUBJECT_DUPLICATE_SEND=1 Scripts/property-tests.sh --jobs 2 --filter SubjectConcurrencyDiscoveryTests/publicationAndLifecycleWaves
BOUTIQUE_PROPERTY_REPLAY=Investigation/SubjectConcurrency/PublicationCalibration/subject-concurrency-waves.json Scripts/property-tests.sh --jobs 2 --filter SubjectConcurrencyDiscoveryTests/publicationAndLifecycleWaves
```

The first command intentionally fails; the second passes. This is a test adapter mutation, not a production change. `clean-run.txt` retains 1,000 passing generated histories with 6,338 waves and 41,352 workers, plus 300 subscription/cancellation races. The test models assert real-time ordering only across completed waves; no exact OS schedule replay is promised.
