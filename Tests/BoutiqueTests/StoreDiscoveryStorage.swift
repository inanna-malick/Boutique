import Foundation
@testable import Boutique

/// Suspension and failure points are explicit storage calls/commit boundaries,
/// not clock delays. Snapshot reads can be paused after taking their snapshot.
actor StoreDiscoveryStorage: StorageEngine {
    enum Failure: Error { case injected, gateTimedOut }
    struct Call: Sendable { let kind: String; let keys: [String] }
    private var values: [CacheKey: Data] = [:]
    private(set) var calls: [Call] = []
    private(set) var commits: [Call] = []
    private var fault: (kind: String, after: Int)?
    private var gatedKind: String?
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var reached = false
    private var observers: [UUID: CheckedContinuation<Void, Error>] = [:]

    func fail(_ kind: String, after: Int) { fault = (kind, after) }
    func pause(_ kind: String) { gatedKind = kind; reached = false }
    func waitForGate(timeout duration: Duration = .seconds(5)) async throws {
        if reached { return }
        let id = UUID()
        let timeout = Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            self.expire(id)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { observers[id] = continuation }
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }
    private func expire(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume(throwing: Failure.gateTimedOut)
    }
    func release() {
        gatedKind = nil
        if !gates.isEmpty { gates.removeFirst().resume() }
    }
    func releaseAll() {
        gatedKind = nil
        let pending = gates; gates = []; pending.forEach { $0.resume() }
    }
    private func enter(_ kind: String, keys: [CacheKey] = []) async {
        calls.append(Call(kind: kind, keys: keys.map(\.value)))
        if gatedKind == kind || (gatedKind == "mutation" && ["write", "batch", "remove", "removeBatch", "clear"].contains(kind)) {
            gatedKind = nil
            await withCheckedContinuation { continuation in
                gates.append(continuation); reached = true
                let waiting = observers; observers = [:]; waiting.values.forEach { $0.resume() }
            }
        }
    }
    private func check(_ kind: String, committed: Int) throws {
        if let fault, fault.kind == kind && fault.after == committed {
            self.fault = nil
            throw Failure.injected
        }
    }
    func write(_ data: Data, key: CacheKey) async throws {
        await enter("write", keys: [key]); try check("write", committed: 0)
        values[key] = data; commits.append(Call(kind: "write", keys: [key.value])); try check("write", committed: 1)
    }
    func write(_ entries: [(key: CacheKey, data: Data)]) async throws {
        await enter("batch", keys: entries.map(\.key)); try check("batch", committed: 0)
        for (index, entry) in entries.enumerated() { values[entry.key] = entry.data; commits.append(Call(kind: "write", keys: [entry.key.value])); try check("batch", committed: index + 1) }
    }
    func remove(key: CacheKey) async throws {
        await enter("remove", keys: [key]); try check("remove", committed: 0)
        values.removeValue(forKey: key); commits.append(Call(kind: "remove", keys: [key.value])); try check("remove", committed: 1)
    }
    func remove(keys: [CacheKey]) async throws {
        await enter("removeBatch", keys: keys); try check("removeBatch", committed: 0)
        for (index, key) in keys.enumerated() { values.removeValue(forKey: key); commits.append(Call(kind: "remove", keys: [key.value])); try check("removeBatch", committed: index + 1) }
    }
    func removeAllData() async throws {
        await enter("clear"); try check("clear", committed: 0)
        values = [:]; commits.append(Call(kind: "clear", keys: [])); try check("clear", committed: 1)
    }
    func readAllData() async -> [Data] {
        let snapshot = values.sorted { $0.key.value < $1.key.value }.map(\.value)
        await enter("readAll")
        return snapshot
    }
    func read(key: CacheKey) -> Data? { values[key] }
    func readDataAndKeys(keys: [CacheKey]) -> [(key: CacheKey, data: Data)] { keys.compactMap { key in values[key].map { (key, $0) } } }
    func allKeys() -> [CacheKey] { Array(values.keys) }
    func keyExists(_ key: CacheKey) -> Bool { values[key] != nil }
    func createdAt(key: CacheKey) -> Date? { nil }
    func updatedAt(key: CacheKey) -> Date? { nil }
}

/// An unstructured operation can be awaited with a deadline without putting a
/// noncooperative storage-gated task inside a task group that must join to return.
actor StoreDiscoveryCompletion {
    private var result: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func hasFinished() -> Bool { result != nil }

    func finish(_ result: Result<Void, Error>) {
        self.result = result
        let pending = waiters; waiters = [:]
        pending.values.forEach { $0.resume(with: result) }
    }

    func wait(timeout duration: Duration) async throws {
        if let result { return try result.get() }
        let id = UUID()
        let timeout = Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            self.expire(id)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: StoreDiscoveryStorage.Failure.gateTimedOut)
    }
}
