import Foundation
import PropertyBased
import Testing

/// A stable invariant ID keeps shrinking on the original failure, not an unrelated error.
struct DiscoveryFailure: Error, Codable, CustomStringConvertible {
    let invariant: String
    let step: Int
    let detail: String
    var description: String { "\(invariant) at step \(step): \(detail)" }
}

func discoveryRequire(_ condition: Bool, _ invariant: String, step: Int, _ detail: String = "") throws {
    if !condition { throw DiscoveryFailure(invariant: invariant, step: step, detail: detail) }
}

@MainActor
final class DiscoveryCoverage {
    private(set) var counts: [String: Int] = [:]
    func hit(_ event: String, by amount: Int = 1) { counts[event, default: 0] += amount }
}

private struct DiscoveryArtifact<Scenario: Codable>: Codable {
    var version = 1
    let suite: String
    let revision: String
    let original: Scenario
    var reduced: Scenario
    var failure: DiscoveryFailure
}

/// The library owns generation, seed reporting, and shrinking. This adapter adds
/// portable concrete traces and invariant-preserving failure reporting.
@MainActor
enum DiscoveryProperty {
    static var cases: Int { positiveEnvironment("BOUTIQUE_PROPERTY_CASES", default: 1_000) }
    static var backendCases: Int { positiveEnvironment("BOUTIQUE_BACKEND_CASES", default: 100) }
    static var steps: Int { positiveEnvironment("BOUTIQUE_PROPERTY_STEPS", default: 100) }

    private static func positiveEnvironment(_ name: String, default fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return fallback }
        guard let value = Int(raw), value > 0 else {
            Issue.record("\(name) must be a positive integer")
            return fallback
        }
        return value
    }

    static func check<S: Codable & Sendable, I>(
        _ name: String, count: Int? = nil,
        input: Generator<S, some Sequence<I>>,
        body: (S, DiscoveryCoverage) async throws -> Void
    ) async throws {
        let env = ProcessInfo.processInfo.environment
        let coverage = DiscoveryCoverage()
        if let path = env["BOUTIQUE_PROPERTY_REPLAY"] {
            let artifact = try JSONDecoder().decode(DiscoveryArtifact<S>.self,
                from: Data(contentsOf: URL(fileURLWithPath: path)))
            try discoveryRequire(artifact.version == 1 && artifact.suite == name,
                                 "replay.schema", step: 0, "Use --filter for the artifact's suite")
            try await body(artifact.reduced, coverage)
            print("PROPERTY REPLAY \(name): passed")
            return
        }

        var artifact: DiscoveryArtifact<S>?
        var successes = 0
        await propertyCheck(count: count ?? cases, input: input) { scenario in
            do {
                try await body(scenario, coverage)
                successes += 1
            } catch {
                let failure = (error as? DiscoveryFailure) ?? DiscoveryFailure(
                    invariant: "unexpected.\(String(reflecting: type(of: error)))", step: -1,
                    detail: String(describing: error))
                // An unrelated failure does not justify accepting this shrink candidate.
                if let original = artifact, original.failure.invariant != failure.invariant { return }
                if artifact == nil {
                    artifact = DiscoveryArtifact(suite: name,
                        revision: env["BOUTIQUE_TEST_REVISION"] ?? "unrecorded",
                        original: scenario, reduced: scenario, failure: failure)
                } else {
                    artifact?.reduced = scenario
                    artifact?.failure = failure
                }
                do {
                    let directory = URL(fileURLWithPath: env["BOUTIQUE_PROPERTY_ARTIFACTS"] ?? ".build/property-artifacts")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(artifact!).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
                } catch {
                    Issue.record("Cannot persist failure artifact: \(error)")
                }
                Issue.record("\(failure)")
            }
        }
        let counters = coverage.counts.keys.sorted().map { "\($0)=\(coverage.counts[$0]!)" }.joined(separator: ", ")
        print("PROPERTY \(name): successful attempts=\(successes); \(counters)")
    }
}
