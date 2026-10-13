@testable import Boutique
import Foundation
import Testing

/// Seeded model-based coverage for keychain-backed values. Every generated trace owns a
/// fresh service/account pair so parallel runs cannot read or erase another test's data.
@MainActor
@Suite("Secure wrapper property tests", .serialized)
struct PropertyBasedSecureWrapperTests {
    @Test("Generated set/remove/reopen histories agree with an optional-value model")
    func generatedSecureValueHistories() throws {
        for seed in 0..<10 {
            var random = PropertyRandom(seed: UInt64(seed) &+ 0xD1B54A32D192ED03)
            let namespace = "Boutique.Proptest.\(UUID().uuidString).\(seed)"
            let key = "history"
            var expected: String?
            var value = SecurelyStoredValue<String>(key: key, service: KeychainService(value: namespace))
            defer { try? value.remove() }

            for step in 0..<36 {
                switch random.pick(3) {
                case 0, 1:
                    let next = "v\(random.pick(8))"
                    try value.set(next)
                    expected = next
                case 2:
                    try value.remove()
                    expected = nil
                default:
                    Issue.record("unreachable command")
                }

                #expect(value.wrappedValue == expected, "seed=\(seed), step=\(step), trace=\(random.trace)")

                // A newly initialized wrapper reads the same persisted account. Reopening
                // is an explicit operation in the generated history, not shared-wrapper state.
                if step.isMultiple(of: 3) {
                    value = SecurelyStoredValue<String>(key: key, service: KeychainService(value: namespace))
                    #expect(value.wrappedValue == expected, "reopen seed=\(seed), step=\(step), trace=\(random.trace)")
                }
            }
        }
    }

    @Test("Generated secure array helper histories match a plain array")
    func generatedSecureArrayHelpers() throws {
        for seed in 0..<12 {
            var random = PropertyRandom(seed: UInt64(seed) &+ 0x94D049BB133111EB)
            let key = "array.\(UUID().uuidString)"
            let service = KeychainService(value: "Boutique.Proptest.\(UUID().uuidString)")
            let value = SecurelyStoredValue<[Int]>(key: key, service: service)
            defer { try? value.remove() }

            var expected: [Int]?
            for step in 0..<32 {
                let item = random.pick(6)
                switch random.pick(4) {
                case 0:
                    try value.append(item)
                    if expected == nil { expected = [] }
                    expected!.append(item)
                case 1:
                    try value.togglePresence(item)
                    if expected == nil { expected = [item] }
                    else if expected!.contains(item) { expected!.removeAll { $0 == item } }
                    else { expected!.append(item) }
                case 2:
                    let replacement = random.pick(6)
                    let position = expected?.firstIndex(of: item)
                    let replaced = try value.replace(item, with: replacement)
                    #expect(replaced == (position != nil), "seed=\(seed), step=\(step), trace=\(random.trace)")
                    if let position { expected![position] = replacement }
                case 3:
                    let replacementCount = random.pick(5)
                    var replacement: [Int] = []
                    for _ in 0..<replacementCount { replacement.append(random.pick(6)) }
                    try value.set(replacement)
                    expected = replacement
                default:
                    Issue.record("unreachable command")
                }

                #expect(value.wrappedValue == expected, "seed=\(seed), step=\(step), trace=\(random.trace)")
            }
        }
    }

    @Test("Generated secure dictionary updates match a plain dictionary")
    func generatedSecureDictionaryHelpers() throws {
        for seed in 0..<12 {
            var random = PropertyRandom(seed: UInt64(seed) &+ 0xBF58476D1CE4E5B9)
            let key = "dictionary.\(UUID().uuidString)"
            let service = KeychainService(value: "Boutique.Proptest.\(UUID().uuidString)")
            let value = SecurelyStoredValue<[Int: Int]>(key: key, service: service)
            defer { try? value.remove() }

            var expected: [Int: Int]?
            for step in 0..<36 {
                let itemKey = random.pick(7)
                let itemValue = random.pick(11)
                if random.pick(4) == 0 {
                    try value.set([itemKey: itemValue])
                    expected = [itemKey: itemValue]
                } else {
                    let next: Int? = random.pick(3) == 0 ? nil : itemValue
                    try value.update(key: itemKey, value: next)
                    if expected == nil { expected = [:] }
                    expected![itemKey] = next
                }
                #expect(value.wrappedValue == expected, "seed=\(seed), step=\(step), trace=\(random.trace)")
            }
        }
    }

    @Test("refreshValue follows successful value, nil and error sequences")
    func generatedRefreshValueSequences() {
        for seed in 0..<32 {
            var random = PropertyRandom(seed: UInt64(seed) &+ 0x632BE59BD9B4E019)
            let value = SecurelyStoredValue<Int>(
                key: "refresh.\(UUID().uuidString)",
                service: KeychainService(value: "Boutique.Proptest.\(UUID().uuidString)"))
            defer { try? value.remove() }

            // Establish the cached-value model through a known successful read first.
            var expected: Int? = seed
            #expect(value.refreshValue(from: { seed }) == expected)

            for step in 0..<40 {
                let result: Int?
                switch random.pick(4) {
                case 0, 1:
                    let fresh = random.pick(100)
                    result = value.refreshValue(from: { fresh })
                    expected = fresh
                case 2:
                    result = value.refreshValue(from: { nil })
                    expected = nil
                case 3:
                    result = value.refreshValue(from: { throw GeneratedReadFailure() })
                default:
                    Issue.record("unreachable refresh result")
                    result = nil
                }
                #expect(result == expected, "seed=\(seed), step=\(step), trace=\(random.trace)")
            }
        }
    }
}

private struct GeneratedReadFailure: Error {}

/// Small deterministic generator. Failure messages include seed and the consumed random
/// choices, so a case can be replayed even if strategy code later changes.
private struct PropertyRandom {
    private var state: UInt64
    private(set) var trace: [Int] = []

    init(seed: UInt64) { self.state = seed }

    mutating func pick(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        self.state &+= 0x9E3779B97F4A7C15
        var mixed = self.state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        mixed ^= mixed >> 31
        let choice = Int(mixed % UInt64(upperBound))
        self.trace.append(choice)
        return choice
    }
}
