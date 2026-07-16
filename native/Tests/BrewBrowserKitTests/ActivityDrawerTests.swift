import Testing
@testable import BrewBrowserKit

@Suite("ActivityDrawer sizing")
struct ActivityDrawerSizingTests {
    @Test func preservesExistingDrawerHeightAsMinimum() {
        #expect(ActivityDrawer.clampedDrawerHeight(120, maximum: 500) == 252)
    }

    @Test func capsDrawerAtTheWindowBound() {
        #expect(ActivityDrawer.clampedDrawerHeight(500, maximum: 360) == 360)
    }

    @Test func retainsAValidPersistedHeight() {
        #expect(ActivityDrawer.clampedDrawerHeight(280, maximum: 360) == 280)
    }

    @Test func favorsTheMinimumWhenBoundsWouldOtherwiseConflict() {
        #expect(ActivityDrawer.clampedDrawerHeight(100, maximum: 150) == 252)
    }
}
