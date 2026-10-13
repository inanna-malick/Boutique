import Foundation
import PropertyBased
import Testing
@testable import Boutique

private enum SecureStreamAction: String, Codable, Sendable {
    case set, remove, peerSet, peerRemove, read, subscribe, consume, cancel, reopen, rejectEncoding
}
private struct SecureStreamCommand: Codable, Sendable {
    let action: SecureStreamAction
    var operand: Int = 0
    var slot: Int = 0
}

@MainActor
@Suite("SecureStreamDiscovery cross-wrapper publication", .serialized)
struct SecureStreamDiscoveryTests {
    @Test(.shrinking)
    func histories() async throws {
        let command = zip(Gen.int(in: 0...9), Gen.int(in: -8...8), Gen.int(in: 0...2)).map {
            SecureStreamCommand(action: [.set, .remove, .peerSet, .peerRemove, .read,
                                         .subscribe, .consume, .cancel, .reopen, .rejectEncoding][$0],
                                operand: $1, slot: $2)
        }
        let histories = command.array(of: 1...40).map { random in
            // Prefix establishes silent refresh and late replay independently of randomness.
            [.init(action: .subscribe), .init(action: .peerSet, operand: 3),
             .init(action: .read), .init(action: .subscribe, slot: 1),
             .init(action: .peerRemove), .init(action: .remove), .init(action: .remove)] + random + [
                // Reopen resets subscription ownership; stale cache survives a peer removal.
                .init(action: .reopen), .init(action: .subscribe), .init(action: .set, operand: 4),
                .init(action: .peerRemove), .init(action: .remove), .init(action: .remove),
                .init(action: .rejectEncoding), .init(action: .set, operand: 5)]
        }
        try await DiscoveryProperty.check("secure-streams", count: DiscoveryProperty.backendCases, input: histories) { history, coverage in
            let service = KeychainService(value: "Boutique.SecureStreams.\(UUID())")
            var wrapper = SecurelyStoredValue<Double>(key: "value", service: service)
            let peer = SecurelyStoredValue<Double>(key: "value", service: service)
            defer { try? peer.remove() }
            var persisted: Double?
            var cached: Double?
            var streams: [Int: AsyncStream<Double?>] = [:]
            var expected: [Int: [Double?]] = [:]

            func publish(_ value: Double?) {
                for slot in expected.keys.sorted() { expected[slot]!.append(value) }
            }
            func cleanup() async {
                for slot in streams.keys.sorted() { await discoveryCancel(streams[slot]!) }
                streams.removeAll(); expected.removeAll()
            }
            func flush(step: Int) async throws {
                for slot in streams.keys.sorted() {
                    let queue = expected[slot]!
                    let actual = try await discoveryRead(streams[slot]!, count: queue.count,
                                                         step: step, invariant: "secure-stream.missing")
                    try discoveryRequire(actual == queue, "secure-stream.queue", step: step)
                    expected[slot] = []
                }
            }
            do {
                for (step, command) in history.enumerated() {
                    coverage.hit("operation.\(command.action.rawValue)")
                    switch command.action {
                    case .set:
                        var value = Double(command.operand)
                        while value == cached || value == persisted { value += 10001 }
                        try wrapper.set(value)
                        persisted = value; cached = value; publish(value)
                    case .remove:
                        try wrapper.remove()
                        persisted = nil
                        if cached != nil { cached = nil; publish(nil); coverage.hit("remove.published") }
                        else { coverage.hit("remove.silent") }
                    case .peerSet:
                        let value = Double(command.operand)
                        try peer.set(value); persisted = value
                    case .peerRemove:
                        try peer.remove(); persisted = nil
                        if cached != nil { coverage.hit("peer-remove.stale-cache") }
                    case .read:
                        try discoveryRequire(wrapper.wrappedValue == persisted, "secure-stream.read", step: step)
                        cached = persisted
                        coverage.hit("read.silent-refresh")
                    case .subscribe:
                        if let old = streams[command.slot] { await discoveryCancel(old) }
                        streams[command.slot] = wrapper.values
                        expected[command.slot] = [cached]
                    case .consume:
                        if let stream = streams[command.slot] {
                            let count = discoveryPrefixCount(selector: command.operand, available: expected[command.slot]!.count)
                            let actual = try await discoveryRead(stream, count: count, step: step,
                                                                 invariant: "secure-stream.consume-missing")
                            try discoveryRequire(actual == Array(expected[command.slot]!.prefix(count)),
                                                 "secure-stream.consume", step: step)
                            expected[command.slot]!.removeFirst(count)
                            coverage.hit("consumed", by: count)
                        }
                    case .cancel:
                        if let stream = streams.removeValue(forKey: command.slot) { await discoveryCancel(stream) }
                        expected.removeValue(forKey: command.slot)
                    case .reopen:
                        try await flush(step: step)
                        await cleanup()
                        wrapper = SecurelyStoredValue(key: "value", service: service)
                        cached = persisted
                    case .rejectEncoding:
                        var threw = false
                        do { try wrapper.set(.infinity) } catch { threw = true }
                        try discoveryRequire(threw, "secure-stream.encoding", step: step)
                        // set() reads the Keychain before encoding; rejection must not publish,
                        // but that successful read refreshes the private fallback cache.
                        cached = persisted
                    }
                }
                try await flush(step: history.count)
                // An extra publication must precede this sentinel and become observable.
                let sentinel = 999_999.0
                try wrapper.set(sentinel)
                for slot in streams.keys.sorted() {
                    let actual = try await discoveryRead(streams[slot]!, count: 1, step: history.count,
                                                         invariant: "secure-stream.sentinel-missing")
                    try discoveryRequire(actual == [sentinel], "secure-stream.unexpected-event", step: history.count)
                }
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }
    }
}
