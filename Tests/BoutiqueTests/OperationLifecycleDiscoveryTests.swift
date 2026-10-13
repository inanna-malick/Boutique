import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct OperationLifecycleScenario: Codable, Sendable {
    enum Run: String, Codable, Sendable, CaseIterable { case never, serial, concurrent }
    var initial: [StoreDiscoveryItem]
    var commands: [StoreDiscoveryCommand]
    var run: Run
    var repeats: Int
}

/// The oracle owns a logical queue and an ordered Array, not executable closures.
/// Mutation after starting run and error recovery have no established contract.
@MainActor
@Suite("OperationLifecycleDiscovery", .serialized)
struct OperationLifecycleDiscoveryTests {
    private func generator() -> Generator<OperationLifecycleScenario, some Sequence> {
        let command = zip(Gen.int(in: 0...4), Gen.int(in: 0...5), Gen.int(in: -10...10), Gen.int(in: 0...3))
        return zip(command.array(of: 1...min(DiscoveryProperty.steps, 50)), Gen.int(in: 0...2), Gen.int(in: 0...3), Gen.int(in: 0...3))
            .map { draws, run, initialCount, repeats in
                let commands = draws.map { kind, id, payload, count in
                    let first = StoreDiscoveryItem(id: "id-\(id)", payload: payload)
                    let items = (0..<count).map { index in
                        StoreDiscoveryItem(id: "id-\((id + index / 2) % 6)", payload: payload + index)
                    }
                    return StoreDiscoveryCommand(kind: [.insert, .batch, .remove, .removeBatch, .clear][kind],
                        items: kind == 0 || kind == 2 ? [first] : items)
                }
                return OperationLifecycleScenario(initial: (0..<initialCount).map { .init(id: "id-\($0)", payload: 99) },
                    commands: commands, run: .allCases[run], repeats: repeats)
            }
    }

    @Test(.shrinking)
    func acceptedQueueHistories() async throws {
        try await DiscoveryProperty.check("operation-lifecycle", input: generator()) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }

    @Test func finiteQueueAndRunMatrix() async throws {
        let alphabet: [StoreDiscoveryCommand] = [
            .init(kind: .insert, items: [.init(id: "a", payload: 0)]),
            .init(kind: .insert, items: [.init(id: "a", payload: 1)]),
            .init(kind: .batch, items: []),
            .init(kind: .removeBatch, items: [.init(id: "a", payload: -1)]),
            .init(kind: .clear, items: [])
        ]
        let coverage = DiscoveryCoverage()
        for encoded in 0..<125 {
            var digits = encoded
            let commands = (0..<3).map { _ -> StoreDiscoveryCommand in
                defer { digits /= alphabet.count }
                return alphabet[digits % alphabet.count]
            }
            for run in OperationLifecycleScenario.Run.allCases {
                for initial in [[], [StoreDiscoveryItem(id: "a", payload: 2)]] {
                    try await replay(.init(initial: initial, commands: commands, run: run, repeats: 2), coverage: coverage)
                }
            }
        }
        print("PROPERTY operation-lifecycle finite histories=750; \(coverage.counts)")
    }

    @Test func waitingFollowerHarnessControl() async throws {
        let scenario = OperationLifecycleScenario(initial: [], commands: [
            .init(kind: .insert, items: [.init(id: "a", payload: 0)]),
            .init(kind: .removeBatch, items: [.init(id: "a", payload: -1)]),
            .init(kind: .batch, items: [.init(id: "b", payload: 2)])
        ], run: .concurrent, repeats: 2)
        // Adapter control deliberately holds the follower until the leader has
        // completed. The harness must allow this alternative completion policy.
        try await replay(scenario, coverage: DiscoveryCoverage(), waitingFollower: true)
    }

