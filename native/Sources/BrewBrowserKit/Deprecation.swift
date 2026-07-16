import Foundation

/// A package's deprecation / disabled status, derived from the SAME two sources
/// as the Tauri shell with the SAME precedence (parity charter, feature #2):
///
///   1. Baseline (offline, every package, installed or not) = bundled catalog
///      flags: `deprecated`, `disabled`, plus the `reason`/`date` strings the
///      catalog carries. Available for every Library/Discover row.
///   2. Enriched (detail panel only, from `brew info --json=v2`) = adds the
///      `replacement` token ("use X instead"). The catalog never carries a
///      replacement, so ROW badges are flags-only on both shells; only the
///      DETAIL panel shows the replacement.
///
/// Precedence: `disabled` is STRONGER than `deprecated` — when both are true the
/// badge reads "Disabled" (danger). `deprecated`-only reads "Deprecated"
/// (warning). Neither set → no badge, no notice (never a placeholder).
///
/// Mirrors the Tauri `Package` deprecation fields (`src/lib/types.ts`) +
/// `CatalogEntrySummary` flags. Reason/date strings are rendered verbatim and
/// never synthesized.
struct DeprecationStatus: Hashable, Sendable {
    var deprecated: Bool = false
    var disabled: Bool = false
    /// Catalog/brew-info `deprecation_reason` (plain text), or nil.
    var deprecationReason: String? = nil
    /// Catalog/brew-info `disable_reason` (plain text), or nil.
    var disableReason: String? = nil
    /// `deprecation_date` — a plain date string (e.g. "2024-01"), rendered as-is.
    var deprecationDate: String? = nil
    /// `disable_date` — a plain date string, rendered as-is.
    var disableDate: String? = nil
    /// Replacement token ("use X instead"). ONLY from `brew info` — the catalog
    /// never supplies it, so this is nil for catalog-sourced rows. Collapsed from
    /// the formula/cask replacement variants at parse time (formula wins).
    var deprecationReplacement: String? = nil
    /// Replacement token for a DISABLED package (brew info only), same rules.
    var disableReplacement: String? = nil

    /// No badge / notice when neither flag is set.
    var isClean: Bool { !deprecated && !disabled }

    /// The badge to show, applying the disabled-wins-over-deprecated precedence.
    /// nil when clean (renders nothing).
    var badge: DeprecationBadgeKind? {
        if disabled { return .disabled }
        if deprecated { return .deprecated }
        return nil
    }

    /// The reason string for the active badge (disabled wins), or nil. Used by
    /// the detail notice; rendered verbatim.
    var activeReason: String? {
        disabled ? disableReason : deprecationReason
    }

    /// The date string for the active badge (disabled wins), or nil.
    var activeDate: String? {
        disabled ? disableDate : deprecationDate
    }

    /// The replacement token for the active badge (disabled wins), or nil. Only
    /// non-nil when sourced from `brew info`.
    var activeReplacement: String? {
        disabled ? disableReplacement : deprecationReplacement
    }
}

/// Which badge a row/detail shows. `disabled` is the stronger, danger-toned
/// state; `deprecated` is the softer, warning-toned state.
enum DeprecationBadgeKind: String, Sendable {
    case deprecated
    case disabled

    /// Short label for the row badge + detail notice header.
    var label: String {
        return self == .disabled ? "Disabled" : "Deprecated"
    }
}

/// Collapse the formula/cask replacement variants into one token: prefer the
/// formula replacement, fall back to the cask replacement, else nil. Both
/// non-null is impossible in practice, but the rule is deterministic (formula
/// first) to match the Tauri parse-time collapse. Free function so the parsers
/// and the unit tests share the exact same logic.
func collapseReplacement(formula: String?, cask: String?) -> String? {
    if let f = formula, !f.isEmpty { return f }
    if let c = cask, !c.isEmpty { return c }
    return nil
}

/// Parse a deprecation status from a decoded JSON object dict — works for both a
/// bundled-catalog entry and a `brew info --json=v2` formula/cask entry (both
/// use the same upstream key names). `includeReplacement` is true only for the
/// brew-info path, where the replacement tokens are honored; the catalog path
/// passes false so ROW badges stay flags-only (parity contract).
func parseDeprecationStatus(_ o: [String: Any], includeReplacement: Bool) -> DeprecationStatus {
    var s = DeprecationStatus()
    s.deprecated = o["deprecated"] as? Bool ?? false
    s.disabled = o["disabled"] as? Bool ?? false
    s.deprecationReason = o["deprecation_reason"] as? String
    s.disableReason = o["disable_reason"] as? String
    s.deprecationDate = o["deprecation_date"] as? String
    s.disableDate = o["disable_date"] as? String
    if includeReplacement {
        s.deprecationReplacement = collapseReplacement(
            formula: o["deprecation_replacement_formula"] as? String,
            cask: o["deprecation_replacement_cask"] as? String
        )
        s.disableReplacement = collapseReplacement(
            formula: o["disable_replacement_formula"] as? String,
            cask: o["disable_replacement_cask"] as? String
        )
    }
    return s
}
