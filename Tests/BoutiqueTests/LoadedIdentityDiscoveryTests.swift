import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct LoadedIdentityItem: Codable, Equatable, Sendable {
    let id: String
    let alternate: String
    let payload: Int
}

private struct LoadedIdentityScenario: Codable, Sendable {
    struct Step: Codable, Sendable {
        let key: Int
        let payload: Int
        let remove: Bool
    }
    let steps: [Step]
}

@MainActor
@Suite("Loaded identity invariants", .serialized)
struct LoadedIdentityDiscoveryTests {
    @Test(.shrinking, arguments: ["disk", "sqlite"])
    func stableKeypathControls(backend: String) async throws {
        let step = zip(Gen.int(in: 0...4), Gen.int(in: -20...20), Gen.bool)
            .map { LoadedIdentityScenario.Step(key: $0, payload: $1, remove: $2) }
        let input = step.array(of: 1...40).map { LoadedIdentityScenario(steps: $0) }
        try await DiscoveryProperty.check("loaded-identity-stable-\(backend)",
            count: DiscoveryProperty.backendCases, input: input) { scenario, coverage in
            let directory = FileManager.Directory.temporary(appendingPath: "Boutique.LoadedIdentity.\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let storage = try engine(backend, directory: directory)
            var store = try await Store<LoadedIdentityItem>(storage: storage, cacheIdentifier: \.id)
            var model: [LoadedIdentityItem] = []
            for (index, command) in scenario.steps.enumerated() {
                let item = LoadedIdentityItem(id: "old-\(command.key)", alternate: "new-\(command.key)", payload: command.payload)
                if command.remove {
                    try await store.remove(item)
                    model.removeAll { $0.id == item.id }
                } else {
                    try await store.insert(item)
                    if let found = model.firstIndex(where: { $0.id == item.id }) { model[found] = item }
                    else { model.append(item) }
                }
                try discoveryRequire(store.items == model, "loaded-identity.memory", step: index)
                let persisted = try await storage.readAllData().map { try JSONDecoder().decode(LoadedIdentityItem.self, from: $0) }
                try discoveryRequire(persisted.count == model.count && Set(persisted.map(\.id)).count == model.count,
                    "loaded-identity.multiplicity", step: index)
                try discoveryRequire(persisted.sorted { $0.id < $1.id } == model.sorted { $0.id < $1.id },
                    "loaded-identity.persisted-values", step: index)
                store = try await Store<LoadedIdentityItem>(storage: storage, cacheIdentifier: \.id)
                try discoveryRequire(store.items.sorted { $0.id < $1.id } == model.sorted { $0.id < $1.id },
                    "loaded-identity.reopen", step: index)
                // Reload order is unspecified; retain model-owned values in observed order.
                model = store.items.map { observed in model.first { $0.id == observed.id }! }
                coverage.hit("reopen.then.\(command.remove ? "remove" : "insert")")
            }
        }
    }

    // Contract-dependent characterization: both keypaths are individually stable
    // and unique, but switching the persistence identity policy is undocumented.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_LOADED_IDENTITY_MIGRATION"] == "1"),
          arguments: ["disk", "sqlite"])
    func migrationCharacterization(backend: String) async throws {
        let directory = FileManager.Directory.temporary(appendingPath: "Boutique.LoadedIdentityMigration.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let storage = try engine(backend, directory: directory)
        let first = LoadedIdentityItem(id: "old-0", alternate: "new-0", payload: 0)
        let updated = LoadedIdentityItem(id: "old-0", alternate: "new-0", payload: 1)
        let old = try await Store<LoadedIdentityItem>(storage: storage, cacheIdentifier: \.id)
        try await old.insert(first)
        let migrated = try await Store<LoadedIdentityItem>(storage: storage, cacheIdentifier: \.alternate)
        #expect(migrated.items == [first])
        try await migrated.insert(updated)
        #expect(migrated.items == [updated])
        let reopened = try await Store<LoadedIdentityItem>(storage: storage, cacheIdentifier: \.alternate)
        #expect(reopened.items.count == 2)
        #expect(Set(reopened.items.map(\.alternate)).count == 1)
        if ProcessInfo.processInfo.environment["BOUTIQUE_LOADED_IDENTITY_TRAP"] == "1" {
            // Run only in a separate test process: OrderedDictionary precondition.
            try await reopened.insert(LoadedIdentityItem(id: "old-1", alternate: "new-1", payload: 2))
        } else {
            try await reopened.remove(updated)
            #expect(reopened.items.isEmpty)
            let remaining = try await storage.readAllData().map { try JSONDecoder().decode(LoadedIdentityItem.self, from: $0) }
            #expect(remaining == [first])
        }
    }

    private func engine(_ backend: String, directory: FileManager.Directory) throws -> any StorageEngine {
        if backend == "disk" { return DiskStorageEngine(directory: directory) }
        guard let storage = SQLiteStorageEngine(directory: directory) else {
            throw DiscoveryFailure(invariant: "loaded-identity.fixture", step: -1, detail: "Cannot create SQLite engine")
        }
        return storage
    }
}
