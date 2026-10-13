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
