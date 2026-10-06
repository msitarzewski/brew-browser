import Foundation

/// Native port of the Tauri `local_search` (`src-tauri/src/commands/search.rs`):
/// an in-memory, field-weighted union scan across a package's name + AI friendly
/// name + category labels + AI summary + upstream desc + enrichment tags.
///
/// Parity contract (both shells must rank identically):
///   - Multi-term queries are AND'd — every term must match at least one field.
///   - Per-term score = the single highest field weight that term matched.
///   - Total score = sum of per-term scores.
///   - Results sort by score desc, then token asc within ties.
///   - Combined results cap at `topN`, split fairly between formulae and casks,
///     spilling unused capacity to whichever side has more.
///
/// Everything here is pure + `Sendable` so it can run off the main actor and be
/// unit-tested without the model (mirrors the Rust weights + ordering exactly).
enum LocalSearch {
    /// Field-match weights — identical to the Rust `weight` module so the two
    /// shells produce the same ranking. Higher = more authoritative match.
    enum Weight {
        static let nameExact = 1000
        static let nameStartsWith = 700
        static let nameSubstring = 500
        static let friendlyName = 350
        static let categoryLabel = 280
        static let summary = 180
        static let desc = 120
        static let tag = 100
    }

    /// Combined formula+cask result cap (mirrors Rust `LOCAL_SEARCH_TOP_N`).
    static let topN = 200

    /// Minimum query length before a search runs (mirrors the Tauri store's
    /// `q.length < 2` gate). Below this the caller shows the idle browse view.
    static let minQueryLength = 2

    /// Parse a raw query into normalized terms: whitespace-split, lowercased,
    /// sorted, de-duped, empties dropped. Mirrors the Rust term parsing.
    static func terms(from query: String) -> [String] {
        let split = query.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        var seen = Set<String>()
        return split.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    /// Score one package's fields against the parsed terms. Returns `nil` when
    /// any term matches no field (AND semantics). Mirrors Rust `score_pkg`.
    /// `desc` empty/`nil` is treated as "no description".
    static func score(
        name: String,
        desc: String?,
        friendlyName: String?,
        summary: String?,
        tags: [String],
        labels: [String],
        terms: [String]
    ) -> Int? {
        guard !terms.isEmpty else { return nil }

        let nameLC = name.lowercased()
        let friendlyLC = friendlyName?.lowercased()
        let summaryLC = summary?.lowercased()
        let descLC = (desc?.isEmpty == false) ? desc?.lowercased() : nil
        let labelsLC = labels.map { $0.lowercased() }
        let tagsLC = tags.map { $0.lowercased() }

        var total = 0
        for term in terms {
            var best = 0
            // Name — exact > starts-with > substring (mutually exclusive).
            if nameLC == term {
                best = max(best, Weight.nameExact)
            } else if nameLC.hasPrefix(term) {
                best = max(best, Weight.nameStartsWith)
            } else if nameLC.contains(term) {
                best = max(best, Weight.nameSubstring)
            }
            if let f = friendlyLC, f.contains(term) { best = max(best, Weight.friendlyName) }
            if labelsLC.contains(where: { $0.contains(term) }) { best = max(best, Weight.categoryLabel) }
            if let s = summaryLC, s.contains(term) { best = max(best, Weight.summary) }
            if let d = descLC, d.contains(term) { best = max(best, Weight.desc) }
            if tagsLC.contains(where: { $0.contains(term) }) { best = max(best, Weight.tag) }

            if best == 0 { return nil } // term matched nothing → reject package
            total += best
        }
        return total
    }

    /// Apply the combined cap across two pre-sorted lists, taking up to half from
    /// each and spilling unused capacity to the longer side — the total never
    /// exceeds `topN`. This is the *corrected* form of the Rust `local_search`
    /// split, whose spill double-counts and can return up to ~1.5× `topN`
    /// (harmless there — the web list virtualizes — but worth fixing upstream for
    /// exact parity).
    static func fairSplit<T>(formulae: [T], casks: [T], topN: Int = LocalSearch.topN) -> (formulae: [T], casks: [T]) {
        let fCap = topN / 2
        let cCap = topN - fCap
        var fTake = min(formulae.count, fCap)
        var cTake = min(casks.count, cCap)
        let remaining = topN - fTake - cTake
        if remaining > 0 {
            let fSpill = min(remaining, formulae.count - fTake)
            fTake += fSpill
            cTake += min(remaining - fSpill, casks.count - cTake)
        }
        return (Array(formulae.prefix(fTake)), Array(casks.prefix(cTake)))
    }
}
