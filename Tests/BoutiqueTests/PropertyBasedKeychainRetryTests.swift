import Security
import Testing
@testable import Boutique

/// Exhausts the retry state machine over its meaningful status classes.
/// This tests the retry policy without touching the host Keychain.
@Suite("Property based Keychain retry checks")
struct PropertyBasedKeychainRetryTests {
    @Test("all three-attempt status traces follow the retry model")
    func exhaustiveRetryStatusTraces() {
        let statuses: [OSStatus] = [
            errSecSuccess,
            errSecDuplicateItem,
            errSecItemNotFound,
            errSecParam,
        ]

        for initial in [KeychainWriteOperation.insert, .update] {
            for encoded in 0..<(statuses.count * statuses.count * statuses.count) {
                var digits = encoded
                var trace: [OSStatus] = []
                for _ in 0..<3 {
                    trace.append(statuses[digits % statuses.count])
                    digits /= statuses.count
                }

                let expected = RetryReference.run(initial: initial, statuses: trace)
                var attempted: [KeychainWriteOperation] = []
                var call = 0
                var returned = false
                var caughtError: Error?

                do {
                    try KeychainWriteOperation.perform(initial) { operation in
                        attempted.append(operation)
                        defer { call += 1 }
                        return trace[call]
                    }
                    returned = true
                } catch {
                    caughtError = error
                }

                #expect(returned == expected.succeeded,
                        "initial=\(initial), statuses=\(trace), attempted=\(attempted)")
                #expect((caughtError is KeychainError) == expected.failed,
                        "initial=\(initial), statuses=\(trace), error=\(String(describing: caughtError))")
                #expect(attempted == expected.attempted.map(\.productionOperation),
                        "initial=\(initial), statuses=\(trace), attempted=\(attempted)")
                #expect(attempted.count == expected.attempted.count,
                        "retry count exceeded model: initial=\(initial), statuses=\(trace)")
            }
        }
    }

    @Test("backend-thrown errors stop retrying at the injected attempt")
    func backendErrorsAreNotRetried() {
        for initial in [KeychainWriteOperation.insert, .update] {
            for throwAt in 1...3 {
                var attempted: [KeychainWriteOperation] = []
                var call = 0
                var caughtError: Error?

                do {
                    try KeychainWriteOperation.perform(initial) { operation in
                        attempted.append(operation)
                        call += 1
                        if call == throwAt { throw InjectedBackendFailure(attempt: throwAt) }
                        return operation == .insert ? errSecDuplicateItem : errSecItemNotFound
                    }
                } catch {
                    caughtError = error
                }

                #expect((caughtError as? InjectedBackendFailure)?.attempt == throwAt,
                        "initial=\(initial), throwAt=\(throwAt), error=\(String(describing: caughtError))")
                #expect(attempted.count == throwAt,
                        "error was retried: initial=\(initial), throwAt=\(throwAt), attempts=\(attempted)")
            }
        }
    }
}

private struct InjectedBackendFailure: Error {
    let attempt: Int
}

private enum ReferenceWriteOperation {
    case insert
    case update

    var productionOperation: KeychainWriteOperation {
        return switch self {
        case .insert: .insert
        case .update: .update
        }
    }
}

private struct RetryExpectation {
    let succeeded: Bool
    let failed: Bool
    let attempted: [ReferenceWriteOperation]
}

private enum RetryReference {
    static func run(
        initial: KeychainWriteOperation,
        statuses: [OSStatus]
    ) -> RetryExpectation {
        var operation: ReferenceWriteOperation = initial == .insert ? .insert : .update
        var attempted: [ReferenceWriteOperation] = []

        for status in statuses {
            attempted.append(operation)
            switch (operation, status) {
            case (_, errSecSuccess):
                return RetryExpectation(succeeded: true, failed: false, attempted: attempted)
            case (.insert, errSecDuplicateItem):
                operation = .update
            case (.update, errSecItemNotFound):
                operation = .insert
            default:
                return RetryExpectation(succeeded: false, failed: true, attempted: attempted)
            }
        }

        // Three recoverable transitions exhaust the production retry budget.
        return RetryExpectation(succeeded: false, failed: true, attempted: attempted)
    }
}
