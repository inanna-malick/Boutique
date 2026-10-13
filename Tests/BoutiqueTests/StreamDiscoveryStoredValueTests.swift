import Foundation
import PropertyBased
import Testing
@testable import Boutique

@MainActor
@Suite("StoredValue stream discovery", .serialized)
struct StreamDiscoveryStoredValueTests {
    @Test(.shrinking)
    func mixedPersistenceAndSubscriberHistories() async throws {
        let command = zip(Gen.int(in: 0...7), Gen.int(in: 0...2), Gen.int(in: -20...20))
            .map { ValueStreamCommand(kind: [.set, .set, .reset, .failedEncoding, .reopen, .subscribe, .consume, .cancel][$0], slot: $1, value: $2) }
        try await DiscoveryProperty.check("stored-value-streams",
            input: command.array(of: 1...DiscoveryProperty.steps)) { history, coverage in
            let suite = "Boutique.StreamDiscovery.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let initial = StreamValue(payload: 0, rejectsEncoding: false)
            var wrapper = StoredValue(key: "value", default: initial, storage: defaults)
            var model = initial
            var streams: [Int: AsyncStream<StreamValue>] = [0: wrapper.values]
            var queues: [Int: [StreamValue]] = [0: [initial]]
            func publish(_ value: StreamValue) {
                for slot in queues.keys.sorted() { queues[slot]!.append(value) }
            }
            @MainActor func verifyAndFlush(step: Int, appendSentinel: Bool = true) async throws {
                // Distinct sentinel catches extras as well as missing events, including
                // an incorrectly emitted failed-encoding or equal-value publication.
                let sentinel = StreamValue(payload: 1_000_000 + step, rejectsEncoding: false)
                if appendSentinel {
                    wrapper.set(sentinel)
                    model = sentinel
                    publish(sentinel)
                }
                for slot in streams.keys.sorted() {
                    let expected = queues[slot]!
                    let actual = try await discoveryCollect(streams[slot]!, count: expected.count)
                    try discoveryRequire(actual == expected, "stored-value.stream-events", step: step,
                                         "actual=\(actual), expected=\(expected)")
                    queues[slot] = []
                    coverage.hit("consumed", by: actual.count)
                }
            }
            do {
                for (step, operation) in history.enumerated() {
                    coverage.hit("operation.\(operation.kind)")
                    switch operation.kind {
                    case .set:
                        model = StreamValue(payload: operation.value, rejectsEncoding: false)
                        wrapper.set(model)
                        publish(model)
                    case .reset:
                        wrapper.reset()
                        model = initial
                        publish(model)
                    case .failedEncoding:
                        wrapper.set(StreamValue(payload: operation.value, rejectsEncoding: true))
                        coverage.hit("failed-encoding")
                    case .reopen:
                        try await verifyAndFlush(step: step, appendSentinel: false)
                        for stream in streams.values { await discoveryCancel(stream) }
                        wrapper = StoredValue(key: "value", default: initial, storage: defaults)
                        streams = [0: wrapper.values]
                        queues = [0: [model]]
                        coverage.hit("reopen")
                    case .subscribe:
                        if let old = streams[operation.slot] { await discoveryCancel(old) }
                        streams[operation.slot] = wrapper.values
                        queues[operation.slot] = [model]
                    case .consume:
                        try await verifyAndFlush(step: step)
                    case .cancel:
                        if let old = streams.removeValue(forKey: operation.slot) {
                            await discoveryCancel(old)
                            queues.removeValue(forKey: operation.slot)
                            coverage.hit("cancel.live")
                        }
                    }
                    try discoveryRequire(wrapper.wrappedValue == model, "stored-value.stream-state", step: step)
                }
                try await verifyAndFlush(step: history.count)
            } catch {
                for stream in streams.values { await discoveryCancel(stream) }
                throw error
            }
            for stream in streams.values { await discoveryCancel(stream) }
        }
    }
}

private struct ValueStreamCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case set, reset, failedEncoding, reopen, subscribe, consume, cancel }
    let kind: Kind
    let slot: Int
    let value: Int
}

private struct StreamValue: Codable, Equatable, Sendable {
    let payload: Int
    let rejectsEncoding: Bool

    enum CodingKeys: String, CodingKey { case payload, rejectsEncoding }
    enum DeliberateFailure: Error { case encoding }
    func encode(to encoder: any Encoder) throws {
        if rejectsEncoding { throw DeliberateFailure.encoding }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payload, forKey: .payload)
        try container.encode(rejectsEncoding, forKey: .rejectsEncoding)
    }
}
