import Foundation
import Testing
@testable import BrewBrowserKit

// Parity tests for the Swift port of the Rust brew-output parsing
// (`src-tauri/src/brew/error_patterns.rs`, `exec.rs`). The fixtures here are
// the SAME real-stderr shapes the Rust tests use, so the two implementations
// are pinned to identical behavior. When the Rust catalog changes, change both.

// MARK: - friendlify

@Suite("BrewErrorPatterns.friendlify")
struct FriendlifyTests {
    // Captured from a real `brew bundle dump --force` run.
    static let topo = """
    Error: key not found: "shivammathur/extensions/imap-uw"
    /opt/homebrew/Library/Homebrew/bundle/brew.rb:686:in 'Homebrew::Bundle::Brew::Topo#tsort_each_child'
    """
    static let report = """
    Error: undefined method 'foo' for nil:NilClass
    Please report this issue:
      https://docs.brew.sh/Troubleshooting
    """
    static let launchd = "Error: Could not find service \"ollama\" in domain for current user (gui/501/16).\nTry running launchctl bootstrap under the right domain, or move the plist to ~/Library/LaunchAgents.\n"
    static let locked = "Error: A `brew upgrade` process has already locked /opt/homebrew/Cellar/ca-certificates.\nPlease wait for it to finish or terminate it to continue.\n"
    static let sudoPassword = """
    ==> Removing launchctl service `com.docker.vmnetd`
    sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
    sudo: a password is required
    Error: docker-desktop: Failure while executing; `/usr/bin/sudo -E -- /usr/bin/xargs -0 -- /bin/rm -r -f --` exited with 1.
    """

    @Test func topoMatchesOnBundle() {
        let msg = BrewErrorPatterns.friendlify(stderr: Self.topo, command: "brew bundle dump --file=/tmp/x --force")
        #expect(msg?.contains("upstream Homebrew bug") == true)
        #expect(msg?.contains("brew untap") == true)
    }

    @Test func topoDoesNotFireOnNonBundle() {
        #expect(BrewErrorPatterns.friendlify(stderr: Self.topo, command: "brew install foo") == nil)
    }

    @Test func pleaseReportMatches() {
        let msg = BrewErrorPatterns.friendlify(stderr: Self.report, command: "brew bundle dump")
        #expect(msg?.contains("docs.brew.sh/Troubleshooting") == true)
    }

    @Test func launchdMatchesOnServices() {
        let msg = BrewErrorPatterns.friendlify(stderr: Self.launchd, command: "brew services start ollama")
        #expect(msg?.contains("launchd") == true)
        #expect(msg?.contains("~/Library/LaunchAgents") == true)
    }

    @Test func launchdDoesNotFireOutsideServices() {
        #expect(BrewErrorPatterns.friendlify(stderr: Self.launchd, command: "brew install ollama") == nil)
    }

    @Test func lockedMatches() {
        let msg = BrewErrorPatterns.friendlify(stderr: Self.locked, command: "brew upgrade")
        #expect(msg?.contains("Another Homebrew process") == true)
    }

    @Test func sudoPasswordPromptMatches() {
        let msg = BrewErrorPatterns.friendlify(stderr: Self.sudoPassword, command: "brew upgrade docker-desktop")
        #expect(msg?.contains("administrator password") == true)
        #expect(msg?.contains("Terminal") == true)
        #expect(msg?.contains("docker-desktop") == true)
        #expect(msg?.contains("brew upgrade --cask docker-desktop") == true)
    }

    @Test func sudoPasswordPromptFallsBackToCommandToken() {
        let msg = BrewErrorPatterns.friendlify(
            stderr: "sudo: a password is required\n",
            command: "brew upgrade --cask docker-desktop"
        )
        #expect(msg?.contains("brew upgrade --cask docker-desktop") == true)
    }

    @Test func genericFailureFallsThrough() {
        let stderr = "Error: No available formula with the name \"definitely-not-a-real-pkg\".\n"
        #expect(BrewErrorPatterns.friendlify(stderr: stderr, command: "brew install definitely-not-a-real-pkg") == nil)
    }

