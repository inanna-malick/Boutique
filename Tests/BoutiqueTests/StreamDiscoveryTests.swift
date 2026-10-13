import Foundation
import PropertyBased
import Testing
@testable import Boutique

@MainActor
@Suite("Stream discovery", .serialized)
struct StreamDiscoveryTests {
    @Test(.shrinking)
    func subscriberOperationHistories() async throws {
        let commands = zip(Gen.int(in: 0...7), Gen.int(in: 0...2), Gen.int(in: -20...20))
            .map { StreamCommand(kind: [.send, .send, .assign, .add, .subscribe, .consume, .cancel, .resubscribe][$0], slot: $1, value: $2) }
        let scenarios = zip(Gen.int(in: 0...2), Gen.int(in: 0...4),
                            commands.array(of: 1...DiscoveryProperty.steps))
            .map { StreamScenario(policy: $0, capacity: $1, commands: $2) }
        try await DiscoveryProperty.check("subject-subscribers", input: scenarios) { scenario, coverage in
            try await run(scenario, coverage: coverage)
        }
    }

    @Test(arguments: [0, 1, 2])
    func requiredPartialConsumptionLifecycle(policy: Int) async throws {
        let scenario = StreamScenario(policy: policy, capacity: 2, commands: [
            .init(kind: .subscribe, slot: 1, value: 0),
            .init(kind: .send, slot: 0, value: 1),
            .init(kind: .send, slot: 0, value: 2),
            .init(kind: .consume, slot: 0, value: 2),
            .init(kind: .send, slot: 0, value: 3),
            .init(kind: .cancel, slot: 0, value: 0),
            .init(kind: .send, slot: 0, value: 4),
            .init(kind: .consume, slot: 1, value: 1),
            .init(kind: .resubscribe, slot: 0, value: 0),
            .init(kind: .send, slot: 0, value: 5)
        ])
        let coverage = DiscoveryCoverage()
        try await run(scenario, coverage: coverage)
        #expect(coverage.counts["consume.partial", default: 0] == 1)
        #expect(coverage.counts["cancel.live", default: 0] == 1)
        #expect(coverage.counts["operation.resubscribe", default: 0] == 1)
    }

