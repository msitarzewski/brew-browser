//! Shared DTOs serialized across the Tauri IPC boundary.
//!
//! Every struct uses `#[serde(rename_all = "camelCase")]` so the
//! TypeScript side matches `src/lib/types.ts` exactly.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::BrewError;

// ---------- Common enums ----------

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum PackageKind {
    Formula,
    Cask,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum TrendingWindow {
    #[serde(rename = "30d")]
    D30,
    #[serde(rename = "90d")]
    D90,
    #[serde(rename = "365d")]
    D365,
}

impl TrendingWindow {
    pub fn as_path_segment(self) -> &'static str {
        match self {
            TrendingWindow::D30 => "30d",
            TrendingWindow::D90 => "90d",
            TrendingWindow::D365 => "365d",
        }
    }
}

// ---------- Environment probe ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(Default)]
pub struct BrewEnvironment {
    pub installed: bool,
    pub version: Option<String>,
    pub prefix: Option<String>,
    pub path_used: Option<String>,
}

// ---------- Package list ----------

/// Where the frontend should source an icon for a given package row.
///
/// Phase 7 covered installed casks (`InstalledApp` → `cask_icon` command).
/// Phase 8 adds an uninstalled-cask path that walks a small homepage
/// favicon/og:image cascade (`Homepage` → `cask_icon_from_homepage`).
/// Formulae and anything without a homepage classify as `None`, which
/// the frontend renders with a fallback glyph.
///
/// Tagged with `kind` so the TS side reads as a discriminated union:
///
/// ```ts
/// type IconSource =
///   | { kind: "installedApp" }
///   | { kind: "homepage"; homepage: string }
///   | { kind: "none" };
/// ```
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum IconSource {
    /// Cask is installed; frontend should call `cask_icon(token)` which
    /// extracts the `.app` bundle icon (Phase 7 path).
    InstalledApp,
    /// Cask is not installed but exposes a homepage; frontend should
    /// call `cask_icon_from_homepage(token, homepage)` which runs the
    /// favicon/og-image cascade (Phase 8 path).
    #[serde(rename_all = "camelCase")]
    Homepage { homepage: String },
    /// No icon available — formula, no `.app` artifact, no homepage,
    /// or anything else the frontend should render as a glyph.
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Package {
    pub name: String,
    pub full_name: String,
    pub kind: PackageKind,
    pub installed_version: Option<String>,
    pub stable_version: Option<String>,
    pub description: Option<String>,
    pub homepage: Option<String>,
    pub license: Option<String>,
    pub tap: Option<String>,
    pub outdated: bool,
    pub pinned: bool,
    pub installed_on_request: bool,
    pub installed_as_dependency: bool,
    /// Feature #2 — deprecation / disabled status. The offline baseline
    /// (`deprecated`/`disabled` + reason/date) comes from the bundled
    /// catalog for every package; `brew info` enriches the same fields
    /// AND adds the replacement token (the catalog has no replacement).
    /// `disabled` is the stronger state — when both are true the UI shows
    /// the disabled badge.
    pub deprecated: bool,
    pub disabled: bool,
    pub deprecation_date: Option<String>,
    pub deprecation_reason: Option<String>,
    pub disable_date: Option<String>,
    pub disable_reason: Option<String>,
    /// "Use X instead" token for a deprecated package. Collapsed at parse
    /// time from `deprecation_replacement_formula` / `_cask` (formula
    /// preferred when both are non-null). Only `brew info` carries this —
    /// always `None` on catalog-sourced packages.
    pub deprecation_replacement: Option<String>,
    /// "Use X instead" token for a disabled package. Collapsed from
    /// `disable_replacement_formula` / `_cask`. `brew info` only.
    pub disable_replacement: Option<String>,
    /// Hint to the frontend's icon layer about which command (if any)
    /// should be used to fetch a real icon for this row. See
    /// [`IconSource`] for the variants. Only meaningful for casks;
    /// formulae always emit `IconSource::None`.
    pub icon_source: IconSource,
    /// Canonical `https://github.com/<owner>/<repo>` URL when any of
    /// the package's GitHub-resolvable URL fields parses cleanly via
    /// `github::extract_github_repo`. None when no candidate URL maps
    /// to a GitHub repo.
    ///
    /// **Why distinct from `homepage`:** the upstream `homepage` is
    /// often a marketing/docs site (e.g. nodejs.org, postgresql.org)
    /// even when the package's source / binary lives on GitHub. This
    /// field walks `homepage` → `urls.stable.url` → `urls.head.url`
    /// (formula) or `homepage` → `url` (cask) so the UI's GitHub
    /// features (star/watch/file-issue/stats) light up for packages
    /// whose `homepage` alone wouldn't have qualified.
    ///
    /// Output is always canonicalized to the strict-parseable form
    /// (`https://github.com/<o>/<r>`, no `.git`, no trailing slash, no
    /// query/fragment) so downstream `parse_github_url` accepts it
    /// without re-validation drift.
    pub github_homepage: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageList {
    pub formulae: Vec<Package>,
    pub casks: Vec<Package>,
    pub generated_at: String,
}

// ---------- Package detail ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageOption {
    pub flag: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageDetail {
    pub package: Package,
    pub caveats: Option<String>,
    pub dependencies: Vec<String>,
    pub build_dependencies: Vec<String>,
    pub optional_dependencies: Vec<String>,
    pub conflicts_with: Vec<String>,
    pub requirements: Vec<String>,
    pub options: Vec<PackageOption>,
    pub installed_paths: Vec<String>,
    pub analytics30d_installs: Option<u64>,
    pub raw_json: serde_json::Value,
    pub exists_in_applications: bool,
    pub is_mas: bool,
    /// Feature #4 — total on-disk size of the installed keg in bytes
    /// (`du -sk` on `<prefix>/Cellar/<name>` for formulae,
    /// `<prefix>/Caskroom/<token>` for casks, summing all installed
    /// versions). `None` when the package isn't installed, the keg dir is
    /// absent (e.g. a cask on Linux), or `du` couldn't measure it. Filled
    /// lazily inside `brew_info` — the static parsers leave it `None`.
    pub installed_size_bytes: Option<u64>,
}

// ---------- Outdated ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutdatedPackage {
    pub name: String,
    pub kind: PackageKind,
    pub installed_versions: Vec<String>,
    pub current_version: String,
    pub pinned: bool,
    pub pinned_version: Option<String>,
}

// ---------- Search results ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub name: String,
    pub kind: PackageKind,
    pub installed: bool,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResults {
    pub query: String,
    pub formulae: Vec<SearchHit>,
    pub casks: Vec<SearchHit>,
    pub generated_at: String,
}

// ---------- Streaming events ----------

// `BrewStreamEvent` is backend → frontend only; we don't derive
// `Deserialize` here because `BrewError` (embedded in the `Error`
// variant) is `Serialize`-only.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BrewStreamEvent {
    #[serde(rename_all = "camelCase")]
    Started {
        job_id: Uuid,
        command: String,
        started_at: String,
    },
    #[serde(rename_all = "camelCase")]
    Stdout {
        job_id: Uuid,
        line: String,
        ts: String,
    },
    #[serde(rename_all = "camelCase")]
    Stderr {
        job_id: Uuid,
        line: String,
        ts: String,
    },
    /// Heuristic progress derived from brew's `==>` markers (best-effort).
    /// `total` is `None` until brew announces a count (e.g.
    /// "Upgrading 32 outdated packages:"); the frontend renders a
    /// determinate bar when `total` is known, a spinner otherwise.
    #[serde(rename_all = "camelCase")]
    Progress {
        job_id: Uuid,
        /// "Downloading" | "Fetching" | "Pouring" | "Installing" | "Upgrading".
        phase: String,
        /// Current package name (best-effort; empty when not parseable).
        package: String,
        /// 1-based index of the current unit of work.
        current: u32,
        /// Total units when known.
        total: Option<u32>,
    },
    #[serde(rename_all = "camelCase")]
    Exit {
        job_id: Uuid,
        exit_code: i32,
        success: bool,
        duration_ms: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        friendly_message: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Canceled { job_id: Uuid },
    #[serde(rename_all = "camelCase")]
    Error { job_id: Uuid, error: BrewError },
}

/// Pre-allocated handle shape from `backendApi.md`. Streaming commands
/// currently return `JobResult` directly, but this struct is retained
/// in the wire schema so the frontend can construct a typed handle if
/// the API evolves to return early before exit.
#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamHandle {
    pub job_id: Uuid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobResult {
    pub job_id: Uuid,
    pub exit_code: i32,
    pub success: bool,
    pub duration_ms: u64,
}

// ---------- Brewfile ----------

pub type BrewfileId = String;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileCounts {
    pub taps: usize,
    pub formulae: usize,
    pub casks: usize,
    pub mas_apps: usize,
    pub vscode_extensions: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileSummary {
    pub id: BrewfileId,
    pub label: String,
    pub path: String,
    pub created_at: String,
    pub size_bytes: u64,
    pub counts: BrewfileCounts,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileFormula {
    pub name: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileCask {
    pub name: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileMasApp {
    pub name: String,
    pub id: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileEntries {
    pub taps: Vec<String>,
    pub formulae: Vec<BrewfileFormula>,
    pub casks: Vec<BrewfileCask>,
    pub mas_apps: Vec<BrewfileMasApp>,
    pub vscode_extensions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Brewfile {
    pub summary: BrewfileSummary,
    pub entries: BrewfileEntries,
    pub raw_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrewfileCheckReport {
    pub satisfied: bool,
    pub missing_taps: Vec<String>,
    pub missing_formulae: Vec<String>,
    pub missing_casks: Vec<String>,
    pub missing_mas_apps: Vec<String>,
    pub missing_vscode_extensions: Vec<String>,
}

// ---------- Trending ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingEntry {
    pub rank: u32,
    pub name: String,
    pub kind: PackageKind,
    /// Cumulative installs over the report's window. Includes installs
    /// pulled in as transitive dependencies — `ca-certificates`,
    /// `openssl@3`, and friends dominate by this metric purely because
    /// everything depends on them.
    pub install_count: u64,
    pub install_count_formatted: String,
    /// v0.4.0 — explicit user-initiated installs (excludes dependency
    /// pulls). Fetched from the `install-on-request` analytics endpoint
    /// in parallel with the primary `install` window. `None` only when
    /// the secondary fetch failed — the entry still ships with whatever
    /// the primary endpoint returned so the tab degrades gracefully.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_on_request_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_on_request_count_formatted: Option<String>,
    /// v0.4.0 — derived velocity index from the three rolling windows.
    /// `1.0` ≈ steady, `>1.5` surging, `<0.7` cooling. `None` when the
    /// other two windows aren't yet cached or the package's annual
    /// count is too small for a stable ratio (see
    /// [`crate::trending::velocity::velocity_index`]).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub velocity_index: Option<f64>,
    pub installed_locally: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingReport {
    pub window: TrendingWindow,
    pub fetched_at: String,
    pub cache_age_seconds: u64,
    pub total_count: u64,
    pub entries: Vec<TrendingEntry>,
}

// ---------- v0.4.0: Trending history (opt-in endpoint) ----------

/// v0.4.0 — origin of a single history point. Lets the frontend fade
/// or label the historical-only portion of a sparkline (the three
/// derived "seed" buckets from rolling-window subtraction) distinctly
/// from the real daily snapshots collected from launch day onward.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TrendingHistorySource {
    /// Derived from formulae.brew.sh rolling-window subtraction at
    /// collector bootstrap. Coarser granularity (covers a multi-day
    /// span); useful for showing trajectory before nightly snapshots
    /// began accumulating.
    Seed,
    /// Captured from a nightly snapshot of the rolling-window counts.
    /// Once we have ~30 days of these, adjacent-snapshot subtraction
    /// produces clean per-day install estimates.
    Daily,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingHistoryPoint {
    /// ISO date YYYY-MM-DD of the snapshot (or bucket midpoint for
    /// seed entries).
    pub date: String,
    /// 30-day rolling-window count at this snapshot. Available for
    /// every Daily point and the most-recent Seed bucket.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count_30d: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count_90d: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count_365d: Option<u64>,
    /// Same shape as the above, sourced from the install-on-request
    /// endpoint. Populated only when the collector pulled both
    /// endpoints on this date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count_install_on_request_30d: Option<u64>,
    /// Server-derived per-day install estimate. `None` for seed
    /// points (no daily granularity yet) and for daily points that
    /// don't have a usable predecessor 30 days earlier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_daily_installs: Option<u64>,
    pub source: TrendingHistorySource,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingHistorySeries {
    pub name: String,
    pub kind: PackageKind,
    pub points: Vec<TrendingHistoryPoint>,
    /// ISO timestamp the collector wrote this series. Distinct from
    /// `cache_age_seconds` which measures how long the *frontend cache*
    /// has held the response.
    pub generated_at: String,
    /// Local cache age in seconds. Populated by the IPC layer after
    /// reading from cache, not by the collector.
    #[serde(default)]
    pub cache_age_seconds: u64,
}

/// v0.4.0 — compact summary blob fetched once and consumed by the
/// Trending list view to render inline sparklines + velocity badges
/// without per-row HTTP. Per-package detail views fetch the full
/// `TrendingHistorySeries` separately.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingHistoryIndex {
    pub generated_at: String,
    pub packages: Vec<TrendingHistoryIndexEntry>,
    /// Local cache age in seconds. Populated by the IPC layer.
    #[serde(default)]
    pub cache_age_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendingHistoryIndexEntry {
    pub name: String,
    pub kind: PackageKind,
    /// Server-precomputed velocity index — the same value the client
    /// could compute from the three rolling windows, but baked in here
    /// for consistency with what the trending list shows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub velocity_index: Option<f64>,
    /// Compact per-day series for inline sparklines. Most recent N
    /// data points (~30), enough for a tiny chart. Mix of estimated
    /// daily installs (when available) and rolling-window snapshots
    /// (otherwise); the frontend treats it as opaque chart data.
    pub sparkline: Vec<u64>,
}

// ---------- Bundles (0.7.0 curated recipes) ----------
//
// Mirrors `recipes/recipe.schema.json` and the generated `bundles.json`.
// Every field carries `#[serde(default)]` so the decode is tolerant and
// forward-compatible: a recipe authored against a newer schema (extra
// fields, or omitting an optional one) still parses on an older binary —
// unknown fields are ignored, missing ones fall back to their default.
//
// The TS mirror lives in `src/lib/types.ts`.

/// Host requirements a bundle declares. `BundleReadiness`/`readiness()`
/// (M1, client-side) gates install against the probed `SystemProfile`.
/// Mirrors the TS `BundleRequires` added in M1.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BundleRequires {
    // Explicit renames: camelCase would yield `minRamGb`, but the contract
    // (and the M1 TS type) keep the upper-case "GB".
    #[serde(rename = "minRamGB")]
    pub min_ram_gb: u32,
    #[serde(rename = "recommendedRamGB")]
    pub recommended_ram_gb: u32,
    #[serde(rename = "minDiskGB")]
    pub min_disk_gb: u32,
    /// `"any" | "apple-silicon" | "intel" | "linux"`.
    pub arch: String,
    /// `"none" | "preferred" | "required"`.
    pub gpu: String,
}

impl Default for BundleRequires {
    fn default() -> Self {
        BundleRequires {
            min_ram_gb: 0,
            recommended_ram_gb: 0,
            min_disk_gb: 0,
            arch: "any".to_string(),
            gpu: "none".to_string(),
        }
    }
}

/// One package in a bundle. `kind` is `"formula" | "cask"` as a plain string
/// (not the `PackageKind` enum) so an unexpected value in a live-refreshed
/// recipe degrades gracefully instead of failing the whole decode.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BundlePackage {
    pub name: String,
    pub kind: String,
}

/// A post-install setup step. The relevant fields depend on `kind`
/// (`service`/`open`/`reveal`/`command`/`note`); all are optional so a step
/// only carries what it needs.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SetupStep {
    pub kind: String,
    pub service: Option<String>,
    pub label: Option<String>,
    pub url: Option<String>,
    pub path: Option<String>,
    pub run: Option<String>,
    pub external: Option<bool>,
    pub text: Option<String>,
}

/// An external reference link (docs, homepage, source).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BundleLink {
    pub label: String,
    pub url: String,
}

/// A curated bundle recipe. See `recipes/recipe.schema.json` for the authoring
/// contract; `capability_notes` maps a RAM-tier (integer-as-string key) to a
/// human note the readiness gate surfaces.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Bundle {
    pub id: String,
    pub name: String,
    pub tagline: String,
    /// Longer intent paragraph shown under the tagline in the detail pane.
    /// Optional; distinct from `tagline` (short) and `caveats` (warning).
    pub description: Option<String>,
    pub category: String,
    pub icon: Option<String>,
    pub packages: Vec<BundlePackage>,
    pub tap: Option<String>,
    pub requires: Option<BundleRequires>,
    pub capability_notes: std::collections::HashMap<String, String>,
    pub setup: Vec<SetupStep>,
    pub caveats: Option<String>,
    pub links: Vec<BundleLink>,
    pub maintainer: Option<String>,
    pub added_in: Option<String>,
}

/// Root shape of the bundled/generated `bundles.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BundlesFile {
    pub schema_version: u32,
    pub bundles: Vec<Bundle>,
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_kind_serializes_lowercase() {
        // PackageKind serializes as lowercase strings on the wire, which is
        // what the TS PackageKind = "formula" | "cask" expects.
        assert_eq!(
            serde_json::to_string(&PackageKind::Formula).unwrap(),
            "\"formula\""
        );
        assert_eq!(
            serde_json::to_string(&PackageKind::Cask).unwrap(),
            "\"cask\""
        );
    }

    #[test]
    fn package_kind_deserializes_lowercase() {
        let k: PackageKind = serde_json::from_str("\"formula\"").unwrap();
        assert_eq!(k, PackageKind::Formula);
        let k: PackageKind = serde_json::from_str("\"cask\"").unwrap();
        assert_eq!(k, PackageKind::Cask);
    }

    #[test]
    fn trending_window_serializes_with_d_prefix_renames() {
        // Wire shape uses "30d" / "90d" / "365d" per the TS contract.
        assert_eq!(
            serde_json::to_string(&TrendingWindow::D30).unwrap(),
            "\"30d\""
        );
        assert_eq!(
            serde_json::to_string(&TrendingWindow::D90).unwrap(),
            "\"90d\""
        );
        assert_eq!(
            serde_json::to_string(&TrendingWindow::D365).unwrap(),
            "\"365d\""
        );
    }

    #[test]
    fn trending_window_deserializes_with_d_prefix_renames() {
        let w: TrendingWindow = serde_json::from_str("\"30d\"").unwrap();
        assert_eq!(w, TrendingWindow::D30);
        let w: TrendingWindow = serde_json::from_str("\"90d\"").unwrap();
        assert_eq!(w, TrendingWindow::D90);
        let w: TrendingWindow = serde_json::from_str("\"365d\"").unwrap();
        assert_eq!(w, TrendingWindow::D365);
    }

    #[test]
    fn trending_window_path_segments_match_url_pattern() {
        assert_eq!(TrendingWindow::D30.as_path_segment(), "30d");
        assert_eq!(TrendingWindow::D90.as_path_segment(), "90d");
        assert_eq!(TrendingWindow::D365.as_path_segment(), "365d");
    }

    #[test]
    fn package_serializes_with_camel_case_fields() {
        // Pin every camelCase field name. Frontend `Package` interface depends
        // on these literal keys; renaming serde alters drift across the wire.
        let pkg = Package {
            name: "wget".into(),
            full_name: "homebrew/core/wget".into(),
            kind: PackageKind::Formula,
            installed_version: Some("1.25.0".into()),
            stable_version: Some("1.25.0".into()),
            description: Some("desc".into()),
            homepage: Some("https://example".into()),
            license: Some("GPL-3.0".into()),
            tap: Some("homebrew/core".into()),
            outdated: false,
            pinned: false,
            installed_on_request: true,
            installed_as_dependency: false,
            deprecated: false,
            disabled: false,
            deprecation_date: None,
            deprecation_reason: None,
            disable_date: None,
            disable_reason: None,
            deprecation_replacement: None,
            disable_replacement: None,
            icon_source: IconSource::None,
            github_homepage: None,
        };
        let v = serde_json::to_value(&pkg).unwrap();
        for k in [
            "name",
            "fullName",
            "kind",
            "installedVersion",
            "stableVersion",
            "description",
            "homepage",
            "license",
            "tap",
            "outdated",
            "pinned",
            "installedOnRequest",
            "installedAsDependency",
            "deprecated",
            "disabled",
            "deprecationDate",
            "deprecationReason",
            "disableDate",
            "disableReason",
            "deprecationReplacement",
            "disableReplacement",
            "iconSource",
            "githubHomepage",
        ] {
            assert!(v.get(k).is_some(), "Package must have wire field {:?}", k);
        }
        // Snake-case keys must not leak.
        for snake in [
            "full_name",
            "installed_version",
            "stable_version",
            "installed_on_request",
            "installed_as_dependency",
            "icon_source",
            "github_homepage",
        ] {
            assert!(
                v.get(snake).is_none(),
                "snake key {:?} must not be present",
                snake
            );
        }
    }

    // ---------- IconSource ----------

    #[test]
    fn icon_source_serializes_with_kind_tag() {
        // Each variant must serialize as a tagged object with `kind` discriminator
        // matching the frontend's discriminated-union shape exactly.
        let installed = serde_json::to_value(IconSource::InstalledApp).unwrap();
        assert_eq!(installed["kind"], "installedApp");

        let none = serde_json::to_value(IconSource::None).unwrap();
        assert_eq!(none["kind"], "none");

        let homepage = serde_json::to_value(IconSource::Homepage {
            homepage: "https://example.com/".into(),
        })
        .unwrap();
        assert_eq!(homepage["kind"], "homepage");
        assert_eq!(homepage["homepage"], "https://example.com/");
    }

    #[test]
    fn icon_source_round_trips_through_serde() {
        // The TS side may echo these back for diagnostics. Round-trip
        // ensures the wire shape stays symmetric.
        for variant in [
            IconSource::InstalledApp,
            IconSource::None,
            IconSource::Homepage {
                homepage: "https://example.com".into(),
            },
        ] {
            let s = serde_json::to_string(&variant).unwrap();
            let back: IconSource = serde_json::from_str(&s).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn brew_stream_event_uses_kind_tag_camel_case() {
        use uuid::Uuid;
        let evt = BrewStreamEvent::Exit {
            job_id: Uuid::nil(),
            exit_code: 0,
            success: true,
            duration_ms: 123,
            friendly_message: None,
        };
        let v = serde_json::to_value(&evt).unwrap();
        // Tag discriminator.
        assert_eq!(v["kind"], "exit");
        // camelCase fields.
        assert_eq!(v["jobId"], "00000000-0000-0000-0000-000000000000");
        assert_eq!(v["exitCode"], 0);
        assert_eq!(v["success"], true);
        assert_eq!(v["durationMs"], 123);
        assert!(v.get("friendlyMessage").is_none());
    }

    #[test]
    fn brew_stream_event_started_serializes_camel_case() {
        use uuid::Uuid;
        let evt = BrewStreamEvent::Started {
            job_id: Uuid::nil(),
            command: "brew install wget".into(),
            started_at: "2026-05-23T00:00:00Z".into(),
        };
        let v = serde_json::to_value(&evt).unwrap();
        assert_eq!(v["kind"], "started");
        assert_eq!(v["jobId"], "00000000-0000-0000-0000-000000000000");
        assert_eq!(v["command"], "brew install wget");
        assert_eq!(v["startedAt"], "2026-05-23T00:00:00Z");
    }
}
