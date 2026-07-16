import Foundation

/// Parsing of brew's textual output — friendly error mapping + non-fatal
/// upgrade classification + live progress. This is a Swift port of the Tauri
/// `src-tauri/src/brew/error_patterns.rs` and the `ProgressParser` in
/// `src-tauri/src/brew/exec.rs`. The two builds parse the SAME brew output, so
/// the rules here must stay in lockstep with the Rust side (parity charter —
/// `memory-bank/decisions.md` 2026-06-01). Canonical tests live on the Rust
/// side (`error_patterns.rs`, `exec.rs`); there is no native test target.
enum BrewErrorPatterns {
    /// Friendly one-sentence message for a known upstream-brew pattern, or nil.
    /// Mirrors `error_patterns::friendlify`.
    static func friendlify(stderr: String, command: String) -> String? {
        let isBundle = command.contains("bundle dump") || command.contains("bundle install")

        // Pattern 1 — `brew bundle` topo-sort key-not-found (upstream Ruby bug).
        if isBundle,
           stderr.contains("key not found:"),
           stderr.contains("Homebrew::Bundle::Brew::Topo") {
            if L10n.isRussian {
                return "В `brew bundle` сработала внутренняя ошибка topo-sort для одной из установленных формул. Это ошибка Homebrew, а не brew-browser. Попробуйте `brew untap` для недавно добавленного tap или посмотрите полный вывод в Активности."
            }
            return "Homebrew's `brew bundle` hit an internal topo-sort error on one "
                + "of your installed formulae. This is an upstream Homebrew bug, not "
                + "a brew-browser issue. Try `brew untap` on a recently-added tap, or "
                + "see the full output in Activity."
        }

        // Pattern 2 — Homebrew explicitly asks the user to report upstream.
        if stderr.contains("Please report this issue:"),
           stderr.contains("docs.brew.sh/Troubleshooting") {
            if L10n.isRussian {
                return "Homebrew сообщил о внутренней ошибке и попросил отправить отчёт upstream. Посмотрите полный вывод в Активности и откройте https://docs.brew.sh/Troubleshooting для дальнейших шагов."
            }
            return "Homebrew reported an internal error and asked you to report it "
                + "upstream. See the full output in Activity, and visit "
                + "https://docs.brew.sh/Troubleshooting for next steps."
        }

        // Pattern 3 — `brew services` failed: plist in a launchd domain the
        // current session doesn't own (ports PR #51).
        if command.contains("services"),
           stderr.contains("Could not find service") || stderr.contains("not found in domain") {
            if L10n.isRussian {
                return "brew не нашёл эту службу в текущем домене launchd. Скорее всего, plist зарегистрирован для другого пользователя или сеанса. Попробуйте `brew services restart` или перенесите plist в ~/Library/LaunchAgents и выполните `launchctl bootstrap gui/$UID`."
            }
            return "brew could not find this service in the current launchd domain. "
                + "The plist is likely registered for a different user or session. "
                + "Try `brew services restart`, or move the plist to "
                + "~/Library/LaunchAgents and run `launchctl bootstrap gui/$UID`."
        }

        // Pattern 4 — another brew process holds the lock (environmental).
        if stderr.contains("has already locked")
            || stderr.contains("Please wait for it to finish or terminate it") {
            if L10n.isRussian {
                return "Другой процесс Homebrew уже выполняется и удерживает lock. Дождитесь его завершения или закройте другой процесс, затем повторите попытку — это не проблема brew-browser."
            }
            return "Another Homebrew process is already running and holds the lock. "
                + "Wait for it to finish (or quit the other process) and try again — "
                + "this isn't a brew-browser problem."
        }

        // Pattern 5 — a cask installer/remover invoked sudo, but brew-browser
        // has no interactive terminal for the admin password prompt.
        if sudoPasswordPromptRequired(stderr) {
            if let token = sudoCaskToken(stderr: stderr, command: command) {
                if L10n.isRussian {
                    return "Cask-пакету `\(token)` нужен пароль администратора, но brew-browser запускает brew без интерактивного терминала, поэтому sudo не может запросить пароль здесь. Выполните в Терминале: `brew upgrade --cask \(token)`, затем обновите brew-browser."
                }
                return "The cask `\(token)` needs an administrator password, but "
                    + "brew-browser runs brew without an interactive terminal so sudo "
                    + "cannot prompt here. Run this in Terminal: "
                    + "`brew upgrade --cask \(token)`, then refresh brew-browser."
            }
            if L10n.isRussian {
                return "Этому Homebrew cask нужен пароль администратора, но brew-browser запускает brew без интерактивного терминала, поэтому sudo не может запросить пароль здесь. Выполните обновление cask-пакета в Терминале, затем обновите brew-browser."
            }
            return "This Homebrew cask needs an administrator password, but "
                + "brew-browser runs brew without an interactive terminal so sudo "
                + "cannot prompt here. Run the cask upgrade in Terminal, then "
                + "refresh brew-browser."
        }

        return nil
    }