    private func run(_ scenario: StreamScenario, coverage: DiscoveryCoverage) async throws {
            let policy: AsyncStream<Int>.Continuation.BufferingPolicy
            switch scenario.policy {
            case 0: policy = .unbounded
            case 1: policy = .bufferingOldest(scenario.capacity)
            default: policy = .bufferingNewest(scenario.capacity)
            }
            coverage.hit("policy.\(scenario.policy).capacity.\(scenario.capacity)")
            let subject = AsyncValueSubject(0, bufferingPolicy: policy)
            var value = 0
            var subscribers: [Int: AsyncStream<Int>] = [:]
            var queues: [Int: [Int]] = [:]
            func publish(_ event: Int) {
                for slot in queues.keys.sorted() {
                    var queue = queues[slot]!
                    if scenario.policy == 0 { queue.append(event) }
                    else if scenario.policy == 1 {
                        if queue.count < scenario.capacity { queue.append(event) }
                    } else if scenario.capacity > 0 {
                        queue.append(event)
                        if queue.count > scenario.capacity { queue.removeFirst() }
                    }
                    queues[slot] = queue
                }
            }
            func subscribe(_ slot: Int) {
                subscribers[slot] = subject.values
                queues[slot] = scenario.policy == 0 || scenario.capacity > 0 ? [value] : []
            }
            subscribe(0)
            do {
                for (step, command) in scenario.commands.enumerated() {
                    coverage.hit("operation.\(command.kind)")
                    switch command.kind {
                    case .send:
                        value = command.value
                        subject.send(command.value)
                        publish(value)
                    case .assign:
                        value = command.value
                        subject.value = command.value
                    case .add:
                        value += command.value
                        subject.inout { $0 += command.value }
                        publish(value)
                    case .subscribe, .resubscribe:
                        if let previous = subscribers.removeValue(forKey: command.slot) {
                            await discoveryCancel(previous)
                            coverage.hit("resubscribe")
                        }
                        subscribe(command.slot)
                    case .consume:
                        if let stream = subscribers[command.slot], let expected = queues[command.slot] {
                            let count = discoveryPrefixCount(selector: command.value, available: expected.count)
                            let actual = try await discoveryRead(stream, count: count, step: step, invariant: "subject.consume-missing")
                            try discoveryRequire(actual == Array(expected.prefix(count)), "subject.consume", step: step,
                                                 "actual=\(actual), expected=\(expected)")
                            queues[command.slot] = Array(expected.dropFirst(count))
                            if count > 0 && count < expected.count { coverage.hit("consume.partial") }
                            if count == 0 { coverage.hit("consume.empty") }
                            if count == expected.count { coverage.hit("consume.full") }
                            coverage.hit("consumed", by: actual.count)
                        } else { coverage.hit("consume.absent") }
                    case .cancel:
                        if let stream = subscribers.removeValue(forKey: command.slot) {
                            await discoveryCancel(stream)
                            queues.removeValue(forKey: command.slot)
                            coverage.hit("cancel.live")
                        } else { coverage.hit("cancel.absent") }
                    }
                    try discoveryRequire(subject.value == value, "subject.scalar", step: step)
                }
                // Drain each modeled queue, then publish an out-of-domain sentinel.
                // In an unbounded queue, an extra publication survives the drain and
                // displaces this sentinel. Bounded policies additionally check retained
                // contents; events already dropped by buffering are unobservable.
                for slot in subscribers.keys.sorted() {
                    let stream = subscribers[slot]!
                    let expected = queues[slot]!
                    let actual = try await discoveryRead(stream, count: expected.count, step: scenario.commands.count, invariant: "subject.final-missing")
                    try discoveryRequire(actual == expected, "subject.final-queue", step: scenario.commands.count)
                    queues[slot] = []
                    if scenario.policy == 0 || scenario.capacity > 0 {
                        value = 1_000_000 + slot
                        subject.send(value)
                        publish(value)
                        let sentinel = try await discoveryRead(stream, count: 1, step: scenario.commands.count, invariant: "subject.sentinel-missing")
                        try discoveryRequire(sentinel == [value], "subject.no-extra-events", step: scenario.commands.count)
                        queues[slot] = []
                    }
                }
            } catch {
                for stream in subscribers.values { await discoveryCancel(stream) }
                throw error
            }
            for stream in subscribers.values { await discoveryCancel(stream) }
    }

    @Test
    func missingEmissionFailsPromptlyAndCancelsSubscription() async throws {
        let pair = AsyncStream<Int>.makeStream()
        do {
            _ = try await discoveryCollect(pair.stream, count: 1, timeout: .milliseconds(10))
            Issue.record("Missing emission should time out")
        } catch is DiscoveryStreamTimeout {}
        // A cancellation must terminate the continuation rather than retain a reader.
        if case .terminated = pair.continuation.yield(1) {} else {
            Issue.record("Timed-out reader did not terminate its subscription")
        }
    }

    @Test(arguments: [0, 1])
    func zeroCapacityDeliversToWaitingSubscriber(policy: Int) async throws {
        let subject = AsyncValueSubject(0, bufferingPolicy: policy == 0 ? .bufferingOldest(0) : .bufferingNewest(0))
        let stream = subject.values
        let ready = AsyncStream<Void>.makeStream()
        let result = AsyncStream<Int>.makeStream()
        let consumer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            ready.continuation.yield(())
            // MainActor serialization ensures next() is entered before the parent
            // can process the readiness signal; no scheduler-dependent sleeps.
            if let value = await iterator.next() { result.continuation.yield(value) }
            result.continuation.finish()
        }
        defer { consumer.cancel(); ready.continuation.finish(); result.continuation.finish() }
        do {
            _ = try await discoveryCollect(ready.stream, count: 1)
            subject.send(7)
            let actual = try await discoveryCollect(result.stream, count: 1)
            try discoveryRequire(actual == [7], "subject.rendezvous", step: 0)
        } catch {
            consumer.cancel()
            await consumer.value
            throw error
        }
        await consumer.value
    }
}

private struct StreamScenario: Codable, Sendable {
    let policy: Int
    let capacity: Int
    let commands: [StreamCommand]
}

private struct StreamCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case send, assign, add, subscribe, consume, cancel, resubscribe }
    let kind: Kind
    let slot: Int
    let value: Int
}
