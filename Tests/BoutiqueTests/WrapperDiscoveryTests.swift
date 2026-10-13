import Foundation
import Observation
import PropertyBased
import Testing
@testable import Boutique

private struct WrapperRecord: Codable, Sendable, Equatable {
    struct Settings: Codable, Sendable, Equatable { var theme: String; var enabled: Bool }
    var name: String
    var settings: Settings
    var tags: [String]
    var score: Double
    static func make(_ n: Int) -> Self {
        let texts = ["", "é", "e\u{301}", "👩🏽‍💻", "quote\"\\\n", "a/b"]
        return Self(name: texts[abs(n) % texts.count],
                    settings: .init(theme: texts[(abs(n) + 1) % texts.count], enabled: n % 2 == 0),
                    tags: [texts[abs(n) % texts.count], String(n)], score: Double(n))
    }
}

private enum WrapperAction: String, Codable, Sendable {
    case set, bindingSet, theme, tags, reset, read, reopen, rejectEncoding, observe, bindingRead
    case peerSet, remove, peerRemove, insertValue, insertNil, removeKey, append, toggle, replace
}
private struct WrapperCommand: Codable, Sendable { let kind: WrapperAction; let operand: Int }
private struct WireCommand: Codable, Sendable { let kind: Int; let operand: Int }
private struct WrapperScenario: Codable, Sendable { let initial: Int; let commands: [WrapperCommand] }
private struct WrapperBox<T: Codable>: Codable { let value: T }
private final class WrapperInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func hit() { lock.lock(); storage += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor
@Suite("WrapperDiscovery mixed operation models", .serialized)
struct WrapperDiscoveryTests {
    @Test(.shrinking)
    func recordHistories() async throws {
        let command = zip(Gen.int(in: 0...9), Gen.int(in: -12...12)).map { WrapperCommand(kind: [.set, .bindingSet, .theme, .tags, .reset, .read, .reopen, .rejectEncoding, .observe, .bindingRead][$0], operand: $1) }
        let scenarios = zip(Gen.int(in: -12...12), command.array(of: 1...DiscoveryProperty.steps))
            .map { WrapperScenario(initial: $0, commands: $1 + [
                .init(kind: .reopen, operand: 0), .init(kind: .read, operand: 0),
                .init(kind: .observe, operand: 0), .init(kind: .read, operand: 0),
                .init(kind: .observe, operand: 0), .init(kind: .theme, operand: 2),
                .init(kind: .observe, operand: 0), .init(kind: .set, operand: 3),
                .init(kind: .rejectEncoding, operand: 1), .init(kind: .bindingSet, operand: 4),
                .init(kind: .reopen, operand: 1), .init(kind: .read, operand: 0)]) }
        try await DiscoveryProperty.check("wrapper-records", input: scenarios) { scenario, coverage in
            let suite = "Boutique.WrapperDiscovery.\(UUID())"
            let defaults = try discoveryUnwrap(UserDefaults(suiteName: suite), "fixture.user-defaults")
            defer { defaults.removePersistentDomain(forName: suite) }
            var fallback = WrapperRecord.make(scenario.initial)
            var model = fallback
            var persisted: WrapperRecord?
            var wrapper = StoredValue(key: "record", default: fallback, storage: defaults)
            var warm = false
            var observers: [WrapperInvalidations] = []
            for (step, command) in scenario.commands.enumerated() {
                let next = WrapperRecord.make(command.operand)
                let previousModel = model
                coverage.hit("operation.\(command.kind)")
                switch command.kind {
                case .set: wrapper.set(next); model = next; persisted = model; warm = true
                case .bindingSet: wrapper.binding.wrappedValue = next; model = next; persisted = model; warm = true
                case .theme:
                    wrapper.set(\.settings.theme, to: next.name)
                    model.settings.theme = next.name; persisted = model; warm = true
                case .tags:
                    wrapper.set(\.tags, to: next.tags)
                    model.tags = next.tags; persisted = model; warm = true
                case .reset: wrapper.reset(); model = fallback; persisted = model; warm = true
                case .read:
                    coverage.hit(warm ? "read.warm" : "read.cold")
                    try discoveryRequire(wrapper.wrappedValue == model, "wrapper.read", step: step)
                    warm = true
                case .reopen:
                    observers.removeAll()
                    fallback = next
                    wrapper = StoredValue(key: "record", default: fallback, storage: defaults)
                    model = persisted ?? fallback; warm = false
                    coverage.hit("reopen")
                case .rejectEncoding:
                    observers.removeAll() // Failed-write invalidation is unspecified.
                    var rejected = next; rejected.score = .infinity
                    let before = defaults.data(forKey: "record")
                    wrapper.set(rejected)
                    try discoveryRequire(defaults.data(forKey: "record") == before, "wrapper.failed-encoding-bytes", step: step)
                    try discoveryRequire(wrapper.wrappedValue == model, "wrapper.failed-encoding-value", step: step)
                    warm = true; coverage.hit("encoding.rejected")
                case .observe:
                    let observer = WrapperInvalidations()
                    withObservationTracking { _ = wrapper.wrappedValue } onChange: { observer.hit() }
                    observers.append(observer); warm = true
                    coverage.hit("observation.arm")
                default:
                    try discoveryRequire(wrapper.binding.wrappedValue == model, "wrapper.binding-read", step: step)
                    warm = true
                }
                if [.set, .bindingSet, .theme, .tags, .reset].contains(command.kind) {
                    // Equal writes' invalidation policy is not part of the contract.
                    if model != previousModel {
                        for observer in observers {
                            try discoveryRequire(observer.count == 1, "wrapper.observation", step: step)
                        }
                        if !observers.isEmpty { coverage.hit("observation.mutate-armed") }
                    }
                    observers.removeAll()
                } else if [.read, .bindingRead, .observe].contains(command.kind) {
                    for observer in observers {
                        try discoveryRequire(observer.count == 0, "wrapper.observation-read", step: step)
                    }
                }
                if let persisted {
                    let data = try discoveryUnwrap(defaults.data(forKey: "record"), "wrapper.persisted-data-present")
                    let decoded = try JSONDecoder().decode(WrapperBox<WrapperRecord>.self, from: data).value
                    try discoveryRequire(decoded == persisted, "wrapper.persisted", step: step)
                } else {
                    try discoveryRequire(defaults.data(forKey: "record") == nil, "wrapper.absent", step: step)
                }
            }
            try discoveryRequire(wrapper.wrappedValue == model, "wrapper.final", step: scenario.commands.count)
        }
    }

