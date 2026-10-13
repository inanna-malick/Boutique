import Foundation
import Testing
@testable import Boutique

/// Opt-in scaffold: an isolated Foundation temporary directory is required before
/// any preview call. This host ignores TMPDIR, so the guard fails without calling
/// previewStore. No shared Preview database is opened or cleaned up.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1" && ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_TEMP_ROOT"] != nil))
struct StorePreviewLifecycleReproductionTests {
    private struct StringItem: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var payload: Int
    }
    private struct UUIDItem: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var payload: Int
    }
    @Test(arguments: ["keypath", "identifiable", "uuid"])
    func suppliedFixturesSurviveLoading(overload: String) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_TEMP_ROOT"])
        try #require(root.contains("BoutiquePreviewInvestigation."))
        try #require(URL.temporaryDirectory.standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path,
                     "Isolation unavailable: do not construct a preview in the shared temporary directory")
        if overload == "uuid" {
            let expected = [UUIDItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, payload: 7)]
            let store = Store<UUIDItem>.previewStore(items: expected)
            #expect(store.items == expected)
            try await store.itemsHaveLoaded()
            #expect(store.items == expected)
        } else {
            let expected = [StringItem(id: "fixture", payload: 7)]
            let store: Store<StringItem> = overload == "keypath"
                ? .previewStore(items: expected, cacheIdentifier: \.id)
                : .previewStore(items: expected)
            #expect(store.items == expected)
            try await store.itemsHaveLoaded()
            #expect(store.items == expected)
        }
    }
}