    @Test func emptyInputsReturnNil() {
        #expect(BrewErrorPatterns.friendlify(stderr: "", command: "") == nil)
        #expect(BrewErrorPatterns.friendlify(stderr: "Error: anything", command: "") == nil)
    }
}

// MARK: - upgradeWarningsOnly

@Suite("BrewErrorPatterns.upgradeWarningsOnly")
struct UpgradeWarningsTests {
    // Real stderr tails from the bogus "Upgrade-all failed" reports (#28/#53/#55).
    static let postInstall = "Warning: ffmpeg@7 was installed but not linked because ffmpeg is already linked.\nWarning: The post-install step did not complete successfully\n"
    static let skipLink = "Warning: The post-install step did not complete successfully\nWarning: It seems there is already a Binary at '/opt/homebrew/bin/codex' from formula codex; skipping link.\n"
    static let linkStep = "Error: The `brew link` step did not complete successfully\n"

    @Test func matchesPostInstallWarning() {
        #expect(BrewErrorPatterns.upgradeWarningsOnly(stderr: Self.postInstall, command: "brew upgrade"))
    }

    @Test func matchesSkipLink() {
        #expect(BrewErrorPatterns.upgradeWarningsOnly(stderr: Self.skipLink, command: "brew upgrade"))
    }

    @Test func matchesLinkStepError() {
        #expect(BrewErrorPatterns.upgradeWarningsOnly(stderr: Self.linkStep, command: "brew upgrade git"))
    }

    @Test func falseOnRealFailure() {
        let mixed = "Warning: The post-install step did not complete successfully\nError: Failed to download resource \"foo\"\n"
        #expect(!BrewErrorPatterns.upgradeWarningsOnly(stderr: mixed, command: "brew upgrade"))
    }

    @Test func falseOnLock() {
        let locked = "Error: A `brew upgrade` process has already locked /opt/homebrew/Cellar/x.\n"
        #expect(!BrewErrorPatterns.upgradeWarningsOnly(stderr: locked, command: "brew upgrade"))
    }

    @Test func falseOnSudoPasswordPrompt() {
        let mixed = "Warning: The post-install step did not complete successfully\n" + FriendlifyTests.sudoPassword
        #expect(!BrewErrorPatterns.upgradeWarningsOnly(stderr: mixed, command: "brew upgrade docker-desktop"))
    }

    @Test func gatedToUpgradeInstall() {
        #expect(!BrewErrorPatterns.upgradeWarningsOnly(stderr: Self.postInstall, command: "brew services list"))
    }

    @Test func falseWhenNoMarker() {
        #expect(!BrewErrorPatterns.upgradeWarningsOnly(stderr: "✔︎ Bottle foo (1.0)\n", command: "brew upgrade"))
    }
}

// MARK: - BrewProgressParser

@Suite("BrewProgressParser")
struct ProgressParserTests {
    @Test func parsesUpgradeSequence() {
        var p = BrewProgressParser()
        // Header sets total, not itself a tick.
        #expect(p.observe("==> Upgrading 3 outdated packages:") == nil)
        // Non-marker lines ignored.
        #expect(p.observe("foo 1.0 -> 1.1") == nil)

        let t1 = p.observe("==> Pouring foo--1.1.arm64.bottle.tar.gz")
        #expect(t1?.phase == "Pouring")
        #expect(t1?.package == "foo")
        #expect(t1?.current == 1)
        #expect(t1?.total == 3)

        // Downloading updates phase without advancing the counter.
        let t2 = p.observe("==> Downloading https://example.com/bar.bottle")
        #expect(t2?.phase == "Downloading")
        #expect(t2?.current == 1)

        let t3 = p.observe("==> Pouring bar--2.0.arm64.bottle.tar.gz")
        #expect(t3?.package == "bar")
        #expect(t3?.current == 2)

        // Same package's later phase does not double-count.
        let t4 = p.observe("==> Installing bar")
        #expect(t4?.current == 2)
    }

