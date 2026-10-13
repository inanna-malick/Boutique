import Foundation
import PropertyBased
import Testing
@testable import Boutique

struct StoreDiscoveryItem: Codable, Sendable, Equatable {
    let id: String
    let payload: Int
}

struct StoreDiscoveryCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case insert, batch, remove, removeBatch, clear }
    var kind: Kind
    var items: [StoreDiscoveryItem]
}

struct StoreDiscoveryScenario: Codable, Sendable {
    struct Step: Codable, Sendable {
        var commands: [StoreDiscoveryCommand]
        var queued: Bool
        var reopen: Bool
        var observe: Bool = true
    }
    var steps: [Step]
}

/// Ordered Array oracle: replacement keeps the first insertion position; batches
/// are interpreted as individual logical writes, independently of OrderedDictionary.
struct StoreDiscoveryModel {
    var items: [StoreDiscoveryItem] = []
    mutating func apply(_ command: StoreDiscoveryCommand) {
        switch command.kind {
        case .insert, .batch:
            for item in command.items {
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
                else { items.append(item) }
            }
        case .remove, .removeBatch:
            items.removeAll { item in command.items.contains { $0.id == item.id } }
        case .clear: items = []
        }
    }
}

@MainActor
@Suite("StoreDiscovery histories")
struct StoreDiscoveryHistoryTests {
    private func generator(steps: Int) -> Generator<StoreDiscoveryScenario, some Sequence> {
        // map resolves operands from an independent shadow model. Shrinking the
        // raw input reconstructs all identities rather than dropping invalid commands.
        let raw = zip(Gen.int(in: 0...99), Gen.int(in: 0...127), Gen.int(in: -20...20), Gen.int(in: 0...15))
        return zip(Gen.int(in: 0...3), raw.array(of: 1...steps)).map { mix, draws in
            var model = StoreDiscoveryModel()
            var result: [StoreDiscoveryScenario.Step] = []
            for (drawIndex, draw) in draws.enumerated() {
                let (choice, key, value, flags) = draw
                let domain = mix == 0 ? 128 : 5
                let existing = !model.items.isEmpty && (mix == 0 ? key % 4 == 0 : key % 4 != 0)
                let id = existing ? model.items[key % model.items.count].id : "key/é-\(key % domain)" + (mix == 0 ? "-\(drawIndex)" : "")
                let item = StoreDiscoveryItem(id: id, payload: value)
                let kind: StoreDiscoveryCommand.Kind
                // Growth, overwrite, removal, and broad mixes have distinct distributions.
                let cut = [85, 70, 40, 60][mix]
                if choice < cut { kind = flags % 2 == 0 ? .insert : .batch }
                else if choice < 95 { kind = flags % 2 == 0 ? .remove : .removeBatch }
                else { kind = mix == 0 ? .insert : .clear }
                var operands = [item]
                if kind == .batch || kind == .removeBatch {
                    operands = flags % 5 == 0 ? [] : [item, StoreDiscoveryItem(id: id, payload: value + 1), StoreDiscoveryItem(id: "extra-\(key % domain)", payload: value)]
                }
                let command = StoreDiscoveryCommand(kind: kind, items: operands)
                var commands = [command]
                // Explicit fusion families include both overlap and disjoint replacement IDs.
                if flags == 7 || flags == 15 {
                    commands = [StoreDiscoveryCommand(kind: flags == 7 && mix != 0 ? .clear : .removeBatch, items: [item]), command]
                }
                commands.forEach { model.apply($0) }
                if flags % 2 == 0, let last = result.indices.last, result[last].queued, result[last].commands.count < 8 {
                    result[last].commands += commands
                } else {
                    result.append(.init(commands: commands, queued: flags % 3 == 0 || commands.count > 1, reopen: flags == 4, observe: flags % 2 == 0))
                }
            }
            return StoreDiscoveryScenario(steps: result)
        }
    }

    @Test(.shrinking) func mockHistories() async throws {
        try await DiscoveryProperty.check("store-history-mock", input: generator(steps: DiscoveryProperty.steps)) { scenario, coverage in
            let storage = StoreDiscoveryStorage()
            try await replay(scenario, storage: storage, coverage: coverage)
        }
    }

    @Test(.shrinking) func diskHistories() async throws { try await backendHistories(backend: "disk") }
    @Test(.shrinking) func sqliteHistories() async throws { try await backendHistories(backend: "sqlite") }

