import Foundation
import PropertyBased
import Testing
@testable import Boutique

private enum ConcurrentFaultOwner { @TaskLocal static var name = "setup" }
private struct ConcurrentFaultScenario: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case before, after }
    struct Operation: Codable, Sendable {
        enum Kind: String, Codable, Sendable, CaseIterable { case insert, batch, remove, removeBatch, clear, fusedClearInsert, fusedRemoveInsert }
        var kind: Kind
        var items: [StoreDiscoveryItem]
        var removals: [StoreDiscoveryItem]
    }
    struct Owner: Codable, Sendable {
        var id: String
        var operation: Operation
        var fault: Int?
        var phase: Phase
    }
    var initial: [StoreDiscoveryItem]
    var permutation: Int
    var owners: [Owner]
    var tail: [Operation]
}
private actor ConcurrentFaultStorage: StorageEngine {
    struct Commit: Sendable, Equatable, CustomStringConvertible {
        let owner: String
        let kind: String
        let key: String?
        let item: StoreDiscoveryItem?
        var description: String { "\(owner):\(kind):\(item.map { "\($0.id)=\($0.payload)" } ?? key ?? "all")" }
    }
    struct Gate {
        let boundary: Int
        let phase: ConcurrentFaultScenario.Phase
        var continuation: CheckedContinuation<Void, Never>?
    }
    struct Injected: Error, Equatable { let owner: String }
    private var faults: [String: Int] = [:]
    func fault(_ owner: String, at index: Int) { faults[owner] = index }
    private var values: [CacheKey: Data] = [:]
    private var boundaries: [String: Int] = [:]
    private var gates: [String: Gate] = [:]
    private var waiters: [String: StoreDiscoveryCompletion] = [:]
    private(set) var commits: [Commit] = []

    func seed(_ items: [StoreDiscoveryItem]) throws {
        for item in items { values[CacheKey(item.id)] = try JSONEncoder().encode(item) }
    }
    func pause(_ owner: String, boundary: Int, phase: ConcurrentFaultScenario.Phase) {
        let token = "\(owner):\(boundary):\(phase.rawValue)"
        gates[token] = Gate(boundary: boundary, phase: phase)
        waiters[token] = StoreDiscoveryCompletion()
    }
    func wait(_ owner: String, index: Int = 0, phase: ConcurrentFaultScenario.Phase = .before, timeout: Duration = .seconds(1)) async throws {
        guard let waiter = waiters["\(owner):\(index):\(phase.rawValue)"] else { throw StoreDiscoveryStorage.Failure.gateTimedOut }
        try await waiter.wait(timeout: timeout)
    }
    func release(_ owner: String, index: Int = 0, phase: ConcurrentFaultScenario.Phase = .before) { gates.removeValue(forKey: "\(owner):\(index):\(phase.rawValue)")?.continuation?.resume() }
    func releaseAll() {
        let pending = gates.values.compactMap(\.continuation)
        gates = [:]
        pending.forEach { $0.resume() }
    }
    private func boundary(_ owner: String, index: Int, phase: ConcurrentFaultScenario.Phase) async {
        let token = "\(owner):\(index):\(phase.rawValue)"
        guard gates[token] != nil else { return }
        await withCheckedContinuation { continuation in
            gates[token]?.continuation = continuation
            // Install the suspension before acknowledging it to the driver.
            if let waiter = waiters[token] { Task { await waiter.finish(.success(())) } }
        }
    }
    private func mutate(kind: String, key: CacheKey?, data: Data?) async throws {
        let owner = ConcurrentFaultOwner.name
        let index = boundaries[owner, default: 0]
        boundaries[owner] = index + 1
        let item = try data.map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        await boundary(owner, index: index, phase: .before)
        if faults[owner] == 0 && index == 0 { faults.removeValue(forKey: owner); throw Injected(owner: owner) }
        if let key {
            if let data {
                if ProcessInfo.processInfo.environment["BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_WRITE"] != "1" { values[key] = data }
            } else { values.removeValue(forKey: key) }
        } else { values = [:] }
        commits.append(.init(owner: owner, kind: kind, key: key?.value, item: item))
        await boundary(owner, index: index, phase: .after)
        if faults[owner] == index + 1 { faults.removeValue(forKey: owner); throw Injected(owner: owner) }
    }
    func write(_ data: Data, key: CacheKey) async throws { try await mutate(kind: "write", key: key, data: data) }
    func write(_ entries: [(key: CacheKey, data: Data)]) async throws {
        for entry in entries { try await mutate(kind: "write", key: entry.key, data: entry.data) }
    }
    func remove(key: CacheKey) async throws { try await mutate(kind: "remove", key: key, data: nil) }
    func remove(keys: [CacheKey]) async throws {
        for key in keys { try await mutate(kind: "remove", key: key, data: nil) }
    }
    func removeAllData() async throws { try await mutate(kind: "clear", key: nil, data: nil) }
    func readAllData() -> [Data] { values.sorted { $0.key.value < $1.key.value }.map(\.value) }
    func read(key: CacheKey) -> Data? { values[key] }
    func readDataAndKeys(keys: [CacheKey]) -> [(key: CacheKey, data: Data)] { keys.compactMap { key in values[key].map { (key, $0) } } }
    func allKeys() -> [CacheKey] { Array(values.keys) }
    func keyExists(_ key: CacheKey) -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) -> Date? { nil }
    func updatedAt(key: CacheKey) -> Date? { nil }
}


