import Foundation
import Testing
@testable import Boutique

/// Independent sequence and dictionary models for Store's observable item semantics.
/// These tests exercise the operation-chain API separately from the direct-mutation suite.
@MainActor
@Suite("Store property mirror", .serialized)
struct StorePropertyMirrorTests {
    @Test("generated operation chains match replaying the same operations one by one")
    func generatedChainsMatchReferenceReplay() async throws {
        for seed in 0..<80 {
            var random = StorePropertyRandom(seed: UInt64(seed) &* 0x9E3779B97F4A7C15)
            let storage = StorePropertyStorage()
            let store = try await Store<StorePropertyItem>(storage: storage, cacheIdentifier: \.id)
            var model = StorePropertyModel()
            let initial = random.items(maxCount: 8)
            try await store.insert(initial)
            model.insert(contentsOf: initial)

            let commandCount = random.int(1, 16)
            var commands: [StorePropertyCommand] = []
            var commandModel = model
            for _ in 0..<commandCount {
                let command = random.command(against: commandModel)
                commands.append(command)
                commandModel.apply(command)
            }
            guard let first = commands.first else { continue }
            var chain = try await enqueue(first, on: store)
            for command in commands.dropFirst() {
                chain = try await enqueue(command, on: chain)
            }

            // Chaining only queues work; it must not mutate the Store before run().
            #expect(store.items == model.items, "queued mutation ran early: seed=\(seed), commands=\(commands)")
            try await chain.run()
            for command in commands { model.apply(command) }

            #expect(store.items == model.items, "seed=\(seed), commands=\(commands)")
            #expect(await storage.decodedItems() == model.byID,
                    "persisted values diverged: seed=\(seed), commands=\(commands)")
            let reloaded = try await Store<StorePropertyItem>(storage: storage, cacheIdentifier: \.id)
            #expect(Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.id, $0) }) == model.byID,
                    "reloaded values diverged: seed=\(seed), commands=\(commands)")
        }
    }

    @Test("bounded exhaustive operation-chain histories cover each command kind")
    func exhaustiveShortChains() async throws {
        let itemA0 = StorePropertyItem(id: "a", payload: 0)
        let itemA1 = StorePropertyItem(id: "a", payload: 1)
        let itemB0 = StorePropertyItem(id: "b", payload: 0)
        let commands: [StorePropertyCommand] = [
            .insertOne(itemA0), .insertOne(itemA1), .insertMany([itemB0, itemA0]),
            .removeOne(itemA0), .removeMany([itemB0, itemA1]), .removeAll,
        ]

        // Exhaust all 6^3 traces from a nonempty initial state. This crosses insertion,
        // replacement, singular/batch removal, clear, and the fusion boundaries around inserts.
        for encoded in 0..<(commands.count * commands.count * commands.count) {
            var n = encoded
            var history: [StorePropertyCommand] = []
            for _ in 0..<3 {
                history.append(commands[n % commands.count])
                n /= commands.count
            }

            let storage = StorePropertyStorage()
            let store = try await Store<StorePropertyItem>(storage: storage, cacheIdentifier: \.id)
            let initial = [StorePropertyItem(id: "a", payload: 7), itemB0]
            try await store.insert(initial)
            var model = StorePropertyModel()
            model.insert(contentsOf: initial)

            guard let first = history.first else { continue }
            var chain = try await enqueue(first, on: store)
            for command in history.dropFirst() { chain = try await enqueue(command, on: chain) }
            try await chain.run()
            for command in history { model.apply(command) }

            #expect(store.items == model.items, "trace=\(history)")
            #expect(await storage.decodedItems() == model.byID, "persisted trace=\(history)")
        }
    }

    @Test("Identifiable String convenience initializer matches the explicit key path")
    func stringIdentifiableInitializersAgree() async throws {
        for seed in 0..<32 {
            var random = StorePropertyRandom(seed: UInt64(seed) &* 0xD1342543DE82EF95)
            let initial = random.items(maxCount: 10)
            let convenienceStorage = StorePropertyStorage()
            let explicitStorage = StorePropertyStorage()
            let convenience = try await Store<StringIDPropertyItem>(storage: convenienceStorage)
            let explicit = try await Store<StringIDPropertyItem>(storage: explicitStorage, cacheIdentifier: \.id)

            try await convenience.insert(initial)
            try await explicit.insert(initial)
            for _ in 0..<12 {
                let item = StringIDPropertyItem(id: "id-\(random.int(0, 5))", payload: random.int(-9, 9))
                switch random.int(0, 3) {
                case 0: try await convenience.insert(item); try await explicit.insert(item)
                case 1: try await convenience.remove(item); try await explicit.remove(item)
                case 2:
                    let batch = random.items(maxCount: 4)
                    try await convenience.insert(batch); try await explicit.insert(batch)
                default:
                    try await convenience.removeAll(); try await explicit.removeAll()
                }
                #expect(convenience.items == explicit.items, "seed=\(seed)")
                let conveniencePersisted = await convenienceStorage.decodedStringItems()
                let explicitPersisted = await explicitStorage.decodedStringItems()
                #expect(conveniencePersisted == explicitPersisted, "persistence seed=\(seed)")
            }
        }
    }

    @Test("synchronous String Identifiable initialization finishes loading persisted values")
    func synchronousStringInitializerLoadsPersistedValues() async throws {
        for seed in 0..<24 {
            var random = StorePropertyRandom(seed: UInt64(seed) &* 0x94D049BB133111EB)
            let expectedItems = random.items(maxCount: 10)
            let storage = StorePropertyStorage()
            let writer = try await Store<StringIDPropertyItem>(storage: storage)
            try await writer.insert(expectedItems)

            let convenience = makeSynchronousStringStore(storage: storage)
            let explicit = makeSynchronousStringStore(storage: storage, keyPath: \.id)
            try await convenience.itemsHaveLoaded()
            try await explicit.itemsHaveLoaded()

            var expected: [String: StringIDPropertyItem] = [:]
            for item in expectedItems { expected[item.id] = item }
            #expect(Dictionary(uniqueKeysWithValues: convenience.items.map { ($0.id, $0) }) == expected,
                    "sync convenience load seed=\(seed)")
            #expect(Dictionary(uniqueKeysWithValues: explicit.items.map { ($0.id, $0) }) == expected,
                    "sync explicit load seed=\(seed)")
        }
    }

    @Test("Identifiable UUID convenience initializer matches uuidString key path")
    func uuidIdentifiableInitializersAgree() async throws {
        for seed in 0..<32 {
            var random = StorePropertyRandom(seed: UInt64(seed) &* 0xA24BAED4963EE407)
            let convenienceStorage = StorePropertyStorage()
            let explicitStorage = StorePropertyStorage()
            let convenience = try await Store<UUIDIDPropertyItem>(storage: convenienceStorage)
            let explicit = try await Store<UUIDIDPropertyItem>(storage: explicitStorage, cacheIdentifier: \.id.uuidString)
            var model = [UUID: UUIDIDPropertyItem]()

            for _ in 0..<24 {
                let removing = random.int(0, 3) == 0
                let item = random.uuidItem(against: model, forRemoval: removing)
                if removing {
                    try await convenience.remove(item)
                    try await explicit.remove(item)
                    model.removeValue(forKey: item.id)
                } else {
                    try await convenience.insert(item)
                    try await explicit.insert(item)
                    model[item.id] = item
                }
                #expect(Dictionary(uniqueKeysWithValues: convenience.items.map { ($0.id, $0) }) == model,
                        "convenience UUID state seed=\(seed)")
                #expect(Dictionary(uniqueKeysWithValues: explicit.items.map { ($0.id, $0) }) == model,
                        "explicit UUID state seed=\(seed)")
                let conveniencePersisted = await convenienceStorage.decodedUUIDItems()
                let explicitPersisted = await explicitStorage.decodedUUIDItems()
                #expect(conveniencePersisted == explicitPersisted, "UUID persistence seed=\(seed)")
            }
        }
    }

    @Test("one-shot storage faults surface and a subsequent operation can proceed")
    func storageFaultsCanBeReproducedAndRecovered() async throws {
        let storage = StorePropertyStorage()
        let store = try await Store<StorePropertyItem>(storage: storage, cacheIdentifier: \.id)
        let original = StorePropertyItem(id: "stable", payload: 1)
        try await store.insert(original)

        await storage.failNext(.write)
        do {
            try await store.insert(StorePropertyItem(id: "failed-write", payload: 2))
            Issue.record("expected injected write error")
        } catch StorePropertyStorage.Failure.injected {
            // Store propagates the storage error. Post-error state is intentionally not
            // asserted here: transaction atomicity is not stated as a public contract.
        }
        try await store.insert(StorePropertyItem(id: "after-write-failure", payload: 3))
        #expect(store.items.contains(StorePropertyItem(id: "after-write-failure", payload: 3)))

        await storage.failNext(.remove)
        do {
            try await store.remove(original)
            Issue.record("expected injected remove error")
        } catch StorePropertyStorage.Failure.injected {
            // As above, this checks propagation and continued usability, not rollback.
        }
        try await store.insert(StorePropertyItem(id: "after-remove-failure", payload: 4))
        #expect(store.items.contains(StorePropertyItem(id: "after-remove-failure", payload: 4)))
    }

    private func enqueue(_ command: StorePropertyCommand, on store: Store<StorePropertyItem>) async throws -> Store<StorePropertyItem>.Operation {
        switch command {
        case .insertOne(let item): return try await store.insert(item)
        case .insertMany(let items): return try await store.insert(items)
        case .removeOne(let item): return try await store.remove(item)
        case .removeMany(let items): return try await store.remove(items)
        case .removeAll: return try await store.removeAll()
        }
    }

    private func enqueue(_ command: StorePropertyCommand, on operation: Store<StorePropertyItem>.Operation) async throws -> Store<StorePropertyItem>.Operation {
        switch command {
        case .insertOne(let item): return try await operation.insert(item)
        case .insertMany(let items): return try await operation.insert(items)
        case .removeOne(let item): return try await operation.remove(item)
        case .removeMany(let items): return try await operation.remove(items)
        case .removeAll: return try await operation.removeAll()
        }
    }
}