    private static func sudoPasswordPromptRequired(_ stderr: String) -> Bool {
        stderr.contains("sudo: a terminal is required to read the password")
            || stderr.contains("sudo: a password is required")
            || stderr.contains("sudo: no tty present and no askpass program specified")
    }

    private static func sudoCaskToken(stderr: String, command: String) -> String? {
        tokenFromBrewError(stderr) ?? tokenFromCommand(command)
    }

    private static func tokenFromBrewError(_ stderr: String) -> String? {
        for line in stderr.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Error: ") else { continue }
            let rest = trimmed.dropFirst("Error: ".count)
            guard let token = rest.split(separator: ":", maxSplits: 1).first.map(String.init),
                  validCaskToken(token) else { continue }
            return token
        }
        return nil
    }

    private static func tokenFromCommand(_ command: String) -> String? {
        var sawAction = false
        for part in command.split(separator: " ").map(String.init) {
            if !sawAction {
                sawAction = part == "upgrade" || part == "install" || part == "reinstall"
                continue
            }
            if part.hasPrefix("-") { continue }
            return validCaskToken(part) ? part : nil
        }
        return nil
    }

    private static func validCaskToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || "._-+@".unicodeScalars.contains(scalar)
        }
    }

    /// True when a non-zero `brew upgrade`/`install` exit carries ONLY non-fatal
    /// warnings (post-install warnings, link conflicts, already-linked kegs,
    /// already-present binaries). brew escalates these to exit code 1 even
    /// though the work completed — the dominant source of bogus "Upgrade-all
    /// failed" reports. Mirrors `error_patterns::upgrade_warnings_only`.
    static func upgradeWarningsOnly(stderr: String, command: String) -> Bool {
        guard command.contains("upgrade") || command.contains("install") else {
            return false
        }

        // Hard-fatal signatures — a real failure regardless of warnings.
        let fatal = [
            "No available formula",
            "No such file or directory",
            "Permission denied",
            "Failed to download",
            "Download failed",
            "Could not resolve host",
            "has already locked",          // concurrent lock — env. failure
            "sudo: a terminal is required to read the password",
            "sudo: a password is required",
            "sudo: no tty present and no askpass program specified",
            "Please report this issue:",
            "Homebrew::Bundle::Brew::Topo",
            "checksum does not match",
            "SHA256 mismatch",
        ]
        if fatal.contains(where: { stderr.contains($0) }) { return false }

        // Known non-fatal warning markers (the `brew link` "Error:" line is a
        // single-keg link conflict, not a failed upgrade).
        let nonFatal = [
            "post-install step did not complete successfully",
            "not linked because",
            "already linked",
            "skipping link",
            "already a Binary at",
            "`brew link` step did not complete successfully",
        ]
        return nonFatal.contains(where: { stderr.contains($0) })
    }

    /// True when `command` is a `brew doctor` invocation. brew doctor exits 1 on
    /// advisories — diagnostics to read, not a job failure. The Activity layer
    /// treats a non-zero doctor exit as effective-success so the advisory output
    /// shows in the log instead of a "doctor failed" notice. Issue #80; mirrors
    /// `error_patterns::doctor_advisory_exit`.
    static func doctorAdvisoryExit(command: String) -> Bool {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true)
        return parts.count >= 2 && parts[0] == "brew" && parts[1] == "doctor"
    }

    /// Parse the byte estimate out of `brew cleanup -n --prune=all` output. brew
    /// prints `==> This operation would free approximately 1.2GB of disk space.`
    /// Returns nil when no figure is present (nothing to clean / unparsable).
    /// Issue #80; mirrors `disk_usage::parse_reclaimable`.
    static func parseReclaimableBytes(_ output: String) -> Int64? {
        let marker = "would free approximately"
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: marker) else { continue }
            let after = line[range.upperBound...]
            guard let token = after.split(separator: " ", omittingEmptySubsequences: true).first else { continue }
            if let bytes = parseSizeToken(String(token)) { return bytes }
        }
        return nil
    }

    /// Parse a Homebrew size token (`1.2GB`, `500MB`, `1.5KB`, `900B`) into
    /// bytes. brew's readable sizes are 1024-based despite KB/MB/GB labels.
    /// nil on any shape we don't recognize. Mirrors `disk_usage::parse_size_token`.
    static func parseSizeToken(_ raw: String) -> Int64? {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,").union(.whitespaces))
        guard let splitIdx = token.firstIndex(where: { $0.isLetter }) else { return nil }
        let numPart = String(token[token.startIndex..<splitIdx])
        let unit = token[splitIdx...].uppercased()
        guard let value = Double(numPart), value >= 0 else { return nil }
        let mult: Double
        switch unit {
        case "B": mult = 1
        case "KB", "K", "KIB": mult = 1024
        case "MB", "M", "MIB": mult = 1024 * 1024
        case "GB", "G", "GIB": mult = 1024 * 1024 * 1024
        case "TB", "T", "TIB": mult = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * mult)
    }
}

