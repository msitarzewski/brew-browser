import Testing
import Foundation
@testable import BrewBrowserKit

// Tests for the shared-inspector detail state that Bundles reuses. Bundle and
// package detail occupy ONE `.inspector` slot (ContentView keys on
// `detailBundle` then `detailPackage`), so `openBundleDetail` must set the
// bundle + open the inspector while clearing any loaded package, and
// `closeDetail` must clear both — keeping the two detail kinds mutually
// exclusive. Drivable without any UI (pure AppModel state transitions).

@Suite("Bundle detail inspector state")
@MainActor
struct BundleDetailStateTests {
    private func sampleBundle() -> BrewBundle {
        BrewBundle(
            id: "sample-bundle",
            name: "Sample Bundle",
            tagline: "A tiny fixture bundle.",
            category: "Development",
            packages: [BundlePackage(name: "git", kind: "formula")]
        )
    }

    @Test func openBundleDetailOpensInspectorAndClearsPackage() {
        let model = AppModel()
        // Simulate a package detail already loaded in the shared inspector.
        model.detailPackage = InstalledPackage(name: "wget", version: "1.0", kind: .formula)
        model.showDetail = true

        model.openBundleDetail(sampleBundle())

        #expect(model.detailBundle?.id == "sample-bundle")
        #expect(model.detailPackage == nil)   // mutually exclusive with the bundle
        #expect(model.detailSection == .bundles)
        #expect(model.showDetail)
    }

    @Test func closeDetailClearsBothDetailKinds() {
        let model = AppModel()
        model.openBundleDetail(sampleBundle())

        model.closeDetail()

        #expect(model.detailBundle == nil)
        #expect(model.detailPackage == nil)
        #expect(!model.showDetail)
        #expect(model.detailSection == nil)
    }
}
