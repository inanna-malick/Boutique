@testable import Boutique
import Testing

/// These tests treat `AsyncValueSubject` as a small sequential state machine:
/// `send` and `inout` publish a value, while direct assignment changes the
/// replayed value without publishing. Tests deliberately serialize mutations;
/// concurrent send ordering is not part of this model.
@Suite("Async Value Subject Property Tests", .serialized)
struct PropertyBasedAsyncValueSubjectTests {
    private enum Mutation: Sendable, CustomStringConvertible {
        case send(Int)
        case assign(Int)
        case add(Int)

        var description: String {
            switch self {
            case .send(let value): "send(\(value))"
            case .assign(let value): "assign(\(value))"
            case .add(let delta): "add(\(delta))"
            }
        }

    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func int(in range: ClosedRange<Int>) -> Int {
            let width = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % width)
        }

        mutating func trace(length: Int) -> [Mutation] {
            var result: [Mutation] = []
            for _ in 0..<length {
                switch next() % 3 {
                case 0: result.append(.send(int(in: -4...4)))
                case 1: result.append(.assign(int(in: -4...4)))
                default: result.append(.add(int(in: -3...3)))
                }
            }
            return result
        }
    }

    /// Applies one mutation and returns the event it should synchronously
    /// publish, if any. This is intentionally separate from subject reads.
    private func apply(_ mutation: Mutation, to subject: AsyncValueSubject<Int>) -> Int? {
        switch mutation {
        case .send(let value):
            subject.send(value)
            return value
        case .assign(let value):
            subject.value = value
            return nil
        case .add(let delta):
            subject.inout { $0 += delta }
            return subject.value
        }
    }

    private func collect(_ stream: AsyncStream<Int>, count: Int) async -> [Int] {
        var iterator = stream.makeAsyncIterator()
        var values: [Int] = []
        for _ in 0..<count {
            guard let value = await iterator.next() else { break }
            values.append(value)
        }
        return values
    }

    @Test("Generated sequential mutation traces match replay and publication model")
    func generatedSequentialMutationTraces() async {
        for seed in 0..<80 {
            var generator = SplitMix64(seed: UInt64(seed) &+ 0xA51CE)
            let trace = generator.trace(length: 1 + (seed % 40))
            let subject = AsyncValueSubject<Int>(0)
            let stream = subject.values
            var expectedEvents = [0]
            var expectedValue = 0

            for mutation in trace {
                switch mutation {
                case .send(let value):
                    expectedValue = value
                    expectedEvents.append(value)
                case .assign(let value):
                    expectedValue = value
                case .add(let delta):
                    expectedValue += delta
                    expectedEvents.append(expectedValue)
                }
                _ = apply(mutation, to: subject)
                #expect(subject.value == expectedValue,
                        "seed=\(seed), trace=\(trace), expected=\(expectedValue), actual=\(subject.value)")
            }

            let observed = await collect(stream, count: expectedEvents.count)
            #expect(observed == expectedEvents, "seed=\(seed), trace=\(trace)")
        }
    }

    @Test("Bounded exhaustive short traces replay the state at every subscription point")
    func exhaustiveShortTracesAndSubscriptionPositions() async {
        // Nine command choices per step, including publish, silent assignment,
        // and inout mutation. For every history, subscribe at all four points.
        let commands: [Mutation] = [
            .send(-1), .send(0), .send(1),
            .assign(-1), .assign(0), .assign(1),
            .add(-1), .add(0), .add(1),
        ]

        for encodedTrace in 0..<(9 * 9 * 9) {
            var remaining = encodedTrace
            var trace: [Mutation] = []
            for _ in 0..<3 {
                trace.append(commands[remaining % commands.count])
                remaining /= commands.count
            }

            for subscriptionIndex in 0...trace.count {
                let subject = AsyncValueSubject<Int>(7)
                var expectedValue = 7
                for mutation in trace[..<subscriptionIndex] {
                    _ = apply(mutation, to: subject)
                    switch mutation {
                    case .send(let value), .assign(let value): expectedValue = value
                    case .add(let delta): expectedValue += delta
                    }
                }

                let stream = subject.values
                var expectedEvents = [expectedValue]
                for mutation in trace[subscriptionIndex...] {
                    switch mutation {
                    case .send(let value):
                        expectedValue = value
                        expectedEvents.append(value)
                    case .assign(let value):
                        expectedValue = value
                    case .add(let delta):
                        expectedValue += delta
                        expectedEvents.append(expectedValue)
                    }
                    _ = apply(mutation, to: subject)
                }

                #expect(subject.value == expectedValue,
                        "encodedTrace=\(encodedTrace), subscriptionIndex=\(subscriptionIndex), trace=\(trace)")
                #expect(await collect(stream, count: expectedEvents.count) == expectedEvents,
                        "encodedTrace=\(encodedTrace), subscriptionIndex=\(subscriptionIndex), trace=\(trace)")
            }
        }
    }

    @Test("Independent subscribers each receive their own replay and later sends")
    func multipleSubscribersHaveIndependentHistories() async {
        for seed in 0..<64 {
            var generator = SplitMix64(seed: UInt64(seed) &+ 0xC0FFEE)
            let subject = AsyncValueSubject<Int>(generator.int(in: -10...10))
            var expectedFirst = [subject.value]
            var expectedSecond: [Int] = []
            let first = subject.values
            let prefix = generator.trace(length: 1 + (seed % 12))

            for mutation in prefix {
                switch mutation {
                case .send(let value): expectedFirst.append(value)
                case .assign: break
                case .add(let delta): expectedFirst.append(subject.value + delta)
                }
                _ = apply(mutation, to: subject)
            }

            expectedSecond.append(subject.value)
            let second = subject.values
            let suffix = generator.trace(length: 1 + (seed % 12))
            for mutation in suffix {
                switch mutation {
                case .send(let value):
                    expectedFirst.append(value)
                    expectedSecond.append(value)
                case .assign: break
                case .add(let delta):
                    expectedFirst.append(subject.value + delta)
                    expectedSecond.append(subject.value + delta)
                }
                _ = apply(mutation, to: subject)
            }

            #expect(await collect(first, count: expectedFirst.count) == expectedFirst,
                    "seed=\(seed), prefix=\(prefix), suffix=\(suffix)")
            #expect(await collect(second, count: expectedSecond.count) == expectedSecond,
                    "seed=\(seed), prefix=\(prefix), suffix=\(suffix)")
        }
    }

    @Test("Finite buffering retains the AsyncStream policy's newest or oldest values")
    func finiteBufferingPolicies() async {
        let oldest = AsyncValueSubject<Int>(0, bufferingPolicy: .bufferingOldest(2))
        let oldestStream = oldest.values
        oldest.send(1)
        oldest.send(2)
        oldest.send(3)
        oldest.send(4)
        #expect(await collect(oldestStream, count: 2) == [0, 1])

        let newest = AsyncValueSubject<Int>(0, bufferingPolicy: .bufferingNewest(2))
        let newestStream = newest.values
        newest.send(1)
        newest.send(2)
        newest.send(3)
        newest.send(4)
        #expect(await collect(newestStream, count: 2) == [3, 4])

        // The subject itself still tracks the latest value even when a stream
        // drops buffered events, and a later subscriber gets that latest value.
        #expect(oldest.value == 4)
        #expect(newest.value == 4)
        #expect(await collect(oldest.values, count: 1) == [4])
        #expect(await collect(newest.values, count: 1) == [4])
    }
}
