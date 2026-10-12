import Foundation
import Testing
@testable import BrewBrowserKit

/// Parity tests for the native partial-upgrade classifier + Terminal hand-off
/// helpers. Mirrors the web `partialUpgrade.test.ts` and the Rust
/// `is_safe_upgrade_token` / `upgrade_command` tests so all three shells parse
/// and escape identically.
@Suite("PartialUpgrade")
struct PartialUpgradeTests {
    private func job(
        command: String = "brew upgrade --greedy",
        status: ActivityJob.JobStatus = .failed,
        exitCode: Int32? = 1,
        text: String = ""
    ) -> ActivityJob {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ActivityLine(stream: .stdout, text: String($0)) }
        return ActivityJob(id: UUID(), label: "Upgrading all packages", command: command,
                           startedAt: 0, status: status, lines: lines, exitCode: exitCode,
                           durationMs: nil, friendlyFailureMessage: nil, progress: nil)
    }

    @Test("parses upgraded count + per-package failures")
    func parsesPartial() {
        let r = PartialUpgrade.classify(job(text: """
        ==> Upgrading miniconda
        Error: miniconda: Failure while executing; `/usr/bin/sudo … /bin/rm -r -f` exited with 1.
        ==> Upgrading qlmarkdown
        Error: qlmarkdown: It seems the App source '/Applications/QLMarkdown.app' is not there.
        ==> Upgraded 74 outdated packages
        """))
        #expect(r == PartialUpgrade.Result(upgraded: 74, failures: ["miniconda", "qlmarkdown"]))
    }

    @Test("handles @-versioned tokens and de-dupes")
    func versionedAndDedup() {
        #expect(PartialUpgrade.classify(job(text: "Error: temurin@17: boom"))?.failures == ["temurin@17"])
        #expect(PartialUpgrade.classify(job(text: "Error: miniconda: a\nError: miniconda: b"))?.failures == ["miniconda"])
    }

    @Test("falls back to counting Upgrading lines minus failures")
    func fallbackCount() {
        let r = PartialUpgrade.classify(job(text: "==> Upgrading a\n==> Upgrading b\n==> Upgrading c\nError: c: boom"))
        #expect(r == PartialUpgrade.Result(upgraded: 2, failures: ["c"]))
    }

    @Test("nil for untrusted-tap (no Error: <token>: form), non-upgrade, spawn failure, success")
    func nilCases() {
        #expect(PartialUpgrade.classify(job(text: "Error: Refusing to load formula steipete/tap/x from untrusted tap.")) == nil)
        #expect(PartialUpgrade.classify(job(command: "brew install --cask foo", text: "Error: foo: exists")) == nil)
        #expect(PartialUpgrade.classify(job(exitCode: nil, text: "Error: x: boom")) == nil)
        #expect(PartialUpgrade.classify(job(status: .succeeded, text: "Error: x: boom")) == nil)
    }

    @Test("token validation + command/script escaping")
    func tokenAndCommand() {
        for ok in ["miniconda", "temurin@17", "user/tap/name", "a-b_c.d+e"] {
            #expect(PartialUpgrade.isSafeToken(ok), "accept \(ok)")
        }
        for bad in ["", "-rf", "/etc/passwd", "../x", "a b", "a;rm", "a\"b", "a'b", "a|b"] {
            #expect(!PartialUpgrade.isSafeToken(bad), "reject \(bad)")
        }
        #expect(PartialUpgrade.upgradeCommand(brew: "/opt/homebrew/bin/brew", name: "miniconda")
            == "'/opt/homebrew/bin/brew' upgrade miniconda")
        #expect(PartialUpgrade.terminalRunScript("say \"hi\"").contains("\\\"hi\\\""))
    }
}
