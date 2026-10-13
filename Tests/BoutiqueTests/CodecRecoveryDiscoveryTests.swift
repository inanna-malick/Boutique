import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct CodecRecord: Codable, Equatable, Sendable {
    enum Rejection: Error { case payload }
    let id: String
    let payload: Int
    let rejects: Bool
    init(id: String, payload: Int, rejects: Bool = false) { self.id = id; self.payload = payload; self.rejects = rejects }
    func encode(to encoder: Encoder) throws {
        if rejects { throw Rejection.payload }
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(id, forKey: .id)
        try values.encode(payload, forKey: .payload)
        try values.encode(false, forKey: .rejects)
    }
    private enum Keys: String, CodingKey { case id, payload, rejects }
}

private actor CodecReadStorage: StorageEngine {
    let base = StoreDiscoveryStorage()
    var rejectsRead = false
    func failRead() { rejectsRead = true }
    func readAllData() async -> [Data] {
        if rejectsRead { rejectsRead = false; return [Data("{".utf8)] }
        return await base.readAllData()
    }
    func write(_ data: Data, key: CacheKey) async throws { try await base.write(data, key: key) }
    func write(_ entries: [(key: CacheKey, data: Data)]) async throws { try await base.write(entries) }
    func remove(key: CacheKey) async throws { try await base.remove(key: key) }
    func remove(keys: [CacheKey]) async throws { try await base.remove(keys: keys) }
    func removeAllData() async throws { try await base.removeAllData() }
    func read(key: CacheKey) async -> Data? { await base.read(key: key) }
    func readDataAndKeys(keys: [CacheKey]) async -> [(key: CacheKey, data: Data)] { await base.readDataAndKeys(keys: keys) }
    func allKeys() async -> [CacheKey] { await base.allKeys() }
    func keyExists(_ key: CacheKey) async -> Bool { await base.keyExists(key) }
    func createdAt(key: CacheKey) async -> Date? { nil }
    func updatedAt(key: CacheKey) async -> Date? { nil }
}

private struct CodecCommand: Codable, Sendable {
    let kind: Int
    let key: Int
    let payload: Int
}

private struct CodecScenario: Codable, Sendable {
    let payload: Int
    let malformed: Int
    let position: Int
    let duplicate: Int
    let fused: Bool
    let repeats: Int
    var commands: [CodecCommand] = []
}

