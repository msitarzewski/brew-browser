import Foundation

/// Loads the bundled `enrichment.json` (Homebrew token → LLM-derived
/// enrichment record) and exposes a per-package lookup — the same offline
/// data the Tauri app bakes in via `tools/enrich/enrich.py`. Locale overlays
/// such as `enrichment.ru.json` are partial files keyed by the same tokens;
/// they replace user-facing prose and add locale search terms while keeping
/// stable package IDs and English fallbacks. There is no runtime LLM request;
/// everything ships in the bundle.
///
/// Mirrors the `Categories.swift` loading pattern: `Bundle.module` resource
/// URL → `Data` → `JSONSerialization`, decoded defensively so missing or
/// partially-enriched fields (only Tier A, only Tier B) round-trip cleanly.

/// One enrichment record, keyed by Homebrew token. All fields are
/// optional / empty-by-default so the placeholder bundle parses and
/// partially-enriched records survive. Field caps mirror the Rust loader
/// in `src-tauri/src/enrichment/mod.rs`.
struct EnrichmentEntry: Sendable, Hashable {
    /// Display name. `nil` when Tier A hasn't run for this token.
    let friendlyName: String?
    /// 1-2 sentence summary. `nil` when Tier A hasn't run.
    let summary: String?
    /// "Why install this?" bullets (capped at 5). Empty when Tier B hasn't run.
    let useCases: [String]
    /// Related package tokens (capped at 50). Validated to look like package names.
    let similar: [String]
    /// Tech-stack tags (capped at 12). Lowercase, hyphenated, `[a-z0-9-]` only.
    let tags: [String]
    /// Locale-specific search aliases. Not shown as tags.
    let searchTerms: [String]
}

struct EnrichmentCatalog: Sendable {
    /// package token → enrichment record
    private let entries: [String: EnrichmentEntry]

    // MARK: - Security caps (mirror src-tauri/src/enrichment/mod.rs)

    private static let maxFriendlyNameLen = 100
    private static let maxSummaryLen = 1024
    private static let maxUseCaseLen = 200
    private static let maxUseCasesCount = 5
    private static let maxSimilarCount = 50
    private static let maxTagsCount = 12
    private static let maxTagLen = 30
    private static let maxSearchTermLen = 60
    private static let maxSearchTermsCount = 16