/// Best-effort progress tracker over brew's stdout `==>` markers. Stateful:
/// learns the total from "Upgrading N outdated packages:" /
/// "Installing dependencies for X: a, b, c", and advances a per-package counter
/// as work markers (Pouring / Installing / Upgrading) name new packages.
/// Heuristic — unrecognized output yields nil, so the stream is never affected.
/// Port of the Rust `ProgressParser` (`exec.rs`).
struct BrewProgressParser {
    private var total: Int?
    private var current: Int = 0
    private var lastPackage: String?

    /// `Pouring foo--1.2.arm64.bottle.tar.gz` → `foo`; `Installing foo` → `foo`.
    private static func pkgName(_ rest: String) -> String {
        let first = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        if let range = first.range(of: "--") {
            return String(first[first.startIndex..<range.lowerBound])
        }
        return first
    }

    mutating func observe(_ line: String) -> JobProgress? {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        guard t.hasPrefix("==> ") else { return nil }
        let rest = String(t.dropFirst(4))

        // Total from the upgrade header.
        if rest.hasPrefix("Upgrading ") {
            let r = String(rest.dropFirst("Upgrading ".count))
            if r.contains("outdated package") {
                if let first = r.split(separator: " ").first, let n = Int(first) {
                    total = n
                }
                return nil
            }
            // else "Upgrading <pkg>" — fall through to work markers.
        }

        // Total from a dependency list.
        if rest.hasPrefix("Installing dependencies for ") {
            if let colon = rest.firstIndex(of: ":") {
                let list = rest[rest.index(after: colon)...]
                let n = list.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                if n > 0 {
                    total = max(total ?? 0, n + 1)  // +1 for the target itself
                }
            }
            return nil
        }

        // Per-package work markers — advance the counter on a new package.
        for kw in ["Pouring ", "Installing ", "Upgrading "] {
            if rest.hasPrefix(kw) {
                let pkg = Self.pkgName(String(rest.dropFirst(kw.count)))
                if pkg.isEmpty { continue }
                if lastPackage != pkg {
                    current += 1
                    lastPackage = pkg
                }
                return JobProgress(phase: String(kw.dropLast()), package: pkg,
                                   current: current, total: total)
            }
        }

        // Phase-only markers — update the phase without advancing the counter.
        for kw in ["Downloading ", "Fetching "] {
            if rest.hasPrefix(kw) {
                let pkg = kw.hasPrefix("Fetching")
                    ? Self.pkgName(String(rest.dropFirst(kw.count)))
                    : (lastPackage ?? "")
                return JobProgress(phase: String(kw.dropLast()), package: pkg,
                                   current: current, total: total)
            }
        }

        return nil
    }
}