    private func backendHistories(backend: String) async throws {
        try await DiscoveryProperty.check("store-history-\(backend)", count: DiscoveryProperty.backendCases, input: generator(steps: 40)) { scenario, coverage in
            let directory = FileManager.Directory.temporary(appendingPath: "StoreDiscovery-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let storage: any StorageEngine = backend == "disk" ? DiskStorageEngine(directory: directory) : try discoveryUnwrap(SQLiteStorageEngine(directory: directory), "fixture.sqlite")
            try await replay(scenario, storage: storage, coverage: coverage, reopenStorage: {
                if backend == "disk" { return DiskStorageEngine(directory: directory) }
                return try discoveryUnwrap(SQLiteStorageEngine(directory: directory), "fixture.sqlite")
            })
        }
    }

    @Test func fusedInteractionMatrix() async throws {
        // Guarantee clear/selective × empty/single/duplicate-batch × overlapping IDs.
        let a = StoreDiscoveryItem(id: "a/é", payload: 1)
        let b = StoreDiscoveryItem(id: "b", payload: 2)
        for clear in [false, true] {
            for batch in [[], [a], [a, StoreDiscoveryItem(id: a.id, payload: 3), b]] {
                let scenario = StoreDiscoveryScenario(steps: [
                    .init(commands: [.init(kind: .batch, items: [a, b])], queued: false, reopen: false),
                    .init(commands: [.init(kind: clear ? .clear : .removeBatch, items: [a]), .init(kind: .batch, items: batch)], queued: true, reopen: true)
                ])
                try await replay(scenario, storage: StoreDiscoveryStorage(), coverage: DiscoveryCoverage())
            }
        }
    }

    private func replay(_ scenario: StoreDiscoveryScenario, storage initialStorage: any StorageEngine, coverage: DiscoveryCoverage, reopenStorage: (() throws -> any StorageEngine)? = nil) async throws {
        var storage = initialStorage
        var store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        var model = StoreDiscoveryModel()
        for (index, step) in scenario.steps.enumerated() {
            if step.queued, let first = step.commands.first {
                let before = store.items
                let persistedBefore = try await decoded(storage)
                let chain = try await enqueue(first, store: store, chain: nil)
                for command in step.commands.dropFirst() { _ = try await enqueue(command, store: store, chain: chain) }
                try discoveryRequire(store.items == before, "store.queue.memory", step: index)
                try discoveryRequire(try await decoded(storage) == persistedBefore, "store.queue.persistence", step: index)
                try await chain.run()
                let once = store.items
                try await chain.run()
                try discoveryRequire(store.items == once, "store.queue.repeat", step: index)
                coverage.hit("queued")
                coverage.hit("chain-length-\(step.commands.count)")
            } else {
                for command in step.commands { try await execute(command, store: store) }
            }
            for command in step.commands {
                if command.kind == .insert || command.kind == .batch {
                    coverage.hit("overwrites", by: command.items.filter { new in model.items.contains { $0.id == new.id } }.count)
                    if command.items.isEmpty { coverage.hit("empty-batch") }
                    if Set(command.items.map(\.id)).count < command.items.count { coverage.hit("duplicate-batch") }
                }
                if command.kind == .remove || command.kind == .removeBatch {
                    coverage.hit("existing-removals", by: model.items.filter { old in command.items.contains { $0.id == old.id } }.count)
                }
                model.apply(command)
                coverage.hit(command.kind.rawValue)
            }
            try discoveryRequire(store.items == model.items, "store.memory", step: index)
            if step.observe || step.reopen || index == scenario.steps.count - 1 {
                try discoveryRequire(try await decoded(storage) == sorted(model.items), "store.persistence", step: index)
                coverage.hit("persistence-read")
            } else { coverage.hit("delayed-persistence-read") }
            coverage.hit("size-\(model.items.count / 8)")
            if step.reopen {
                if let reopenStorage { storage = try reopenStorage() }
                store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
                try discoveryRequire(sorted(store.items) == sorted(model.items), "store.reopen", step: index)
                // Backend loading order is unspecified. Adopt only ordering, after
                // independently verifying exact identity/payload/multiplicity.
                model.items = store.items.map { loaded in model.items.first { $0.id == loaded.id }! }
                coverage.hit("reopen")
            }
        }
    }

    private func sorted(_ items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] { items.sorted { $0.id < $1.id } }
    private func decoded(_ storage: any StorageEngine) async throws -> [StoreDiscoveryItem] {
        let items = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        try discoveryRequire(Set(items.map(\.id)).count == items.count, "store.persisted-duplicate-identity", step: -1)
        return sorted(items)
    }

    private func execute(_ command: StoreDiscoveryCommand, store: Store<StoreDiscoveryItem>) async throws {
        switch command.kind {
        case .insert: try await store.insert(command.items[0]) as Void
        case .batch: try await store.insert(command.items) as Void
        case .remove: try await store.remove(command.items[0]) as Void
        case .removeBatch: try await store.remove(command.items) as Void
        case .clear: try await store.removeAll() as Void
        }
    }
    private func enqueue(_ command: StoreDiscoveryCommand, store: Store<StoreDiscoveryItem>, chain: Store<StoreDiscoveryItem>.Operation?) async throws -> Store<StoreDiscoveryItem>.Operation {
        if let chain {
            switch command.kind {
            case .insert: return try await chain.insert(command.items[0])
            case .batch: return try await chain.insert(command.items)
            case .remove: return try await chain.remove(command.items[0])
            case .removeBatch: return try await chain.remove(command.items)
            case .clear: return try await chain.removeAll()
            }
        }
        switch command.kind {
        case .insert: return try await store.insert(command.items[0])
        case .batch: return try await store.insert(command.items)
        case .remove: return try await store.remove(command.items[0])
        case .removeBatch: return try await store.remove(command.items)
        case .clear: return try await store.removeAll()
        }
    }
}
