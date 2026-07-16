import AppKit
import Foundation

/// "Report to brew-browser" — builds a pre-filled GitHub new-issue URL from a
/// failed Activity job and opens it in the browser. Mirrors the Tauri
/// `src/lib/util/reportIssue.ts` (`openReportIssueFromJob`): same repo, same
/// templated body (app + Homebrew version, command, exit code, stderr excerpt),
/// same `from-app` label.
enum ReportIssue {
    private static let newIssueURL = "https://github.com/msitarzewski/brew-browser/issues/new"

    /// Cap on the stderr excerpt, keeping the URL well under GitHub's ~8 KiB
    /// limit even with the rest of the templated context (matches Tauri).
    private static let stderrMaxChars = 2000

    /// This app's short version string (CFBundleShortVersionString), or "unknown".
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Build the pre-filled new-issue URL for a job. `brewVersion` comes from the
    /// app model (already resolved via `brew --version`).
    static func url(for job: ActivityJob, brewVersion: String) -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[brew-browser] \(job.label)"),
            URLQueryItem(name: "labels", value: "from-app"),
            URLQueryItem(name: "body", value: body(for: job, brewVersion: brewVersion)),
        ]
        return components?.url
    }

    /// Open the pre-filled issue page in the default browser.
    static func open(for job: ActivityJob, brewVersion: String) {
        guard let url = url(for: job, brewVersion: brewVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Enrichment corrections ("Wrong?")

    /// Which enriched field a correction is about — the label appears in the
    /// issue title + body so triage is one glance. Mirrors the fields the Tauri
    /// PackageDetail "Wrong?" affordance covers (AI summary, categories, tags,
    /// use-cases, similar packages).
    enum EnrichmentField: String {
        case summary = "AI summary"
        case categories = "Categories"
        case tags = "Tags"
        case useCases = "Why install this?"
        case similar = "Similar packages"

        /// Bold heading for the field's InfoButton popover (mirrors Tauri).
        var infoTitle: String {
            switch self {
            case .summary:    return L10n.string("About this summary")
            case .categories: return L10n.string("About categories")
            case .tags:       return L10n.string("About tags")
            case .useCases:   return L10n.string("About use cases")
            case .similar:    return L10n.string("About similar packages")
            }
        }

        /// Provenance copy for the InfoButton popover — verbatim from the Tauri
        /// `InfoButton` bodies, with the field-specific tail.
        var infoBody: String {
            switch self {
            case .summary:    return L10n.string("detail.aboutSummary.body")
            case .categories: return L10n.string("detail.aboutCategories.body")
            case .tags:       return L10n.string("detail.aboutTags.body")
            case .useCases:   return L10n.string("detail.aboutUseCases.body")
            case .similar:    return L10n.string("detail.aboutSimilar.body")
            }
        }
    }

    /// Build a pre-filled brew-browser new-issue URL reporting a wrong enriched
    /// field for a package. Same repo + `from-app` label as the job reporter;
    /// the body carries the token, the field, the current (wrong) value, and a
    /// prompt for the correction, plus the app version. Mirrors the Tauri
    /// `IssueModal`/deeplink correction flow.
    static func enrichmentCorrectionURL(token: String, field: EnrichmentField, currentValue: String) -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[enrichment] \(token) — \(field.rawValue) correction"),
            URLQueryItem(name: "labels", value: "from-app,enrichment"),
            URLQueryItem(name: "body", value: enrichmentBody(token: token, field: field, currentValue: currentValue)),
        ]
        return components?.url
    }

    /// Open the pre-filled enrichment-correction issue page in the browser.
    static func openEnrichmentCorrection(token: String, field: EnrichmentField, currentValue: String) {
        guard let url = enrichmentCorrectionURL(token: token, field: field, currentValue: currentValue) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func enrichmentBody(token: String, field: EnrichmentField, currentValue: String) -> String {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "**brew-browser:** \(appVersion)",
            "**Package:** `\(token)`",
            "**Field:** \(field.rawValue)",
            "",
            "**Current value:**",
            "",
            "> " + (trimmed.isEmpty ? "_(empty)_" : trimmed.replacingOccurrences(of: "\n", with: "\n> ")),
            "",
            "---",
            "",
            "_What's wrong, and what should it say instead?_",
        ]
        // Keep the URL comfortably under GitHub's limit even for long values.
        if trimmed.count > stderrMaxChars {
            lines = lines.map { $0.count > stderrMaxChars ? String($0.prefix(stderrMaxChars)) + "…" : $0 }
        }
        return lines.joined(separator: "\n")
    }

    private static func body(for job: ActivityJob, brewVersion: String) -> String {
        var lines: [String] = [
            "**brew-browser:** \(appVersion)",
            "**Homebrew:** \(brewVersion)",
            "**Command:** `\(job.command)`",
        ]
        if let code = job.exitCode {
            lines.append("**Exit code:** \(code)")
        }

        // Prefer the stderr stream; fall back to the full log tail if a failure
        // produced nothing on stderr (some brew errors print to stdout).
        let stderr = job.lines.filter { $0.stream == .stderr }.map(\.text).joined(separator: "\n")
        let excerptSource = stderr.isEmpty
            ? job.lines.map(\.text).joined(separator: "\n")
            : stderr
        let trimmed = excerptSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let capped = trimmed.count > stderrMaxChars
                ? "…(truncated)…\n" + String(trimmed.suffix(stderrMaxChars))
                : trimmed
            lines.append(contentsOf: ["", "**Output excerpt:**", "", "```", capped, "```"])
        }

        lines.append(contentsOf: [
            "",
            "---",
            "",
            "_Replace this line with what you were doing when the error appeared, and what you expected to happen._",
        ])
        return lines.joined(separator: "\n")
    }
}
