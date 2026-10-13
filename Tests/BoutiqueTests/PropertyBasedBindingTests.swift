import Boutique
import Foundation
import SwiftUI
import Testing

private struct PropertyRecord: Codable, Sendable, Equatable {
    var name: String
    var settings: Settings
    var tags: [String]
    var score: Double

    struct Settings: Codable, Sendable, Equatable {
        var theme: String
        var notificationsEnabled: Bool
        var retryLimit: Int
    }
}

/// Domain adapter around the shared library RNG for retained seeded sweeps.
private struct RecordGenerator {
    private var random: DiscoveryRandom

    init(seed: UInt64) {
        random = DiscoveryRandom(seed: seed)
    }

    mutating func next() -> UInt64 {
        return random.next()
    }

    mutating func int(_ upperBound: Int) -> Int {
        Int(self.next() % UInt64(upperBound))
    }

    mutating func bool() -> Bool {
        self.next() & 1 == 1
    }

    mutating func string() -> String {
        let alphabet = Array("abcXYZ012-é🧪")
        let length = self.int(10)
        var characters: [Character] = []
        for _ in 0..<length {
            characters.append(alphabet[self.int(alphabet.count)])
        }
        return String(characters)
    }

    mutating func strings(count: Int) -> [String] {
        var result: [String] = []
        for _ in 0..<count {
            result.append(self.string())
        }
        return result
    }

    mutating func record() -> PropertyRecord {
        let tagCount = self.int(6)
        return PropertyRecord(
            name: self.string(),
            settings: .init(
                theme: self.string(),
                notificationsEnabled: self.bool(),
                retryLimit: self.int(1001) - 500
            ),
            tags: self.strings(count: tagCount),
            score: Double(self.int(200_001) - 100_000) / 17.0
        )
    }
}

