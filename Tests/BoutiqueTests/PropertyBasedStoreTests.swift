import Foundation
import Testing
@testable import Boutique

/// Exploratory model-based checks for Store.  The generated traces deliberately
/// use a tiny ID domain: replacement and duplicate interactions should be common.
@MainActor
@Suite("Property based Store checks", .serialized)
struct PropertyBasedStoreTests {
    @Test("generated Store histories agree with an ordered-map model")
    func generatedStoreHistories() async throws {
        for seed in 0..<24 {
            var generator = TraceGenerator(seed: UInt64(seed) &+ 0x9E3779B97F4A7C15)
            let storage = PropertyStorageEngine()
            let store = try await Store<PropertyItem>(storage: storage, cacheIdentifier: \.id)
            var model = OrderedStoreModel()
            var history: [StoreCommand] = []

            for step in 0..<48 {
                let command = generator.action(against: model)
                history.append(command)
                try await Self.apply(command, to: store, model: &model)

                let expected = model.items
                let trace = "seed=\(seed), step=\(step), history=\(history)"
                #expect(store.items == expected, "memory diverged: \(trace)")

                let persisted = await storage.readAllData()
                let persistedItems = try persisted.map { try JSONDecoder().decode(PropertyItem.self, from: $0) }
                #expect(Dictionary(uniqueKeysWithValues: persistedItems.map { ($0.id, $0.payload) }) == model.payloadsByID,
                        "persistence diverged: \(trace)")

                if step.isMultiple(of: 11) {
                    let reloaded = try await Store<PropertyItem>(storage: storage, cacheIdentifier: \.id)
                    let reloadedByID = Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.id, $0.payload) })
                    #expect(reloadedByID == model.payloadsByID, "reload diverged: \(trace)")
                }
            }
        }
    }

    @Test("generated Store events report each direct operation", .timeLimit(.minutes(1)))
    func generatedDirectEvents() async throws {
        for seed in 100..<112 {
            var generator = TraceGenerator(seed: UInt64(seed) &* 0xD1342543DE82EF95)
            let store = try await Store<PropertyItem>(storage: PropertyStorageEngine(), cacheIdentifier: \.id)
            var iterator = store.events.makeAsyncIterator()
            let initial = await iterator.next()
            #expect(initial?.operation == .loaded)
            #expect(initial?.items.isEmpty == true)
            var model = OrderedStoreModel()
            var history: [StoreCommand] = []

            for step in 0..<32 {
                let action = generator.action(against: model)
                history.append(action)
                let expectedEvent = model.event(for: action)
                try await Self.apply(action, to: store, model: &model)

                let actualEvent = await iterator.next()
                #expect(actualEvent?.operation == expectedEvent.operation,
                        "wrong event kind for seed=\(seed), step=\(step), history=\(history)")
                #expect(actualEvent?.items == expectedEvent.items,
                        "wrong event payload for seed=\(seed), step=\(step), history=\(history)")
                #expect(store.items == model.items,
                        "wrong state for seed=\(seed), step=\(step), history=\(history)")
            }
        }
    }

    @Test("all short operation histories agree with the ordered-map model")
    func boundedExhaustiveHistories() async throws {
        // Exhaust all 7^4 histories over a compact partition of operation types:
        // three overwrites, three removes, and clear.
        let alphabet: [StoreCommand] = [
            .insertOne(PropertyItem(id: "a", payload: 0)),
            .insertOne(PropertyItem(id: "a", payload: 1)),
            .insertOne(PropertyItem(id: "b", payload: 0)),
            .removeOne(PropertyItem(id: "a", payload: 0)),
            .removeOne(PropertyItem(id: "a", payload: 1)),
            .removeOne(PropertyItem(id: "b", payload: 0)),
            .removeAll,
        ]

        for encoded in 0..<(7 * 7 * 7 * 7) {
            var digits = encoded
            var history: [StoreCommand] = []
            for _ in 0..<4 {
                history.append(alphabet[digits % alphabet.count])
                digits /= alphabet.count
            }

            let store = try await Store<PropertyItem>(storage: PropertyStorageEngine(), cacheIdentifier: \.id)
            var model = OrderedStoreModel()
            for command in history {
                try await Self.apply(command, to: store, model: &model)
            }
            #expect(store.items == model.items, "history=\(history)")
        }
    }

    @Test("batched mutations match their individual-operation expansion")
    func batchOperationsAreMetamorphic() async throws {
        for seed in 200..<240 {
            var generator = TraceGenerator(seed: UInt64(seed) &* 0xA24BAED4963EE407)
            let batch = (0..<generator.count(8)).map { _ in generator.item() }
            let removals = (0..<generator.count(8)).map { _ in generator.item() }

            let batchStore = try await Store<PropertyItem>(storage: PropertyStorageEngine(), cacheIdentifier: \.id)
            let singlesStore = try await Store<PropertyItem>(storage: PropertyStorageEngine(), cacheIdentifier: \.id)
            try await batchStore.insert(batch)
            for item in batch { try await singlesStore.insert(item) }
            #expect(batchStore.items == singlesStore.items, "insert batch seed=\(seed), items=\(batch)")

            try await batchStore.remove(removals)
            for item in removals { try await singlesStore.remove(item) }
            #expect(batchStore.items == singlesStore.items, "remove batch seed=\(seed), items=\(removals)")
        }
    }

    @Test("run is required and a completed chain runs only once")
    func operationExecutionLifecycle() async throws {
        for seed in 300..<324 {
            var generator = TraceGenerator(seed: UInt64(seed) &* 0x9E3779B185EBCA87)
            let storage = PropertyStorageEngine()
            let store = try await Store<PropertyItem>(storage: storage, cacheIdentifier: \.id)
            var model = OrderedStoreModel()
            var actions: [StoreCommand] = []
            for _ in 0..<generator.count(12) {
                let action = generator.action(against: model)
                actions.append(action)
                model.apply(action)
            }

            guard let first = actions.first else { continue }
            var operation = try await Self.enqueue(first, on: store)
            for action in actions.dropFirst() {
                operation = try await Self.enqueue(action, on: operation)
            }

            let beforeRun = store.items
            #expect(beforeRun.isEmpty, "queued actions ran before run(), seed=\(seed)")
            try await operation.run()
            #expect(store.items == model.items, "seed=\(seed), actions=\(actions)")

            let finished = store.items
            try await operation.run()
            #expect(store.items == finished, "second run changed state, seed=\(seed)")
        }
    }

    @Test("malformed persisted items fail loading and a repaired backend loads cleanly")
    func malformedPersistedItemsAreReportedAndRecoverableByReopening() async throws {
        let malformedPayloads = [
            Data([0xFF, 0x00]),
            Data("{".utf8),
            Data("{\"id\":1,\"payload\":2}".utf8),
            Data("{\"id\":\"missing-payload\"}".utf8),
        ]

        for seed in 0..<32 {
            let storage = PropertyStorageEngine()
            let invalidKey = CacheKey("invalid-\(seed)")
            try await storage.write(malformedPayloads[seed % malformedPayloads.count], key: invalidKey)
            let validItem = PropertyItem(id: "valid-\(seed)", payload: seed)
            try await storage.write(try JSONEncoder().encode(validItem), key: CacheKey(validItem.id))

            // The synchronous initializer starts a load task; awaiting it must surface a
            // decode error and leave the in-memory collection empty.
            let synchronousStore = makeSynchronousPropertyStore(storage: storage)
            var synchronousError: Error?
            do {
                try await synchronousStore.itemsHaveLoaded()
            } catch {
                synchronousError = error
            }
            #expect(synchronousError is DecodingError, "sync load seed=\(seed), error=\(String(describing: synchronousError))")
            #expect(synchronousStore.items.isEmpty, "partial load escaped on seed=\(seed)")

            var asynchronousError: Error?
            do {
                let _: Store<PropertyItem> = try await Store(storage: storage, cacheIdentifier: \.id)
            } catch {
                asynchronousError = error
            }
            #expect(asynchronousError is DecodingError, "async load seed=\(seed), error=\(String(describing: asynchronousError))")

            try await storage.remove(key: invalidKey)
            let repairedStore = try await Store<PropertyItem>(storage: storage, cacheIdentifier: \.id)
            #expect(repairedStore.items == [validItem], "repaired load seed=\(seed)")
        }
    }

    private static func apply(
        _ command: StoreCommand,
        to store: Store<PropertyItem>,
        model: inout OrderedStoreModel
    ) async throws {
        switch command {
        case .insertOne(let item):
            try await store.insert(item)
            model.insert(item)
        case .insertMany(let items):
            try await store.insert(items)
            model.insert(contentsOf: items)
        case .removeOne(let item):
            try await store.remove(item)
            model.remove(item)
        case .removeMany(let items):
            try await store.remove(items)
            model.remove(contentsOf: items)
        case .removeAll:
            try await store.removeAll()
            model.removeAll()
        }
    }

    private static func enqueue(
        _ command: StoreCommand,
        on store: Store<PropertyItem>
    ) async throws -> Store<PropertyItem>.Operation {
        switch command {
        case .insertOne(let item): return try await store.insert(item)
        case .insertMany(let items): return try await store.insert(items)
        case .removeOne(let item): return try await store.remove(item)
        case .removeMany(let items): return try await store.remove(items)
        case .removeAll: return try await store.removeAll()
        }
    }

    private static func enqueue(
        _ command: StoreCommand,
        on operation: Store<PropertyItem>.Operation
    ) async throws -> Store<PropertyItem>.Operation {
        switch command {
        case .insertOne(let item): return try await operation.insert(item)
        case .insertMany(let items): return try await operation.insert(items)
        case .removeOne(let item): return try await operation.remove(item)
        case .removeMany(let items): return try await operation.remove(items)
        case .removeAll: return try await operation.removeAll()
        }
    }
}

