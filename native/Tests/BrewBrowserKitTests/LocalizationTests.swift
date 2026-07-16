import Testing
@testable import BrewBrowserKit

@Suite("Localization helpers")
struct LocalizationTests {
    @Test func catalogAgeTodayDoesNotExposeMissingKey() {
        let label = L10n.catalogAge(days: 0)

        #expect(label != "date.today")
        if L10n.isRussian {
            #expect(label == "сегодня")
        } else {
            #expect(label == "today")
        }
    }

    @Test func catalogSourceDoesNotExposeWireValueInRussian() {
        let label = L10n.display("user-refreshed")

        if L10n.isRussian {
            #expect(label == "обновлён пользователем")
        } else {
            #expect(label == "user-refreshed")
        }
    }
}