    private func replay(_ scenario: OperationLifecycleScenario, coverage: DiscoveryCoverage, waitingFollower: Bool = false) async throws {
        let storage = StoreDiscoveryStorage()
        let store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        try await store.insert(scenario.initial) as Void
        var model = StoreDiscoveryModel(items: scenario.initial)
        let operation = Store<StoreDiscoveryItem>.Operation(store: store)
        let baselineCalls = await storage.calls.count
        let baselineCommits = await storage.commits.count
        var queued: [StoreDiscoveryCommand] = []
        for (step, command) in scenario.commands.enumerated() {
            try await append(command, to: operation)
            queued.append(command)
            try discoveryRequire(store.items == scenario.initial, "operation.queue.memory", step: step)
            try discoveryRequire(await storage.calls.count == baselineCalls, "operation.queue.backend", step: step)
            try discoveryRequire(await storage.commits.count == baselineCommits, "operation.queue.commits", step: step)
            coverage.hit("append-\(command.kind.rawValue)")
            if command.items.isEmpty { coverage.hit("empty-operands") }
        }
        coverage.hit("initial-\(scenario.initial.count)")
        coverage.hit("run-\(scenario.run.rawValue)")
        if scenario.run == .never {
            try await checkPersistence(storage, expected: scenario.initial, step: queued.count)
            return
        }
        if scenario.run == .concurrent {
            // Every nonempty queue enters storage, including empty batch calls.
            await storage.pause("mutation")
            let completion = StoreDiscoveryCompletion()
            let task = Task { @MainActor in
                do { try await operation.run(); await completion.finish(.success(())) }
                catch { await completion.finish(.failure(error)) }
            }
            var secondTask: Task<Void, Never>?
            do {
                try await storage.waitForGate(timeout: .seconds(2))
                let secondCompletion = StoreDiscoveryCompletion()
                await withCheckedContinuation { started in
                    secondTask = Task { @MainActor in
                        started.resume()
                        do {
                            if waitingFollower { try await completion.wait(timeout: .seconds(2)) }
                            try await operation.run()
                            await secondCompletion.finish(.success(()))
                        }
                        catch { await secondCompletion.finish(.failure(error)) }
                    }
                }
                // Acknowledgement occurs synchronously before calling run on the
                // same actor. The controller resumes when the caller returns or
                // suspends; either concurrent completion policy is allowed.
                coverage.hit("concurrent-run-while-gated")
                await storage.releaseAll()
                try await completion.wait(timeout: .seconds(2))
                try await secondCompletion.wait(timeout: .seconds(2))
                await task.value
                await secondTask?.value
            } catch {
                await storage.releaseAll()
                task.cancel()
                secondTask?.cancel()
                await task.value
                await secondTask?.value
                throw error
            }
        } else { try await operation.run() }
        if scenario.run == .concurrent {
            // Metamorphic effect trace: one serial run and two overlapping runs
            // must issue the same backend effects. This also detects repeated
            // remove/clear effects whose final state would be idempotent.
            let controlStorage = StoreDiscoveryStorage()
            let control = try await Store<StoreDiscoveryItem>(storage: controlStorage, cacheIdentifier: \.id)
            try await control.insert(scenario.initial) as Void
            let controlChain = Store<StoreDiscoveryItem>.Operation(store: control)
            for command in queued { try await append(command, to: controlChain) }
            try await controlChain.run()
            let actualTrace = await storage.calls.map { "\($0.kind):\($0.keys)" }
            let controlTrace = await controlStorage.calls.map { "\($0.kind):\($0.keys)" }
            try discoveryRequire(actualTrace == controlTrace, "operation.concurrent.effects-once", step: queued.count)
        }
        queued.forEach { model.apply($0) }
        try discoveryRequire(store.items == model.items, "operation.run.accepted-sequence", step: queued.count)
        try await checkPersistence(storage, expected: model.items, step: queued.count)
        // Writes cannot be fused away. Count each physical key commit from logical
        // insert commands to expose duplicate execution even when final writes agree.
        let expectedWrites = queued.reduce(0) { count, command in
            count + ([.insert, .batch].contains(command.kind) ? Set(command.items.map(\.id)).count : 0)
        }
        let actualWrites = await storage.commits.dropFirst(baselineCommits).filter { $0.kind == "write" }.count
        try discoveryRequire(actualWrites == expectedWrites, "operation.run.insert-once", step: queued.count,
                             "expected \(expectedWrites) write effects, got \(actualWrites)")
        let finishedCalls = await storage.calls.count
        let finishedCommits = await storage.commits.count
        for repeatIndex in 0..<scenario.repeats {
            try await operation.run()
            let calls = await storage.calls.count
            let commits = await storage.commits.count
            try discoveryRequire(store.items == model.items && calls == finishedCalls && commits == finishedCommits,
                                 "operation.run.repeated-noop", step: queued.count + repeatIndex)
            coverage.hit("repeat-successful-run")
        }
        coverage.hit("logical-commands", by: queued.count)
        coverage.hit("write-effects", by: expectedWrites)
    }

    private func append(_ command: StoreDiscoveryCommand, to operation: Store<StoreDiscoveryItem>.Operation) async throws {
        switch command.kind {
        case .insert: _ = try await operation.insert(command.items[0])
        case .batch: _ = try await operation.insert(command.items)
        case .remove: _ = try await operation.remove(command.items[0])
        case .removeBatch: _ = try await operation.remove(command.items)
        case .clear: _ = try await operation.removeAll()
        }
    }

