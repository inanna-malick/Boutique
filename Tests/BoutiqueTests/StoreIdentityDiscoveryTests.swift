import Foundation
import PropertyBased
import Testing
@testable import Boutique

/// Store uses Swift String equality for its in-memory identity map. These checks
/// ask whether the persistence layer agrees for canonically equivalent spellings.
@MainActor
@Suite("Store identity representation discovery", .serialized)
struct StoreIdentityDiscoveryTests {
    private func scenarios() -> Generator<IdentityScenario, some Sequence> {
        let command = zip(Gen.int(in: 0...3), Gen.bool, Gen.int(in: 0...3))
            .map { IdentityCommand(kind: [.insert, .insertBatch, .remove, .removeBatch][$0], alternate: $1, delta: $2) }
        return zip(Gen.int(in: 0...3), Gen.int(in: 0...3), Gen.int(in: 0...3),
                   Gen.int(in: -10...10), command.array(of: 1...12))
            .map { IdentityScenario(form: $0, prefix: $1, suffix: $2, payload: $3, commands: $4) }
    }

    @Test(.shrinking, arguments: ["disk", "sqlite"])
    func exactRepresentationControls(backend: String) async throws {
        try await DiscoveryProperty.check("identity-exact-\(backend)", count: DiscoveryProperty.backendCases,
            input: scenarios()) { scenario, coverage in
            try await replay(scenario, backend: backend, equivalent: false, coverage: coverage)
        }
    }

    @Test(.shrinking,
          .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_IDENTITY_SEARCH"] == "1"),
          arguments: ["disk", "sqlite"])
    func equivalentRepresentationHistories(backend: String) async throws {
        try await DiscoveryProperty.check("identity-equivalent-\(backend)", count: DiscoveryProperty.backendCases,
            input: scenarios()) { scenario, coverage in
            try await replay(scenario, backend: backend, equivalent: true, coverage: coverage)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_STORE_IDENTITY_WITNESSES"] == "1"),
          arguments: ["disk", "sqlite"], Array(0..<16))
    func equivalentRepresentationWitnesses(backend: String, witness: Int) async throws {
        let kinds: [IdentityCommand.Kind] = [.insert, .insertBatch, .remove, .removeBatch]
        let scenario = IdentityScenario(form: witness / 4, prefix: 0, suffix: 0, payload: 0,
            commands: [.init(kind: kinds[witness % 4], alternate: true, delta: 0)])
        try await replay(scenario, backend: backend, equivalent: true, coverage: DiscoveryCoverage())
    }

    private func replay(_ scenario: IdentityScenario, backend: String, equivalent: Bool,
                        coverage: DiscoveryCoverage) async throws {
        let pairs = [("é", "e\u{301}"), ("å", "a\u{30a}"), ("각", "\u{1100}\u{1161}\u{11a8}"), ("ñ", "n\u{303}")]
        let prefixes = ["", "path/", "👩🏽/", "id-"]
        let suffixes = ["", ".json", "/tail", "#suffix"]
        let pair = pairs[scenario.form]
        let left = prefixes[scenario.prefix] + pair.0 + suffixes[scenario.suffix]
        let right = equivalent ? prefixes[scenario.prefix] + pair.1 + suffixes[scenario.suffix] : left
        try discoveryRequire(left == right, "identity.fixture-equality", step: -1)
        if equivalent {
            try discoveryRequire(Array(left.utf8) != Array(right.utf8), "identity.fixture-distinct-bytes", step: -1)
        }
        let directory = FileManager.Directory.temporary(appendingPath: "Boutique.IdentityDiscovery.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let storage: any StorageEngine
        if backend == "disk" { storage = DiskStorageEngine(directory: directory) }
        else {
            guard let sqlite = SQLiteStorageEngine(directory: directory) else {
                throw DiscoveryFailure(invariant: "identity.fixture-sqlite", step: -1, detail: "Cannot create SQLite engine")
            }
            storage = sqlite
        }
        let store = try await Store<IdentityItem>(storage: storage, cacheIdentifier: \.id)
        let initial = IdentityItem(id: left, payload: scenario.payload)
        try await store.insert(initial)
        var model = [initial]
        for (step, command) in scenario.commands.enumerated() {
            let id = command.alternate ? right : left
            let item = IdentityItem(id: id, payload: scenario.payload + 1 + command.delta)
            switch command.kind {
            case .insert:
                try await store.insert(item)
                if let index = model.firstIndex(where: { $0.id == item.id }) { model[index] = item }
                else { model.append(item) }
            case .insertBatch:
                // Same logical identity twice, including different byte spellings.
                let first = IdentityItem(id: left, payload: scenario.payload)
                try await store.insert([first, item])
                for inserted in [first, item] {
                    if let index = model.firstIndex(where: { $0.id == inserted.id }) { model[index] = inserted }
                    else { model.append(inserted) }
                }
            case .remove:
                try await store.remove(item)
                model.removeAll { $0.id == item.id }
            case .removeBatch:
                try await store.remove([item])
                model.removeAll { $0.id == item.id }
            }
            coverage.hit("operation.\(command.kind).alternate.\(command.alternate)")
            coverage.hit("form.\(scenario.form)")
            try discoveryRequire(store.items == model, "identity.memory", step: step)
            let persisted = try await storage.readAllData().map { try JSONDecoder().decode(IdentityItem.self, from: $0) }
            // Check multiplicity before constructing a dictionary or reopening: a
            // duplicate logical identity can crash Store's next OrderedDictionary build.
            try discoveryRequire(persisted.count == model.count, "identity.persisted-multiplicity", step: step,
                "memory=\(model), persisted=\(persisted), leftBytes=\(Array(left.utf8)), rightBytes=\(Array(right.utf8))")
            try discoveryRequire(Set(persisted.map(\.id)).count == persisted.count,
                                 "identity.persisted-distinct-identities", step: step)
            try discoveryRequire(persisted == model, "identity.persisted-values", step: step)
        }
        let reopened = try await Store<IdentityItem>(storage: storage, cacheIdentifier: \.id)
        try discoveryRequire(reopened.items == model, "identity.reopen", step: scenario.commands.count)
    }
}

private struct IdentityItem: Codable, Equatable, Sendable {
    let id: String
    let payload: Int
}

private struct IdentityScenario: Codable, Sendable {
    let form: Int
    let prefix: Int
    let suffix: Int
    let payload: Int
    let commands: [IdentityCommand]
}

private struct IdentityCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case insert, insertBatch, remove, removeBatch }
    let kind: Kind
    let alternate: Bool
    let delta: Int
}