    @Test(.shrinking)
    func secureHistories() async throws {
        let command = zip(Gen.int(in: 0...7), Gen.int(in: -12...12)).map { WrapperCommand(kind: [.set, .bindingSet, .peerSet, .remove, .theme, .rejectEncoding, .reopen, .peerRemove][$0], operand: $1) }
        let scenarios = command.array(of: 1...40)
        try await DiscoveryProperty.check("wrapper-secure", count: DiscoveryProperty.backendCases, input: scenarios) { commands, coverage in
            let service = KeychainService(value: "Boutique.WrapperDiscovery.\(UUID())")
            var wrapper = SecurelyStoredValue<WrapperRecord>(key: "record", service: service)
            let peer = SecurelyStoredValue<WrapperRecord>(key: "record", service: service)
            defer { try? wrapper.remove() }
            var model: WrapperRecord?
            for (step, command) in commands.enumerated() {
                let next = WrapperRecord.make(command.operand)
                coverage.hit("operation.\(command.kind)")
                switch command.kind {
                case .set: try wrapper.set(next); model = next
                case .bindingSet: wrapper.binding.wrappedValue = next; model = next
                case .peerSet: try peer.set(next); model = next; coverage.hit("peer.write")
                case .remove: try wrapper.remove(); model = nil
                case .theme:
                    if var existing = model {
                        try wrapper.set(\.settings.theme, to: next.name)
                        existing.settings.theme = next.name; model = existing
                    } else {
                        var rejected = false
                        do { try wrapper.set(\.name, to: next.name) } catch { rejected = true }
                        try discoveryRequire(rejected, "secure.missing-keypath", step: step)
                        coverage.hit("keypath.missing")
                    }
                case .rejectEncoding:
                    var rejected = next; rejected.score = .infinity
                    var threw = false
                    do { try wrapper.set(rejected) } catch { threw = true }
                    try discoveryRequire(threw, "secure.encoding-throws", step: step)
                    wrapper.binding.wrappedValue = rejected
                    coverage.hit("encoding.rejected")
                case .reopen: wrapper = SecurelyStoredValue(key: "record", service: service)
                default: try peer.remove(); model = nil; coverage.hit("peer.remove")
                }
                try discoveryRequire(wrapper.wrappedValue == model, "secure.value", step: step)
                try discoveryRequire(peer.wrappedValue == model, "secure.peer", step: step)
            }
        }
    }