@MainActor
@Suite("Generated key-path setter and Binding properties", .serialized)
struct PropertyBasedBindingTests {
    @Test("StoredValue key-path writes match copied-value mutations")
    func storedValueKeyPathWritesMatchDirectMutation() {
        let suiteName = "Boutique.PropertyBasedBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let value = StoredValue(key: "record", default: PropertyRecord(
            name: "initial",
            settings: .init(theme: "light", notificationsEnabled: false, retryLimit: 3),
            tags: ["preserve-me"],
            score: 0
        ), storage: defaults)
        var generator = RecordGenerator(seed: 0x12D5_48A9_72E1_C301)

        var expected = PropertyRecord(name: "initial",
            settings: .init(theme: "light", notificationsEnabled: false, retryLimit: 3),
            tags: ["preserve-me"], score: 0)
        for index in 0..<600 {
            switch generator.int(6) {
            case 0:
                let update = generator.string()
                expected.name = update
                value.set(\.name, to: update)
            case 1:
                let update = generator.string()
                expected.settings.theme = update
                value.set(\.settings.theme, to: update)
            case 2:
                let update = generator.bool()
                expected.settings.notificationsEnabled = update
                value.set(\.settings.notificationsEnabled, to: update)
            case 3:
                let update = generator.int(2001) - 1000
                expected.settings.retryLimit = update
                value.set(\.settings.retryLimit, to: update)
            case 4:
                let tagCount = generator.int(8)
                let update = generator.strings(count: tagCount)
                expected.tags = update
                value.set(\.tags, to: update)
            default:
                let update = Double(generator.int(200_001) - 100_000) / 13.0
                expected.score = update
                value.set(\.score, to: update)
            }

            #expect(value.wrappedValue == expected, "Mismatch after generated update \(index)")
        }
    }

    @Test("StoredValue Binding get/set round trips generated records")
    func storedValueBindingRoundTrips() {
        let suiteName = "Boutique.PropertyBasedBindingTests.Binding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let value = StoredValue(key: "record", default: PropertyRecord(
            name: "initial",
            settings: .init(theme: "light", notificationsEnabled: false, retryLimit: 0),
            tags: [],
            score: 0
        ), storage: defaults)
        let binding = value.binding
        var generator = RecordGenerator(seed: 0xF21B_937C_0864_55A1)

        for index in 0..<300 {
            let expected = generator.record()
            #expect(binding.wrappedValue == value.wrappedValue)
            binding.wrappedValue = expected
            #expect(binding.wrappedValue == expected, "Binding round trip failed at \(index)")
        }
    }

    @Test("SecurelyStoredValue key-path writes preserve untouched fields")
    func securelyStoredValueKeyPathWritesMatchDirectMutation() throws {
        let service = KeychainService(value: "Boutique.PropertyBasedBindingTests.\(UUID().uuidString)")
        let value = SecurelyStoredValue<PropertyRecord>(key: "record-\(UUID().uuidString)", service: service)
        defer { try? value.remove() }

        var generator = RecordGenerator(seed: 0x005A_1623_99C7_4B8D)
        var expected = generator.record()
        try value.set(expected)

        for index in 0..<300 {
            switch generator.int(6) {
            case 0:
                let update = generator.string()
                expected.name = update
                try value.set(\.name, to: update)
            case 1:
                let update = generator.string()
                expected.settings.theme = update
                try value.set(\.settings.theme, to: update)
            case 2:
                let update = generator.bool()
                expected.settings.notificationsEnabled = update
                try value.set(\.settings.notificationsEnabled, to: update)
            case 3:
                let update = generator.int(2001) - 1000
                expected.settings.retryLimit = update
                try value.set(\.settings.retryLimit, to: update)
            case 4:
                let tagCount = generator.int(8)
                let update = generator.strings(count: tagCount)
                expected.tags = update
                try value.set(\.tags, to: update)
            default:
                let update = Double(generator.int(200_001) - 100_000) / 13.0
                expected.score = update
                try value.set(\.score, to: update)
            }

            #expect(value.wrappedValue == expected, "Mismatch after generated update \(index)")
        }
    }

    @Test("SecurelyStoredValue key-path setter throws when no object exists")
    func securelyStoredValueKeyPathSetterRequiresAnExistingRecord() throws {
        let service = KeychainService(value: "Boutique.PropertyBasedBindingTests.Nil.\(UUID().uuidString)")
        let value = SecurelyStoredValue<PropertyRecord>(key: "record-\(UUID().uuidString)", service: service)
        defer { try? value.remove() }

        var didThrow = false
        do {
            try value.set(\.name, to: "cannot-create-from-a-field")
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(value.wrappedValue == nil)
    }

    @Test("SecurelyStoredValue Binding round trips and suppresses write errors")
    func securelyStoredValueBindingRoundTripsAndSuppressesErrors() throws {
        let service = KeychainService(value: "Boutique.PropertyBasedBindingTests.SecureBinding.\(UUID().uuidString)")
        let value = SecurelyStoredValue<PropertyRecord>(key: "record-\(UUID().uuidString)", service: service)
        defer { try? value.remove() }

        let binding = value.binding
        #expect(binding.wrappedValue == nil)

        var generator = RecordGenerator(seed: 0x39B1_2C7A_41E8_6DF0)
        for index in 0..<100 {
            let expected = generator.record()
            binding.wrappedValue = expected
            #expect(binding.wrappedValue == expected, "Binding round trip failed at \(index)")
        }

        let lastValidValue = try #require(value.wrappedValue)
        var invalidEncodingValue = lastValidValue
        invalidEncodingValue.score = .infinity
        binding.wrappedValue = invalidEncodingValue
        // Binding's setter intentionally uses try?; a rejected encoding leaves the last
        // successfully persisted object in place. We avoid asserting a specific error.
        #expect(value.wrappedValue == lastValidValue)

        binding.wrappedValue = nil
        #expect(binding.wrappedValue == nil)
    }
}
