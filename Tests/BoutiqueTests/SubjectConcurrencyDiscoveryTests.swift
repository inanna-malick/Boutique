import Foundation
import PropertyBased
import Testing
@testable import Boutique

/// Waves impose real-time order only between completed groups. Within a wave,
/// each subscriber may observe its own permutation of the unique publications.
@MainActor
@Suite("Subject concurrency discovery", .serialized)
struct SubjectConcurrencyDiscoveryTests {
    private struct Scenario: Codable, Sendable {
        let widths: [Int]
        let incremental: Bool
    }

    @Test(.shrinking)
    func publicationAndLifecycleWaves() async throws {
        let scenarios = zip(Gen.int(in: 1...12).array(of: 1...12), Gen.int(in: 0...1))
            .map { Scenario(widths: $0, incremental: $1 == 1) }
        try await DiscoveryProperty.check("subject-concurrency-waves", input: scenarios) { scenario, coverage in
            let subject = AsyncValueSubject(0)
            var streams = [subject.values, subject.values]
            var previous = 0
            for (step, width) in scenario.widths.enumerated() {
                // Drain replay separately: it is a subscription event, not a send.
                for stream in streams {
                    let replay = try await discoveryRead(stream, count: 1, step: step, invariant: "subject.concurrent.replay-missing")
                    try discoveryRequire(replay == [previous], "subject.concurrent.replay", step: step)
                }
                let lower = previous + 1
                let duplicateSend = ProcessInfo.processInfo.environment["BOUTIQUE_SUBJECT_DUPLICATE_SEND"] == "1"
                await withTaskGroup(of: Void.self) { group in
                    for value in lower..<(lower + width) {
                        group.addTask {
                            if scenario.incremental { subject.inout { $0 += 1 } }
                            else { subject.send(duplicateSend && width > 1 && value == lower ? lower + 1 : value) }
                        }
                    }
                }
                let final = subject.value
                if scenario.incremental {
                    try discoveryRequire(final == previous + width, "subject.concurrent.atomic-update", step: step)
                } else {
                    try discoveryRequire((lower..<(lower + width)).contains(final), "subject.concurrent.final-membership", step: step)
                }
                let sentinel = lower + width
                subject.send(sentinel) // all workers returned before this publication
                for stream in streams {
                    let prefix = try await discoveryRead(stream, count: max(1, width / 2), step: step, invariant: "subject.concurrent.missing")
                    let suffix = try await discoveryRead(stream, count: width + 1 - prefix.count, step: step, invariant: "subject.concurrent.missing")
                    let observed = prefix + suffix
                    let publications = Array(observed.dropLast())
                    try discoveryRequire(publications.sorted() == Array(lower..<(lower + width)), "subject.concurrent.membership", step: step, "wave=\(width), observed=\(observed)")
                    try discoveryRequire(observed.last == sentinel, "subject.concurrent.real-time", step: step)
                    await discoveryCancel(stream)
                }
                coverage.hit("wave.workers", by: width)
                coverage.hit(scenario.incremental ? "wave.inout" : "wave.send")
                coverage.hit("subscriber.cancel-resubscribe", by: streams.count)
                previous = sentinel
                streams = [subject.values, subject.values]
            }
            for stream in streams { await discoveryCancel(stream) }
        }
    }

    @Test(arguments: [1, 2, 4, 8, 16, 32])
    func subscribeDuringConcurrentUpdates(width: Int) async throws {
        for attempt in 0..<50 {
            let subject = AsyncValueSubject(0)
            let retired = subject.values
            let stream = await withTaskGroup(of: AsyncStream<Int>?.self, returning: AsyncStream<Int>.self) { group in
                group.addTask { subject.values }
                group.addTask { await discoveryCancel(retired); return nil }
                for _ in 0..<width { group.addTask { subject.inout { $0 += 1 }; return nil } }
                var subscription: AsyncStream<Int>?
                for await result in group { if let result { subscription = result } }
                return subscription!
            }
            let replay = try await discoveryRead(stream, count: 1, step: attempt, invariant: "subject.concurrent-subscribe.replay-missing")[0]
            try discoveryRequire((0...width).contains(replay), "subject.concurrent-subscribe.replay", step: attempt)
            subject.send(width + 1)
            let tail = try await discoveryRead(stream, count: width - replay + 1, step: attempt, invariant: "subject.concurrent-subscribe.missing")
            try discoveryRequire(Array(tail.dropLast()).sorted() == Array((replay + 1)..<(width + 1)), "subject.concurrent-subscribe.membership", step: attempt, "replay=\(replay), tail=\(tail)")
            try discoveryRequire(tail.last == width + 1, "subject.concurrent-subscribe.real-time", step: attempt)
            await discoveryCancel(stream)
        }
    }
}
