import Foundation
import Testing
@testable import Boutique

@MainActor
@Suite("Store mutation concurrency")
struct StoreMutationConcurrencyTests {
    @Test(arguments: [false, true])
    func competingInsertsKeepBothItems(batch: Bool) async throws {
        let storage = MutationTestStorage()
        let store = try await Store<MutationTestItem>(storage: storage, cacheIdentifier: \.id)
        let firstItem = MutationTestItem(id: "first", payload: 1)
        let secondItem = MutationTestItem(id: "second", payload: 2)
        await storage.pauseNextMutation()
        let first = MutationTestCompletion.start { try await insert(firstItem, batch: batch, into: store) }
        guard await storage.waitUntilPaused() else {
            await storage.release()
            _ = await first.resultWithin(.seconds(1))
            Issue.record("The first write did not reach its suspension point")
            return
        }
        let second = MutationTestCompletion.start { try await insert(secondItem, batch: batch, into: store) }
        await second.waitUntilStarted()
        // A serialized second operation need not reach the backend. Bound the
        // attempt while the first is held, then release and join both operations.
        _ = await second.resultWithin(.seconds(1))
        await storage.release()
        let firstResult = await first.resultWithin(.seconds(1))
        let secondResult = await second.resultWithin(.seconds(1))
        try #require(firstResult).get()
        try #require(secondResult).get()
        let persisted = try await storage.decodedItems()
        #expect(persisted == [firstItem, secondItem])
        #expect(store.items.sorted { $0.id < $1.id } == persisted)
    }

    @Test(arguments: [false, true])
    func initialLoadAndInsertionKeepBothItems(batch: Bool) async throws {
        let initial = MutationTestItem(id: "initial", payload: 1)
        let inserted = MutationTestItem(id: "inserted", payload: 2)
        let storage = MutationTestStorage()
        try await storage.write(JSONEncoder().encode(initial), key: CacheKey(initial.id))
        await storage.pauseNextRead()
        let store = makeSynchronousStore(storage: storage)
        let loading = MutationTestCompletion.start { try await store.itemsHaveLoaded() }
        guard await storage.waitUntilPaused() else {
            await storage.release()
            _ = await loading.resultWithin(.seconds(1))
            Issue.record("The initial read did not reach its snapshot suspension point")
            return
        }
        let mutation = MutationTestCompletion.start { try await insert(inserted, batch: batch, into: store) }
        await mutation.waitUntilStarted()
        _ = await mutation.resultWithin(.seconds(1))
        await storage.release()
        let loadedResult = await loading.resultWithin(.seconds(1))
        let mutationResult = await mutation.resultWithin(.seconds(1))
        try #require(loadedResult).get()
        try #require(mutationResult).get()
        let persisted = try await storage.decodedItems()
        #expect(persisted == [initial, inserted])
        #expect(store.items.sorted { $0.id < $1.id } == persisted)
    }

    @Test(arguments: [false, true])
    func sequentialInsertControl(batch: Bool) async throws {
        let storage = MutationTestStorage()
        let store = try await Store<MutationTestItem>(storage: storage, cacheIdentifier: \.id)
        try await insert(.init(id: "first", payload: 1), batch: batch, into: store)
        try await insert(.init(id: "second", payload: 2), batch: batch, into: store)
        #expect(store.items.sorted { $0.id < $1.id } == (try await storage.decodedItems()))
        #expect(store.items.count == 2)
    }

    private func makeSynchronousStore(storage: MutationTestStorage) -> Store<MutationTestItem> {
        Store(storage: storage, cacheIdentifier: \.id)
    }

    private func insert(_ item: MutationTestItem, batch: Bool, into store: Store<MutationTestItem>) async throws {
        if batch { try await store.insert([item]) as Void }
        else { try await store.insert(item) as Void }
    }
}

private struct MutationTestItem: Codable, Sendable, Equatable {
    let id: String
    let payload: Int
}