    private func boundedRun(_ operation: Store<StoreDiscoveryItem>.Operation, storage: StoreDiscoveryStorage) async throws {
        let completion = StoreDiscoveryCompletion()
        let task = Task { @MainActor in
            do { try await operation.run(); await completion.finish(.success(())) }
            catch { await completion.finish(.failure(error)) }
        }
        do { try await completion.wait(timeout: .seconds(2)); await task.value }
        catch {
            await storage.releaseAll()
            task.cancel()
            await task.value
            throw error
        }
    }

    private func checkPersistence(_ storage: StoreDiscoveryStorage, expected: [StoreDiscoveryItem], step: Int) async throws {
        let persisted = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        try discoveryRequire(Set(persisted.map(\.id)).count == persisted.count, "operation.persistence.unique", step: step)
        try discoveryRequire(persisted.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id }, "operation.persistence.state", step: step)
    }
}

private struct OperationProbeScenario: Codable, Sendable {
    enum Schedule: String, Codable, Sendable, CaseIterable { case appendDuringRun, appendAfterRun, retryAfterFailure }
    var schedule: Schedule
    var queuedCount: Int
    var appendedCount: Int
    var failureAfterCommit: Bool
}

extension OperationLifecycleDiscoveryTests {
    /// These probes document observed policy; they do not require the library to
    /// retry a failed chain or accept commands on an already-started chain.
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_OPERATION_PROBES"] == "1"))
    func ambiguousLifecycleProbes() async throws {
        let input = zip(Gen.int(in: 0...2), Gen.int(in: 1...8), Gen.int(in: 1...4), Gen.bool)
            .map { schedule, queued, appended, committed in
                OperationProbeScenario(schedule: .allCases[schedule], queuedCount: queued,
                                       appendedCount: appended, failureAfterCommit: committed)
            }
        try await DiscoveryProperty.check("operation-lifecycle-probes", input: input) { scenario, coverage in
            try await probe(scenario, coverage: coverage)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_OPERATION_PROBES"] == "1"))
    func ambiguousScheduleMatrix() async throws {
        let coverage = DiscoveryCoverage()
        for schedule in OperationProbeScenario.Schedule.allCases {
            for queued in [1, 3] {
                for appended in [1, 2] {
                    for committed in [false, true] {
                        try await probe(.init(schedule: schedule, queuedCount: queued, appendedCount: appended,
                                              failureAfterCommit: committed), coverage: coverage)
                    }
                }
            }
        }
        print("PROPERTY operation-lifecycle probes finite schedules=24; \(coverage.counts)")
    }

    private func probe(_ scenario: OperationProbeScenario, coverage: DiscoveryCoverage) async throws {
        let storage = StoreDiscoveryStorage()
        let store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        let operation = Store<StoreDiscoveryItem>.Operation(store: store)
        let queued = (0..<scenario.queuedCount).map { StoreDiscoveryItem(id: "queued-\($0)", payload: $0) }
        let appended = (0..<scenario.appendedCount).map { StoreDiscoveryItem(id: "appended-\($0)", payload: $0) }
        for item in queued { _ = try await operation.insert(item) }
        await storage.pause("write")
        if scenario.schedule == .retryAfterFailure { await storage.fail("write", after: scenario.failureAfterCommit ? 1 : 0) }
        let completion = StoreDiscoveryCompletion()
        let task = Task { @MainActor in
            do { try await operation.run(); await completion.finish(.success(())) }
            catch { await completion.finish(.failure(error)) }
        }
        var followerTask: Task<Void, Never>?
        do {
            try await storage.waitForGate(timeout: .seconds(2))
            if scenario.schedule == .appendDuringRun {
                for item in appended { _ = try await operation.insert(item) }
            }
            let followerCompletion = StoreDiscoveryCompletion()
            await withCheckedContinuation { started in
                followerTask = Task { @MainActor in
                    started.resume()
                    do { try await operation.run(); await followerCompletion.finish(.success(())) }
                    catch { await followerCompletion.finish(.failure(error)) }
                }
            }
            // Read a completion flag rather than requiring one completion policy.
            coverage.hit(await followerCompletion.hasFinished() ? "second-run-returned-before-first" : "second-run-pending-before-release")
            await storage.releaseAll()
            var failed = false
            do { try await completion.wait(timeout: .seconds(2)) }
            catch StoreDiscoveryStorage.Failure.injected { failed = true }
            await task.value
            do { try await followerCompletion.wait(timeout: .seconds(2)) }
            catch StoreDiscoveryStorage.Failure.injected { coverage.hit("follower-propagated-first-error") }
            await followerTask?.value
            try discoveryRequire(failed == (scenario.schedule == .retryAfterFailure), "operation.probe.injected-error", step: 0)
            let priorCalls = await storage.calls.count
            let priorCommits = await storage.commits.count
            if scenario.schedule != .appendDuringRun {
                for item in appended { _ = try await operation.insert(item) }
            }
            do { try await boundedRun(operation, storage: storage) }
            catch StoreDiscoveryStorage.Failure.injected { coverage.hit("later-run-propagated-first-error") }
            let subsequentCalls = await storage.calls.count
            let subsequentCommits = await storage.commits.count
            let persisted = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
            // Descriptive coverage: these are observed outcomes, not desired
            // mutable-chain/retry semantics made into passing invariants.
            coverage.hit("schedule-\(scenario.schedule.rawValue)")
            coverage.hit(subsequentCalls == priorCalls && subsequentCommits == priorCommits ? "later-run-no-effects" : "later-run-effects")
            coverage.hit("appended-items-persisted", by: persisted.filter { $0.id.hasPrefix("appended-") }.count)
            coverage.hit("appended-items-absent", by: appended.count - persisted.filter { $0.id.hasPrefix("appended-") }.count)
            if scenario.schedule == .retryAfterFailure {
                coverage.hit(scenario.failureAfterCommit ? "failed-after-commit" : "failed-before-commit")
                coverage.hit("queued-items-persisted-after-failure", by: persisted.filter { $0.id.hasPrefix("queued-") }.count)
            } else {
                coverage.hit(store.items == queued ? "memory-only-original-queue" : "memory-changed-by-post-start-append")
            }
        } catch {
            await storage.releaseAll()
            task.cancel()
            followerTask?.cancel()
            await task.value
            await followerTask?.value
            throw error
        }
    }
}

private enum OperationCodecFailure: Error { case rejected }
private final class OperationCodecMetrics: @unchecked Sendable {
    static let shared = OperationCodecMetrics()
    private let lock = NSLock()
    private var encodes = 0
    private var decodes = 0
    func encoded() { lock.lock(); defer { lock.unlock() }; encodes += 1 }
    func decoded() { lock.lock(); defer { lock.unlock() }; decodes += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; encodes = 0; decodes = 0 }
    func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return [encodes, decodes] }
}
private struct OperationCodecItem: Codable, Sendable {
    var id: String
    var rejectsEncoding: Bool
    enum Keys: String, CodingKey { case id, rejectsEncoding }
    init(id: String, rejectsEncoding: Bool) { self.id = id; self.rejectsEncoding = rejectsEncoding }
    init(from decoder: Decoder) throws {
        OperationCodecMetrics.shared.decoded()
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        rejectsEncoding = try container.decode(Bool.self, forKey: .rejectsEncoding)
    }
    func encode(to encoder: Encoder) throws {
        OperationCodecMetrics.shared.encoded()
        if rejectsEncoding { throw OperationCodecFailure.rejected }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rejectsEncoding, forKey: .rejectsEncoding)
    }
}