    @Test func totalFromDependencyList() {
        var p = BrewProgressParser()
        #expect(p.observe("==> Installing dependencies for wget: openssl@3, ca-certificates") == nil)
        let t = p.observe("==> Installing openssl@3")
        #expect(t?.total == 3) // 2 deps + the target
    }

    @Test func nonMarkerLinesYieldNil() {
        var p = BrewProgressParser()
        #expect(p.observe("") == nil)
        #expect(p.observe("just some output") == nil)
        #expect(p.observe("Warning: something") == nil)
    }

    // Robustness: adversarial lines must never crash, and the counter must be
    // monotonic non-decreasing (parity with the Rust fuzz test in exec.rs).
    @Test func robustAgainstAdversarialLines() {
        var p = BrewProgressParser()
        let lines = [
            "", "==>", "==> ", "==> Pouring", "==> Pouring ", "==> Pouring --",
            "==> Upgrading 4294967296 outdated packages:",
            "==> Upgrading 999999999999999999999 outdated packages:",
            "==> Upgrading -1 outdated packages:",
            "==> Installing dependencies for x:",
            "==> Installing dependencies for x: ,, , ,",
            "==> Fetching ", "==> Downloading ",
            "==> Pouring x--" + String(repeating: "y", count: 50_000),
            "日本語==> Pouring 日本--1.0",
        ]
        var last = 0
        for _ in 0..<200 {
            for l in lines {
                if let t = p.observe(l) {
                    #expect(t.current >= last)
                    last = t.current
                }
            }
        }
    }
}

@Suite("Classifier robustness")
struct ClassifierFuzzTests {
    @Test func neverCrashOnAdversarialInput() {
        var inputs = ["", " ", "\n\0\t", "Error:", "Warning:", "has already locked"]
        inputs.append(String(repeating: "A", count: 200_000))
        inputs.append(String(repeating: "日本語", count: 20_000))
        inputs.append("\u{0}\u{1}\u{2}\u{7f}control")
        let commands = ["", "brew upgrade", "brew install x", "brew services start y", "brew bundle dump"]
        for inp in inputs {
            for cmd in commands {
                _ = BrewErrorPatterns.friendlify(stderr: inp, command: cmd)
                _ = BrewErrorPatterns.upgradeWarningsOnly(stderr: inp, command: cmd)
            }
        }
    }
}

// MARK: - Issue #80: doctor advisory exit + cleanup reclaimable parsing
// Parity with disk_usage.rs / error_patterns.rs tests (same fixtures).

@Suite("Issue #80 — doctor / cleanup parsing")
struct DoctorCleanupParsingTests {
    @Test func doctorAdvisoryExitMatchesBrewDoctor() {
        #expect(BrewErrorPatterns.doctorAdvisoryExit(command: "brew doctor"))
    }

    @Test func doctorAdvisoryExitRejectsOthers() {
        #expect(!BrewErrorPatterns.doctorAdvisoryExit(command: "brew upgrade"))
        #expect(!BrewErrorPatterns.doctorAdvisoryExit(command: "brew cleanup --prune=all --scrub"))
        #expect(!BrewErrorPatterns.doctorAdvisoryExit(command: "brew install doctor"))
        #expect(!BrewErrorPatterns.doctorAdvisoryExit(command: ""))
        #expect(!BrewErrorPatterns.doctorAdvisoryExit(command: "doctor"))
    }

    @Test func parseSizeTokenUnits() {
        #expect(BrewErrorPatterns.parseSizeToken("900B") == Int64(900))
        #expect(BrewErrorPatterns.parseSizeToken("1KB") == Int64(1024))
        #expect(BrewErrorPatterns.parseSizeToken("1.5KB") == Int64(1536))
        #expect(BrewErrorPatterns.parseSizeToken("500MB") == Int64(500 * 1024 * 1024))
        #expect(BrewErrorPatterns.parseSizeToken("2GB.") == Int64(2) * 1024 * 1024 * 1024)
    }

