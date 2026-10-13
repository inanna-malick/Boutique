import Foundation
import PropertyBased
import Testing
@testable import Boutique

struct SharedStoreScenario: Codable, Sendable {
    struct Step: Codable, Sendable {
        var owner: Int
        var kind: Int
        var key: Int
        var payload: Int
        var reconstruct: Bool
    }
    var owners: Int
    var late: Bool
    var steps: [Step]
}

@MainActor
@Suite("Shared Store persistence discovery", .serialized)
struct StoreSharedPersistenceDiscoveryTests {
    private func generator(_ length: Int) -> Generator<SharedStoreScenario, some Sequence> {
        let step = zip(Gen.int(in: 0...2), Gen.int(in: 0...5), Gen.int(in: 0...4), Gen.int(in: -20...20), Gen.bool)
            .map { SharedStoreScenario.Step(owner: $0, kind: $1, key: $2, payload: $3, reconstruct: $4) }
        return zip(Gen.int(in: 2...3), Gen.bool, step.array(of: 1...length))
            .map { SharedStoreScenario(owners: $0, late: $1, steps: $2) }
    }

    @Test(.shrinking) func instrumentedControls() async throws { try await campaign("mock", separate: false, fusedClear: false) }
    @Test(.shrinking, arguments: ["disk", "sqlite"], [false, true])
    func backendControls(backend: String, separate: Bool) async throws { try await campaign(backend, separate: separate, fusedClear: false) }
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_SHARED_STORES_FINDINGS"] == "1"), arguments: ["mock", "disk", "sqlite"], [false, true])
    func fusedClearSearch(backend: String, separate: Bool) async throws { try await campaign(backend, separate: separate, fusedClear: true) }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_SHARED_STORES_FINDINGS"] == "1"))
    func instrumentedFusedClearReplay() async throws { try await campaign("mock", separate: false, fusedClear: true) }

    private func campaign(_ backend: String, separate: Bool, fusedClear: Bool) async throws {
        try await DiscoveryProperty.check("shared-stores-\(backend)-\(separate ? "separate" : "shared")-\(fusedClear ? "fused" : "direct")",
            count: backend == "mock" ? DiscoveryProperty.cases : DiscoveryProperty.backendCases,
            input: generator(backend == "mock" ? DiscoveryProperty.steps : 40)) { scenario, coverage in
            _ = try await replay(scenario, backend: backend, separate: separate, fusedClear: fusedClear, coverage: coverage)
        }
    }

