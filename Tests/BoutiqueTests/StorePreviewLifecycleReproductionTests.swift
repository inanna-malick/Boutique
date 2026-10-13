import Foundation
import Testing
@testable import Boutique

/// Standalone opt-in regression. run-owned.sh exclusively creates an absent
/// Foundation Previews directory and supplies a matching ownership marker.
/// Existing Preview data is never opened or cleaned by the runner.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_FINDINGS"] == "1" && ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNED_DIRECTORY"] != nil))
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
        let root = try #require(ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNED_DIRECTORY"])
        try #require(URL.temporaryDirectory.appendingPathComponent("Previews").standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path)
        try #require(try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".boutique-preview-owner"), encoding: .utf8) == ProcessInfo.processInfo.environment["BOUTIQUE_PREVIEW_OWNER_TOKEN"])
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
