import Foundation

/// Native port of the web `partialUpgrade.ts` (and the Rust token/command
/// helpers in `commands/env.rs`). Recognizes a bulk `brew upgrade` that mostly
/// SUCCEEDED but exited non-zero because a few individual packages errored — a
/// cask that needed `sudo`, whose app was moved, or that's OS-incompatible.
///
/// Lets the UI report the real outcome ("Upgraded 74 · 2 had errors") and offer
/// a per-package "Run in Terminal" hand-off (where sudo can prompt), instead of
/// a blanket "Upgrade failed" — the single largest source of misfiled
/// "[brew-browser] Upgrade(-all) failed" reports. Everything here is pure +
/// unit-tested so both shells rank/parse identically.
enum PartialUpgrade {
    struct Result: Equatable, Sendable {
        var upgraded: Int
        var failures: [String]
    }

    // "Error: miniconda: …" / "Error: temurin@17: …" — capture group 1 is the
    // package token. The trailing ": " distinguishes it from "Error: Refusing …".
    private static let errorRe = try! NSRegularExpression(
        pattern: #"^Error:\s+([A-Za-z0-9@._+/-]+):\s"#)
    // "==> Upgraded 74 outdated packages" / "Upgraded 3 packages".
    private static let summaryRe = try! NSRegularExpression(
        pattern: #"Upgraded\s+(\d+)\s+(?:outdated\s+)?packages?"#, options: [.caseInsensitive])
    // "==> Upgrading <token>" — fallback count when no summary is present.
    private static let upgradingRe = try! NSRegularExpression(
        pattern: #"^==>\s*Upgrading\s+\S"#)

    /// Classify a failed `brew upgrade` job as a partial success, or nil when it
    /// isn't one (not a failed upgrade, no exit code = our spawn failure, or no
    /// named per-package failures to act on). Pure.
    static func classify(_ job: ActivityJob) -> Result? {
        guard job.status == .failed, job.exitCode != nil else { return nil }
        guard job.command.range(of: #"\bupgrade\b"#, options: .regularExpression) != nil else { return nil }

        var failures: [String] = []
        var upgrading = 0
        for line in job.lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if let name = errorToken(t), !failures.contains(name) { failures.append(name) }
            if matches(upgradingRe, t) { upgrading += 1 }
        }
        guard !failures.isEmpty else { return nil }

        let whole = job.lines.map(\.text).joined(separator: "\n")
        let upgraded = upgradedCount(whole) ?? max(0, upgrading - failures.count)
        return Result(upgraded: upgraded, failures: failures)
    }

    /// Extract the package token from an "Error: <token>: …" line, or nil.
    static func errorToken(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = errorRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Parse the "Upgraded N packages" summary count, or nil.
    static func upgradedCount(_ text: String) -> Int? {
        let ns = text as NSString
        guard let m = summaryRe.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: Terminal hand-off (mirrors Rust is_safe_upgrade_token / upgrade_command)

    /// Accept only a brew package token: ASCII alphanumerics plus `@ . _ + -`
    /// and the tap separator `/`. No whitespace/quotes/shell metacharacters, no
    /// leading `-` (flag injection) or `..`. The trust boundary for the Terminal
    /// hand-off.
    static func isSafeToken(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              !name.hasPrefix("-"), !name.hasPrefix("/"), !name.contains("..") else { return false }
        return name.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || "@._+-/".contains(c))
        }
    }

    /// `'<brew>' upgrade <name>` — brew path single-quoted defensively; `name`
    /// is pre-validated to a shell-safe token so it needs no quoting.
    static func upgradeCommand(brew: String, name: String) -> String {
        "'\(brew.replacingOccurrences(of: "'", with: "'\\''"))' upgrade \(name)"
    }

    /// AppleScript that opens Terminal.app and runs `command` in a fresh window,
    /// with the command escaped for the AppleScript string literal.
    static func terminalRunScript(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\n\tactivate\n\tdo script \"\(escaped)\"\nend tell"
    }
}