@MainActor
@Suite("Store concurrent repeated faults discovery")
struct StoreConcurrentFaultDiscoveryTests {
    private func execute(_ operation: ConcurrentFaultScenario.Operation, store: Store<StoreDiscoveryItem>) async throws {
        switch operation.kind {
        case .insert: try await store.insert(operation.items[0]) as Void
        case .batch: try await store.insert(operation.items) as Void
        case .remove: try await store.remove(operation.items[0]) as Void
        case .removeBatch: try await store.remove(operation.items) as Void
        case .clear: try await store.removeAll() as Void
        case .fusedClearInsert:
            let chain: Store<StoreDiscoveryItem>.Operation = try await store.removeAll()
            try await chain.insert(operation.items).run()
        case .fusedRemoveInsert:
            let chain: Store<StoreDiscoveryItem>.Operation = try await store.remove(operation.removals)
            try await chain.insert(operation.items).run()
        }
    }

    private func acceptedCommits(_ operation: ConcurrentFaultScenario.Operation,
                                 owner: String, starting: [StoreDiscoveryItem]) -> [ConcurrentFaultStorage.Commit] {
        var result: [ConcurrentFaultStorage.Commit] = []
        func removals(_ items: [StoreDiscoveryItem]) {
            for item in items { result.append(.init(owner: owner, kind: "remove", key: CacheKey(item.id).value, item: nil)) }
        }
        switch operation.kind {
        case .clear: return [.init(owner: owner, kind: "clear", key: nil, item: nil)]
        case .remove: removals(Array(operation.items.prefix(1))); return result
        case .removeBatch: removals(operation.items); return result
        case .fusedClearInsert: removals(starting)
        case .fusedRemoveInsert: removals(operation.removals)
        case .insert, .batch: break
        }
        // Independent Array deduplication captures the accepted payload of every
        // write, preserving first position and last payload for repeated IDs.
        var accepted = StoreDiscoveryModel()
        accepted.apply(.init(kind: .batch, items: operation.kind == .insert ? Array(operation.items.prefix(1)) : operation.items))
        result += accepted.items.map { .init(owner: owner, kind: "write", key: CacheKey($0.id).value, item: $0) }
        return result
    }

    private func applying(_ operation: ConcurrentFaultScenario.Operation, to items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] {
        var model = StoreDiscoveryModel(items: items)
        switch operation.kind {
        case .clear: model.apply(.init(kind: .clear, items: []))
        case .remove, .removeBatch: model.apply(.init(kind: .removeBatch, items: operation.items))
        case .fusedClearInsert:
            model.apply(.init(kind: .clear, items: []))
            model.apply(.init(kind: .batch, items: operation.items))
        case .fusedRemoveInsert:
            model.apply(.init(kind: .removeBatch, items: operation.removals))
            model.apply(.init(kind: .batch, items: operation.items))
        case .insert, .batch: model.apply(.init(kind: .batch, items: operation.items))
        }
        return model.items
    }