/// Standalone storage fixture: no generated discovery infrastructure is needed
/// to replay these regressions. A read is gated after taking its snapshot; a
/// mutation is gated before its commit.
private actor MutationTestStorage: StorageEngine {
    private var values: [CacheKey: Data] = [:]
    private var pauseRead = false
    private var pauseMutation = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observers: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func pauseNextRead() { pauseRead = true }
    func pauseNextMutation() { pauseMutation = true }
    func waitUntilPaused() async -> Bool {
        if gate != nil { return true }
        let id = UUID()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            observers.removeValue(forKey: id)?.resume(returning: false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { observers[id] = $0 }
    }
    func release() {
        pauseRead = false; pauseMutation = false
        let pending = gate; gate = nil; pending?.resume()
        let waiting = observers; observers = [:]
        waiting.values.forEach { $0.resume(returning: false) }
    }
    private func suspend() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            let pending = observers; observers = [:]
            pending.values.forEach { $0.resume(returning: true) }
        }
    }
    private func beforeMutation() async throws {
        if pauseMutation {
            pauseMutation = false
            await suspend()
        }
    }
    func write(_ data: Data, key: CacheKey) async throws { try await beforeMutation(); values[key] = data }
    func write(_ entries: [(key: CacheKey, data: Data)]) async throws {
        try await beforeMutation()
        for entry in entries { values[entry.key] = entry.data }
    }
    func remove(key: CacheKey) async throws { try await beforeMutation(); values.removeValue(forKey: key) }
    func remove(keys: [CacheKey]) async throws { try await beforeMutation(); keys.forEach { values.removeValue(forKey: $0) } }
    func removeAllData() async throws { try await beforeMutation(); values = [:] }
    func readAllData() async -> [Data] {
        let entries = await readAllDataAndKeys()
        return entries.map(\.data)
    }
    func readAllDataAndKeys() async -> [(key: CacheKey, data: Data)] {
        let snapshot = values.sorted { $0.key.value < $1.key.value }.map { (key: $0.key, data: $0.value) }
        if pauseRead { pauseRead = false; await suspend() }
        return snapshot
    }
    func decodedItems() throws -> [MutationTestItem] {
        try values.values.map { try JSONDecoder().decode(MutationTestItem.self, from: $0) }.sorted { $0.id < $1.id }
    }
    func read(key: CacheKey) -> Data? { values[key] }
    func readDataAndKeys(keys: [CacheKey]) -> [(key: CacheKey, data: Data)] { keys.compactMap { key in values[key].map { (key, $0) } } }
    func allKeys() -> [CacheKey] { Array(values.keys) }
    func keyExists(_ key: CacheKey) -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) -> Date? { nil }
    func updatedAt(key: CacheKey) -> Date? { nil }
}

/// A bounded observation of an unstructured task leaves the task alive on a
/// timeout, so the fixture can release its gate before joining it.
@MainActor
private final class MutationTestCompletion {
    private var finished: Result<Void, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [UUID: CheckedContinuation<Result<Void, Error>?, Never>] = [:]

    static func start(_ body: @escaping @MainActor () async throws -> Void) -> MutationTestCompletion {
        let completion = MutationTestCompletion()
        Task {
            completion.started = true
            let starting = completion.startWaiters; completion.startWaiters = []
            starting.forEach { $0.resume() }
            let result: Result<Void, Error>
            do { try await body(); result = .success(()) }
            catch { result = .failure(error) }
            completion.finished = result
            let pending = completion.waiters; completion.waiters = [:]
            pending.values.forEach { $0.resume(returning: result) }
        }
        return completion
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resultWithin(_ duration: Duration) async -> Result<Void, Error>? {
        if let finished { return finished }
        let id = UUID()
        let timeout = Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            waiters.removeValue(forKey: id)?.resume(returning: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { waiters[id] = $0 }
    }
}
