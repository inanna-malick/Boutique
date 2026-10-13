import Foundation
import Observation
import PropertyBased
import Testing
@testable import Boutique

struct PreviewFixture: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var payload: Int
}
struct PreviewScenario: Codable, Sendable {
    var payloads: [Int]
    var waits: Int
}

@MainActor
@Suite("Preview Store lifecycle discovery", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_TEMP_ROOT"] != nil))
struct StorePreviewLifecycleDiscoveryTests {
    private func isolation() throws {
        let root = try discoveryUnwrap(ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_TEMP_ROOT"], "preview.isolation-token")
        try discoveryRequire(root.contains("BoutiquePreviewInvestigation."), "preview.isolation-name", step: -1)
        try discoveryRequire(URL.temporaryDirectory.standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path,
            "preview.isolation-directory", step: -1, "TMPDIR must be set before process launch: actual=\(URL.temporaryDirectory.path), expected=\(root)")
    }
    private func generator() -> Generator<PreviewScenario, some Sequence> {
        zip(Gen.int(in: -100...100).array(of: 1...12), Gen.int(in: 1...3))
            .map { PreviewScenario(payloads: $0, waits: $1) }
    }
    private func fixtures(_ scenario: PreviewScenario) -> [PreviewFixture] {
        scenario.payloads.enumerated().map { PreviewFixture(id: "fixture-\($0.offset)", payload: $0.element) }
    }
    private func make(_ values: [PreviewFixture], overload: String) -> Store<PreviewFixture> {
        if overload == "identifiable" { return Store.previewStore(items: values) }
        return Store.previewStore(items: values, cacheIdentifier: \.id)
    }

    @Test(.shrinking, arguments: ["keypath", "identifiable"])
    func immediateConstructionControls(overload: String) async throws {
        try isolation()
        try await DiscoveryProperty.check("preview-immediate-\(overload)", input: generator()) { scenario, coverage in
            let expected = fixtures(scenario)
            let store = make(expected, overload: overload)
            // No suspension before this assertion: the MainActor load task cannot run.
            try discoveryRequire(store.items == expected, "preview.immediate-fixtures", step: 0)
            coverage.hit("fixtures", by: expected.count)
            try await store.itemsHaveLoaded() // Drain each task without asserting the known defect.
        }
    }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1"), arguments: ["keypath", "identifiable"])
    func loadedFixturesSearch(overload: String) async throws {
        try await loadedSearch(overload: overload)
    }

    @Test(.shrinking, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1"))
    func keypathLoadedReplay() async throws { try await loadedSearch(overload: "keypath") }

    private func loadedSearch(overload: String) async throws {
        try isolation()
        try await DiscoveryProperty.check("preview-loaded-\(overload)", count: 100, input: generator()) { scenario, coverage in
            let expected = fixtures(scenario)
            let store = make(expected, overload: overload)
            try discoveryRequire(store.items == expected, "preview.immediate-fixtures", step: 0)
            for wait in 1...scenario.waits {
                try await store.itemsHaveLoaded()
                try discoveryRequire(store.items == expected, "preview.loaded-fixtures", step: wait,
                    "supplied=\(expected), loaded=\(store.items)")
                coverage.hit("wait")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1"))
    func observationAfterLoadWitness() async throws {
        try isolation()
        let expected = [PreviewFixture(id: "fixture", payload: 7)]
        let store = make(expected, overload: "keypath")
        let observer = PreviewObservationCounter()
        withObservationTracking { _ = store.items } onChange: { observer.hit() }
        try await store.itemsHaveLoaded()
        print("PREVIEW observation notifications=\(observer.count)")
        #expect(store.items == expected)
    }
}

private final class PreviewObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func hit() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