    @Test func parseSizeTokenRejectsGarbage() {
        #expect(BrewErrorPatterns.parseSizeToken("") == nil)
        #expect(BrewErrorPatterns.parseSizeToken("GB") == nil)
        #expect(BrewErrorPatterns.parseSizeToken("12") == nil)
        #expect(BrewErrorPatterns.parseSizeToken("1.2ZB") == nil)
        #expect(BrewErrorPatterns.parseSizeToken("-5GB") == nil)
    }

    @Test func parseReclaimableFromRealLine() {
        let out = """
        Would remove: ~/Library/Caches/Homebrew/foo (1.2GB)
        ==> This operation would free approximately 2.5GB of disk space.
        """
        #expect(BrewErrorPatterns.parseReclaimableBytes(out) == Int64(2.5 * 1024 * 1024 * 1024))
    }

    @Test func parseReclaimableNoneWhenNothing() {
        #expect(BrewErrorPatterns.parseReclaimableBytes("Nothing to clean up.") == nil)
        #expect(BrewErrorPatterns.parseReclaimableBytes("") == nil)
    }
}

@Suite("BrewService.brewEnvironment")
struct BrewEnvironmentTests {
    // The privacy contract (parity with Rust `brew::exec::BREW_ENV`): every
    // app-spawned brew command disables Homebrew's own InfluxDB analytics ping.
    @Test func disablesHomebrewAnalytics() {
        #expect(BrewService.brewEnvironment()["HOMEBREW_NO_ANALYTICS"] == "1")
    }

    @Test func keepsTerminalChatterSuppressed() {
        let env = BrewService.brewEnvironment()
        #expect(env["HOMEBREW_NO_COLOR"] == "1")
        #expect(env["HOMEBREW_NO_ENV_HINTS"] == "1")
    }
}

@Suite("BrewArgs")
struct BrewArgsTests {
    // Parity with the Rust `commands::actions::tests` arg-builders.

    @Test func installAdoptIsCaskOnly() {
        #expect(BrewArgs.install("cursor", kind: .cask, adopt: true)
            == ["install", "--cask", "cursor", "--adopt"])
        // Formulae have no on-disk app to adopt → flag dropped.
        #expect(BrewArgs.install("wget", kind: .formula, adopt: true)
            == ["install", "wget"])
    }

    @Test func installAdoptAndForceOrder() {
        #expect(BrewArgs.install("cursor", kind: .cask, force: true, adopt: true)
            == ["install", "--cask", "cursor", "--adopt", "--force"])
    }

    @Test func installPlainUnchanged() {
        #expect(BrewArgs.install("cursor", kind: .cask) == ["install", "--cask", "cursor"])
    }

    @Test func uninstallIgnoreDependenciesForceRemove() {
        #expect(BrewArgs.uninstall("gstreamer-runtime", kind: .cask, ignoreDependencies: true)
            == ["uninstall", "--cask", "gstreamer-runtime", "--ignore-dependencies"])
    }

    @Test func uninstallZapIsCaskOnly() {
        // --zap dropped for a formula; --ignore-dependencies still applies.
        #expect(BrewArgs.uninstall("foo", kind: .formula, zap: true, ignoreDependencies: true)
            == ["uninstall", "foo", "--ignore-dependencies"])
    }

    @Test func pinFormulaAndCask() {
        #expect(BrewArgs.setPinned("wget", kind: .formula, pinned: true) == ["pin", "wget"])
        // Casks pin too in current Homebrew — the actual #90/#134 case.
        #expect(BrewArgs.setPinned("google-chrome", kind: .cask, pinned: true)
            == ["pin", "--cask", "google-chrome"])
    }

    @Test func unpinUsesUnpinVerb() {
        #expect(BrewArgs.setPinned("google-chrome", kind: .cask, pinned: false)
            == ["unpin", "--cask", "google-chrome"])
    }

    // MARK: - installBundle (M3 "Install all" arg groups)

    private func pkg(_ name: String, _ kind: String) -> BundlePackage {
        BundlePackage(name: name, kind: kind)
    }

    @Test func installBundleSplitsFormulaAndCaskGroups() {
        // brew rejects `--formula … --cask …` in one invocation, so the builder
        // emits two per-kind groups: formulae first (input order), then casks.
        let groups = BrewArgs.installBundle([pkg("ollama", "formula"), pkg("open-webui", "cask")])
        #expect(groups == [
            ["install", "--formula", "ollama"],
            ["install", "--cask", "open-webui"],
        ])
    }

    @Test func installBundleFormulaeOnlyIsOneGroup() {
        let groups = BrewArgs.installBundle([
            pkg("ffmpeg", "formula"), pkg("yt-dlp", "formula"), pkg("mpv", "formula"),
        ])
        #expect(groups == [["install", "--formula", "ffmpeg", "yt-dlp", "mpv"]])
    }

    @Test func installBundleCasksOnlyIsOneGroup() {
        let groups = BrewArgs.installBundle([
            pkg("inkscape", "cask"), pkg("gimp", "cask"), pkg("krita", "cask"),
        ])
        #expect(groups == [["install", "--cask", "inkscape", "gimp", "krita"]])
    }

    @Test func installBundleEmptyYieldsNoGroups() {
        #expect(BrewArgs.installBundle([]).isEmpty)
    }

    @Test func installBundleUnknownKindTreatedAsFormula() {
        // brew's default is a formula; an unexpected kind must not silently drop
        // the package from the install set.
        let groups = BrewArgs.installBundle([pkg("node", "unknown")])
        #expect(groups == [["install", "--formula", "node"]])
    }
}

