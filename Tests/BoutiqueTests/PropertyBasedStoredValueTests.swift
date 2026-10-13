import Foundation
import Testing
@testable import Boutique

@MainActor
@Suite("Property based StoredValue checks", .serialized)
struct PropertyBasedStoredValueTests {
    @Test("array updates agree with a plain array through generated histories")
    func generatedArrayHistories() throws {
        for seed in 0..<24 {
            let suite = "Boutique.PropertyTests.Array.\(seed).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let stored = StoredValue<[Int]>(key: "items", default: [], storage: defaults)
            var model: [Int] = []
            var generator = ValueGenerator(seed: UInt64(seed) &* 0xD1342543DE82EF95)

            for step in 0..<96 {
                let operation = generator.arrayOperation()
                switch operation {
                case .append(let value):
                    stored.append(value)
                    model.append(value)
                case .toggle(let value):
                    stored.togglePresence(value)
                    if model.contains(value) {
                        model.removeAll { $0 == value }
                    } else {
                        model.append(value)
                    }
                case .replace(let old, let new):
                    let index = model.firstIndex(of: old)
                    let actual = stored.replace(old, with: new)
                    #expect(actual == (index != nil),
                            "replace return, seed=\(seed), step=\(step), operation=\(operation)")
                    if let index { model[index] = new }
                case .set(let values):
                    stored.set(values)
                    model = values
                case .reset:
                    stored.reset()
                    model = []
                }

                #expect(stored.wrappedValue == model,
                        "seed=\(seed), step=\(step), operation=\(operation)")
                if step.isMultiple(of: 13) {
                    let reloaded = StoredValue<[Int]>(key: "items", default: [], storage: defaults)
                    #expect(reloaded.wrappedValue == model,
                            "reload, seed=\(seed), step=\(step), operation=\(operation)")
                }
            }
        }
    }

    @Test("dictionary updates agree with a plain dictionary through generated histories")
    func generatedDictionaryHistories() throws {
        for seed in 24..<48 {
            let suite = "Boutique.PropertyTests.Dictionary.\(seed).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let stored = StoredValue<[Int: Int]>(key: "values", default: [:], storage: defaults)
            var model: [Int: Int] = [:]
            var generator = ValueGenerator(seed: UInt64(seed) &* 0x9E3779B185EBCA87)

            for step in 0..<96 {
                let key = generator.smallInt()
                let value = generator.optionalSmallInt()
                stored.update(key: key, value: value)
                model[key] = value

                #expect(stored.wrappedValue == model,
                        "seed=\(seed), step=\(step), key=\(key), value=\(String(describing: value))")
                if step.isMultiple(of: 13) {
                    let reloaded = StoredValue<[Int: Int]>(key: "values", default: [:], storage: defaults)
                    #expect(reloaded.wrappedValue == model, "reload, seed=\(seed), step=\(step)")
                }
            }
        }
    }

    @Test("boolean toggles match parity across generated histories")
    func generatedBooleanToggles() throws {
        for seed in 48..<80 {
            let suite = "Boutique.PropertyTests.Boolean.\(seed).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let stored = StoredValue<Bool>(key: "flag", default: false, storage: defaults)
            var expected = false
            var generator = ValueGenerator(seed: UInt64(seed) &* 0xA24BAED4963EE407)
            for step in 0..<64 {
                if generator.bit() {
                    stored.toggle()
                    expected.toggle()
                } else {
                    let value = generator.bit()
                    stored.set(value)
                    expected = value
                }
                #expect(stored.wrappedValue == expected, "seed=\(seed), step=\(step)")
            }
        }
    }

    @Test("generated constructor states use valid stored data or fall back to defaults")
    func generatedInitializationAndResetHistories() throws {
        for seed in 0..<160 {
            let suite = "Boutique.PropertyTests.Initialization.\(seed).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            var generator = ValueGenerator(seed: UInt64(seed) &* 0xDB4F0B9175AE2165)
            let initialDefault = generator.smallInt()
            var persistedValue: Int?

            switch seed % 4 {
            case 0:
                // Missing key.
                break
            case 1:
                let value = generator.smallInt()
                defaults.set(try JSONEncoder().encode(IndependentValueBox(value: value)), forKey: "value")
                persistedValue = value
            case 2:
                defaults.set(Data([0xFF, UInt8(truncatingIfNeeded: generator.smallInt())]), forKey: "value")
            default:
                defaults.set(try JSONEncoder().encode(IndependentValueBox(value: ["wrong": generator.smallInt()])), forKey: "value")
            }

            let stored = StoredValue<Int>(key: "value", default: initialDefault, storage: defaults)
            var modelValue = persistedValue ?? initialDefault
            var modelHasPersistedValue = persistedValue != nil
            #expect(stored.wrappedValue == modelValue, "initial state, seed=\(seed)")
            if !modelHasPersistedValue {
                let reopenedDefault = generator.smallInt()
                let reopened = StoredValue<Int>(key: "value", default: reopenedDefault, storage: defaults)
                #expect(reopened.wrappedValue == reopenedDefault,
                        "missing/invalid key should use the new default, seed=\(seed)")
            }

            for step in 0..<32 {
                if generator.bit() {
                    let value = generator.smallInt()
                    stored.set(value)
                    modelValue = value
                    modelHasPersistedValue = true
                } else {
                    stored.reset()
                    modelValue = initialDefault
                    modelHasPersistedValue = true
                }

                #expect(stored.wrappedValue == modelValue, "seed=\(seed), step=\(step)")

                let reopenedDefault = generator.smallInt()
                let reopened = StoredValue<Int>(key: "value", default: reopenedDefault, storage: defaults)
                let reopenedExpected = modelHasPersistedValue ? modelValue : reopenedDefault
                #expect(reopened.wrappedValue == reopenedExpected,
                        "reopen seed=\(seed), step=\(step), persisted=\(modelHasPersistedValue)")
            }
        }
    }

    @Test("nested optional dictionary updates distinguish nil payload from removal")
    func generatedNestedOptionalDictionaryHistories() throws {
        for seed in 0..<64 {
            let suite = "Boutique.PropertyTests.OptionalDictionary.\(seed).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let stored = StoredValue<[Int: Int?]>(key: "values", default: [:], storage: defaults)
            var model: [Int: Int?] = [:]
            var generator = ValueGenerator(seed: UInt64(seed) &* 0xBBE0563303A4615F)

            for step in 0..<48 {
                let key = generator.count(4)
                switch generator.count(2) {
                case 0:
                    let value = generator.smallInt()
                    stored.update(key: key, value: .some(value))
                    model.updateValue(value, forKey: key)
                case 1:
                    stored.update(key: key, value: .some(nil))
                    model.updateValue(nil, forKey: key)
                default:
                    stored.update(key: key, value: nil)
                    model.removeValue(forKey: key)
                }

                let actual = stored.wrappedValue
                #expect(Set(actual.keys) == Set(model.keys), "key set seed=\(seed), step=\(step)")
                #expect(actual == model, "values seed=\(seed), step=\(step), key=\(key)")

                if step.isMultiple(of: 11) {
                    let reopened = StoredValue<[Int: Int?]>(key: "values", default: [:], storage: defaults)
                    #expect(Set(reopened.wrappedValue.keys) == Set(model.keys),
                            "reopen key set seed=\(seed), step=\(step)")
                    #expect(reopened.wrappedValue == model, "reopen values seed=\(seed), step=\(step)")
                }
            }
        }
    }

    @Test("boxed Codable values round-trip over generated payloads")
    func boxedCodableRoundTrips() throws {
        var generator = ValueGenerator(seed: 0x6A09E667F3BCC909)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for index in 0..<512 {
            let item = PropertyCodableValue(
                identifier: generator.text(),
                numbers: generator.integers(12),
                optional: generator.bit() ? generator.text() : nil
            )
            let encoded = try encoder.encodeBoxedData(item: item)
            let decoded = try decoder.decodeBoxedData(data: encoded) as PropertyCodableValue
            #expect(decoded == item, "round-trip case=\(index), item=\(item)")
        }
    }

    @Test("integer boundary values survive persistence and wrapper reconstruction")
    func integerBoundaryRoundTrips() throws {
        let suite = "Boutique.PropertyTests.IntegerBoundaries.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let values = [Int.min, Int.min + 1, -1, 0, 1, Int.max - 1, Int.max]
        let stored = StoredValue<Int>(key: "integer", default: 0, storage: defaults)
        for (index, value) in values.enumerated() {
            stored.set(value)
            #expect(stored.wrappedValue == value, "in-memory boundary index=\(index)")

            let reopened = StoredValue<Int>(key: "integer", default: 99, storage: defaults)
            #expect(reopened.wrappedValue == value, "persisted boundary index=\(index)")
        }
    }

    @Test("CachedValue performs one initial read and uses explicit replacements")
    func cachedValueReadAndReplacementHistories() {
        for seed in 0..<128 {
            var generator = ValueGenerator(seed: UInt64(seed) &* 0x94D049BB133111EB)
            var source = generator.smallInt()
            var reads = 0
            let cached = CachedValue<Int> {
                reads += 1
                return source
            }

            let cachedInitialValue = source
            #expect(cached.wrappedValue == cachedInitialValue)
            source = generator.smallInt()
            for _ in 0..<generator.count(16) {
                #expect(cached.wrappedValue == cachedInitialValue)
            }
            #expect(reads == 1, "warm cache re-read source, seed=\(seed)")

            let replacement = generator.smallInt()
            cached.set(replacement)
            #expect(cached.wrappedValue == replacement, "replacement was not observed, seed=\(seed)")
            #expect(reads == 1, "explicit replacement called source, seed=\(seed)")
        }
    }
}

