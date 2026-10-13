import Foundation
import PropertyBased
import Testing
@testable import Boutique

@MainActor
@Suite("Store event discovery", .serialized)
struct StreamDiscoveryStoreEventsTests {
    @Test(.shrinking)
    func delayedEventConsumersAndStoredProjection() async throws {
        let item = zip(Gen.int(in: 0...3), Gen.int(in: 0...9))
            .map { EventItem(id: String($0), payload: $1) }
        let command = zip(Gen.int(in: 0...6), Gen.int(in: 0...2), item.array(of: 0...4))
            .map { EventCommand(kind: [.insert, .remove, .clear, .subscribe, .consume, .cancel, .insert][$0], slot: $1, items: $2) }
        try await DiscoveryProperty.check("store-event-consumers", count: DiscoveryProperty.backendCases,
            input: command.array(of: 1...DiscoveryProperty.steps)) { history, coverage in
            let directory = FileManager.Directory.temporary(appendingPath: "Boutique.EventDiscovery.\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let store = try await Store<EventItem>(storage: DiskStorageEngine(directory: directory), cacheIdentifier: \.id)
            let projection = Stored(in: store)
            var model: [EventItem] = []
            var latest = StoreEvent<EventItem>(operation: .loaded, items: [])
            var streams: [Int: AsyncStream<StoreEvent<EventItem>>] = [0: store.events]
            var queues: [Int: [StoreEvent<EventItem>]] = [0: [latest]]
            func publish(_ operation: StoreEvent<EventItem>.Operation, _ items: [EventItem]) {
                latest = StoreEvent(operation: operation, items: items)
                for slot in queues.keys.sorted() { queues[slot]!.append(latest) }
            }
            do {
                for (step, operation) in history.enumerated() {
                    coverage.hit("operation.\(operation.kind)")
                    switch operation.kind {
                    case .insert:
                        try await store.insert(operation.items)
                        var affected: [EventItem] = []
                        for item in operation.items {
                            if let position = model.firstIndex(where: { $0.id == item.id }) { model[position] = item }
                            else { model.append(item) }
                            if let position = affected.firstIndex(where: { $0.id == item.id }) { affected[position] = item }
                            else { affected.append(item) }
                        }
                        publish(.insert, affected)
                    case .remove:
                        // Present values keep event expectations independent of the
                        // ambiguous stale/absent-removal payload convention.
                        let keys = Set(operation.items.map(\.id))
                        let removed = model.filter { keys.contains($0.id) }
                        try await store.remove(removed)
                        model.removeAll { keys.contains($0.id) }
                        publish(.remove, removed)
                    case .clear:
                        let removed = model
                        try await store.removeAll()
                        model = []
                        publish(.remove, removed)
                    case .subscribe:
                        if let old = streams[operation.slot] { await discoveryCancel(old) }
                        streams[operation.slot] = store.events
                        queues[operation.slot] = [latest]
                    case .consume:
                        if let stream = streams[operation.slot], let expected = queues[operation.slot] {
                            let count = discoveryPrefixCount(selector: operation.items.count, available: expected.count)
                            let actual = try await discoveryRead(stream, count: count, step: step, invariant: "store.event-prefix-missing")
                            try discoveryRequire(eventsEqual(actual, Array(expected.prefix(count))), "store.event-prefix", step: step)
                            queues[operation.slot] = Array(expected.dropFirst(count))
                            coverage.hit("consumed", by: count)
                            if count > 0 && count < expected.count { coverage.hit("consume.partial") }
                        }
                    case .cancel:
                        if let old = streams.removeValue(forKey: operation.slot) {
                            await discoveryCancel(old)
                            queues.removeValue(forKey: operation.slot)
                        }
                    }
                    try discoveryRequire(projection.wrappedValue == model && store.items == model,
                                         "stored.projection", step: step)
                    try discoveryRequire(projection.projectedValue === store, "stored.identity", step: step)
                }
                // An out-of-domain payload is a terminal marker: queue comparison
                // catches extra events before it, not just missing expected events.
                let marker = EventItem(id: "sentinel", payload: -1)
                try await store.insert(marker)
                publish(.insert, [marker])
                for slot in streams.keys.sorted() {
                    let expected = queues[slot]!
                    let actual = try await discoveryRead(streams[slot]!, count: expected.count, step: history.count, invariant: "store.event-final-missing")
                    try discoveryRequire(eventsEqual(actual, expected), "store.event-final", step: history.count)
                }
            } catch {
                for stream in streams.values { await discoveryCancel(stream) }
                throw error
            }
            for stream in streams.values { await discoveryCancel(stream) }
        }
    }
}

private struct EventItem: Codable, Equatable, Sendable {
    let id: String
    let payload: Int
}

private struct EventCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case insert, remove, clear, subscribe, consume, cancel }
    let kind: Kind
    let slot: Int
    let items: [EventItem]
}

private func eventsEqual(_ lhs: [StoreEvent<EventItem>], _ rhs: [StoreEvent<EventItem>]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.operation == $1.operation && $0.items == $1.items }
}
