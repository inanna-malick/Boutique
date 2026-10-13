import Foundation
import Testing
@testable import Boutique

private struct SharedClearRecord: Codable, Equatable, Sendable {
    let id: String
    let payload: Int
}

@MainActor
@Suite("Shared storage clear standalone reproduction")
struct StoreSharedClearReproductionTests {
    @Test(arguments: ["disk", "sqlite"], [false, true])
    func directClearRemovesOtherStoresRecord(backend: String, batch: Bool) async throws {
        try await reproduce(backend: backend, batch: batch, fused: false)
    }

    @Test(arguments: ["disk", "sqlite"], [false, true])
    func fusedClearRemovesOtherStoresRecord(backend: String, batch: Bool) async throws {
        try await reproduce(backend: backend, batch: batch, fused: true)
    }

    private func reproduce(backend: String, batch: Bool, fused: Bool) async throws {
        let directory = FileManager.Directory.temporary(appendingPath: "SharedClear.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let storage: any StorageEngine
        if backend == "disk" { storage = DiskStorageEngine(directory: directory) }
        else { storage = try #require(SQLiteStorageEngine(directory: directory)) }
        let first = try await Store<SharedClearRecord>(storage: storage, cacheIdentifier: \.id)
        let second = try await Store<SharedClearRecord>(storage: storage, cacheIdentifier: \.id)
        let original = SharedClearRecord(id: "original", payload: 1)
        let replacement = SharedClearRecord(id: "replacement", payload: 2)
        try await first.insert(original) as Void

        // Every call succeeds sequentially; no cross-instance cache refresh is assumed.
        if fused {
            let operation: Store<SharedClearRecord>.Operation = try await second.removeAll()
            if batch { try await operation.insert([replacement]).run() }
            else { try await operation.insert(replacement).run() }
        } else {
            try await second.removeAll() as Void
            if batch { try await second.insert([replacement]) as Void }
            else { try await second.insert(replacement) as Void }
        }
        #expect(second.items == [replacement])
        let persisted = try await storage.readAllData().map { try JSONDecoder().decode(SharedClearRecord.self, from: $0) }
        #expect(persisted == [replacement])
        let reopened = try await Store<SharedClearRecord>(storage: storage, cacheIdentifier: \.id)
        #expect(reopened.items == [replacement])
    }
}
