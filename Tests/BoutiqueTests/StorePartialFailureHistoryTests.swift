import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct PartialFailureScenario: Codable, Sendable {
    enum Fault: String, Codable, Sendable, CaseIterable {
        case insertSingle, insertBatch, removeSingle, removeBatch, clear
        case fusedClearWrite, fusedClearRemoval, fusedSelectiveWrite, fusedSelectiveRemoval
    }
    var prefix: [StoreDiscoveryCommand]
    var fault: Fault
    var position: Int
    var payload: Int
    var continuation: [StoreDiscoveryScenario.Step]
}

@MainActor
@Suite("Store partial failure histories")
struct StorePartialFailureHistoryTests {
    private func generator() -> Generator<PartialFailureScenario, some Sequence> {
        let draw = zip(Gen.int(in: 0...4), Gen.int(in: 0...4), Gen.int(in: -10...10), Gen.int(in: 0...15))
        return zip(draw.array(of: 0...12), Gen.int(in: 0...8), Gen.int(in: 0...20), Gen.int(in: -20...20), draw.array(of: 1...DiscoveryProperty.steps)).map { prefix, fault, position, payload, tail in
            func command(_ draw: (Int, Int, Int, Int)) -> StoreDiscoveryCommand {
                let (kind, key, value, flags) = draw
                let a = StoreDiscoveryItem(id: "k\(key)", payload: value)
                let b = StoreDiscoveryItem(id: "k\((key + 1) % 5)", payload: value + 1)
                let operands = flags % 5 == 0 ? [] : [a, StoreDiscoveryItem(id: a.id, payload: value + 2), b]
                return .init(kind: [.insert, .batch, .remove, .removeBatch, .clear][kind], items: kind == 1 || kind == 3 ? operands : [a])
            }
            var steps: [StoreDiscoveryScenario.Step] = []
            for value in tail {
                let command = command(value)
                if value.3 % 3 == 0, let index = steps.indices.last, steps[index].queued, steps[index].commands.count < 6 {
                    steps[index].commands.append(command)
                } else {
                    steps.append(.init(commands: [command], queued: value.3 % 3 == 0, reopen: value.3 == 14, observe: value.3 % 2 == 0))
                }
            }
            // A constructed suffix specifically exercises clear fusion after continued use.
            steps.append(.init(commands: [.init(kind: .clear, items: []), .init(kind: .batch, items: [.init(id: "replacement", payload: payload + 100)])], queued: true, reopen: true))
            return PartialFailureScenario(prefix: prefix.map(command), fault: .allCases[fault], position: position, payload: payload, continuation: steps)
        }
    }

    @Test(.shrinking) func reopenedContinuationControls() async throws {
        try await DiscoveryProperty.check("partial-failure-reopened", input: generator()) { scenario, coverage in
            try await replay(scenario, recoverByReopening: true, allowFusedClear: true, coverage: coverage)
        }
    }

    @Test(.shrinking) func directClearContinuationControls() async throws {
        try await DiscoveryProperty.check("partial-failure-direct", input: generator()) { scenario, coverage in
            try await replay(scenario, recoverByReopening: false, allowFusedClear: false, coverage: coverage)
        }
    }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PARTIAL_FAILURE_FINDINGS"] == "1"))
    func fusedClearContinuationSearch() async throws {
        try await DiscoveryProperty.check("partial-failure-fused", input: generator()) { scenario, coverage in
            try await replay(scenario, recoverByReopening: false, allowFusedClear: true, coverage: coverage)
        }
    }

