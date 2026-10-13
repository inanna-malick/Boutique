import Foundation

struct DiscoveryStreamTimeout: Error, Sendable {}

/// A timeout cancels the losing iterator task. AsyncStream cooperatively terminates
/// its subscription on cancellation, so the task group cannot leave a blocked next().
func discoveryCollect<Value: Sendable>(
    _ stream: AsyncStream<Value>, count: Int, timeout: Duration = .seconds(2)
) async throws -> [Value] {
    guard count > 0 else { return [] }
    return try await withThrowingTaskGroup(of: [Value].self) { group in
        group.addTask {
            var result: [Value] = []
            for await value in stream {
                result.append(value)
                if result.count == count { break }
            }
            return result
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw DiscoveryStreamTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func discoveryCancel<Value: Sendable>(_ stream: AsyncStream<Value>) async {
    let consumer = Task {
        for await _ in stream {}
    }
    consumer.cancel()
    await consumer.value
}

/// Deliberately partitions empty, full, and interior-prefix consumption.
func discoveryPrefixCount(selector: Int, available: Int) -> Int {
    guard available > 0 else { return 0 }
    let choice = selector.magnitude
    switch choice % 3 {
    case 0: return 0
    case 1: return available
    default: return min(available, max(1, Int(choice / 3)))
    }
}

/// Keep a missing emission tied to the operation and invariant while shrinking.
func discoveryRead<Value: Sendable>(_ stream: AsyncStream<Value>, count: Int,
                                    step: Int, invariant: String) async throws -> [Value] {
    do { return try await discoveryCollect(stream, count: count) }
    catch is DiscoveryStreamTimeout {
        throw DiscoveryFailure(invariant: invariant, step: step, detail: "Timed out waiting for \(count) events")
    }
}