private struct PropertyItem: Codable, Sendable, Equatable {
    let id: String
    let payload: Int
}

private enum StoreCommand: Sendable, CustomStringConvertible {
    case insertOne(PropertyItem)
    case insertMany([PropertyItem])
    case removeOne(PropertyItem)
    case removeMany([PropertyItem])
    case removeAll

    var description: String {
        switch self {
        case .insertOne(let item): return "insertOne(\(item))"
        case .insertMany(let items): return "insertMany(\(items))"
        case .removeOne(let item): return "removeOne(\(item))"
        case .removeMany(let items): return "removeMany(\(items))"
        case .removeAll: return "removeAll"
        }
    }
}

private struct OrderedStoreModel {
    private(set) var items: [PropertyItem] = []

    var payloadsByID: [String: Int] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.payload) })
    }

    mutating func insert(_ item: PropertyItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    mutating func insert(contentsOf newItems: [PropertyItem]) {
        for item in newItems { insert(item) }
    }

    mutating func remove(_ item: PropertyItem) {
        items.removeAll { $0.id == item.id }
    }

    mutating func remove(contentsOf removedItems: [PropertyItem]) {
        let identifiers = Set(removedItems.map(\.id))
        items.removeAll { identifiers.contains($0.id) }
    }

    mutating func removeAll() {
        items.removeAll()
    }

    mutating func apply(_ command: StoreCommand) {
        switch command {
        case .insertOne(let item): insert(item)
        case .insertMany(let newItems): insert(contentsOf: newItems)
        case .removeOne(let item): remove(item)
        case .removeMany(let removedItems): remove(contentsOf: removedItems)
        case .removeAll: removeAll()
        }
    }

    func event(for command: StoreCommand) -> StoreEvent<PropertyItem> {
        switch command {
        case .insertOne(let item): return StoreEvent(operation: .insert, items: [item])
        case .insertMany(let items): return StoreEvent(operation: .insert, items: deduplicated(items))
        case .removeOne(let item): return StoreEvent(operation: .remove, items: [item])
        case .removeMany(let items): return StoreEvent(operation: .remove, items: items)
        case .removeAll: return StoreEvent(operation: .remove, items: items)
        }
    }

    private func deduplicated(_ input: [PropertyItem]) -> [PropertyItem] {
        var result: [PropertyItem] = []
        for item in input {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}

private struct TraceGenerator {
    private var random: DiscoveryRandom

    init(seed: UInt64) { random = DiscoveryRandom(seed: seed) }

    private mutating func next() -> UInt64 {

        return random.next()
    }

    mutating func count(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound + 1)) }

    mutating func item() -> PropertyItem {
        PropertyItem(id: "id-\(next() % 6)", payload: Int(next() % 13))
    }

    /// Bias operands toward logical items in the independent model while retaining
    /// absent and never-before-used IDs. This makes overwrites, successful deletes,
    /// and stale-payload removal observable in short histories.
    mutating func action(against model: OrderedStoreModel) -> StoreCommand {
        switch next() % 8 {
        case 0, 1, 2:
            return .insertOne(relatedItem(against: model))
        case 3, 4:
            return .insertMany(relatedItems(maxCount: 5, against: model, removals: false))
        case 5:
            return .removeOne(relatedItem(against: model, forRemoval: true))
        case 6:
            return .removeMany(relatedItems(maxCount: 5, against: model, removals: true))
        default:
            return .removeAll
        }
    }

    private mutating func relatedItem(
        against model: OrderedStoreModel,
        forRemoval: Bool = false
    ) -> PropertyItem {
        if forRemoval, !model.items.isEmpty, next().isMultiple(of: 4) == false {
            let existing = model.items[Int(next() % UInt64(model.items.count))]
            // Deliberately vary payload independently of identity. Store removal is by ID.
            let payload = next().isMultiple(of: 2) ? existing.payload : Int(next() % 13)
            return PropertyItem(id: existing.id, payload: payload)
        }

        let presentIDs = Set(model.items.map(\.id))
        let missingIDs = (0..<6).map { "id-\($0)" }.filter { !presentIDs.contains($0) }
        if !missingIDs.isEmpty, next().isMultiple(of: 3) {
            return PropertyItem(
                id: missingIDs[Int(next() % UInt64(missingIDs.count))],
                payload: Int(next() % 13)
            )
        }
        if !model.items.isEmpty, next().isMultiple(of: 2) {
            let existing = model.items[Int(next() % UInt64(model.items.count))]
            return PropertyItem(id: existing.id, payload: Int(next() % 13))
        }
        return item()
    }

    private mutating func relatedItems(
        maxCount: Int,
        against model: OrderedStoreModel,
        removals: Bool
    ) -> [PropertyItem] {
        let amount = count(maxCount)
        var result: [PropertyItem] = []
        for _ in 0..<amount {
            if !removals, !result.isEmpty, next().isMultiple(of: 4) {
                let prior = result[Int(next() % UInt64(result.count))]
                result.append(PropertyItem(id: prior.id, payload: Int(next() % 13)))
            } else {
                result.append(relatedItem(against: model, forRemoval: removals))
            }
        }
        return result
    }

}

private actor PropertyStorageEngine: StorageEngine {
    private var values: [CacheKey: Data] = [:]

    func write(_ data: Data, key: CacheKey) async throws {
        values[key] = data
    }

    func write(_ dataAndKeys: [(key: CacheKey, data: Data)]) async throws {
        for entry in dataAndKeys { values[entry.key] = entry.data }
    }

    func read(key: CacheKey) async -> Data? { values[key] }

    func readDataAndKeys(keys: [CacheKey]) async -> [(key: CacheKey, data: Data)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }

    func allKeys() async -> [CacheKey] { Array(values.keys) }

    func readAllDataAndKeys() async -> [(key: CacheKey, data: Data)] {
        values.map { (key: $0.key, data: $0.value) }
    }

    func remove(key: CacheKey) async throws { values.removeValue(forKey: key) }

    func removeAllData() async throws { values.removeAll() }

    func keyExists(_ key: CacheKey) async -> Bool { values[key] != nil }

    func createdAt(key: CacheKey) async -> Date? { nil }

    func updatedAt(key: CacheKey) async -> Date? { nil }
}

@MainActor
private func makeSynchronousPropertyStore(storage: StorageEngine) -> Store<PropertyItem> {
    Store(storage: storage, cacheIdentifier: \.id)
}
