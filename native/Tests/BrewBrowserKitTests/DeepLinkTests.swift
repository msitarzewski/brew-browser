import Foundation
import Testing
@testable import BrewBrowserKit

/// Deep-link parsing (`brewbrowser://bundle/<id>`). Mirrors the Tauri
/// `deeplink.test.ts` cases so both shells agree on what a valid link is.
@Suite("DeepLink")
struct DeepLinkTests {
    private func id(_ s: String) -> String? {
        guard let url = URL(string: s) else { return nil }
        return AppModel.deepLinkBundleID(from: url)
    }

    @Test("parses brewbrowser://bundle/<id> (host authority)")
    func hostForm() {
        #expect(id("brewbrowser://bundle/local-llm") == "local-llm")
    }

    @Test("tolerates the empty-authority form brewbrowser:///bundle/<id>")
    func emptyAuthorityForm() {
        #expect(id("brewbrowser:///bundle/image-gen") == "image-gen")
    }

    @Test("rejects other schemes")
    func rejectsOtherSchemes() {
        #expect(id("https://bundle/local-llm") == nil)
        #expect(id("file:///etc/passwd") == nil)
    }

    @Test("rejects unknown hosts and missing id")
    func rejectsUnknownOrMissing() {
        #expect(id("brewbrowser://package/jq") == nil)
        #expect(id("brewbrowser://bundle") == nil)
        #expect(id("brewbrowser://bundle/") == nil)
    }
}