    private func generator() -> Generator<ConcurrentFaultScenario, some Sequence> {
        let operand = zip(Gen.int(in: 0...6), Gen.int(in: 0...15), Gen.int(in: -20...20))
        return zip(operand.array(of: 2...3), operand.array(of: 0...30), Gen.int(in: 0...2)).map { draws, tails, faultCount in
            func operation(_ draw: (Int, Int, Int)) -> ConcurrentFaultScenario.Operation {
                let (kind, flags, payload) = draw
                let item = StoreDiscoveryItem(id: "key-\(flags % 4)", payload: payload)
                let operands = flags % 4 == 0 ? [] : [item, .init(id: item.id, payload: payload + 1), .init(id: "key-\((flags + 1) % 4)", payload: payload + 2)]
                let k = ConcurrentFaultScenario.Operation.Kind.allCases[kind]
                return .init(kind: k, items: k == .insert || k == .remove ? [item] : operands,
                             removals: [.init(id: "key-0", payload: 999), .init(id: "key-0", payload: -999)])
            }
            let initial = (0..<(draws[0].1 % 3)).map { StoreDiscoveryItem(id: "seed-\($0)", payload: draws[0].2) }
            let owners = draws.enumerated().map { index, draw in
                let op = operation(draw)
                // Direct/fused clears start from empty memory at the rendezvous.
                let count = op.kind == .clear ? 1 : op.kind == .fusedRemoveInsert ? 2 + Set(op.items.map(\.id)).count : op.kind == .fusedClearInsert ? initial.count + Set(op.items.map(\.id)).count : op.kind == .removeBatch ? op.items.count : Set(op.items.map(\.id)).count
                return ConcurrentFaultScenario.Owner(id: ["A", "B", "C"][index], operation: op,
                    fault: index < faultCount && count > 0 ? draw.1 % (count + 1) : nil,
                    phase: draw.1 % 2 == 0 ? .before : .after)
            }
            return .init(initial: initial, permutation: draws[0].1 % 6, owners: owners, tail: tails.map(operation))
        }
    }

    @Test(.shrinking) func persistenceAndReopenedRecoveryHistories() async throws {
        try await DiscoveryProperty.check("store-concurrent-fault-recovery", input: generator()) { scenario, coverage in
            try await replay(scenario, coverage: coverage)
        }
    }

    @Test(.shrinking) func directClearContinuedUseHistories() async throws {
        try await DiscoveryProperty.check("store-concurrent-fault-direct-recovery", input: generator()) { scenario, coverage in
            try await replay(scenario, coverage: coverage, directReset: true)
        }
    }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_CONCURRENT_FAULT_MEMORY"] == "1"))
    func successfulConcurrentMemorySearch() async throws {
        try await DiscoveryProperty.check("store-concurrent-fault-memory", input: generator()) { scenario, coverage in
            try await replay(scenario, coverage: coverage, memory: true)
        }
    }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_CONCURRENT_FAULT_FUSED"] == "1"))
    func unreconciledFusedClearSearch() async throws {
        try await DiscoveryProperty.check("store-concurrent-fault-unreconciled", input: generator()) { scenario, coverage in
            try await replay(scenario, coverage: coverage, continuing: true)
        }
    }

    @Test func boundedSmallMatrix() async throws {
        let coverage = DiscoveryCoverage()
        var histories = 0
        let initial = [StoreDiscoveryItem(id: "seed-0", payload: -1), StoreDiscoveryItem(id: "seed-1", payload: -2)]
        for owners in 2...3 { for firstKind in ConcurrentFaultScenario.Operation.Kind.allCases {
            for secondKind in ConcurrentFaultScenario.Operation.Kind.allCases { for prefix in 0...2 {
                for phase in [ConcurrentFaultScenario.Phase.before, .after] {
                    let scenario = ConcurrentFaultScenario(initial: initial, permutation: phase == .after ? 1 : 0, owners: (0..<owners).map { i in
                        let op = ConcurrentFaultScenario.Operation(kind: i == 0 ? firstKind : secondKind,
                            items: [.init(id: "key-0", payload: i), .init(id: "key-1", payload: i)],
                            removals: [.init(id: "seed-0", payload: 999), .init(id: "seed-0", payload: -999)])
                        let count = acceptedCommits(op, owner: "matrix", starting: initial).count
                        return .init(id: ["A", "B", "C"][i], operation: op,
                                     fault: i < 2 && count > 0 ? min(prefix, count) : nil, phase: phase)
                    }, tail: [.init(kind: .fusedClearInsert, items: [.init(id: "recovered", payload: 42)], removals: [])])
                    try await replay(scenario, coverage: coverage)
                    histories += 1
                }
            } }
        } }
        coverage.hit("matrix.histories", by: histories)
        print("PROPERTY concurrent-fault-matrix: \(coverage.counts)")
    }