    private func replay(_ scenario: SharedStoreScenario, backend: String, separate: Bool, fusedClear: Bool, coverage: DiscoveryCoverage, verifyPersistence: Bool = true) async throws -> [StoreDiscoveryItem] {
        let directory = FileManager.Directory.temporary(appendingPath: "SharedStores.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let mock = StoreDiscoveryStorage()
        func engine() throws -> any StorageEngine {
            if backend == "mock" { return mock }
            if backend == "disk" { return DiskStorageEngine(directory: directory) }
            return try discoveryUnwrap(SQLiteStorageEngine(directory: directory), "shared.fixture.sqlite")
        }
        let storage = try engine()
        var stores: [Store<StoreDiscoveryItem>?] = []
        var histories: [StoreDiscoveryModel] = []
        var persisted = StoreDiscoveryModel()
        func sorted(_ values: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] { values.sorted { $0.id < $1.id } }
        func decode() async throws -> [StoreDiscoveryItem] { try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) } }
        func make() async throws -> Store<StoreDiscoveryItem> { try await Store(storage: separate ? engine() : storage, cacheIdentifier: \.id) }
        coverage.hit("instances.\(scenario.owners)")
        coverage.hit(scenario.late ? "late-construction" : "early-construction")
        for owner in 0..<scenario.owners {
            let store = try await make()
            try discoveryRequire(sorted(store.items) == sorted(persisted.items), "shared.construct", step: -1)
            stores.append(store)
            histories.append(StoreDiscoveryModel(items: store.items.map { loaded in persisted.items.first { $0.id == loaded.id }! }))
            if scenario.late && owner == 0 {
                let seed = StoreDiscoveryItem(id: "seed", payload: 99)
                try await store.insert(seed)
                let command = StoreDiscoveryCommand(kind: .insert, items: [seed])
                persisted.apply(command); histories[0].apply(command)
            }
        }
        for (index, step) in scenario.steps.enumerated() {
            let owner = step.owner % stores.count
            if step.reconstruct {
                stores[owner] = nil
                stores[owner] = try await make()
                try discoveryRequire(sorted(stores[owner]!.items) == sorted(persisted.items), "shared.reconstruct", step: index)
                histories[owner].items = stores[owner]!.items.map { loaded in persisted.items.first { $0.id == loaded.id }! }
                coverage.hit("reconstruct")
            }
            let store = stores[owner]!
            let item = StoreDiscoveryItem(id: "key\(step.key)", payload: step.payload)
            let replacement = StoreDiscoveryItem(id: "replacement", payload: step.payload)
            let stale = sorted(histories[owner].items) != sorted(persisted.items)
            coverage.hit(stale ? "stale-writer" : "current-writer")
            let commands: [StoreDiscoveryCommand]
            switch step.kind {
            case 0: commands = [.init(kind: .insert, items: [item])]; try await store.insert(item)
            case 1:
                let batch = step.payload == 0 ? [] : [item, StoreDiscoveryItem(id: item.id, payload: item.payload + 1)]
                if batch.isEmpty { coverage.hit("empty-batch") }
                commands = [.init(kind: .batch, items: batch)]; try await store.insert(batch)
            case 2: commands = [.init(kind: .remove, items: [item])]; try await store.remove(item)
            case 3:
                commands = [.init(kind: .removeBatch, items: [item]), .init(kind: .insert, items: [replacement])]
                let chain: Store<StoreDiscoveryItem>.Operation = try await store.remove([item]).insert(replacement)
                try await chain.run()
                coverage.hit("selective-fusion")
                if stale { coverage.hit("stale-selective-removal") }
            case 4: commands = [.init(kind: .clear, items: [])]; try await store.removeAll(); if stale { coverage.hit("stale-direct-clear") }
            default:
                commands = [.init(kind: .clear, items: []), .init(kind: .batch, items: [replacement])]
                if fusedClear { try await store.removeAll().insert([replacement]).run() }
                else { try await store.removeAll(); try await store.insert([replacement]) }
                coverage.hit("clear-insert")
            }
            for command in commands { persisted.apply(command); histories[owner].apply(command) }
            try discoveryRequire(store.items == histories[owner].items, "shared.writer-memory", step: index)
            let actual = try await decode()
            if verifyPersistence { try discoveryRequire(actual.count == persisted.items.count && sorted(actual) == sorted(persisted.items), "shared.persisted", step: index, "expected=\(persisted.items), actual=\(actual)") }
            let fresh = try await make()
            if verifyPersistence { try discoveryRequire(sorted(fresh.items) == sorted(persisted.items), "shared.fresh-reopen", step: index) }
            coverage.hit("operation.\(step.kind)"); coverage.hit("owner.\(owner)"); coverage.hit("checkpoint")
        }
        return sorted(try await decode())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_SHARED_STORES_FINDINGS"] == "1"), arguments: ["mock", "disk", "sqlite"], [false, true])
    func pairedClearWitness(backend: String, separate: Bool) async throws {
        let scenario = SharedStoreScenario(owners: 2, late: false, steps: [
            .init(owner: 0, kind: 0, key: 0, payload: 1, reconstruct: false),
            .init(owner: 1, kind: 5, key: 1, payload: 2, reconstruct: false)])
        let direct = try await replay(scenario, backend: backend, separate: separate, fusedClear: false, coverage: DiscoveryCoverage())
        let fused = try await replay(scenario, backend: backend, separate: separate, fusedClear: true, coverage: DiscoveryCoverage(), verifyPersistence: false)
        try discoveryRequire(direct == fused, "shared.metamorphic-clear", step: 1)
    }

    @Test func boundedMatrix() async throws {
        let coverage = DiscoveryCoverage()
        for owners in 2...3 { for late in [false, true] { for reconstruct in [false, true] { for kind in 0...5 {
            let scenario = SharedStoreScenario(owners: owners, late: late, steps: [
                .init(owner: 0, kind: 0, key: 0, payload: 1, reconstruct: false),
                .init(owner: 1, kind: kind, key: 0, payload: 2, reconstruct: reconstruct),
                .init(owner: 0, kind: 3, key: 0, payload: 3, reconstruct: reconstruct)])
            _ = try await replay(scenario, backend: "mock", separate: false, fusedClear: false, coverage: coverage)
        } } } }
        for firstOwner in 0...1 { for secondOwner in 0...1 { for firstKey in 0...1 { for secondKey in 0...1 { for firstKind in [0, 1, 2] { for secondKind in 0...5 {
            let scenario = SharedStoreScenario(owners: 2, late: false, steps: [
                .init(owner: firstOwner, kind: firstKind, key: firstKey, payload: 1, reconstruct: false),
                .init(owner: secondOwner, kind: secondKind, key: secondKey, payload: 2, reconstruct: false)])
            _ = try await replay(scenario, backend: "mock", separate: false, fusedClear: false, coverage: coverage)
        } } } } } }
        for event in ["stale-selective-removal", "stale-direct-clear", "late-construction", "reconstruct"] {
            try discoveryRequire((coverage.counts[event] ?? 0) > 0, "shared.matrix-reachability", step: -1, event)
        }
        print("PROPERTY shared-stores matrix: 336 histories; \(coverage.counts)")
    }
}
