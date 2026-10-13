import Foundation
import PropertyBased
import Testing
@testable import Boutique

private struct PreviewStringFixture: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var payload: Int
}
private struct PreviewUUIDFixture: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var payload: Int
}
private let previewOverloads = ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OVERLOAD"].map { [$0] } ?? ["keypath", "identifiable", "uuid"]
private enum PreviewCommand: String, Codable, Sendable {
    case inspect, yield, awaitLoaded
}
private struct PreviewScenario: Codable, Sendable {
    var payloads: [Int]
    var commands: [PreviewCommand]
}

/// Construction, read-only suspension, and explicit loading must preserve the
/// supplied Array model. No Store mutations or persistence writes are generated.
@MainActor
@Suite("Preview Store lifecycle discovery", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNED_DIRECTORY"] != nil))
struct StorePreviewLifecycleDiscoveryTests {
    private func ownership() throws {
        let root = try discoveryUnwrap(ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNED_DIRECTORY"], "preview.owner-directory")
        try discoveryRequire(URL.temporaryDirectory.appendingPathComponent("Previews").standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path,
            "preview.owner-directory", step: -1)
        let token = try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".boutique-preview-owner"), encoding: .utf8)
        try discoveryRequire(token == ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNER_TOKEN"], "preview.owner-token", step: -1)
    }
    private func generator() -> Generator<PreviewScenario, some Sequence> {
        zip(Gen.int(in: -100...100).array(of: 1...12), Gen.int(in: 0...2).array(of: 0...12))
            .map { payloads, commands in
                PreviewScenario(payloads: payloads, commands: commands.map { [.inspect, .yield, .awaitLoaded][$0] })
            }
    }
    private func execute(_ scenario: PreviewScenario, overload: String, checkLoaded: Bool, coverage: DiscoveryCoverage) async throws {
        if overload == "uuid" {
            let expected = scenario.payloads.enumerated().map {
                PreviewUUIDFixture(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0.offset + 1))!, payload: $0.element)
            }
            try await execute(Store.previewStore(items: expected), expected: expected, scenario: scenario, checkLoaded: checkLoaded, coverage: coverage)
        } else {
            let expected = scenario.payloads.enumerated().map { PreviewStringFixture(id: "fixture-\($0.offset)", payload: $0.element) }
            let store: Store<PreviewStringFixture> = overload == "keypath"
                ? .previewStore(items: expected, cacheIdentifier: \.id) : .previewStore(items: expected)
            try await execute(store, expected: expected, scenario: scenario, checkLoaded: checkLoaded, coverage: coverage)
        }
    }
    private func execute<T: StorableItem & Equatable>(_ store: Store<T>, expected: [T], scenario: PreviewScenario,
                                                      checkLoaded: Bool, coverage: DiscoveryCoverage) async throws {
        try discoveryRequire(store.items == expected, "preview.immediate-fixtures", step: 0)
        coverage.hit("fixtures", by: expected.count)
        // Draining each control's task prevents background work escaping its attempt.
        if !checkLoaded { try await store.itemsHaveLoaded(); return }
        // The required final wait is part of every history; arbitrary prefixes
        // explore reads, scheduler suspension, and repeated loading waits.
        for (index, command) in (scenario.commands + [.awaitLoaded]).enumerated() {
            switch command {
            case .inspect: break
            case .yield: await Task.yield()
            case .awaitLoaded: try await store.itemsHaveLoaded()
            }
            coverage.hit(command.rawValue)
            // Ensure the started task is drained even when this candidate fails.
            let observed = store.items
            if observed != expected { try await store.itemsHaveLoaded() }
            try discoveryRequire(observed == expected, "preview.loaded-fixtures", step: index + 1,
                "command=\(command), supplied=\(expected), observed=\(observed)")
        }
    }
    @Test(.shrinking, arguments: previewOverloads)
    func immediateConstructionControls(overload: String) async throws {
        try ownership()
        try await DiscoveryProperty.check("preview-immediate-\(overload)", input: generator()) { scenario, coverage in
            try await execute(scenario, overload: overload, checkLoaded: false, coverage: coverage)
        }
    }
    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1"),
          arguments: previewOverloads)
    func loadedFixturesSearch(overload: String) async throws {
        try ownership()
        try await DiscoveryProperty.check("preview-loaded-\(overload)", count: 100, input: generator()) { scenario, coverage in
            try await execute(scenario, overload: overload, checkLoaded: true, coverage: coverage)
        }
    }
}
