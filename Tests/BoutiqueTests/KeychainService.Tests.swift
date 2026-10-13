import Boutique
import Foundation
import Security
import Testing

extension KeychainService {
    // Each test gets an isolated namespace, including suite instance initialization.
    // Rebuilt test executables must not request access to an older executable's items.
    static var test: Self { Self(value: IsolatedTestKeychain.service) }
}

struct IsolatedTestKeychain: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    @TaskLocal static var service = "Boutique.UnscopedTests"

    func provideScope(for test: Test, testCase: Test.Case?, performing function: () async throws -> Void) async throws {
        let namespace = "Boutique.Tests.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword,
                           kSecAttrService: namespace] as CFDictionary)
        }
        try await Self.$service.withValue(namespace) { try await function() }
    }
}
