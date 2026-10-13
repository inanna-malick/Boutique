import Foundation
import PropertyBased
import Testing
@testable import Boutique

/// An acceptance gate for the dependency, not a replacement for the broader Store model.
@MainActor
@Suite("PropertyBased library acceptance", .serialized)
struct PropertyLibraryAcceptanceTests {
    @Test(.shrinking)
    func asyncStoreHistoriesShrinkAndReplay() async throws {
        // Concrete identifiers make every subsequence valid: removing a missing key is
        // a legal operation, and no command refers to an allocation in another command.
        let operation = zip(Gen.int(in: 0...3), Gen.int(in: 0...2), Gen.int(in: 0...20))
            .map { kind, key, payload in
                switch kind {
                case 0, 1: return AcceptanceOperation.put(key: key, payload: payload)
                case 2: return AcceptanceOperation.remove(key: key)
                default: return AcceptanceOperation.read
                }
            }
        let histories = operation.array(of: 0...24)
        let environment = ProcessInfo.processInfo.environment
        let mutate = environment["BOUTIQUE_ACCEPTANCE_IGNORE_OVERWRITE"] == "1"
        let artifactURL = environment["BOUTIQUE_ACCEPTANCE_ARTIFACT"].map { URL(fileURLWithPath: $0) }
        var artifact = AcceptanceArtifact(mutation: mutate)

        // An explicit scenario also provides generator-independent regression replay.
        if let replayPath = environment["BOUTIQUE_ACCEPTANCE_REPLAY"] {
            let scenario = try JSONDecoder().decode([AcceptanceOperation].self,
                                                    from: Data(contentsOf: URL(fileURLWithPath: replayPath)))
            try await attempt(scenario, mutate: mutate, artifact: &artifact, artifactURL: artifactURL)
        } else {
            await propertyCheck(count: 100, input: histories) { history in
                try await attempt(history, mutate: mutate, artifact: &artifact, artifactURL: artifactURL)
            }
        }
        #expect(artifact.attempts > 0)
        #expect(artifact.createdFixtures == artifact.removedFixtures)
    }

    @Test
    func cancelledFixtureAndSubscriberAreCleanedUp() async throws {
        let directory = FileManager.Directory.temporary(appendingPath: "Boutique-Acceptance-Cancellation-\(UUID())")
        let fixture = Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let store = try await Store<AcceptanceItem>(storage: DiskStorageEngine(directory: directory),
                                                        cacheIdentifier: \.id)
            try await store.insert(AcceptanceItem(id: "0", payload: 1))
            try Task.checkCancellation()
        }
        // Cancellation precedes the task's first execution on this actor; no sleeps.
        fixture.cancel()
        do {
            try await fixture.value
            Issue.record("Expected the cancelled fixture to throw")
        } catch is CancellationError {
        }
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))

        let subject = AsyncValueSubject(0)
        let stream = subject.values
        let consumer = Task { () -> Int? in
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // buffered initial value
            return await iterator.next()
        }
        consumer.cancel()
        let next = await consumer.value
        #expect(next == nil)
        // The subject remains usable after another subscriber has cancelled.
        subject.send(9)
        var fresh = subject.values.makeAsyncIterator()
        #expect(await fresh.next() == 9)
    }

    private func attempt(_ history: [AcceptanceOperation], mutate: Bool,
                         artifact: inout AcceptanceArtifact, artifactURL: URL?) async throws {
        let directory = FileManager.Directory.temporary(appendingPath: "Boutique-Acceptance-\(UUID())")
        artifact.attempts += 1
        artifact.createdFixtures += 1
        var divergence: Int?
        defer {
            do {
                if FileManager.default.fileExists(atPath: directory.url.path) {
                    try FileManager.default.removeItem(at: directory.url)
                }
                artifact.removedFixtures += 1
            } catch {
                Issue.record("Fixture cleanup failed: \(error)")
            }
            if let divergence {
                let failure = AcceptanceFailure(operations: history, firstDivergence: divergence)
                if artifact.originalFailure == nil { artifact.originalFailure = failure }
                artifact.finalFailure = failure
            }
            if let artifactURL {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(artifact).write(to: artifactURL, options: .atomic)
                } catch {
                    Issue.record("Cannot persist acceptance artifact: \(error)")
                }
            }
        }

        let storage = DiskStorageEngine(directory: directory)
        let store = try await Store<AcceptanceItem>(storage: storage, cacheIdentifier: \.id)
        var expected: [AcceptanceItem] = []
        #expect(store.items.isEmpty, "Every generation and shrink attempt must start fresh")
        for (index, operation) in history.enumerated() {
            switch operation {
            case .put(let key, let payload):
                try #require((0...2).contains(key) && (0...20).contains(payload),
                             "Generator and shrinker must preserve operand domains")
                let item = AcceptanceItem(id: String(key), payload: payload)
                // Fault injection exists only in the adapter and is opt-in. The model
                // never consults Store to determine its expected state.
                if !mutate || !store.items.contains(where: { $0.id == item.id }) {
                    try await store.insert(item)
                }
                if let position = expected.firstIndex(where: { $0.id == item.id }) {
                    expected[position] = item
                } else {
                    expected.append(item)
                }
            case .remove(let key):
                try #require((0...2).contains(key))
                try await store.remove(AcceptanceItem(id: String(key), payload: -1))
                expected.removeAll { $0.id == String(key) }
            case .read:
                break
            }
            // Guarantees the check runs after suspension even for read/no-op commands.
            await Task.yield()
            if store.items != expected {
                divergence = index
                #expect(store.items == expected, "step \(index), history \(history)")
                return
            }
        }
        let reopened = try await Store<AcceptanceItem>(storage: DiskStorageEngine(directory: directory),
                                                       cacheIdentifier: \.id)
        if reopened.items.sorted(by: { $0.id < $1.id }) != expected.sorted(by: { $0.id < $1.id }) {
            divergence = history.count
            Issue.record("Reopened contents differ for history \(history)")
        }
        #expect(await storage.keyCount() == expected.count)
    }
}

private struct AcceptanceItem: Codable, Equatable, Sendable {
    let id: String
    let payload: Int
}

private enum AcceptanceOperation: Codable, Sendable, CustomStringConvertible {
    case put(key: Int, payload: Int)
    case remove(key: Int)
    case read

    var description: String {
        switch self {
        case .put(let key, let payload): return "put(\(key), \(payload))"
        case .remove(let key): return "remove(\(key))"
        case .read: return "read"
        }
    }
}

private struct AcceptanceFailure: Codable {
    var operations: [AcceptanceOperation]
    var firstDivergence: Int
}

private struct AcceptanceArtifact: Encodable {
    let schemaVersion = 1
    let mutation: Bool
    var attempts = 0
    var createdFixtures = 0
    var removedFixtures = 0
    var originalFailure: AcceptanceFailure?
    var finalFailure: AcceptanceFailure?
}