private struct StorePropertyItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let payload: Int
}

private struct StringIDPropertyItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let payload: Int
}

private struct UUIDIDPropertyItem: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let payload: Int
}

private enum StorePropertyCommand: CustomStringConvertible {
    case insertOne(StorePropertyItem)
    case insertMany([StorePropertyItem])
    case removeOne(StorePropertyItem)
    case removeMany([StorePropertyItem])
    case removeAll

    var description: String {
        switch self {
        case .insertOne(let item): "insert(\(item))"
        case .insertMany(let items): "insertMany(\(items))"
        case .removeOne(let item): "remove(\(item))"
        case .removeMany(let items): "removeMany(\(items))"
        case .removeAll: "removeAll"
        }
    }
}

private struct StorePropertyModel {
    private(set) var items: [StorePropertyItem] = []
    var byID: [String: StorePropertyItem] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }

    mutating func insert(_ item: StorePropertyItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }

    mutating func insert(contentsOf newItems: [StorePropertyItem]) {
        for item in newItems { insert(item) }
    }

    mutating func remove(_ item: StorePropertyItem) { items.removeAll { $0.id == item.id } }
    mutating func remove(contentsOf removed: [StorePropertyItem]) {
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
    }
    mutating func apply(_ command: StorePropertyCommand) {
        switch command {
        case .insertOne(let item): insert(item)
        case .insertMany(let items): insert(contentsOf: items)
        case .removeOne(let item): remove(item)
        case .removeMany(let items): remove(contentsOf: items)
        case .removeAll: items.removeAll()
        }
    }
}