    private func replay(_ scenario: ConcurrentFaultScenario, coverage: DiscoveryCoverage, memory: Bool = false, directReset: Bool = false, continuing: Bool = false) async throws {
        let storage = ConcurrentFaultStorage()
        try await storage.seed(scenario.initial)
        let store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        // Nested directives disappear with their owner during structural shrinking.
        try discoveryRequire(Set(scenario.owners.map(\.id)).count == scenario.owners.count,
                             "concurrent.owner-identity", step: 0)
        try discoveryRequire(Set(store.items.map(\.id)).count == store.items.count &&
            store.items.sorted { $0.id < $1.id } == scenario.initial.sorted { $0.id < $1.id },
            "concurrent.initial-load", step: 0)
        let starting = store.items.map { actual in scenario.initial.first { $0.id == actual.id }! }
        var tasks: [Task<Result<Bool, Error>, Never>] = []
        var completions: [String: StoreDiscoveryCompletion] = [:]
        var startInfeasible = false
        var authored: [String: [ConcurrentFaultStorage.Commit]] = [:]
        for owner in scenario.owners {
            let accepted = acceptedCommits(owner.operation, owner: owner.id, starting: starting)
            authored[owner.id] = Array(accepted.prefix(owner.fault ?? accepted.count))
            if let fault = owner.fault { await storage.fault(owner.id, at: fault) }
            // All owners rendezvous before their first effect; empty operations
            // cannot reach a storage gate and are explicitly counted infeasible.
            if !accepted.isEmpty { await storage.pause(owner.id, boundary: 0, phase: .before) }
            if (authored[owner.id] ?? []).count > 1 { await storage.pause(owner.id, boundary: 1, phase: owner.phase) }
            let completion = StoreDiscoveryCompletion()
            completions[owner.id] = completion
            let task = Task { () -> Result<Bool, Error> in
                do {
                    try await ConcurrentFaultOwner.$name.withValue(owner.id) { try await execute(owner.operation, store: store) }
                    await completion.finish(.success(()))
                    return .success(false)
                } catch let failure as ConcurrentFaultStorage.Injected {
                    await completion.finish(.success(()))
                    return .success(failure.owner == owner.id)
                } catch { await completion.finish(.success(())); return .failure(error) }
            }
            tasks.append(task)
            if !accepted.isEmpty {
                do { try await storage.wait(owner.id, timeout: .seconds(1)); coverage.hit("gate.before.ack") }
                catch { startInfeasible = true; coverage.hit("schedule.infeasible"); await storage.releaseAll() }
            } else { coverage.hit("schedule.infeasible.empty") }
        }
        let permutations = scenario.owners.count == 2 ? [[0, 1], [1, 0]] :
            [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let order = permutations[scenario.permutation % permutations.count]
        if !startInfeasible {
            for index in order {
                let owner = scenario.owners[index]
                await storage.release(owner.id)
                do {
                    if (authored[owner.id] ?? []).count > 1 {
                        try await storage.wait(owner.id, index: 1, phase: owner.phase, timeout: .seconds(1))
                        coverage.hit("gate.\(owner.phase.rawValue).ack")
                    } else { try await completions[owner.id]!.wait(timeout: .seconds(1)) }
                } catch { startInfeasible = true; coverage.hit("schedule.infeasible"); break }
            }
            for index in order.reversed() {
                let owner = scenario.owners[index]
                await storage.release(owner.id, index: 1, phase: owner.phase)
                if !startInfeasible {
                    do { try await completions[owner.id]!.wait(timeout: .seconds(1)) }
                    catch { startInfeasible = true; coverage.hit("schedule.infeasible") }
                }
            }
        }
        await storage.releaseAll()
        var outcomes: [Result<Bool, Error>] = []
        for task in tasks { outcomes.append(await task.value) }
        for outcome in outcomes { if case .failure(let error) = outcome { throw error } }
        if startInfeasible { coverage.hit("histories.infeasible"); return }
        var failures = 0
        for (index, outcome) in outcomes.enumerated() {
            let failed = try outcome.get()
            let owner = scenario.owners[index]
            let accepted = acceptedCommits(owner.operation, owner: owner.id, starting: starting)
            let shouldFail = owner.fault != nil && !accepted.isEmpty
            try discoveryRequire(failed == shouldFail, "concurrent.exact-fault", step: index)
            if failed {
                failures += 1
                coverage.hit("fault.prefix.\(owner.fault!)")
                coverage.hit(owner.fault == 0 ? "fault.before" : owner.fault == accepted.count ? "fault.full-commit" : "fault.partial")
            }
            coverage.hit("operation.\(owner.operation.kind.rawValue)")
            if owner.operation.items.isEmpty { coverage.hit("operands.empty") }
            if Set(owner.operation.items.map(\.id)).count < owner.operation.items.count { coverage.hit("operands.duplicate") }
        }
        coverage.hit("release.permutation.\(scenario.permutation % permutations.count)")
        coverage.hit("owners.\(scenario.owners.count)")
        coverage.hit("failures.\(failures)")
        let commits = await storage.commits
        // Validate every complete authored prefix before using actual order.
        // Write payloads used below are the authored records, never decoded bytes.
        for owner in scenario.owners {
            let actual = commits.filter { $0.owner == owner.id }
            let expected = authored[owner.id] ?? []
            try discoveryRequire(actual == expected, "concurrent.commit-completeness", step: commits.count,
                                 "owner=\(owner.id); actual=\(actual); authored=\(expected)")
        }
        var model = StoreDiscoveryModel(items: scenario.initial)
        var offsets: [String: Int] = [:]
        var segments: [String] = []
        for actual in commits {
            let offset = offsets[actual.owner, default: 0]
            let expected = authored[actual.owner]![offset]
            offsets[actual.owner] = offset + 1
            if segments.last != actual.owner { segments.append(actual.owner) }
            switch expected.kind {
            case "write": model.apply(.init(kind: .insert, items: [expected.item!]))
            case "remove": model.items.removeAll { CacheKey($0.id).value == expected.key }
            case "clear": model.items = []
            default: throw DiscoveryFailure(invariant: "concurrent.kind", step: 0, detail: expected.kind)
            }
        }
        if segments.count > scenario.owners.count { coverage.hit("commit.interleaved") }
        coverage.hit("commits", by: commits.count)
        func sorted(_ items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] { items.sorted { $0.id < $1.id } }
        func verify(_ expected: [StoreDiscoveryItem], step: Int) async throws {
            let decoded = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
            try discoveryRequire(Set(decoded.map(\.id)).count == decoded.count, "concurrent.persisted-duplicates", step: step)
            try discoveryRequire(sorted(decoded) == sorted(expected), "concurrent.persistence", step: step,
                                 "commits=\(commits); actual=\(decoded); expected=\(expected)")
        }
        try await verify(model.items, step: commits.count)
        if memory && failures == 0 {
            try discoveryRequire(sorted(store.items) == sorted(model.items), "concurrent.known-pr86-memory", step: commits.count,
                                 "commits=\(commits); actual=\(store.items); expected=\(model.items)")
        }
        var reopened: Store<StoreDiscoveryItem>
        if continuing {
            reopened = store
            coverage.hit("recovery.original-instance-unreconciled")
        } else if directReset {
            // Explicit successful reset on the original instance is specified
            // even when failed calls leave unknown persisted records.
            try await store.removeAll() as Void
            model.items = []
            try await verify(model.items, step: commits.count)
            try discoveryRequire(store.items.isEmpty, "concurrent.direct-reset-memory", step: commits.count)
            reopened = store
            coverage.hit("recovery.original-instance-direct-clear")
        } else {
            reopened = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        }
        if !continuing { try discoveryRequire(sorted(reopened.items) == sorted(model.items), "concurrent.reopen", step: commits.count) }
        // Load ordering is unspecified. Adopt identity order using model-owned
        // payloads after content verification, then execute arbitrary successful tails.
        if !continuing { model.items = reopened.items.map { actual in model.items.first { $0.id == actual.id }! } }
        for (step, operation) in scenario.tail.enumerated() {
            model.items = applying(operation, to: model.items)
            if ProcessInfo.processInfo.environment["BOUTIQUE_CONCURRENT_FAULT_CALIBRATE_TAIL"] != "1" {
                try await execute(operation, store: reopened)
            }
            try await verify(model.items, step: step)
            if !continuing { try discoveryRequire(sorted(reopened.items) == sorted(model.items), "concurrent.recovery-memory", step: step) }
            coverage.hit("recovery.\(operation.kind.rawValue)")
            let reload = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
            if !directReset && !continuing { reopened = reload }
            try discoveryRequire(sorted(reload.items) == sorted(model.items), "concurrent.recovery-reopen", step: step)
            if !continuing { model.items = reopened.items.map { actual in model.items.first { $0.id == actual.id }! } }
        }
    }
}
