import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct StoreDiscoveryFaultScenario: Codable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case insertBatch, removeBatch, clear, fusedClearInsert, insertSingle, fusedClearRemovalFailure, fusedSelectiveRemovalFailure
    }
    var kind: Kind
    var count: Int
    var committed: Int
    var payload: Int
}

private struct StoreDiscoveryOverlapScenario: Codable, Sendable {
    enum Following: String, Codable, Sendable, CaseIterable { case insert, remove, clear }
    var loading: Bool
    var firstBatch: Bool
    var secondBatch: Bool
    var following: Following
    var initialCount: Int
    var payload: Int
    /// False is the serialized control. True completes the second operation while
    /// the first is suspended. The schedule is data, so corpus replay needs no RNG.
    var secondCompletesFirst: Bool
    var bothStartedFirstCompletesFirst: Bool? = nil
}

@MainActor
@Suite("StoreDiscovery controlled schedules")
struct StoreDiscoveryScheduleTests {
    @Test(.shrinking)
    func faultSchedules() async throws {
        let input = zip(Gen.int(in: 0...6), Gen.int(in: 0...4), Gen.int(in: 0...4), Gen.int(in: -100...100))
            .map { kind, count, committed, payload in
                StoreDiscoveryFaultScenario(kind: .allCases[kind], count: count, committed: committed % (count + 1), payload: payload)
            }
        try await DiscoveryProperty.check("store-fault-schedules", input: input) { scenario, coverage in
            try await fault(scenario, coverage: coverage)
        }
    }

    @Test func faultBoundaryMatrix() async throws {
        for kind in StoreDiscoveryFaultScenario.Kind.allCases {
            for count in [0, 1, 3] {
                for committed in 0...count {
                    try await fault(.init(kind: kind, count: count, committed: committed, payload: 42), coverage: DiscoveryCoverage())
                }
            }
        }
    }

    private func fault(_ scenario: StoreDiscoveryFaultScenario, coverage: DiscoveryCoverage) async throws {
        let storage = StoreDiscoveryStorage()
        let store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        let count = [.insertSingle, .fusedClearRemovalFailure, .fusedSelectiveRemovalFailure].contains(scenario.kind) ? max(1, scenario.count) : scenario.count
        let initial = (0..<count).map { StoreDiscoveryItem(id: "old-\($0)", payload: scenario.payload) }
        let inserted = (0..<count).map { StoreDiscoveryItem(id: "new-\($0)", payload: scenario.payload + 1) }
        try await store.insert(initial) as Void
        let committed = scenario.kind == .clear || scenario.kind == .insertSingle ? min(scenario.committed, 1) : scenario.committed
        let kind: String
        switch scenario.kind {
        case .insertBatch, .fusedClearInsert: kind = "batch"
        case .removeBatch: kind = "removeBatch"
        case .clear: kind = "clear"
        case .insertSingle: kind = "write"
        case .fusedClearRemovalFailure, .fusedSelectiveRemovalFailure: kind = count == 1 ? "remove" : "removeBatch"
        }
        await storage.fail(kind, after: committed)
        var threw = false
        do {
            switch scenario.kind {
            case .insertBatch: try await store.insert(inserted) as Void
            case .removeBatch: try await store.remove(initial) as Void
            case .clear: try await store.removeAll() as Void
            case .fusedClearInsert:
                let chain: Store<StoreDiscoveryItem>.Operation = try await store.removeAll()
                try await chain.insert(inserted).run()
            case .insertSingle: try await store.insert(inserted[0]) as Void
            case .fusedClearRemovalFailure:
                let chain: Store<StoreDiscoveryItem>.Operation = try await store.removeAll()
                try await chain.insert(inserted).run()
            case .fusedSelectiveRemovalFailure:
                let chain: Store<StoreDiscoveryItem>.Operation = try await store.remove(initial)
                try await chain.insert(inserted).run()
            }
        } catch StoreDiscoveryStorage.Failure.injected { threw = true }
        try discoveryRequire(threw, "store.fault.propagation", step: 0)
        // Expected bytes follow the backend commit schedule, not an assumed
        // transaction rollback guarantee. The Store must propagate the error.
        var persisted: [StoreDiscoveryItem]
        switch scenario.kind {
        case .insertBatch, .insertSingle: persisted = initial + inserted.prefix(committed)
        case .removeBatch, .fusedClearRemovalFailure, .fusedSelectiveRemovalFailure: persisted = Array(initial.dropFirst(committed))
        case .clear: persisted = committed == 0 ? initial : []
        case .fusedClearInsert: persisted = Array(inserted.prefix(committed))
        }
        let decoded = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        try discoveryRequire(sorted(decoded) == sorted(persisted), "store.fault.persisted-prefix", step: 0)
        let reopened = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        try discoveryRequire(sorted(reopened.items) == sorted(persisted), "store.fault.reopen", step: 0)
        let recovery = StoreDiscoveryItem(id: "recovery", payload: scenario.payload)
        try await store.insert(recovery) as Void
        try discoveryRequire(store.items.contains(recovery), "store.fault.continued-use", step: 1)
        try await store.removeAll() as Void
        try await store.insert(inserted) as Void
        persisted = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        try discoveryRequire(store.items == inserted && sorted(persisted) == sorted(inserted), "store.fault.reset-recovery", step: 2)
        coverage.hit("fault-\(scenario.kind.rawValue)-commit-\(committed)")
    }