private struct StorePropertyRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func int(_ lower: Int, _ upper: Int) -> Int { lower + Int(next() % UInt64(upper - lower + 1)) }
    mutating func item() -> StorePropertyItem { StorePropertyItem(id: "id-\(int(0, 5))", payload: int(-20, 20)) }
    mutating func items(maxCount: Int) -> [StorePropertyItem] {
        let count = int(0, maxCount)
        var result: [StorePropertyItem] = []
        for _ in 0..<count { result.append(item()) }
        return result
    }
    mutating func command(against model: StorePropertyModel) -> StorePropertyCommand {
        switch int(0, 4) {
        case 0: .insertOne(item(against: model))
        case 1: .insertMany(items(maxCount: 5, against: model, forRemoval: false))
        case 2: .removeOne(item(against: model, forRemoval: true))
        case 3: .removeMany(items(maxCount: 5, against: model, forRemoval: true))
        default: .removeAll
        }
    }

    private mutating func item(against model: StorePropertyModel, forRemoval: Bool = false) -> StorePropertyItem {
        if forRemoval, !model.items.isEmpty, int(0, 3) != 0 {
            let existing = model.items[int(0, model.items.count - 1)]
            let payload = int(0, 1) == 0 ? existing.payload : int(-20, 20)
            return StorePropertyItem(id: existing.id, payload: payload)
        }

        if !model.items.isEmpty, int(0, 2) != 0 {
            let existing = model.items[int(0, model.items.count - 1)]
            return StorePropertyItem(id: existing.id, payload: int(-20, 20))
        }
        return item()
    }

    private mutating func items(
        maxCount: Int,
        against model: StorePropertyModel,
        forRemoval: Bool
    ) -> [StorePropertyItem] {
        var result: [StorePropertyItem] = []
        for _ in 0..<int(0, maxCount) {
            if !forRemoval, !result.isEmpty, int(0, 3) == 0 {
                let existing = result[int(0, result.count - 1)]
                result.append(StorePropertyItem(id: existing.id, payload: int(-20, 20)))
            } else {
                result.append(item(against: model, forRemoval: forRemoval))
            }
        }
        return result
    }
    mutating func uuid() -> UUID {
        // UUID construction is deterministic and intentionally independent from Store.
        let high = next()
        let low = next()
        let text = String(format: "%08x-%04x-%04x-%04x-%012llx",
                          UInt32(truncatingIfNeeded: high >> 32),
                          UInt16(truncatingIfNeeded: high >> 16),
                          UInt16(truncatingIfNeeded: high),
                          UInt16(truncatingIfNeeded: low >> 48),
                          low & 0x0000_FFFF_FFFF_FFFF)
        return UUID(uuidString: text)!
    }

    mutating func uuidItem(
        against model: [UUID: UUIDIDPropertyItem],
        forRemoval: Bool
    ) -> UUIDIDPropertyItem {
        let existingItems = model.values.sorted { $0.id.uuidString < $1.id.uuidString }
        if !existingItems.isEmpty,
           (forRemoval ? int(0, 3) != 0 : int(0, 1) == 0) {
            let existing = existingItems[int(0, existingItems.count - 1)]
            return UUIDIDPropertyItem(id: existing.id, payload: int(-30, 30))
        }

        var identifier = uuid()
        while model[identifier] != nil { identifier = uuid() }
        return UUIDIDPropertyItem(id: identifier, payload: int(-30, 30))
    }
}