    private func replay(_ scenario: PartialFailureScenario, recoverByReopening: Bool, allowFusedClear: Bool, coverage: DiscoveryCoverage) async throws {
        let storage = StoreDiscoveryStorage()
        var store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
        var memory = StoreDiscoveryModel()
        var persisted = StoreDiscoveryModel()
        for command in scenario.prefix {
            try await execute(command, store: store)
            memory.apply(command); persisted.apply(command)
            try discoveryRequire(store.items == memory.items, "partial.prefix.memory", step: -1)
            try discoveryRequire(try await decoded(storage) == sorted(persisted.items), "partial.prefix.persistence", step: -1)
            coverage.hit("prefix-operation")
        }
        // Establish present keys for removal schedules; other generated prefix keys survive.
        let setup = (0..<3).map { StoreDiscoveryItem(id: "k\($0)", payload: scenario.payload) }
        let setupCommand = StoreDiscoveryCommand(kind: .batch, items: setup)
        try await execute(setupCommand, store: store)
        memory.apply(setupCommand); persisted.apply(setupCommand)
        let before = memory.items
        let inserted = [StoreDiscoveryItem(id: "k0", payload: scenario.payload + 1),
                        .init(id: "fault0", payload: scenario.payload + 2),
                        .init(id: "fault0", payload: scenario.payload + 3),
                        .init(id: "fault1", payload: scenario.payload + 4)]
        var deduplicated = StoreDiscoveryModel()
        deduplicated.apply(.init(kind: .batch, items: inserted))
        let removed = [setup[0], setup[1], setup[0], setup[2]]
        let selective = [setup[0], setup[1]]
        let commands: [StoreDiscoveryCommand]
        let faultKind: String
        let commitOperands: [StoreDiscoveryItem]
        let removalPhase: Bool
        switch scenario.fault {
        case .insertSingle:
            commands = [.init(kind: .insert, items: [inserted[1]])]; faultKind = "write"; commitOperands = [inserted[1]]; removalPhase = false
        case .insertBatch:
            commands = [.init(kind: .batch, items: inserted)]; faultKind = "batch"; commitOperands = deduplicated.items; removalPhase = false
        case .removeSingle:
            commands = [.init(kind: .remove, items: [setup[0]])]; faultKind = "remove"; commitOperands = [setup[0]]; removalPhase = true
        case .removeBatch:
            commands = [.init(kind: .removeBatch, items: removed)]; faultKind = "removeBatch"; commitOperands = removed; removalPhase = true
        case .clear:
            commands = [.init(kind: .clear, items: [])]; faultKind = "clear"; commitOperands = [.init(id: "unused", payload: 0)]; removalPhase = true
        case .fusedClearWrite, .fusedSelectiveWrite:
            let clear = scenario.fault == .fusedClearWrite
            commands = [.init(kind: clear ? .clear : .removeBatch, items: selective), .init(kind: .batch, items: inserted)]
            faultKind = "batch"; commitOperands = deduplicated.items; removalPhase = false
            persisted.apply(commands[0])
        case .fusedClearRemoval, .fusedSelectiveRemoval:
            let clear = scenario.fault == .fusedClearRemoval
            commands = [.init(kind: clear ? .clear : .removeBatch, items: selective), .init(kind: .batch, items: inserted)]
            commitOperands = clear ? before : selective
            faultKind = commitOperands.count == 1 ? "remove" : "removeBatch"; removalPhase = true
        }
        let committed = scenario.position % (commitOperands.count + 1)
        await storage.fail(faultKind, after: committed)
        var threw = false
        do { try await run(commands, queued: commands.count > 1, store: store) }
        catch StoreDiscoveryStorage.Failure.injected { threw = true }
        try discoveryRequire(threw, "partial.fault.propagation", step: 0)
        if scenario.fault == .clear {
            if committed == 1 { persisted.apply(.init(kind: .clear, items: [])) }
        } else {
            persisted.apply(.init(kind: removalPhase ? .removeBatch : .batch, items: Array(commitOperands.prefix(committed))))
        }
        try discoveryRequire(try await decoded(storage) == sorted(persisted.items), "partial.fault.committed-prefix", step: 0)
        coverage.hit("fault-\(scenario.fault.rawValue)"); coverage.hit("committed-\(committed)")
        coverage.hit(committed == 0 ? "zero-commit" : committed == commitOperands.count ? "full-commit-before-error" : "partial-commit")

        if recoverByReopening {
            store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
            try discoveryRequire(sorted(store.items) == sorted(persisted.items), "partial.recovery.reopen", step: 0)
            memory.items = store.items.map { observed in persisted.items.first { $0.id == observed.id }! }
            coverage.hit("reopen-recovery")
        } else {
            // Failed-call memory semantics have no established promise. Adopt only
            // selection/order of independently authored versions, never an expected
            // payload obtained from Store.items. This baseline constrains later
            // successful calls; it makes no assertion about rollback/reconciliation.
            let knownVersions = before + inserted
            memory.items = try store.items.map { observed in
                try discoveryUnwrap(knownVersions.first { $0 == observed }, "partial.fixture.unknown-memory-version")
            }
            coverage.hit("unreconciled-continuation")
            coverage.hit("memory-persistence-differ", by: sorted(memory.items) == sorted(persisted.items) ? 0 : 1)
        }
        for (offset, step) in scenario.continuation.enumerated() {
            let index = offset + 1
            // Direct controls retain selective fusion and arbitrary queued chains,
            // but split clear+insert at the explicit clear boundary.
            let calibrate = ProcessInfo.processInfo.environment["BOUTIQUE_PARTIAL_FAILURE_CALIBRATE_DROP_INSERT"] == "1"
            let executed = calibrate ? step.commands.filter { $0.kind != .insert && $0.kind != .batch } : step.commands
            let shouldQueue = !executed.isEmpty && step.queued && (allowFusedClear || !executed.contains { $0.kind == .clear })
            let memoryBefore = store.items
            let persistedBefore = try await decoded(storage)
            if shouldQueue {
                let chain = try await enqueue(executed[0], store: store, chain: nil)
                for command in executed.dropFirst() { _ = try await enqueue(command, store: store, chain: chain) }
                let queuedPersistence = try await decoded(storage)
                try discoveryRequire(store.items == memoryBefore && queuedPersistence == persistedBefore, "partial.queue.deferred", step: index)
                try await chain.run()
                try await chain.run()
                coverage.hit("queued-chain"); coverage.hit("chain-length-\(step.commands.count)")
            } else { try await run(executed, queued: false, store: store) }
            for command in step.commands {
                coverage.hit("continuation-\(command.kind.rawValue)")
                coverage.hit("unequal-overwrite", by: command.items.filter { item in memory.items.contains { $0.id == item.id && $0.payload != item.payload } }.count)
                if command.items.isEmpty { coverage.hit("empty-operands") }
                if Set(command.items.map(\.id)).count < command.items.count { coverage.hit("duplicate-operands") }
                memory.apply(command); persisted.apply(command)
            }
            try discoveryRequire(store.items == memory.items, "partial.successful.memory", step: index,
                                 "expected \(memory.items); actual \(store.items)")
            if step.observe || step.reopen || offset == scenario.continuation.count - 1 {
                let actual = try await decoded(storage)
                try discoveryRequire(actual == sorted(persisted.items), "partial.successful.persistence", step: index,
                                     "expected \(sorted(persisted.items)); actual \(actual); commands \(step.commands.map(\.kind))")
                coverage.hit("persistence-read")
            } else { coverage.hit("delayed-read") }
            if step.reopen {
                store = try await Store<StoreDiscoveryItem>(storage: storage, cacheIdentifier: \.id)
                try discoveryRequire(sorted(store.items) == sorted(persisted.items), "partial.successful.reopen", step: index)
                memory.items = store.items.map { observed in persisted.items.first { $0.id == observed.id }! }
                coverage.hit("continuation-reopen")
            }
        }
    }