    private func overlapGenerator(concurrent: Bool) -> Generator<StoreDiscoveryOverlapScenario, some Sequence> {
        zip(Gen.int(in: 0...15), Gen.int(in: 0...4), Gen.int(in: -20...20), Gen.int(in: 0...2))
            .map { modes, count, payload, following in
                StoreDiscoveryOverlapScenario(loading: modes % 2 == 0, firstBatch: modes % 4 < 2,
                    secondBatch: modes % 8 < 4, following: .allCases[following], initialCount: count,
                    payload: payload, secondCompletesFirst: concurrent, bothStartedFirstCompletesFirst: concurrent && modes >= 8)
            }
    }

    @Test(.shrinking)
    func serializedScheduleControls() async throws {
        try await DiscoveryProperty.check("store-serialized-schedules", input: overlapGenerator(concurrent: false)) { scenario, coverage in
            try await overlap(scenario, coverage: coverage)
        }
    }

    /// Known failing search kept executable until the independent races are fixed.
    /// Every original/reduced scenario is persisted by the shared discovery runner.
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_OVERLAP_SEARCH"] == "1"))
    func generatedOverlaps() async throws {
        try await DiscoveryProperty.check("store-overlap-schedules", input: overlapGenerator(concurrent: true)) { scenario, coverage in
            try await overlap(scenario, coverage: coverage)
        }
    }