@MainActor
@Suite("Codec recovery discovery", .serialized)
struct CodecRecoveryDiscoveryTests {
    private func generator() -> Generator<CodecScenario, some Sequence> {
        zip(Gen.int(in: -100...100), Gen.int(in: 0...2), Gen.int(in: 0...2),
            Gen.int(in: 0...2), Gen.bool, Gen.int(in: 1...4), zip(Gen.int(in: 0...6), Gen.int(in: 0...1), Gen.int(in: -10...10)).map { CodecCommand(kind: $0, key: $1, payload: $2) }.array(of: 1...30))
            .map { CodecScenario(payload: $0, malformed: $1, position: $2, duplicate: $3, fused: $4, repeats: $5, commands: $6) }
    }
    @Test(.shrinking)
    func authoredRawLoadRecovery() async throws {
        try await DiscoveryProperty.check("codec-load", input: generator()) { scenario, coverage in
            try await load(scenario, storage: CodecReadStorage(), readFailure: false, coverage: coverage)
        }
    }
    @Test(.shrinking)
    func backendCorruptReadRepairReconstruct() async throws {
        try await DiscoveryProperty.check("codec-read", input: generator()) { scenario, coverage in
            try await load(scenario, storage: CodecReadStorage(), readFailure: true, coverage: coverage)
        }
    }
    @Test(.shrinking, arguments: ["disk", "sqlite"])
    func realBackendMalformedRecovery(backend: String) async throws {
        try await DiscoveryProperty.check("codec-load-\(backend)", count: DiscoveryProperty.backendCases, input: generator()) { scenario, coverage in
            let directory = FileManager.Directory.temporary(appendingPath: "Codec-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let storage: any StorageEngine = backend == "disk" ? DiskStorageEngine(directory: directory) : try discoveryUnwrap(SQLiteStorageEngine(directory: directory), "codec.fixture")
            try await load(scenario, storage: storage, readFailure: false, coverage: coverage)
        }
    }
    private func decodeKind(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted: return "dataCorrupted"
        case DecodingError.typeMismatch: return "typeMismatch"
        case DecodingError.keyNotFound: return "keyNotFound"
        case DecodingError.valueNotFound: return "valueNotFound"
        default: return "unexpected"
        }
    }
    private func coldStore(_ storage: any StorageEngine) -> Store<CodecRecord> {
        Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
    }
    private func load(_ scenario: CodecScenario, storage: any StorageEngine, readFailure: Bool, coverage: DiscoveryCoverage) async throws {
        // Raw records are authored independently of the production encoder.
        let good = Data("{\"id\":\"good\",\"payload\":\(scenario.payload),\"rejects\":false}".utf8)
        let repaired = Data("{\"id\":\"bad\",\"payload\":7,\"rejects\":false}".utf8)
        let bad = [Data("{".utf8), Data("{\"id\":\"bad\",\"payload\":".utf8), Data("[]".utf8)][scenario.malformed]
        try await storage.write(good, key: CacheKey("good"))
        try await storage.write(readFailure ? repaired : bad, key: CacheKey("bad"))
        let before = await storage.readAllData()
        if readFailure { await (storage as! CodecReadStorage).failRead() }
        let failed = coldStore(storage)
        do { try await failed.itemsHaveLoaded(); throw DiscoveryFailure(invariant: "codec.load.error", step: 0, detail: "load accepted failure") }
        catch let error as DecodingError {
            let corrupt = readFailure ? Data("{".utf8) : bad
            var expectedKind = ""
            do { _ = try JSONDecoder().decode(CodecRecord.self, from: corrupt) }
            catch { expectedKind = decodeKind(error) }
            try discoveryRequire(decodeKind(error) == expectedKind, "codec.load.error.kind", step: 0)
            coverage.hit("exactDecodingError")
        }
        try discoveryRequire(await storage.readAllData().sorted { $0.lexicographicallyPrecedes($1) } == before.sorted { $0.lexicographicallyPrecedes($1) }, "codec.load.persistence", step: 0)
        try await storage.write(repaired, key: CacheKey("bad"))
        // Characterization only: a second wait observes the same failed Task.
        do { try await failed.itemsHaveLoaded(); coverage.hit("retrySucceeded") }
        catch is DecodingError { coverage.hit("retryRetainedFailure") }
        let reopened = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
        let expected = [CodecRecord(id: "good", payload: scenario.payload), CodecRecord(id: "bad", payload: 7)]
        try discoveryRequire(reopened.items.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id }, "codec.load.reconstruct", step: 1)
        coverage.hit("malformed.\(scenario.malformed)"); coverage.hit(readFailure ? "corruptRead" : "decodeFailure")
    }
    @Test(.shrinking)
    func encodingRecoveryHistories() async throws {
        try await DiscoveryProperty.check("codec-encoding", input: generator()) { scenario, coverage in
            try await encoding(scenario, coverage: coverage)
        }
    }
    @Test(.shrinking)
    func encodeBeforeRemovalPolicyControl() async throws {
        try await DiscoveryProperty.check("codec-encode-first-control", input: generator()) { scenario, coverage in
            try await encoding(scenario, coverage: coverage, encodeBeforeRemoval: true)
        }
    }
    @Test
    func boundedEncodingMatrix() async throws {
        for position in 0...2 { for duplicate in 0...2 { for fused in [false, true] {
            try await encoding(.init(payload: 8, malformed: 0, position: position, duplicate: duplicate, fused: fused, repeats: 2), coverage: DiscoveryCoverage())
        } } }
        for first in 0...6 { for second in 0...6 {
            try await encoding(.init(payload: 1, malformed: 0, position: 0, duplicate: 0, fused: false, repeats: 1, commands: [CodecCommand(kind: first, key: first % 2, payload: 1), CodecCommand(kind: second, key: second % 2, payload: 2)]), coverage: DiscoveryCoverage())
        } }
        print("PROPERTY codec-matrix: combinations=18, two-command histories=49")
    }
    private func encoding(_ scenario: CodecScenario, coverage: DiscoveryCoverage, encodeBeforeRemoval: Bool = false) async throws {
        let storage = StoreDiscoveryStorage()
        var store = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
        let unrelated = CodecRecord(id: "unrelated", payload: scenario.payload)
        try await store.insert(unrelated) as Void
        for round in 0..<scenario.repeats {
            var operands = (0...2).map { CodecRecord(id: "item\($0)", payload: scenario.payload + $0) }
            operands[scenario.position] = CodecRecord(id: "item\(scenario.position)", payload: round, rejects: true)
            if scenario.duplicate == 1 { operands.append(CodecRecord(id: operands[scenario.position].id, payload: 44)) }
            if scenario.duplicate == 2 { operands.insert(CodecRecord(id: operands[scenario.position].id, payload: 45), at: 0) }
            // Last-write identity normalization uses an authored Array oracle.
            var normalized: [CodecRecord] = []
            for item in operands {
                if let index = normalized.firstIndex(where: { $0.id == item.id }) { normalized[index] = item }
                else { normalized.append(item) }
            }
            let rejects = normalized.contains { $0.rejects }
            let before = await storage.readAllData()
            do {
                if scenario.fused {
                    if encodeBeforeRemoval { for item in normalized { _ = try JSONEncoder().encode(item) } }
                    let op: Store<CodecRecord>.Operation = try await store.removeAll()
                    try await op.insert(operands).run()
                } else { try await store.insert(operands) as Void }
                try discoveryRequire(!rejects, "codec.encoding.error", step: round)
            } catch CodecRecord.Rejection.payload { try discoveryRequire(rejects, "codec.encoding.error", step: round) }
            var retainedBeforeFailure = [unrelated]
            if rejects {
                let raw = await storage.readAllData()
                if scenario.fused {
                    // Failed fused-call memory and removal timing are unspecified.
                    // Adopt only retained identity selection from authored versions.
                    let actual = try raw.map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
                    try discoveryRequire(Set(actual.map(\.id)).count == actual.count && actual.allSatisfy { $0 == unrelated }, "codec.encoding.fusedKnownVersions", step: round)
                    retainedBeforeFailure = [unrelated].filter { authored in actual.contains { $0.id == authored.id } }
                    coverage.hit(actual.isEmpty ? "failedFusedRemoved" : "failedFusedRetained")
                } else {
                    try discoveryRequire(raw == before, "codec.encoding.persistence", step: round)
                }
                coverage.hit("rejected"); coverage.hit("position.\(scenario.position)")
            } else {
                let expected = (scenario.fused ? [] : [unrelated]) + normalized
                let actual = try await storage.readAllData().map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
                try discoveryRequire(actual.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id }, "codec.encoding.accepted", step: round)
                coverage.hit("duplicateMasksRejectedValue")
            }
            var persistedModel = rejects ? retainedBeforeFailure : ((scenario.fused ? [] : [unrelated]) + normalized)
            // Successful insertion on the original failed Store: only persistence
            // is asserted before reconstruction, with no failed-memory contract.
            let continued = CodecRecord(id: "continued", payload: round)
            try await store.insert(continued) as Void
            let continuedRaw = try await storage.readAllData().map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
            persistedModel.append(continued)
            try discoveryRequire(continuedRaw.sorted { $0.id < $1.id } == persistedModel.sorted { $0.id < $1.id }, "codec.recovery.continued", step: round)
            coverage.hit("continuedBeforeReopen")
            // Arbitrary direct continuations immediately after the failure;
            // persistence has an independent model, memory remains unspecified.
            for (step, command) in scenario.commands.enumerated() {
                let item = CodecRecord(id: "history\(command.key)", payload: command.payload)
                switch command.kind {
                case 0, 1, 2:
                    try await store.insert(item) as Void
                    if let index = persistedModel.firstIndex(where: { $0.id == item.id }) { persistedModel[index] = item } else { persistedModel.append(item) }
                case 3:
                    try await store.remove(item) as Void
                    persistedModel.removeAll { $0.id == item.id }
                case 4:
                    try await store.removeAll() as Void; persistedModel = []
                case 5:
                    store = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
                default:
                    var rejected = false
                    do { try await store.insert(CodecRecord(id: item.id, payload: item.payload, rejects: true)) as Void }
                    catch CodecRecord.Rejection.payload { rejected = true }
                    try discoveryRequire(rejected, "codec.continuation.error", step: step)
                }
                let actual = try await storage.readAllData().map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
                try discoveryRequire(actual.sorted { $0.id < $1.id } == persistedModel.sorted { $0.id < $1.id }, "codec.continuation.persistence", step: step)
                coverage.hit("continuation.\(command.kind)")
            }
            // Reconstruct before ordered memory assertions.
            store = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
            let recovered = CodecRecord(id: "recovered", payload: round)
            try await store.insert(recovered) as Void
            let decoded = try await storage.readAllData().map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
            persistedModel.append(recovered)
            try discoveryRequire(decoded.sorted { $0.id < $1.id } == persistedModel.sorted { $0.id < $1.id }, "codec.recovery.mutation", step: round)
            if scenario.fused {
                let op: Store<CodecRecord>.Operation = try await store.removeAll()
                try await op.insert(unrelated).run()
            } else {
                try await store.removeAll() as Void
                try await store.insert(unrelated) as Void
            }
            let final = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
            try discoveryRequire(final.items == [unrelated], "codec.recovery.clear", step: round)
            coverage.hit(scenario.fused ? "fusedClear" : "directClear"); coverage.hit("reopen")
            store = final
            var model = [unrelated]
            for (step, command) in scenario.commands.enumerated() {
                let item = CodecRecord(id: "history\(command.key)", payload: command.payload)
                switch command.kind {
                case 0, 1, 2:
                    try await store.insert(item) as Void
                    if let index = model.firstIndex(where: { $0.id == item.id }) { model[index] = item } else { model.append(item) }
                case 3:
                    try await store.remove(item) as Void
                    model.removeAll { $0.id == item.id }
                case 4:
                    try await store.removeAll() as Void; model = []
                case 5:
                    store = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
                default:
                    var rejected = false
                    do { try await store.insert(CodecRecord(id: item.id, payload: step, rejects: true)) as Void }
                    catch CodecRecord.Rejection.payload { rejected = true; coverage.hit("historyRejected") }
                    try discoveryRequire(rejected, "codec.history.error", step: step)
                    // No failed-call memory assertion: reconstruct from raw model.
                    store = try await Store<CodecRecord>(storage: storage, cacheIdentifier: \.id)
                }
                let bytes = try await storage.readAllData().map { try JSONDecoder().decode(CodecRecord.self, from: $0) }
                try discoveryRequire(bytes.sorted { $0.id < $1.id } == model.sorted { $0.id < $1.id }, "codec.history.persistence", step: step)
                if command.kind != 6 {
                    try discoveryRequire(store.items.sorted { $0.id < $1.id } == model.sorted { $0.id < $1.id }, "codec.history.memory", step: step)
                }
                coverage.hit("command.\(command.kind)")
            }
            // Reset authored baseline for the next rejected-batch round.
            try await store.removeAll() as Void
            try await store.insert(unrelated) as Void
        }
    }
}