    private func sorted(_ items: [StoreDiscoveryItem]) -> [StoreDiscoveryItem] { items.sorted { $0.id < $1.id } }
    private func decoded(_ storage: StoreDiscoveryStorage) async throws -> [StoreDiscoveryItem] {
        let result = try await storage.readAllData().map { try JSONDecoder().decode(StoreDiscoveryItem.self, from: $0) }
        try discoveryRequire(Set(result.map(\.id)).count == result.count, "partial.persisted-duplicate", step: -1)
        return sorted(result)
    }
    private func execute(_ command: StoreDiscoveryCommand, store: Store<StoreDiscoveryItem>) async throws {
        switch command.kind {
        case .insert: try await store.insert(command.items[0]) as Void
        case .batch: try await store.insert(command.items) as Void
        case .remove: try await store.remove(command.items[0]) as Void
        case .removeBatch: try await store.remove(command.items) as Void
        case .clear: try await store.removeAll() as Void
        }
    }
    private func run(_ commands: [StoreDiscoveryCommand], queued: Bool, store: Store<StoreDiscoveryItem>) async throws {
        if queued {
            let chain = try await enqueue(commands[0], store: store, chain: nil)
            for command in commands.dropFirst() { _ = try await enqueue(command, store: store, chain: chain) }
            try await chain.run()
        } else { for command in commands { try await execute(command, store: store) } }
    }
    private func enqueue(_ command: StoreDiscoveryCommand, store: Store<StoreDiscoveryItem>, chain: Store<StoreDiscoveryItem>.Operation?) async throws -> Store<StoreDiscoveryItem>.Operation {
        if let chain {
            switch command.kind {
            case .insert: return try await chain.insert(command.items[0])
            case .batch: return try await chain.insert(command.items)
            case .remove: return try await chain.remove(command.items[0])
            case .removeBatch: return try await chain.remove(command.items)
            case .clear: return try await chain.removeAll()
            }
        }
        switch command.kind {
        case .insert: return try await store.insert(command.items[0])
        case .batch: return try await store.insert(command.items)
        case .remove: return try await store.remove(command.items[0])
        case .removeBatch: return try await store.remove(command.items)
        case .clear: return try await store.removeAll()
        }
    }
}
