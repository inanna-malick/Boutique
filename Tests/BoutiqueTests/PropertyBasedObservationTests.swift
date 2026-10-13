@testable import Boutique
import Foundation
import Observation
import Testing

private struct ObservationItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let revision: Int
}

@MainActor
private struct StoreProjection {
    @Stored var items: [ObservationItem]

    init(store: Store<ObservationItem>) {
        self._items = Stored(in: store)
    }
}

@MainActor
@Suite("Generated observation and projection properties", .serialized)
struct PropertyBasedObservationTests {
    @Test("@Stored projection follows generated Store mutations")
    func storedProjectionFollowsStoreMutations() async throws {
        let store = try await Store<ObservationItem>(
            storage: SQLiteStorageEngine(directory: .temporary(appendingPath: "PropertyBasedObservation-\(UUID().uuidString)"))!,
            cacheIdentifier: \.id
        )
        let projection = StoreProjection(store: store)
        var model: [ObservationItem] = []
        var random = ObservationGenerator(seed: 0xA11CE)
        var revision = 0

        for _ in 0..<256 {
            let canRemove = !model.isEmpty
            let action = canRemove ? random.next(upperBound: 3) : 0

            switch action {
            case 0:
                let id = "item-\(random.next(upperBound: 8))"
                let item = ObservationItem(id: id, revision: revision)
                revision += 1
                try await store.insert(item)
                if let index = model.firstIndex(where: { $0.id == id }) {
                    model[index] = item
                } else {
                    model.append(item)
                }
            case 1:
                let index = random.next(upperBound: model.count)
                let item = model.remove(at: index)
                try await store.remove(item)
            default:
                try await store.removeAll()
                model.removeAll()
            }

            #expect(projection.items == model)
            #expect(projection.items == store.items)
        }
    }

    @Test("Store item reads invalidate a fresh observation tracker after each generated mutation")
    func storeItemObservationInvalidatesAfterMutations() async throws {
        let store = try await Store<ObservationItem>(
            storage: SQLiteStorageEngine(directory: .temporary(appendingPath: "PropertyBasedStoreObservation-\(UUID().uuidString)"))!,
            cacheIdentifier: \.id
        )
        var model: [ObservationItem] = []
        var random = ObservationGenerator(seed: 0x51A7E)
        var revision = 0

        for _ in 0..<128 {
            let invalidation = ObservationInvalidationCounter()
            withObservationTracking {
                _ = store.items
            } onChange: {
                invalidation.increment()
            }

            if model.isEmpty || random.next(upperBound: 2) == 0 {
                let id = "store-\(random.next(upperBound: 6))"
                let item = ObservationItem(id: id, revision: revision)
                revision += 1
                try await store.insert(item)
                if let index = model.firstIndex(where: { $0.id == id }) {
                    model[index] = item
                } else {
                    model.append(item)
                }
            } else {
                let item = model.remove(at: random.next(upperBound: model.count))
                try await store.remove(item)
            }

            #expect(invalidation.count == 1)
            #expect(store.items == model)
        }
    }

    @Test("StoredValue mutations invalidate a fresh observation tracker")
    func storedValueObservationInvalidatesAfterMutations() {
        let suiteName = "PropertyBasedObservation-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let storedValue = StoredValue<Int>(key: "counter", default: 0, storage: userDefaults)

        for expectedValue in 1...128 {
            let invalidation = ObservationInvalidationCounter()
            withObservationTracking {
                _ = storedValue.wrappedValue
            } onChange: {
                invalidation.increment()
            }

            storedValue.set(expectedValue)

            #expect(invalidation.count == 1)
            #expect(storedValue.wrappedValue == expectedValue)
        }
    }

    @Test("SecurelyStoredValue mutations invalidate a fresh observation tracker")
    func secureValueObservationInvalidatesAfterMutations() throws {
        let key = "PropertyBasedObservation.\(UUID().uuidString)"
        let storedValue = SecurelyStoredValue<String>(key: key, service: .test)
        defer { try? storedValue.remove() }

        // A unique key gives this generated trace a known empty initial state.
        #expect(storedValue.wrappedValue == nil)
        for index in 0..<64 {
            let invalidation = ObservationInvalidationCounter()
            withObservationTracking {
                _ = storedValue.wrappedValue
            } onChange: {
                invalidation.increment()
            }

            if index.isMultiple(of: 2) {
                try storedValue.set("value-\(index)")
                #expect(storedValue.wrappedValue == "value-\(index)")
            } else {
                try storedValue.remove()
                #expect(storedValue.wrappedValue == nil)
            }

            #expect(invalidation.count == 1)
        }
    }
}

private struct ObservationGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        self.state &+= 0x9E3779B97F4A7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Int(value % UInt64(upperBound))
    }
}

private final class ObservationInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedCount
    }

    func increment() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedCount += 1
    }
}