extension OperationLifecycleDiscoveryTests {
    @Test func queueDoesNotInvokeCodecs() async throws {
        let storage = StoreDiscoveryStorage()
        let item = OperationCodecItem(id: "stored", rejectsEncoding: false)
        try await storage.write(try JSONEncoder().encode(item), key: CacheKey(item.id))
        let store = try await Store<OperationCodecItem>(storage: storage, cacheIdentifier: \.id)
        OperationCodecMetrics.shared.reset()
        let baselineCalls = await storage.calls.count
        let chain: Store<OperationCodecItem>.Operation = try await store.removeAll()
        _ = try await chain.insert(OperationCodecItem(id: "poison", rejectsEncoding: true))
        _ = try await chain.insert(OperationCodecItem(id: "tail", rejectsEncoding: false))
        try discoveryRequire(OperationCodecMetrics.shared.snapshot() == [0, 0], "operation.queue.codecs", step: 0)
        try discoveryRequire(await storage.calls.count == baselineCalls, "operation.queue.backend", step: 0)
        try discoveryRequire(store.items.map(\.id) == ["stored"], "operation.queue.memory", step: 0)
        var rejected = false
        do { try await chain.run() }
        catch OperationCodecFailure.rejected { rejected = true }
        try discoveryRequire(rejected, "operation.run.encoding-error", step: 1)
        try discoveryRequire(OperationCodecMetrics.shared.snapshot() == [1, 0], "operation.run.encoding-count", step: 1)
    }
}
