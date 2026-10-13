import Foundation
import PropertyBased
import Testing
@testable import Boutique

private enum StoreInterleavingOwner {
    @TaskLocal static var name = "setup"
}

/// A concrete initial-state / operation / schedule AST. No generator state is
/// consulted during execution or corpus replay.
private struct StoreInterleavingScenario: Codable, Sendable {
    struct Operation: Codable, Sendable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case insert, batch, remove, removeBatch, clear, fusedClearInsert, fusedRemoveInsert
        }
        var kind: Kind
        var items: [StoreDiscoveryItem]
        var removals: [StoreDiscoveryItem]
    }
    struct Schedule: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case before, after }
        var serialized: Bool
        var firstBoundary: Int
        var firstPhase: Phase
        var releaseFirst: Bool
    }
    var initial: [StoreDiscoveryItem]
    var first: Operation
    var second: Operation
    var schedule: Schedule
}

/// Unlike the older call-entry backend, this backend can suspend after each
/// individual element commits. Values in the ledger come from independently
/// decoding the actual bytes; the oracle never guesses which task wrote a key.
private actor StoreInterleavingStorage: StorageEngine {
    struct Commit: Sendable, Equatable, CustomStringConvertible {
        let owner: String
        let kind: String
        let key: String?
        let item: StoreDiscoveryItem?
        var description: String { "\(owner):\(kind):\(item.map { "\($0.id)=\($0.payload)" } ?? key ?? "all")" }
    }
    struct Gate {
        let boundary: Int
        let phase: StoreInterleavingScenario.Schedule.Phase
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var values: [CacheKey: Data] = [:]
    private var boundaries: [String: Int] = [:]
    private var gates: [String: Gate] = [:]
    private var waiters: [String: StoreDiscoveryCompletion] = [:]
    private(set) var commits: [Commit] = []

    func seed(_ items: [StoreDiscoveryItem]) throws {
        for item in items { values[CacheKey(item.id)] = try JSONEncoder().encode(item) }
    }
    func pause(_ owner: String, boundary: Int, phase: StoreInterleavingScenario.Schedule.Phase) {
        gates[owner] = Gate(boundary: boundary, phase: phase)
        waiters[owner] = StoreDiscoveryCompletion()
    }
    func wait(_ owner: String, timeout: Duration = .seconds(1)) async throws {
        guard let waiter = waiters[owner] else { throw StoreDiscoveryStorage.Failure.gateTimedOut }
        try await waiter.wait(timeout: timeout)
    }
    func release(_ owner: String) { gates.removeValue(forKey: owner)?.continuation?.resume() }
    func releaseAll() {
        let pending = gates.values.compactMap(\.continuation)
        gates = [:]
        pending.forEach { $0.resume() }
    }
    private func boundary(_ owner: String, index: Int, phase: StoreInterleavingScenario.Schedule.Phase) async {
        guard let gate = gates[owner], gate.boundary == index, gate.phase == phase else { return }
        await withCheckedContinuation { continuation in
            gates[owner]?.continuation = continuation
            // Install the suspension before acknowledging it to the driver.
            if let waiter = waiters[owner] { Task { await waiter.finish(.success(())) } }
        }
    }
    private func mutate(kind: String, key: CacheKey?, data: Data?) async throws {
        let owner = StoreInterleavingOwner.name
        let index = boundaries[owner, default: 0]
        boundaries[owner] = index + 1
        let item = try data.map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        await boundary(owner, index: index, phase: .before)
        if let key {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        } else { values = [:] }
        commits.append(.init(owner: owner, kind: kind, key: key?.value, item: item))
        await boundary(owner, index: index, phase: .after)
    }
    func write(_ data: Data, key: CacheKey) async throws { try await mutate(kind: "write", key: key, data: data) }
    func write(_ entries: [(key: CacheKey, data: Data)]) async throws {
        for entry in entries { try await mutate(kind: "write", key: entry.key, data: entry.data) }
    }
    func remove(key: CacheKey) async throws { try await mutate(kind: "remove", key: key, data: nil) }
    func remove(keys: [CacheKey]) async throws {
        for key in keys { try await mutate(kind: "remove", key: key, data: nil) }
    }
    func removeAllData() async throws { try await mutate(kind: "clear", key: nil, data: nil) }
    func readAllData() -> [Data] { values.sorted { $0.key.value < $1.key.value }.map(\.value) }
    func read(key: CacheKey) -> Data? { values[key] }
    func readDataAndKeys(keys: [CacheKey]) -> [(key: CacheKey, data: Data)] { keys.compactMap { key in values[key].map { (key, $0) } } }
    func allKeys() -> [CacheKey] { Array(values.keys) }
    func keyExists(_ key: CacheKey) -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) -> Date? { nil }
    func updatedAt(key: CacheKey) -> Date? { nil }
}