    private func overlap(_ scenario: StoreDiscoveryOverlapScenario, coverage: DiscoveryCoverage) async throws {
        let storage = StoreDiscoveryStorage()
        let initial = (0..<scenario.initialCount).map { StoreDiscoveryItem(id: "initial-\($0)", payload: scenario.payload) }
        for item in initial { try await storage.write(JSONEncoder().encode(item), key: CacheKey(item.id)) }
        let a = StoreDiscoveryItem(id: "a", payload: scenario.payload)
        let b = StoreDiscoveryItem(id: "b", payload: scenario.payload + 1)
        let store: Store<StoreDiscoveryItem>
        if scenario.loading {
            await storage.pause("readAll")
            store = synchronous(storage)
            do {
                try await storage.waitForGate()
                if !scenario.secondCompletesFirst {
                    await storage.release()
                    try await store.itemsHaveLoaded()
                }
                if scenario.bothStartedFirstCompletesFirst == true {
                    await storage.pause(followingStorageKind(scenario))
                    let second = Task { try await following(scenario, store: store, inserted: b, removed: initial.first ?? a) }
                    do {
                        try await storage.waitForGate()
                        await storage.release()
                        try await store.itemsHaveLoaded()
                        await storage.release()
                        try await second.value
                    } catch {
                        await storage.releaseAll()
                        _ = try? await second.value
                        throw error
                    }
                } else {
                    try await following(scenario, store: store, inserted: b, removed: initial.first ?? a)
                    await storage.release()
                    try await store.itemsHaveLoaded()
                }
            } catch {
                await storage.releaseAll()
                _ = try? await store.itemsHaveLoaded()
                throw error
            }
        } else {
            store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
            await storage.pause(scenario.firstBatch ? "batch" : "write")
            let first = Task {
                if scenario.firstBatch { try await store.insert([a]) as Void }
                else { try await store.insert(a) as Void }
            }
            do {
                try await storage.waitForGate()
                if !scenario.secondCompletesFirst { await storage.release(); try await first.value }
                if scenario.bothStartedFirstCompletesFirst == true {
                    await storage.pause(followingStorageKind(scenario))
                    let second = Task { try await following(scenario, store: store, inserted: b, removed: initial.first ?? a) }
                    do {
                        try await storage.waitForGate()
                        await storage.release()
                        try await first.value
                        await storage.release()
                        try await second.value
                    } catch {
                        await storage.releaseAll()
                        _ = try? await second.value
                        throw error
                    }
                } else {
                    try await following(scenario, store: store, inserted: b, removed: initial.first ?? a)
                    await storage.release()
                    try await first.value
                }
            } catch {
                await storage.releaseAll()
                _ = try? await first.value
                throw error
            }
        }
        let reopened = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        // The independent model applies actual storage commit order. For distinct
        // inserts/removing an unrelated initial key, either order has one result.
        var expected = StoreDiscoveryModel(items: initial)
        if !scenario.loading && (!scenario.secondCompletesFirst || scenario.bothStartedFirstCompletesFirst == true) { expected.apply(.init(kind: .insert, items: [a])) }
        switch scenario.following {
        case .insert: expected.apply(.init(kind: .insert, items: [b]))
        case .remove: expected.apply(.init(kind: .remove, items: [initial.first ?? a]))
        case .clear: expected.apply(.init(kind: .clear, items: []))
        }
        if !scenario.loading && scenario.secondCompletesFirst && scenario.bothStartedFirstCompletesFirst != true { expected.apply(.init(kind: .insert, items: [a])) }
        let family = scenario.loading ? "load" : "mutation"
        coverage.hit("\(family)-\(scenario.following.rawValue)-\(scenario.firstBatch)-\(scenario.secondBatch)-first-completes-\(scenario.bothStartedFirstCompletesFirst == true)")
        try discoveryRequire(sorted(reopened.items) == sorted(expected.items), "store.overlap.\(family).persistence", step: 0)
        try discoveryRequire(sorted(store.items) == sorted(expected.items), "store.overlap.\(family).memory", step: 0,
            "actual=\(store.items), expected=\(expected.items)")
    }

    private func followingStorageKind(_ scenario: StoreDiscoveryOverlapScenario) -> String {
        switch scenario.following {
        case .insert: return scenario.secondBatch ? "batch" : "write"
        case .remove: return scenario.secondBatch ? "removeBatch" : "remove"
        case .clear: return "clear"
        }
    }

    private func following(_ scenario: StoreDiscoveryOverlapScenario, store: Store<StoreDiscoveryItem>, inserted: StoreDiscoveryItem, removed: StoreDiscoveryItem) async throws {
        switch scenario.following {
        case .insert:
            if scenario.secondBatch { try await store.insert([inserted]) as Void }
            else { try await store.insert(inserted) as Void }
        case .remove:
            if scenario.secondBatch { try await store.remove([removed]) as Void }
            else { try await store.remove(removed) as Void }
        case .clear: try await store.removeAll() as Void
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_OVERLAP_WITNESSES"] == "1"), arguments: [false, true], [false, true])
    func extractedOverlapWitness(loading: Bool, firstCompletesFirst: Bool) async throws {
        try await overlap(.init(loading: loading, firstBatch: false, secondBatch: false,
            following: .insert, initialCount: loading && firstCompletesFirst ? 1 : 0, payload: 0, secondCompletesFirst: true,
            bothStartedFirstCompletesFirst: firstCompletesFirst), coverage: DiscoveryCoverage())
    }

    private func synchronous(_ storage: any StorageEngine) -> Store<StoreDiscoveryItem> {
        Store(storage: storage, cacheIdentifier: \.id)
    }
    private func sorted(_ items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] { items.sorted { $0.id < $1.id } }
}
