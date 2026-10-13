import Foundation
import Testing
@testable import Boutique

/// Deterministic reproductions for the mismatch between Swift String equality
/// and Bodega's representation-sensitive CacheKey(String).
@MainActor
@Suite("Store canonical identifier regressions", .serialized)
struct StoreIdentityRegressionTests {
    private let equivalentIDs = ("é", "e\u{301}")

    @Test(arguments: ["disk", "sqlite"])
    func alternateSpellingOverwritePersistsOneRecord(backend: String) async throws {
        let (storage, directory) = try makeStorage(backend: backend)
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let store = try await Store<RegressionItem>(storage: storage, cacheIdentifier: \.id)
        let (composed, decomposed) = equivalentIDs

        try await store.insert(RegressionItem(id: composed, payload: 0))
        let replacement = RegressionItem(id: decomposed, payload: 1)
        try await store.insert(replacement)

        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        #expect(store.items == [replacement])
        let persisted = try await readItems(from: storage)
        #expect(persisted == [replacement])
    }

    @Test(arguments: ["disk", "sqlite"])
    func alternateSpellingRemovalDeletesPersistedRecord(backend: String) async throws {
        let (storage, directory) = try makeStorage(backend: backend)
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let store = try await Store<RegressionItem>(storage: storage, cacheIdentifier: \.id)
        let (composed, decomposed) = equivalentIDs
        try await store.insert(RegressionItem(id: composed, payload: 0))

        try await store.remove(RegressionItem(id: decomposed, payload: -1))

        #expect(store.items.isEmpty)
        let persisted = try await readItems(from: storage)
        #expect(persisted.isEmpty)
    }

    @Test(arguments: ["disk", "sqlite"])
    func batchOverwriteOfPreseededLegacyRecordLeavesOneRecord(backend: String) async throws {
        let (storage, directory) = try makeStorage(backend: backend)
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let (composed, decomposed) = equivalentIDs
        let legacy = RegressionItem(id: composed, payload: 0)
        try await storage.write(try JSONEncoder().encode(legacy), key: CacheKey(composed))
        let store = try await Store<RegressionItem>(storage: storage, cacheIdentifier: \.id)
        let replacement = RegressionItem(id: decomposed, payload: 1)

        try await store.insert([legacy, replacement])

        #expect(store.items == [replacement])
        let persisted = try await readItems(from: storage)
        #expect(persisted == [replacement])
    }

    private func makeStorage(backend: String) throws -> (any StorageEngine, FileManager.Directory) {
        let directory = FileManager.Directory.temporary(appendingPath: "Boutique.IdentityRegression.\(UUID())")
        if backend == "disk" { return (DiskStorageEngine(directory: directory), directory) }
        guard let sqlite = SQLiteStorageEngine(directory: directory) else {
            throw RegressionFailure.cannotCreateSQLite
        }
        return (sqlite, directory)
    }

    private func readItems(from storage: any StorageEngine) async throws -> [RegressionItem] {
        try await storage.readAllData().map { try JSONDecoder().decode(RegressionItem.self, from: $0) }
    }
}

private struct RegressionItem: Codable, Equatable, Sendable {
    let id: String
    let payload: Int
}

private enum RegressionFailure: Error {
    case cannotCreateSQLite
}
