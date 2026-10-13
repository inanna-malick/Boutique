import Foundation
import Testing
@testable import Boutique

@MainActor
@Suite("Store empty-batch clear regression")
struct StoreEmptyBatchClearRegressionTests {
    @Test("an empty insert chained after removeAll still clears persisted items")
    func emptyInsertDoesNotCancelClear() async throws {
        let storage = ClearRegressionStorage()
        let store = try await Store<ClearRegressionItem>(storage: storage, cacheIdentifier: \.id)
        try await store.insert([
            ClearRegressionItem(id: "first", payload: 1),
            ClearRegressionItem(id: "second", payload: 2),
        ])

        #expect(store.items.count == 2)
        #expect(await storage.keyCount() == 2)

        var operation: Store<ClearRegressionItem>.Operation = try await store.removeAll()
        operation = try await operation.insert([ClearRegressionItem]())
        try await operation.run()

        #expect(store.items.isEmpty)
        #expect(await storage.keyCount() == 0)
        let reopened = try await Store<ClearRegressionItem>(storage: storage, cacheIdentifier: \.id)
        #expect(reopened.items.isEmpty)
    }
}

private struct ClearRegressionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let payload: Int
}

private actor ClearRegressionStorage: StorageEngine {
    private var values: [CacheKey: Data] = [:]

    func write(_ data: Data, key: CacheKey) async throws { values[key] = data }
    func write(_ dataAndKeys: [(key: CacheKey, data: Data)]) async throws {
        for entry in dataAndKeys { values[entry.key] = entry.data }
    }
    func read(key: CacheKey) async -> Data? { values[key] }
    func readDataAndKeys(keys: [CacheKey]) async -> [(key: CacheKey, data: Data)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }
    func allKeys() async -> [CacheKey] { Array(values.keys) }
    func remove(key: CacheKey) async throws { values.removeValue(forKey: key) }
    func removeAllData() async throws { values.removeAll() }
    func keyExists(_ key: CacheKey) async -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) async -> Date? { nil }
    func updatedAt(key: CacheKey) async -> Date? { nil }
}