private actor StorePropertyStorage: StorageEngine {
    enum Failure: Error { case injected }
    enum OperationKind: Equatable { case write, remove }
    private var values: [CacheKey: Data] = [:]
    private var nextFailure: OperationKind?

    func failNext(_ kind: OperationKind) { nextFailure = kind }
    private func failIfNeeded(_ kind: OperationKind) throws {
        guard nextFailure == kind else { return }
        nextFailure = nil
        throw Failure.injected
    }

    func write(_ data: Data, key: CacheKey) async throws {
        try failIfNeeded(.write)
        values[key] = data
    }
    func write(_ dataAndKeys: [(key: CacheKey, data: Data)]) async throws {
        try failIfNeeded(.write)
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
    func remove(key: CacheKey) async throws {
        try failIfNeeded(.remove)
        values.removeValue(forKey: key)
    }
    func remove(keys: [CacheKey]) async throws {
        try failIfNeeded(.remove)
        for key in keys { values.removeValue(forKey: key) }
    }
    func removeAllData() async throws {
        try failIfNeeded(.remove)
        values.removeAll()
    }
    func keyExists(_ key: CacheKey) async -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) async -> Date? { nil }
    func updatedAt(key: CacheKey) async -> Date? { nil }

    private func decodeStoreItems() throws -> [String: StorePropertyItem] {
        try Dictionary(uniqueKeysWithValues: values.values.map {
            let item = try JSONCoders.decoder.decode(StorePropertyItem.self, from: $0)
            return (item.id, item)
        })
    }
    func decodedItems() async -> [String: StorePropertyItem] {
        (try? decodeStoreItems()) ?? [:]
    }
    func decodedStringItems() -> [String: StringIDPropertyItem] {
        (try? Dictionary(uniqueKeysWithValues: values.values.map {
            let item = try JSONCoders.decoder.decode(StringIDPropertyItem.self, from: $0)
            return (item.id, item)
        })) ?? [:]
    }
    func decodedUUIDItems() -> [String: UUIDIDPropertyItem] {
        (try? Dictionary(uniqueKeysWithValues: values.values.map {
            let item = try JSONCoders.decoder.decode(UUIDIDPropertyItem.self, from: $0)
            return (item.id.uuidString, item)
        })) ?? [:]
    }
}

@MainActor
private func makeSynchronousStringStore(
    storage: StorePropertyStorage,
    keyPath: KeyPath<StringIDPropertyItem, String>? = nil
) -> Store<StringIDPropertyItem> {
    if let keyPath {
        return Store(storage: storage, cacheIdentifier: keyPath)
    }
    return Store(storage: storage)
}
