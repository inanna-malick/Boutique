import Foundation
import Testing
@testable import Boutique

// Standalone regression: no PropertyBased, discovery storage, or reference-model
// dependency. The backend intentionally commits one batch entry before throwing.
private struct PartialClearRecord: Codable, Sendable, Equatable {
    let id: String
    let payload: Int
}

private actor PartialClearStorage: StorageEngine {
    enum Failure: Error { case committedFirstBatchEntry }
    private var records: [CacheKey: Data] = [:]
    private var failNextBatch = true

    func write(_ data: Data, key: CacheKey) { records[key] = data }
    func write(_ entries: [(key: CacheKey, data: Data)]) throws {
        let shouldFail = failNextBatch
        failNextBatch = false
        for entry in entries {
            records[entry.key] = entry.data
            if shouldFail { throw Failure.committedFirstBatchEntry }
        }
    }
    func remove(key: CacheKey) { records.removeValue(forKey: key) }
    func remove(keys: [CacheKey]) { for key in keys { records.removeValue(forKey: key) } }
    func removeAllData() { records.removeAll() }
    func readAllData() -> [Data] { Array(records.values) }
    func read(key: CacheKey) -> Data? { records[key] }
    func readDataAndKeys(keys: [CacheKey]) -> [(key: CacheKey, data: Data)] {
        keys.compactMap { key in records[key].map { (key, $0) } }
    }
    func allKeys() -> [CacheKey] { Array(records.keys) }
    func keyExists(_ key: CacheKey) -> Bool { records[key] != nil }
    func createdAt(key: CacheKey) -> Date? { nil }
    func updatedAt(key: CacheKey) -> Date? { nil }
}

@MainActor
@Suite("Partial failure clear standalone reproduction")
struct StorePartialFailureClearReproductionTests {
    @Test(arguments: [false, true])
    func directClearRemovesPartiallyCommittedRecord(batchReplacement: Bool) async throws {
        try await reproduce(fused: false, batchReplacement: batchReplacement)
    }

    @Test(arguments: [false, true])
    func successfulFusedClearRemovesPartiallyCommittedRecord(batchReplacement: Bool) async throws {
        try await reproduce(fused: true, batchReplacement: batchReplacement)
    }

    private func reproduce(fused: Bool, batchReplacement: Bool) async throws {
        let storage = PartialClearStorage()
        let store = try await Store<PartialClearRecord>(storage: storage, cacheIdentifier: \.id)
        let committed = PartialClearRecord(id: "committed", payload: 1)
        let uncommitted = PartialClearRecord(id: "uncommitted", payload: 2)
        var threwExpectedError = false
        do { try await store.insert([committed, uncommitted]) as Void }
        catch PartialClearStorage.Failure.committedFirstBatchEntry { threwExpectedError = true }
        #expect(threwExpectedError)
        let afterFailure = try await storage.readAllData().map { try JSONDecoder().decode(PartialClearRecord.self, from: $0) }
        #expect(afterFailure == [committed])
        // No assertion requires failed-call memory rollback or reconciliation.
        let replacement = PartialClearRecord(id: "replacement", payload: 3)
        if fused {
            let operation: Store<PartialClearRecord>.Operation = try await store.removeAll()
            if batchReplacement { try await operation.insert([replacement]).run() }
            else { try await operation.insert(replacement).run() }
        } else {
            try await store.removeAll() as Void
            if batchReplacement { try await store.insert([replacement]) as Void }
            else { try await store.insert(replacement) as Void }
        }
        #expect(store.items == [replacement])
        let persisted = try await storage.readAllData().map { try JSONDecoder().decode(PartialClearRecord.self, from: $0) }
        #expect(persisted == [replacement])
        let reopened = try await Store<PartialClearRecord>(storage: storage, cacheIdentifier: \.id)
        #expect(reopened.items == [replacement])
    }
}
