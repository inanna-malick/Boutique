import Foundation
import Testing
@testable import Boutique

@MainActor
@Suite("Store fused removal persistence")
struct StoreFusedRemovalTests {
    enum Backend: String, CaseIterable, Sendable {
        case disk, sqlite

        func makeStorage(directory: FileManager.Directory) throws -> any StorageEngine {
            switch self {
            case .disk:
                return DiskStorageEngine(directory: directory)
            case .sqlite:
                return try #require(SQLiteStorageEngine(directory: directory))
            }
        }
    }

    enum Removal: String, CaseIterable, Sendable {
        case all, oneItemBatch, multipleItemBatch
    }

    enum Insertion: String, CaseIterable, Sendable {
        case single, batch, emptyBatch
    }

    @Test("Fused removals use the same persistence keys as inserts",
          arguments: Backend.allCases, Removal.allCases)
    func fusedRemovalsPersist(backend: Backend, removal: Removal) async throws {
        for insertion in Insertion.allCases {
            let context = "backend=\(backend), removal=\(removal), insertion=\(insertion)"
            let directory = FileManager.Directory.temporary(
                appendingPath: "Boutique-FusedRemoval-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory.url) }

            let storage = try backend.makeStorage(directory: directory)
            let store = try await Store<FusedRemovalItem>(storage: storage, cacheIdentifier: \.id)
            let first = FusedRemovalItem(id: "first/é", payload: 1)
            let second = FusedRemovalItem(id: "second", payload: 2)
            let keeper = FusedRemovalItem(id: "keeper", payload: 3)
            let initial = [first, second, keeper]
            try await store.insert(initial)
            try #require(store.items == initial, "\(context)")
            try #require(await storage.keyCount() == initial.count, "\(context)")

            var operation: Store<FusedRemovalItem>.Operation
            let survivors: [FusedRemovalItem]
            switch removal {
            case .all:
                operation = try await store.removeAll()
                survivors = []
            case .oneItemBatch:
                // The array overload participates in fusion even with one item.
                operation = try await store.remove([first])
                survivors = [second, keeper]
            case .multipleItemBatch:
                operation = try await store.remove([first, second])
                survivors = [keeper]
            }

            let newItem = FusedRemovalItem(id: "new", payload: 4)
            let otherNewItem = FusedRemovalItem(id: "other-new", payload: 5)
            let inserted: [FusedRemovalItem]
            switch insertion {
            case .single:
                operation = try await operation.insert(newItem)
                inserted = [newItem]
            case .batch:
                operation = try await operation.insert([newItem, otherNewItem])
                inserted = [newItem, otherNewItem]
            case .emptyBatch:
                operation = try await operation.insert([FusedRemovalItem]())
                inserted = []
            }

            #expect(store.items == initial, "queued operations ran early: \(context)")
            try await operation.run()

            let expected = survivors + inserted
            #expect(store.items == expected, "\(context)")
            #expect(await storage.keyCount() == expected.count, "\(context)")

            // A fresh engine must see the same values, including surviving payloads.
            // Loading order is backend-specific, so compare in identifier order.
            let reopenedStorage = try backend.makeStorage(directory: directory)
            let reopened = try await Store<FusedRemovalItem>(storage: reopenedStorage, cacheIdentifier: \.id)
            #expect(reopened.items.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id },
                    "reopened values: \(context)")
        }
    }
}

private struct FusedRemovalItem: Codable, Sendable, Equatable {
    let id: String
    let payload: Int
}