    /// Decode the bundled JSON. Returns `nil` if the resource is missing or
    /// malformed (callers then just render no enriched data). Per-field caps
    /// are re-applied here so a swapped bundle can't smuggle oversized fields,
    /// matching the Rust loader's defense-in-depth posture.
    static func loadBundled(locale: String? = nil) -> EnrichmentCatalog? {
        guard let url = Bundle.module.url(forResource: "enrichment", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Missing `entries` object is treated as an empty (placeholder) bundle
        // rather than a hard failure — the file still parsed, there's just
        // nothing enriched yet.
        let rawEntries = (root["entries"] as? [String: Any]) ?? [:]

        var entries: [String: EnrichmentEntry] = [:]
        entries.reserveCapacity(rawEntries.count)
        for (name, value) in rawEntries {
            guard let obj = value as? [String: Any] else { continue }
            entries[name] = parseEntry(obj)
        }
        applyLocaleOverlay(normalizeLocale(locale), to: &entries)
        return EnrichmentCatalog(entries: entries)
    }

    /// The enrichment record for `name`, or `nil` when the token is absent
    /// or every field is empty/`nil` (a record that carries no usable data
    /// is indistinguishable from "no record" for callers).
    func entry(for name: String) -> EnrichmentEntry? {
        guard let entry = entries[name], !entry.isEmpty else { return nil }
        return entry
    }

    /// Build a capped `EnrichmentEntry` from the LIVE endpoint's **camelCase**
    /// JSON (`friendlyName`/`summary`/`useCases`/`similar`/`tags`) — the served
    /// per-token shape from `render_served.py`. Same caps + validators as the
    /// bundled `parseEntry` (which reads the snake_case on-disk shape).
    static func parseLiveEntry(_ obj: [String: Any]) -> EnrichmentEntry {
        let friendlyName = (obj["friendlyName"] as? String).map { truncate($0, maxFriendlyNameLen) }
        let summary = (obj["summary"] as? String).map { truncate($0, maxSummaryLen) }

        let rawUseCases = (obj["useCases"] as? [String]) ?? []
        let useCases = rawUseCases.prefix(maxUseCasesCount).map { truncate($0, maxUseCaseLen) }

        let rawSimilar = (obj["similar"] as? [String]) ?? []
        let similar = Array(rawSimilar.filter(isValidPackageName).prefix(maxSimilarCount))

        let rawTags = (obj["tags"] as? [String]) ?? []
        let tags = Array(rawTags.map { truncate($0, maxTagLen) }.filter(isValidTag).prefix(maxTagsCount))

        return EnrichmentEntry(
            friendlyName: friendlyName,
            summary: summary,
            useCases: Array(useCases),
            similar: similar,
            tags: tags,
            searchTerms: parseSearchTerms(obj)
        )
    }

    // MARK: - Defensive decoding

    /// Build one capped `EnrichmentEntry` from a raw JSON object. Reads the
    /// on-disk snake_case keys (`friendly_name`, `use_cases`); unknown or
    /// wrong-typed fields fall back to `nil`/empty so a malformed record
    /// degrades gracefully instead of poisoning the whole catalog.
    private static func parseEntry(_ obj: [String: Any]) -> EnrichmentEntry {
        let friendlyName = (obj["friendly_name"] as? String)
            .map { truncate($0, maxFriendlyNameLen) }
        let summary = (obj["summary"] as? String)
            .map { truncate($0, maxSummaryLen) }

        // use_cases: cap the count, then each bullet's length.
        let rawUseCases = (obj["use_cases"] as? [String]) ?? []
        let useCases = rawUseCases
            .prefix(maxUseCasesCount)
            .map { truncate($0, maxUseCaseLen) }

        // similar: drop tokens that don't look like package names, then cap.
        let rawSimilar = (obj["similar"] as? [String]) ?? []
        let similar = Array(
            rawSimilar
                .filter(isValidPackageName)
                .prefix(maxSimilarCount)
        )

        // tags: normalise to [a-z0-9-], cap length, drop anything left empty
        // or non-conforming, then cap the count.
        let rawTags = (obj["tags"] as? [String]) ?? []
        let tags = Array(
            rawTags
                .map { truncate($0, maxTagLen) }
                .filter(isValidTag)
                .prefix(maxTagsCount)
        )

        return EnrichmentEntry(
            friendlyName: friendlyName,
            summary: summary,
            useCases: Array(useCases),
            similar: similar,
            tags: tags,
            searchTerms: parseSearchTerms(obj)
        )
    }

    private static func normalizeLocale(_ locale: String?) -> String {
        guard let locale else { return "en" }
        let lc = locale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lc == "ru" || lc.hasPrefix("ru-") || lc.hasPrefix("ru_") ? "ru" : "en"
    }

    private static func applyLocaleOverlay(_ locale: String, to entries: inout [String: EnrichmentEntry]) {
        guard locale == "ru",
              let url = Bundle.module.url(forResource: "enrichment.ru", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              normalizeLocale(root["locale"] as? String) == locale,
              let rawEntries = root["entries"] as? [String: Any]
        else { return }

        for (name, value) in rawEntries {
            guard let obj = value as? [String: Any] else { continue }
            let patch = parseEntry(obj)
            entries[name] = patch.localized(over: entries[name])
        }
    }

    private static func parseSearchTerms(_ obj: [String: Any]) -> [String] {
        let raw = (obj["search_terms"] as? [String]) ?? (obj["searchTerms"] as? [String]) ?? []
        return Array(
            raw
                .prefix(maxSearchTermsCount)
                .map { truncate($0, maxSearchTermLen) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    /// UTF-8/grapheme-safe truncate by character count. Swift `String`
    /// indexing never splits a multibyte scalar, so this can't produce
    /// invalid text the way a raw byte cut could.
    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    /// Rough package-name guard, mirroring the Rust `validate_package_name`
    /// gate used on `similar` tokens: non-empty and free of shell/path
    /// metacharacters or whitespace. Keeps obviously-hallucinated or
    /// injection-shaped tokens out of the UI.
    private static func isValidPackageName(_ token: String) -> Bool {
        guard !token.isEmpty, token.first != "-" else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-/")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Tags must be lowercase ASCII letters, digits, or hyphens — the same
    /// `[a-z0-9-]` rule the Rust loader enforces. Empty strings are rejected.
    private static func isValidTag(_ tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        return tag.unicodeScalars.allSatisfy {
            ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || $0 == "-"
        }
    }
}

extension EnrichmentEntry {
    /// True when the record carries no usable data — used to treat a present
    /// but empty record the same as an absent one.
    var isEmpty: Bool {
        (friendlyName?.isEmpty ?? true)
            && (summary?.isEmpty ?? true)
            && useCases.isEmpty
            && similar.isEmpty
            && tags.isEmpty
            && searchTerms.isEmpty
    }

    func localized(over base: EnrichmentEntry?) -> EnrichmentEntry {
        EnrichmentEntry(
            friendlyName: friendlyName.flatMap { $0.isEmpty ? nil : $0 } ?? base?.friendlyName,
            summary: summary.flatMap { $0.isEmpty ? nil : $0 } ?? base?.summary,
            useCases: useCases.isEmpty ? (base?.useCases ?? []) : useCases,
            // Stable fields stay sourced from the base bundle. Locale overlays
            // may carry prose/search aliases, but never translated package-token
            // suggestions or technical tag labels.
            similar: base?.similar ?? [],
            tags: base?.tags ?? [],
            searchTerms: searchTerms.isEmpty ? (base?.searchTerms ?? []) : searchTerms
        )
    }
}