@MainActor
@Suite("StoreDiscovery per-element interleavings")
struct StoreDiscoveryInterleavingTests {
    private func generator(serialized: Bool, atomicSameID: Bool = false,
                           sameIDAfterCommit: Bool = false, interleavedBatches: Bool = false) -> Generator<StoreInterleavingScenario, some Sequence> {
        zip(Gen.int(in: 0...27), Gen.int(in: 0...27), Gen.int(in: 0...31), Gen.int(in: -20...20))
            .map { firstDraw, secondDraw, flags, payload in
                let initialCount = atomicSameID ? 1 : 1 + flags % 4
                let initial = (0..<initialCount).map { StoreDiscoveryItem(id: "key-\($0)", payload: payload) }
                let count = atomicSameID ? 1 : interleavedBatches ? 2 + (flags / 4) % 2 : 1 + (flags / 4) % 3
                let relation = atomicSameID ? 0 : flags % 3
                let firstIDs = (0..<count).map { "key-\($0)" }
                let secondIDs = (0..<count).map { "key-\(relation == 0 ? $0 : relation == 1 ? $0 + 1 : $0 + 4)" }
                let firstKind: StoreInterleavingScenario.Operation.Kind = atomicSameID ? (firstDraw % 2 == 0 ? .insert : .batch) : interleavedBatches ? .batch : [.insert, .batch, .fusedClearInsert, .fusedRemoveInsert][firstDraw % 4]
                let secondKind: StoreInterleavingScenario.Operation.Kind = atomicSameID ? (secondDraw % 2 == 0 ? .insert : .batch) : interleavedBatches ? .batch : .allCases[secondDraw % 7]
                let firstItems = firstIDs.prefix(firstKind == .insert ? 1 : count).map { StoreDiscoveryItem(id: $0, payload: payload + 1) }
                let secondItems = secondIDs.prefix([.insert, .remove].contains(secondKind) ? 1 : count).map { StoreDiscoveryItem(id: $0, payload: payload + 2) }
                let removals = Array(initial.prefix(1 + secondDraw % initialCount))
                let firstRemovalCount = firstKind == .fusedClearInsert ? initial.count : firstKind == .fusedRemoveInsert ? removals.count : 0
                let total = firstRemovalCount + firstItems.count
                return StoreInterleavingScenario(initial: initial,
                    first: .init(kind: firstKind, items: firstItems, removals: removals),
                    second: .init(kind: secondKind, items: secondItems, removals: removals),
                    schedule: .init(serialized: serialized, firstBoundary: atomicSameID || interleavedBatches ? 0 : (firstDraw / 4) % total,
                        firstPhase: sameIDAfterCommit || interleavedBatches ? .after : atomicSameID || flags < 16 ? .before : .after,
                        releaseFirst: sameIDAfterCommit || interleavedBatches ? false : flags % 2 == 0))
            }
    }