    @Test(.shrinking)
    func optionalDictionaryHistories() async throws {
        let command = zip(Gen.int(in: 0...5), Gen.int(in: -3...3)).map { WrapperCommand(kind: [.insertValue, .insertNil, .removeKey, .reset, .reopen, .bindingSet][$0], operand: $1) }
        try await DiscoveryProperty.check("wrapper-optionals", input: command.array(of: 1...DiscoveryProperty.steps)) { commands, coverage in
            let suite = "Boutique.WrapperOptionals.\(UUID())"
            let defaults = try discoveryUnwrap(UserDefaults(suiteName: suite), "fixture.user-defaults")
            defer { defaults.removePersistentDomain(forName: suite) }
            var wrapper = StoredValue<[String: Int?]>(key: "value", default: [:], storage: defaults)
            var model: [String: Int?] = [:]
            for (step, command) in commands.enumerated() {
                let key = WrapperRecord.make(command.operand).name
                coverage.hit("operation.\(command.kind)")
                switch command.kind {
                case .insertValue: wrapper.update(key: key, value: .some(command.operand)); model.updateValue(command.operand, forKey: key)
                case .insertNil: wrapper.update(key: key, value: .some(nil)); model.updateValue(nil, forKey: key)
                case .removeKey: wrapper.update(key: key, value: nil); model.removeValue(forKey: key)
                case .reset: wrapper.reset(); model = [:]
                case .reopen: wrapper = StoredValue(key: "value", default: [:], storage: defaults)
                default: wrapper.binding.wrappedValue = model
                }
                try discoveryRequire(wrapper.wrappedValue == model, "optional.values", step: step)
                try discoveryRequire(Set(wrapper.wrappedValue.keys) == Set(model.keys), "optional.keys", step: step)
                if let data = defaults.data(forKey: "value") {
                    let independent = try JSONDecoder().decode(WrapperBox<[String: Int?]>.self, from: data).value
                    try discoveryRequire(independent == model, "optional.persisted", step: step)
                }
            }
        }
    }
    @Test(.shrinking)
    func arrayHistories() async throws {
        let operation = zip(Gen.int(in: 0...5), Gen.int(in: -2...2)).map {
            WrapperCommand(kind: [.append, .toggle, .replace, .reset, .reopen, .read][$0], operand: $1)
        }
        let histories = operation.array(of: 1...DiscoveryProperty.steps).map { $0 + [
            .init(kind: .append, operand: 1), .init(kind: .append, operand: 1),
            .init(kind: .replace, operand: 1), .init(kind: .toggle, operand: 1),
            .init(kind: .reset, operand: 0), .init(kind: .reopen, operand: 0),
            .init(kind: .replace, operand: 2)] }
        try await DiscoveryProperty.check("wrapper-arrays", input: histories) { commands, coverage in
            let suite = "Boutique.WrapperArray.\(UUID())"
            let defaults = try discoveryUnwrap(UserDefaults(suiteName: suite), "fixture.user-defaults")
            defer { defaults.removePersistentDomain(forName: suite) }
            var wrapper = StoredValue<[Int]>(key: "array", default: [], storage: defaults)
            var model: [Int] = []
            for (step, command) in commands.enumerated() {
                coverage.hit("operation.\(command.kind)")
                switch command.kind {
                case .append: wrapper.append(command.operand); model.append(command.operand)
                case .toggle:
                    wrapper.togglePresence(command.operand)
                    if model.contains(command.operand) { model = model.filter { $0 != command.operand } }
                    else { model.append(command.operand) }
                case .replace:
                    let index = model.firstIndex(of: command.operand)
                    let replaced = wrapper.replace(command.operand, with: command.operand + 1)
                    try discoveryRequire(replaced == (index != nil), "array.replace-result", step: step)
                    if let index { model[index] = command.operand + 1 }
                    coverage.hit(index == nil ? "replace.missing" : "replace.present")
                case .reset: wrapper.reset(); model = []
                case .reopen: wrapper = StoredValue(key: "array", default: [], storage: defaults)
                default: break
                }
                try discoveryRequire(wrapper.wrappedValue == model, "array.values", step: step)
                if let data = defaults.data(forKey: "array") {
                    let decoded = try JSONDecoder().decode(WrapperBox<[Int]>.self, from: data).value
                    try discoveryRequire(decoded == model, "array.persisted", step: step)
                }
            }
        }
    }

    @Test(.shrinking)
    func independentlyAuthoredSerialization() async throws {
        let inputs = zip(Gen.int(in: -12...12), Gen.int(in: 0...4)).map {
            WireCommand(kind: $1, operand: $0)
        }
        try await DiscoveryProperty.check("wrapper-wire", input: inputs) { command, coverage in
            let record = WrapperRecord.make(command.operand)
            // The fixture schema is authored independently of Encodable and BoxedValue.
            let wire: [String: Any] = ["value": ["name": record.name,
                "settings": ["theme": record.settings.theme, "enabled": record.settings.enabled],
                "tags": record.tags, "score": record.score]]
            let valid = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
            let suite = "Boutique.WrapperWire.\(UUID())"
            let defaults = try discoveryUnwrap(UserDefaults(suiteName: suite), "fixture.user-defaults")
            defer { defaults.removePersistentDomain(forName: suite) }
            var data = valid
            switch command.kind {
            case 1: data = Data(valid.dropLast())
            case 2: data = Data([0xff, 0xfe])
            case 3: data = Data("{\"value\":null}".utf8)
            case 4: data = Data("{\"value\":{\"name\":4}}".utf8)
            default: break
            }
            defaults.set(data, forKey: "record")
            let fallback = WrapperRecord.make(command.operand + 1)
            let wrapper = StoredValue(key: "record", default: fallback, storage: defaults)
            try discoveryRequire(wrapper.wrappedValue == (command.kind == 0 ? record : fallback),
                                 "wire.initial", step: 0)
            wrapper.set(record)
            let persisted = try discoveryUnwrap(defaults.data(forKey: "record"), "wrapper.persisted-data-present")
            let object = try JSONSerialization.jsonObject(with: persisted) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: valid) as? NSDictionary
            try discoveryRequire(object == expected, "wire.semantic-shape", step: 1)
            coverage.hit("fixture.\(command.kind)")
        }
    }

}
