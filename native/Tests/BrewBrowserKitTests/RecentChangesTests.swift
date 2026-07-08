import Testing
import Foundation
@testable import BrewBrowserKit

// Tests for `RecentChanges` — the pure classifier + feed builder behind the
// Dashboard "Recent changes" card. Mirrors the Tauri `recentChanges(jobs)`
// test cases so the two shells stay in parity (same classification rules, same
// inclusion rules, same most-recent-first ordering, no fabricated data).

@Suite("RecentChanges")
struct RecentChangesTests {

    /// Build an `ActivityJob` with just the fields the classifier reads.
    private func job(
        _ label: String,
        _ command: String,
        startedAt: Double = 0,
        status: ActivityJob.JobStatus = .succeeded
    ) -> ActivityJob {
        ActivityJob(
            id: UUID(),
            label: label,
            command: command,
            startedAt: startedAt,
            status: status,
            lines: [],
            exitCode: nil,
            durationMs: nil,
            friendlyFailureMessage: nil,
            progress: nil
        )
    }

    @Test @MainActor func postJobRefreshOnlyRunsAfterSuccessfulCompletion() {
        #expect(AppModel.shouldRefreshAfterJob(succeeded: true, canceled: false))
        #expect(!AppModel.shouldRefreshAfterJob(succeeded: false, canceled: false))
        #expect(!AppModel.shouldRefreshAfterJob(succeeded: false, canceled: true))
    }

    @Test @MainActor func failureNoticeTitlesUseActionVerb() {
        let expectedUpgrade = L10n.isRussian ? "Не удалось обновить" : "Upgrade failed"
        let expectedInstall = L10n.isRussian ? "Не удалось установить" : "Install failed"
        let expectedUninstall = L10n.isRussian ? "Не удалось удалить" : "Uninstall failed"
        let expectedBrewfile = L10n.isRussian ? "Не удалось выполнить: Создаём Brewfile: nightly" : "Dumping Brewfile: nightly failed"
        #expect(AppModel.failureNoticeTitle(for: "Upgrading docker-desktop") == expectedUpgrade)
        #expect(AppModel.failureNoticeTitle(for: "Installing wget") == expectedInstall)
        #expect(AppModel.failureNoticeTitle(for: "Uninstalling wget") == expectedUninstall)
        #expect(AppModel.failureNoticeTitle(for: "Dumping Brewfile: nightly") == expectedBrewfile)
    }

    // MARK: - classify()

    @Test func classifiesInstall() {
        let r = RecentChanges.classify(label: "Installing wget", command: "brew install wget")
        #expect(r.kind == .installed)
        #expect(r.package == "wget")
        #expect(r.count == nil)
    }

    @Test func classifiesUninstall() {
        let r = RecentChanges.classify(label: "Uninstalling wget", command: "brew uninstall wget")
        #expect(r.kind == .uninstalled)
        #expect(r.package == "wget")
    }

    @Test func classifiesSingleUpgrade() {
        let r = RecentChanges.classify(label: "Upgrading wget", command: "brew upgrade wget")
        #expect(r.kind == .upgraded)
        #expect(r.package == "wget")
        #expect(r.count == nil)
    }

    @Test func classifiesBulkUpgradeWithCount() {
        let r = RecentChanges.classify(label: "Upgrading 3 packages", command: "brew upgrade a b c")
        #expect(r.kind == .upgraded)
        #expect(r.package == nil)  // bulk — no single name fabricated
        #expect(r.count == 3)
    }

    @Test func classifiesUpgradeAllAsBulkNoName() {
        let r = RecentChanges.classify(label: "Upgrading all packages", command: "brew upgrade")
        #expect(r.kind == .upgraded)
        #expect(r.package == nil)
        #expect(r.count == nil)  // "all" carries no count
    }

    @Test func classifiesBrewUpdateAsOther() {
        // Native emits "Updating Homebrew" for `brew update` (AppModel:407).
        let r = RecentChanges.classify(label: "Updating Homebrew", command: "brew update")
        #expect(r.kind == .other)
    }

    @Test func classifiesBundleDumpAsOther() {
        let r = RecentChanges.classify(label: "Dumping Brewfile: nightly", command: "brew bundle dump --file=/x.Brewfile --force")
        #expect(r.kind == .other)
    }

    @Test func classifiesSnapshotRestoreAsOther() {
        let r = RecentChanges.classify(label: "Restoring nightly", command: "brew bundle install --file=/x.Brewfile")
        #expect(r.kind == .other)
    }

    @Test func packageReadFromLabelNotCommandFlags() {
        // Force-install: the `--force` flag lives on the command; the label is
        // the clean "Installing iterm2". Package must come from the label.
        let r = RecentChanges.classify(label: "Installing iterm2", command: "brew install iterm2 --force")
        #expect(r.kind == .installed)
        #expect(r.package == "iterm2")
    }

    @Test func unknownLabelIsOtherNotCrash() {
        let r = RecentChanges.classify(label: "Tapping homebrew/cask", command: "brew tap homebrew/cask")
        #expect(r.kind == .other)
        #expect(r.package == nil)
    }

    // MARK: - recentChanges()

    @Test func excludesRunningJobs() {
        let jobs = [
            job("Installing wget", "brew install wget", status: .running),
            job("Installing curl", "brew install curl", status: .succeeded),
        ]
        let changes = RecentChanges.recentChanges(jobs)
        #expect(changes.count == 1)
        #expect(changes.first?.package == "curl")
    }

    @Test func filtersOutOtherKinds() {
        let jobs = [
            job("Updating Homebrew", "brew update"),
            job("Dumping Brewfile: nightly", "brew bundle dump"),
            job("Installing wget", "brew install wget"),
        ]
        let changes = RecentChanges.recentChanges(jobs)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .installed)
    }

    @Test func sortsMostRecentFirst() {
        let jobs = [
            job("Installing a", "brew install a", startedAt: 100),
            job("Installing b", "brew install b", startedAt: 300),
            job("Installing c", "brew install c", startedAt: 200),
        ]
        let changes = RecentChanges.recentChanges(jobs)
        #expect(changes.map(\.package) == ["b", "c", "a"])
    }

    @Test func stableOrderForEqualTimestamps() {
        // Equal startedAt → preserve input order (first-listed stays first).
        let jobs = [
            job("Installing a", "brew install a", startedAt: 100),
            job("Installing b", "brew install b", startedAt: 100),
        ]
        let changes = RecentChanges.recentChanges(jobs)
        #expect(changes.map(\.package) == ["a", "b"])
    }

    @Test func retainsFailedAndCanceledWithStatus() {
        // Failed/canceled aren't dropped — they're carried so the UI can mark
        // them "attempted"/"canceled". The package was NOT changed, but the row
        // is honest about that via `status`, not by inventing success.
        let jobs = [
            job("Installing a", "brew install a", startedAt: 300, status: .failed),
            job("Upgrading b", "brew upgrade b", startedAt: 200, status: .canceled),
            job("Installing c", "brew install c", startedAt: 100, status: .succeeded),
        ]
        let changes = RecentChanges.recentChanges(jobs)
        #expect(changes.count == 3)
        #expect(changes.map(\.status) == [.failed, .canceled, .succeeded])
    }

    @Test func emptyHistoryYieldsEmptyFeed() {
        #expect(RecentChanges.recentChanges([]).isEmpty)
    }

}