    @Test(.shrinking) func serializedCommitControls() async throws {
        try await DiscoveryProperty.check("store-element-serialized", input: generator(serialized: true)) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }
    @Test(.shrinking) func sameIdentityAtomicControls() async throws {
        try await DiscoveryProperty.check("store-same-id-atomic", input: generator(serialized: false, atomicSameID: true)) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_ELEMENT_SEARCH"] == "1"))
    func generatedElementInterleavings() async throws {
        try await DiscoveryProperty.check("store-element-interleavings", input: generator(serialized: false)) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_ELEMENT_SEARCH"] == "1"))
    func sameIdentityCommitReturnSearch() async throws {
        try await DiscoveryProperty.check("store-same-id-commit-return", input: generator(serialized: false, atomicSameID: true, sameIDAfterCommit: true)) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_ELEMENT_SEARCH"] == "1"))
    func interleavedBatchSearch() async throws {
        try await DiscoveryProperty.check("store-interleaved-batches", input: generator(serialized: false, interleavedBatches: true)) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_ELEMENT_WITNESSES"] == "1"),
          arguments: ["same-id", "equal-batches", "overlap-batches", "disjoint-batches", "insert-remove", "insert-clear", "fused-clear", "fused-remove"])
    func extractedElementWitness(_ witness: String) async throws {
        let item: (Int, Int) -> StoreDiscoveryItem = { .init(id: "key-\($0)", payload: $1) }
        let initial = [item(0, 0), item(1, 0)]
        let first: StoreInterleavingScenario.Operation
        let second: StoreInterleavingScenario.Operation
        switch witness {
        case "same-id":
            first = .init(kind: .insert, items: [item(0, 1)], removals: [])
            second = .init(kind: .insert, items: [item(0, 2)], removals: [])
        case "equal-batches", "overlap-batches", "disjoint-batches":
            first = .init(kind: .batch, items: [item(0, 1), item(1, 1)], removals: [])
            let offset = witness == "equal-batches" ? 0 : witness == "overlap-batches" ? 1 : 4
            second = .init(kind: .batch, items: [item(offset, 2), item(offset + 1, 2)], removals: [])
        case "insert-remove", "insert-clear":
            first = .init(kind: .insert, items: [item(0, 1)], removals: [])
            second = .init(kind: witness == "insert-clear" ? .clear : .remove, items: [item(0, 2)], removals: [])
        case "fused-clear", "fused-remove":
            first = .init(kind: witness == "fused-clear" ? .fusedClearInsert : .fusedRemoveInsert,
                          items: [item(0, 1), item(1, 1)], removals: [item(0, 0)])
            second = .init(kind: .batch, items: [item(0, 2), item(2, 2)], removals: [])
        default: throw DiscoveryFailure(invariant: "witness.unknown", step: 0, detail: witness)
        }
        let scenario = StoreInterleavingScenario(initial: witness == "same-id" ? [] : initial, first: first, second: second,
            schedule: .init(serialized: false, firstBoundary: 0, firstPhase: .after, releaseFirst: false))
        let coverage = DiscoveryCoverage()
        do { try await replay(scenario, coverage: coverage) }
        catch {
            print("PROPERTY ELEMENT WITNESS \(witness): \(coverage.counts); failure=\(error)")
            throw error
        }
    }

    @Test func internallySerializedControlIsExplicitlyInfeasible() async throws {
        let coverage = DiscoveryCoverage()
        let item = StoreDiscoveryItem(id: "key-0", payload: 0)
        let scenario = StoreInterleavingScenario(initial: [item],
            first: .init(kind: .insert, items: [.init(id: item.id, payload: 1)], removals: []),
            second: .init(kind: .fusedClearInsert, items: [.init(id: item.id, payload: 2)], removals: []),
            schedule: .init(serialized: false, firstBoundary: 0, firstPhase: .after, releaseFirst: false))
        try await replay(scenario, coverage: coverage, forceSerializedSecond: true, deadline: .milliseconds(20))
        try discoveryRequire(coverage.counts["schedule.infeasible"] == 1 && coverage.counts["schedule.reached"] == nil,
                             "store.element.infeasible-accounting", step: 0)
    }

    private func execute(_ operation: StoreInterleavingScenario.Operation, store: Store<StoreDiscoveryItem>) async throws {
        switch operation.kind {
        case .insert: try await store.insert(operation.items[0]) as Void
        case .batch: try await store.insert(operation.items) as Void
        case .remove: try await store.remove(operation.items[0]) as Void
        case .removeBatch: try await store.remove(operation.items) as Void
        case .clear: try await store.removeAll() as Void
        case .fusedClearInsert:
            let chain: Store<StoreDiscoveryItem>.Operation = try await store.removeAll()
            try await chain.insert(operation.items).run()
        case .fusedRemoveInsert:
            let chain: Store<StoreDiscoveryItem>.Operation = try await store.remove(operation.removals)
            try await chain.insert(operation.items).run()
        }
    }

    private func acceptedCommits(_ operation: StoreInterleavingScenario.Operation,
                                 owner: String, starting: [StoreDiscoveryItem]) -> [StoreInterleavingStorage.Commit] {
        var result: [StoreInterleavingStorage.Commit] = []
        func removals(_ items: [StoreDiscoveryItem]) {
            for item in items { result.append(.init(owner: owner, kind: "remove", key: CacheKey(item.id).value, item: nil)) }
        }
        switch operation.kind {
        case .clear: return [.init(owner: owner, kind: "clear", key: nil, item: nil)]
        case .remove: removals(Array(operation.items.prefix(1))); return result
        case .removeBatch: removals(operation.items); return result
        case .fusedClearInsert: removals(starting)
        case .fusedRemoveInsert: removals(operation.removals)
        case .insert, .batch: break
        }
        // Independent Array deduplication captures the accepted payload of every
        // write, preserving first position and last payload for repeated IDs.
        var accepted = StoreDiscoveryModel()
        accepted.apply(.init(kind: .batch, items: operation.kind == .insert ? Array(operation.items.prefix(1)) : operation.items))
        result += accepted.items.map { .init(owner: owner, kind: "write", key: CacheKey($0.id).value, item: $0) }
        return result
    }

    private func applying(_ operation: StoreInterleavingScenario.Operation, to items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] {
        var model = StoreDiscoveryModel(items: items)
        switch operation.kind {
        case .clear: model.apply(.init(kind: .clear, items: []))
        case .remove, .removeBatch: model.apply(.init(kind: .removeBatch, items: operation.items))
        case .fusedClearInsert:
            model.apply(.init(kind: .clear, items: []))
            model.apply(.init(kind: .batch, items: operation.items))
        case .fusedRemoveInsert:
            model.apply(.init(kind: .removeBatch, items: operation.removals))
            model.apply(.init(kind: .batch, items: operation.items))
        case .insert, .batch: model.apply(.init(kind: .batch, items: operation.items))
        }
        return model.items
    }

    private func replay(_ scenario: StoreInterleavingScenario, coverage: DiscoveryCoverage,
                        forceSerializedSecond: Bool = false, deadline: Duration = .seconds(1)) async throws {
        let storage = StoreInterleavingStorage()
        try await storage.seed(scenario.initial)
        let store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        await storage.pause("first", boundary: scenario.schedule.firstBoundary, phase: scenario.schedule.firstPhase)
        let firstCompletion = StoreDiscoveryCompletion()
        let first = Task {
            do {
                try await StoreInterleavingOwner.$name.withValue("first") { try await execute(scenario.first, store: store) }
                await firstCompletion.finish(.success(()))
            } catch {
                await firstCompletion.finish(.failure(error))
                throw error
            }
        }
        var second: Task<Void, Error>?
        var scheduleInfeasible = false
        do {
            try await storage.wait("first")
            if scenario.schedule.serialized {
                await storage.releaseAll()
                try await first.value
                try await StoreInterleavingOwner.$name.withValue("second") { try await execute(scenario.second, store: store) }
                coverage.hit("schedule.serialized")
            } else {
                await storage.pause("second", boundary: 0, phase: .before)
                let secondCompletion = StoreDiscoveryCompletion()
                let task = Task {
                    do {
                        if forceSerializedSecond { try await firstCompletion.wait(timeout: .seconds(5)) }
                        try await StoreInterleavingOwner.$name.withValue("second") { try await execute(scenario.second, store: store) }
                        await secondCompletion.finish(.success(()))
                    } catch {
                        await secondCompletion.finish(.failure(error))
                        throw error
                    }
                }
                second = task
                do {
                    try await storage.wait("second", timeout: deadline)
                    if scenario.schedule.releaseFirst {
                        await storage.release("first")
                        try await firstCompletion.wait(timeout: deadline)
                    } else {
                        await storage.release("second")
                        try await secondCompletion.wait(timeout: deadline)
                    }
                    await storage.releaseAll()
                    try await first.value
                    try await task.value
                    coverage.hit("schedule.reached")
                } catch StoreDiscoveryStorage.Failure.gateTimedOut {
                    // Serialization is a valid implementation. A deadline alone
                    // never decides correctness; the actual ledger does.
                    coverage.hit("schedule.infeasible")
                    scheduleInfeasible = true
                    await storage.releaseAll()
                    try await first.value
                    try await task.value
                }
            }
        } catch {
            await storage.releaseAll()
            _ = try? await first.value
            _ = try? await second?.value
            throw error
        }
        let commits = await storage.commits
        // The actual ledger supplies order, but never supplies completeness.
        // Both concurrent tasks begin against initial memory because the first
        // is acknowledged inside persistence, before it publishes memory.
        let secondStarting = scenario.schedule.serialized ? applying(scenario.first, to: scenario.initial) : scenario.initial
        for (owner, operation, starting) in [("first", scenario.first, scenario.initial), ("second", scenario.second, secondStarting)] {
            // Loading order is unspecified; compare accepted per-owner commit
            // multiplicity and payloads without inventing an order for removals.
            let accepted = acceptedCommits(operation, owner: owner, starting: starting).sorted { $0.description < $1.description }
            let actual = commits.filter { $0.owner == owner }.sorted { $0.description < $1.description }
            // A repaired implementation may serialize internally. When the
            // requested overlap was not acknowledged, either independent start
            // state is legal for snapshot-based fused clear. A timeout does not
            // select one; exact accepted writes/removals still must be present.
            let serializedAlternative = acceptedCommits(operation, owner: owner, starting: applying(scenario.first, to: scenario.initial)).sorted { $0.description < $1.description }
            let complete = actual == accepted || (owner == "second" && scheduleInfeasible && actual == serializedAlternative)
            try discoveryRequire(complete, "store.element.commit-completeness", step: commits.count,
                "owner=\(owner); actual=\(actual); accepted=\(accepted)")
        }
        var expected = StoreDiscoveryModel(items: scenario.initial)
        for (index, commit) in commits.enumerated() {
            switch commit.kind {
            case "write":
                let item = try discoveryUnwrap(commit.item, "store.element.commit-item")
                if let previous = expected.items.first(where: { $0.id == item.id }), previous.payload != item.payload {
                    coverage.hit("same-id-unequal-payload-overwrite")
                }
                expected.apply(.init(kind: .insert, items: [item]))
            case "remove":
                // ASCII identifiers are intentional: hash mapping is used only
                // to recover removal identity, never to test Unicode equivalence.
                expected.items.removeAll { CacheKey($0.id).value == commit.key }
            case "clear": expected.apply(.init(kind: .clear, items: []))
            default: try discoveryRequire(false, "store.element.commit-kind", step: index)
            }
        }
        let decoded = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        let reopened = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        let sorted: ([StoreDiscoveryItem]) -> [StoreDiscoveryItem] = { $0.sorted { $0.id == $1.id ? $0.payload < $1.payload : $0.id < $1.id } }
        try discoveryRequire(Set(decoded.map(\.id)).count == decoded.count, "store.element.persisted-duplicates", step: commits.count)
        try discoveryRequire(sorted(decoded) == sorted(expected.items), "store.element.persistence", step: commits.count)
        try discoveryRequire(sorted(reopened.items) == sorted(expected.items), "store.element.reopen", step: commits.count)
        coverage.hit("first-\(scenario.first.kind.rawValue)")
        coverage.hit("second-\(scenario.second.kind.rawValue)")
        coverage.hit("gate-\(scenario.schedule.firstPhase.rawValue)-\(scenario.schedule.firstBoundary)")
        coverage.hit("commits", by: commits.count)
        let firstKeys = Set(scenario.first.items.map(\.id)), secondKeys = Set(scenario.second.items.map(\.id))
        coverage.hit(firstKeys == secondKeys ? "keysets.equal" : firstKeys.isDisjoint(with: secondKeys) ? "keysets.disjoint" : "keysets.overlap")
        if commits.contains(where: { $0.owner == "first" }), commits.contains(where: { $0.owner == "second" }) {
            coverage.hit("both-committed")
        }
        var segments: [String] = []
        for commit in commits where segments.last != commit.owner { segments.append(commit.owner) }
        if segments.count > 2 { coverage.hit("interleaved-elements") }
        try discoveryRequire(sorted(store.items) == sorted(expected.items), "store.element.memory", step: commits.count,
            "commits=\(commits); actual=\(store.items); expected=\(expected.items)")
    }
}