private enum ArrayOperation: CustomStringConvertible {
    case append(Int)
    case toggle(Int)
    case replace(Int, Int)
    case set([Int])
    case reset

    var description: String {
        switch self {
        case .append(let value): return "append(\(value))"
        case .toggle(let value): return "toggle(\(value))"
        case .replace(let old, let new): return "replace(\(old), \(new))"
        case .set(let values): return "set(\(values))"
        case .reset: return "reset"
        }
    }
}

private struct ValueGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func bit() -> Bool { next().isMultiple(of: 2) }
    mutating func count(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound + 1)) }
    mutating func smallInt() -> Int { Int(next() % 11) - 5 }
    mutating func optionalSmallInt() -> Int? { bit() ? smallInt() : nil }

    mutating func integers(_ upperBound: Int) -> [Int] {
        var values: [Int] = []
        for _ in 0..<count(upperBound) { values.append(smallInt()) }
        return values
    }

    mutating func text() -> String {
        let samples = ["", "alpha", "é", "🧪", "e\u{301}", "\u{0}", "a/b", "line\nbreak"]
        return samples[Int(next() % UInt64(samples.count))]
    }

    mutating func arrayOperation() -> ArrayOperation {
        switch next() % 5 {
        case 0: return .append(smallInt())
        case 1: return .toggle(smallInt())
        case 2: return .replace(smallInt(), smallInt())
        case 3:
            let elementCount = count(9)
            var values: [Int] = []
            for _ in 0..<elementCount { values.append(smallInt()) }
            return .set(values)
        default: return .reset
        }
    }
}

private struct PropertyCodableValue: Codable, Sendable, Equatable {
    let identifier: String
    let numbers: [Int]
    let optional: String?
}

private struct IndependentValueBox<Value: Codable>: Codable {
    let value: Value
}