@Suite("BrewRecovery")
struct BrewRecoveryTests {
    // Parity with the Tauri `util/recovery.test.ts`.

    private func failed(_ command: String, _ stderr: [String],
                        status: ActivityJob.JobStatus = .failed,
                        exitCode: Int32? = 1) -> ActivityJob {
        ActivityJob(
            id: UUID(), label: "x", command: command, startedAt: 0,
            status: status,
            lines: stderr.map { ActivityLine(stream: .stderr, text: $0) },
            exitCode: exitCode)
    }

    @Test func caskAlreadyExistsOffersAdoptAndOverwrite() {
        let r = BrewRecovery.classify(failed("brew install --cask google-chrome",
            ["Error: It seems there is already an App at '/Applications/Google Chrome.app'."]))
        #expect(r != nil)
        #expect(r?.action == .install)
        #expect(r?.kind == .cask)
        #expect(r?.name == "google-chrome")
        #expect(r?.choices.map(\.choice) == [.adopt, .overwrite])
    }

    @Test func formulaAlreadyExistsOffersOnlyOverwrite() {
        let r = BrewRecovery.classify(failed("brew install --formula foo",
            ["Error: It seems there is already a Binary at '/opt/homebrew/bin/foo'."]))
        #expect(r?.kind == .formula)
        #expect(r?.choices.map(\.choice) == [.overwrite])
    }

    @Test func uninstallRequiredByOffersForceRemove() {
        let r = BrewRecovery.classify(failed("brew uninstall --cask gstreamer-runtime",
            ["Error: Refusing to uninstall gstreamer-runtime",
             "because it is required by wine-stable, which is currently installed."]))
        #expect(r?.action == .uninstall)
        #expect(r?.name == "gstreamer-runtime")
        #expect(r?.choices.map(\.choice) == [.forceRemove])
    }

    @Test func nonRecoverableCasesReturnNil() {
        // Succeeded.
        #expect(BrewRecovery.classify(failed("brew install --cask x", ["whatever"], status: .succeeded)) == nil)
        // No exit code = our spawn failure.
        #expect(BrewRecovery.classify(failed("brew install --cask x", ["boom"], exitCode: nil)) == nil)
        // Unrelated upgrade failure.
        #expect(BrewRecovery.classify(failed("brew upgrade", ["Error: other"])) == nil)
        // Install failure that isn't an existing-app conflict.
        #expect(BrewRecovery.classify(failed("brew install --cask x", ["Error: Download failed: 404"])) == nil)
    }
}
