/**
 * TypeScript equivalents of all Rust DTOs from `memory-bank/backendApi.md`.
 *
 * Camel-case JSON shape on the wire — these types match exactly what
 * `invoke()` returns for each Tauri command.
 */

import { keyringNameCapitalized } from "$lib/util/platform";

// =========================================================
// 2.1 Common enums
// =========================================================

export type PackageKind = "formula" | "cask";
export type TrendingWindow = "30d" | "90d" | "365d";

/**
 * Where a package's icon can be sourced from.
 *
 * Phase 8 — discriminated union the backend stamps on every `Package` so the
 * frontend can route to the right extractor without knowing implementation
 * details. Lets installed casks use the local `.app` bundle (fast, exact) and
 * uninstalled casks fall back to a homepage favicon (slower, best-effort).
 *
 * - `installedApp`: the cask has an `.app` in `/Applications` or `~/Applications`
 *   — use `cask_icon` to pull from the bundle.
 * - `homepage`: no installed app bundle but the cask has a homepage URL — use
 *   `cask_icon_from_homepage` to fetch a favicon for that origin.
 * - `none`: no icon source available (formulae always; casks without an app
 *   artifact AND without a homepage).
 */
export type IconSource =
  | { kind: "installedApp" }
  | { kind: "homepage"; homepage: string }
  | { kind: "none" };

// =========================================================
// 2.2 Environment probe
// =========================================================

export interface BrewEnvironment {
  installed: boolean;
  version: string | null;
  prefix: string | null;
  pathUsed: string | null;
}

/**
 * Snapshot from `system_status` / `brew_redetect` that drives the
 * missing-Homebrew onboarding gate. `cltFound` is the Xcode Command Line
 * Tools probe (`xcode-select -p`); always `true` on non-macOS builds.
 */
export interface SystemStatus {
  brewFound: boolean;
  brewPath: string | null;
  cltFound: boolean;
}

// =========================================================
// 2.3 Package list (Phase 1)
// =========================================================

export interface Package {
  name: string;
  fullName: string;
  kind: PackageKind;
  installedVersion: string | null;
  stableVersion: string | null;
  description: string | null;
  homepage: string | null;
  license: string | null;
  tap: string | null;
  outdated: boolean;
  pinned: boolean;
  installedOnRequest: boolean;
  installedAsDependency: boolean;
  /**
   * Feature #2 — deprecation / disabled status. The flags + reason/date
   * are the offline baseline (also on the bundled catalog, via
   * {@link CatalogEntrySummary}); `brew info` additionally fills the
   * replacement tokens below. `disabled` is the stronger state — when
   * both are true the UI shows the disabled (danger) badge.
   */
  deprecated: boolean;
  disabled: boolean;
  deprecationDate: string | null;
  deprecationReason: string | null;
  disableDate: string | null;
  disableReason: string | null;
  /** "Use X instead" token for a deprecated package. Collapsed from
   *  the upstream formula/cask replacement variants (formula preferred).
   *  Only `brew info` carries this — always null on catalog-sourced rows. */
  deprecationReplacement: string | null;
  /** "Use X instead" token for a disabled package. `brew info` only. */
  disableReplacement: string | null;
  iconSource: IconSource;
  /**
   * Canonical `https://github.com/<owner>/<repo>` URL when ANY of the
   * package's GitHub-resolvable URL fields parses cleanly via the
   * backend's `extract_github_repo` (the tolerant variant). Null when
   * no candidate URL maps to a GitHub repo.
   *
   * Backend walks `homepage` → `urls.stable.url` → `urls.head.url`
   * (formula) or `homepage` → `url` (cask), so packages whose `homepage`
   * is a marketing site but whose source/binary lives on GitHub still
   * surface a canonical homepage here.
   *
   * Use this (not `homepage`) for GitHub feature routing — star, watch,
   * file-issue, repo-stats. Use `homepage` for display + "Open homepage"
   * link.
   */
  githubHomepage: string | null;
}

export interface PackageList {
  formulae: Package[];
  casks: Package[];
  generatedAt: string;
}

// =========================================================
// 2.4 Package detail (Phase 1)
// =========================================================

export interface PackageOption {
  flag: string;
  description: string;
}

export interface PackageDetail {
  package: Package;
  caveats: string | null;
  dependencies: string[];
  buildDependencies: string[];
  optionalDependencies: string[];
  conflictsWith: string[];
  requirements: string[];
  options: PackageOption[];
  installedPaths: string[];
  analytics30dInstalls: number | null;
  rawJson: unknown;
  existsInApplications: boolean;
  isMas: boolean;
  /**
   * Feature #4 — total on-disk size of the installed keg in bytes
   * (`du -sk` on `<prefix>/Cellar/<name>` for formulae,
   * `<prefix>/Caskroom/<token>` for casks, summing all installed
   * versions). Null when the package isn't installed, the keg dir is
   * absent (e.g. a cask on Linux), or `du` couldn't measure it.
   * Computed lazily inside `brew_info` (travels on this DTO — no second
   * IPC round-trip). Null → the detail "Size" row is not rendered.
   */
  installedSizeBytes: number | null;
}

// =========================================================
// 2.5 Outdated (Phase 1 / 3)
// =========================================================

export interface OutdatedPackage {
  name: string;
  kind: PackageKind;
  installedVersions: string[];
  currentVersion: string;
  pinned: boolean;
  pinnedVersion: string | null;
}

// =========================================================
// 2.6 Search results (Phase 2)
// =========================================================

export interface SearchHit {
  name: string;
  kind: PackageKind;
  installed: boolean;
  description: string | null;
}

export interface SearchResults {
  query: string;
  formulae: SearchHit[];
  casks: SearchHit[];
  generatedAt: string;
}

// =========================================================
// 2.7 Streaming events (Phase 3 & 4)
// =========================================================

export type BrewStreamEvent =
  | { kind: "started";  jobId: string; command: string; startedAt: string }
  | { kind: "stdout";   jobId: string; line: string; ts: string }
  | { kind: "stderr";   jobId: string; line: string; ts: string }
  | { kind: "progress"; jobId: string; phase: string; package: string; current: number; total: number | null }
  | { kind: "exit";     jobId: string; exitCode: number; success: boolean; durationMs: number; friendlyMessage?: string }
  | { kind: "canceled"; jobId: string }
  | { kind: "error";    jobId: string; error: BrewErrorPayload };

export interface JobResult {
  jobId: string;
  exitCode: number;
  success: boolean;
  durationMs: number;
}

export interface StreamHandle {
  jobId: string;
}

// =========================================================
// 2.8 Brewfile (Phase 4)
// =========================================================

export type BrewfileId = string;

export interface BrewfileCounts {
  taps: number;
  formulae: number;
  casks: number;
  masApps: number;
  vscodeExtensions: number;
}

export interface BrewfileSummary {
  id: BrewfileId;
  label: string;
  path: string;
  createdAt: string;
  sizeBytes: number;
  counts: BrewfileCounts;
}

export interface BrewfileFormula { name: string; args: string[] }
export interface BrewfileCask    { name: string; args: string[] }
export interface BrewfileMasApp  { name: string; id: number }

export interface BrewfileEntries {
  taps: string[];
  formulae: BrewfileFormula[];
  casks: BrewfileCask[];
  masApps: BrewfileMasApp[];
  vscodeExtensions: string[];
}

export interface Brewfile {
  summary: BrewfileSummary;
  entries: BrewfileEntries;
  rawText: string;
}

export interface BrewfileCheckReport {
  satisfied: boolean;
  missingTaps: string[];
  missingFormulae: string[];
  missingCasks: string[];
  missingMasApps: string[];
  missingVscodeExtensions: string[];
}

// =========================================================
// 2.9.0 Catalog (Phase 12a)
// =========================================================

/**
 * Lightweight summary of the active catalog. Returned by
 * `catalog_summary` and `catalog_refresh`. Used by the Dashboard
 * catalog line + Discover stale-catalog banner.
 *
 * Wire shape matches the Rust `CatalogSummary` struct (camelCase).
 */
export interface CatalogSummary {
  /** ISO 8601 UTC timestamp of the catalog's `as_of` field. */
  asOf: string;
  /** Which copy of the catalog is currently active. */
  source: "bundled" | "user-refreshed";
  formulaCount: number;
  caskCount: number;
  /** Days between `asOf` and now (UTC). Clamped to 0 on clock skew. */
  daysOld: number;
}

/**
 * Light per-entry record returned by `catalog_formulae_summary` and
 * `catalog_casks_summary`. Used for fast list views that only need
 * name + desc + flags.
 */
export interface CatalogEntrySummary {
  name: string;
  desc: string | null;
  /** "Stable" version — what `brew install <name>` would pull right
   *  now. From `Formula.versions_stable` (formulae) or `Cask.version`
   *  (casks). Null for entries that genuinely have no stable value
   *  (head-only formulae, version-less vintage casks). */
  version: string | null;
  deprecated: boolean;
  disabled: boolean;
  /** Feature #2 — catalog deprecation/disable reason (offline baseline).
   *  Powers a status tooltip on list/Discover rows without a per-token
   *  `brew info` lookup. The catalog never carries a replacement token —
   *  that's `brew info`-only (see {@link Package.deprecationReplacement}). */
  deprecationReason: string | null;
  disableReason: string | null;
}

/**
 * One reverse-dependent of a queried package — a catalog entry that
 * declares the queried token in one of its dependency arrays (or, for a
 * cask, in `depends_on.formula`). Returned inside {@link ReverseDependents}
 * by `catalog_reverse_dependents`. Wire shape mirrors the Rust
 * `ReverseDependent` struct (camelCase).
 */
export interface ReverseDependent {
  /** Name (formula) or token (cask) of the dependent. */
  name: string;
  /** Whether the dependent is a formula or a cask. Cask dependents only
   *  ever appear on macOS — the backend folds them in under
   *  `cfg!(target_os = "macos")`. */
  kind: "formula" | "cask";
  /** How the dependent declares the edge. Cask edges are always
   *  "required". */
  edge: "required" | "build" | "recommended" | "optional";
}

/**
 * Reverse-dependents payload for one queried token. Returned by
 * `catalog_reverse_dependents`. `dependents` is deduped by (name, kind)
 * keeping the strongest edge, sorted ascending by name; empty when
 * nothing in the catalog depends on the queried token.
 */
export interface ReverseDependents {
  /** The queried token, echoed back. */
  name: string;
  dependents: ReverseDependent[];
}

/**
 * Full formula record from the bundled / user-refreshed catalog.
 * Mirrors the Rust `Formula` struct in `src-tauri/src/catalog/mod.rs`.
 * Nullable fields are skipped on the wire when `None` (per
 * `skip_serializing_if = "Option::is_none"`), so consumers must accept
 * `undefined` in addition to `null` and treat both as "not set".
 */
export interface Formula {
  name: string;
  fullName: string;
  desc: string | null;
  homepage: string | null;
  /** Flattened to a single SPDX string by the backend deserializer. */
  license: string | null;
  deprecated: boolean;
  deprecationDate: string | null;
  deprecationReason: string | null;
  disabled: boolean;
  disableDate: string | null;
  disableReason: string | null;
  dependencies: string[];
  recommendedDependencies: string[];
  optionalDependencies: string[];
  conflictsWith: string[];
  /** Just the `stable` version string from upstream `versions: {...}`. */
  versionsStable: string | null;
  tap: string;
  aliases: string[];
}

/**
 * Full cask record from the bundled / user-refreshed catalog. Mirrors
 * the Rust `Cask` struct.
 */
export interface Cask {
  token: string;
  /** Pretty display name(s). Casks routinely have multiple; the first
      is the canonical one. */
  name: string[];
  desc: string | null;
  homepage: string | null;
  deprecated: boolean;
  deprecationDate: string | null;
  deprecationReason: string | null;
  disabled: boolean;
  version: string | null;
  tap: string;
}

// =========================================================
// 2.9.1 Categories (Phase 9)
// =========================================================

/**
 * One entry in the `categories` map of `categories.json`. The backend bundles
 * the JSON at compile time (see `commands/categories.rs`) so this shape must
 * match the Rust `CategoryMeta` struct.
 *
 * `icon` is the PascalCase name of a Lucide icon (e.g. "Cloud", "Brain"). The
 * frontend resolves it via a static map in `lib/util/categoryIcon.ts` rather
 * than dynamic imports.
 */
export interface CategoryMeta {
  label: string;
  icon: string;
}

/**
 * Full payload of `categories_data`. `casks` and `formulae` map token → array
 * of category slugs (multiple categories per item is the norm).
 */
export interface CategoriesData {
  version: string;
  generatedAt: string;
  model: string;
  categories: Record<string, CategoryMeta>;
  casks: Record<string, string[]>;
  formulae: Record<string, string[]>;
}

// =========================================================
// 2.9.4 Enrichment (Phase 13)
// =========================================================

/**
 * One enrichment record, keyed by Homebrew token. All fields are
 * optional / possibly-empty so the placeholder bundle round-trips and
 * partially-enriched records (only Tier A, only Tier B) render
 * progressively.
 *
 * Wire shape matches the Rust `EnrichmentEntry` struct (camelCase).
 * The Tauri command serialises with `skip_serializing_if = "Option::is_none"`
 * on the optional fields, so consumers must accept `undefined` in addition
 * to `null` and treat both as "not set".
 */
export interface EnrichmentEntry {
  /** Display name (e.g. "PostgreSQL 14"). Null/undefined when Tier A
      hasn't been run for this token. */
  friendlyName?: string | null;
  /** 1-2 sentence "what + when" summary. Null/undefined when Tier A
      hasn't been run. */
  summary?: string | null;
  /** "Why install this?" bullets, 1-3 expected. Empty when Tier B
      hasn't been run for this token. */
  useCases: string[];
  /** Related package tokens, 3-5 expected. Each entry is a valid
      Homebrew token (the backend filters hallucinations). Empty when
      Tier B hasn't been run. */
  similar: string[];
  /** Tech-stack tags (lowercase, hyphenated). 3-8 expected. Empty when
      Tier B hasn't been run. */
  tags: string[];
  /** Locale-specific search aliases. Not rendered as tags; used so
      translated package summaries can be searched without renaming
      Homebrew tokens or upstream metadata. */
  searchTerms?: string[];
}

/**
 * Full payload of `enrichment_data`. `entries` maps token →
 * EnrichmentEntry. The bundled placeholder ships with an empty entries
 * map; the UI renders no enriched content until a real enrichment
 * bundle (produced by `tools/enrich/enrich.py`) is in place.
 */
export interface EnrichmentData {
  version: string;
  generatedAt: string;
  model: string;
  /** Which tiers have been baked in. Possible values: `"A"`, `"B"`. */
  tiers: string[];
  entries: Record<string, EnrichmentEntry>;
}

/** Live-enrichment freshness probe (`…/enrichment/version.json`). */
export interface LiveEnrichmentVersion {
  version: string;
  generatedAt: string;
  categoriesVersion: string;
}

// =========================================================
// 2.9.3 Services (brew services)
// =========================================================

/**
 * Raw status string from `brew services list --json`. Observed values:
 * "started", "stopped", "none", "error", "scheduled", "unknown".
 * The frontend treats unknown values as `unknown` rather than crashing.
 */
export interface Service {
  name: string;
  status: string;
  user: string | null;
  file: string | null;
  exitCode: number | null;
}

/** Normalised status for the UI's tone/icon mapping. */
export type ServiceStatus = "started" | "stopped" | "none" | "error" | "scheduled" | "unknown";

export function normalizeServiceStatus(raw: string): ServiceStatus {
  switch (raw) {
    case "started":   return "started";
    case "stopped":   return "stopped";
    case "none":      return "none";
    case "error":     return "error";
    case "scheduled": return "scheduled";
    default:          return "unknown";
  }
}

// =========================================================
// 2.9.2 Disk usage (Dashboard Storage card)
// =========================================================

export interface DiskUsageEntry {
  label: string;
  path: string;
  bytes: number;
  exists: boolean;
  error: string | null;
}

export interface DiskUsageReport {
  generatedAt: string;
  prefix: string;
  cacheDir: string;
  entries: DiskUsageEntry[];
  totalBytes: number;
  cacheAgeSeconds: number;
}

/** Issue #80 — estimate of how much `brew cleanup --prune=all` would reclaim.
 *  `reclaimableBytes` is null when brew reported no figure (nothing to clean,
 *  or output we couldn't parse) — the UI hides the hint rather than show 0. */
export interface CleanupPreview {
  reclaimableBytes: number | null;
}

// =========================================================
// 2.9 Trending (Phase 6)
// =========================================================

export interface TrendingEntry {
  rank: number;
  name: string;
  kind: PackageKind;
  /** Cumulative installs over the window, inclusive of dependency-pulled
      installs (the leaderboard-dominator metric). */
  installCount: number;
  installCountFormatted: string;
  /** v0.4.0 — explicit user-initiated installs (excludes deps). Optional
      because the secondary endpoint can soft-fail; the row still ships. */
  installOnRequestCount?: number;
  installOnRequestCountFormatted?: string;
  /** v0.4.0 — server-derived velocity index. 1.0 ≈ steady, >1.5 surging,
      <0.7 cooling. None when the other two windows haven't cached yet
      or the package's annual count is too small for a stable ratio. */
  velocityIndex?: number;
  installedLocally: boolean;
}

export interface TrendingReport {
  window: TrendingWindow;
  fetchedAt: string;
  cacheAgeSeconds: number;
  totalCount: number;
  entries: TrendingEntry[];
}

// ---------- v0.4.0: Trending history (opt-in endpoint) ----------

/**
 * Origin of a history point. Lets the UI fade or label the historical-
 * only portion of a sparkline (`seed`) distinctly from the real daily
 * snapshots (`daily`) collected from the day the user opted in.
 */
export type TrendingHistorySource = "seed" | "daily";

export interface TrendingHistoryPoint {
  /** ISO date YYYY-MM-DD of the snapshot (or bucket midpoint for seed). */
  date: string;
  count30d?: number;
  count90d?: number;
  count365d?: number;
  countInstallOnRequest30d?: number;
  /** Server-derived per-day install estimate. None for seed points and
      for daily points without a usable 30-day-prior predecessor. */
  estimatedDailyInstalls?: number;
  source: TrendingHistorySource;
}

export interface TrendingHistorySeries {
  name: string;
  kind: PackageKind;
  points: TrendingHistoryPoint[];
  /** ISO timestamp the collector wrote this series. */
  generatedAt: string;
  /** Local cache age in seconds. */
  cacheAgeSeconds: number;
}

export interface TrendingHistoryIndexEntry {
  name: string;
  kind: PackageKind;
  velocityIndex?: number;
  /** Compact per-day series for inline sparklines (~30 data points).
      The frontend treats it as opaque chart data. */
  sparkline: number[];
}

export interface TrendingHistoryIndex {
  generatedAt: string;
  packages: TrendingHistoryIndexEntry[];
  /** Local cache age in seconds. */
  cacheAgeSeconds: number;
}

// =========================================================
// 2.10 Settings (Phase 12d)
// =========================================================

/**
 * Catalog auto-refresh cadence. Wire-format mirrors the Rust enum
 * `CatalogAutoRefresh` (kebab-case).
 */
export type CatalogAutoRefresh = "off" | "weekly" | "daily";

/**
 * Cask icon fetching mode. `all` matches the current Phase 8 behaviour
 * where every uninstalled cask with a homepage probes for a favicon.
 * `installed-only` skips the homepage cascade; `off` disables even
 * installed-app icon extraction.
 */
export type CaskIconMode = "off" | "installed-only" | "all";

/**
 * Persisted user settings (Phase 12d). Lives at
 * `~/Library/Application Support/brew-browser/settings.json` and is
 * round-tripped via `settingsGet` / `settingsSet`.
 *
 * Bounds (enforced server-side, also re-checked client-side for snappier
 * UX): `catalogStaleBannerDays` ∈ [1, 365]; `trendingTtlMinutes` ∈ [5, 1440].
 */
export interface Settings {
  /** Master switch — when true, every outbound command fails with
      `paranoid_mode_blocked`. */
  paranoidMode: boolean;
  catalogAutoRefresh: CatalogAutoRefresh;
  catalogStaleBannerDays: number;
  caskIconMode: CaskIconMode;
  trendingTtlMinutes: number;
  /** Phase 12c — when true, PackageDetail probes `api.github.com` for
      repo stats whenever the package's homepage is a GitHub URL. Off
      by default; the user opts in via Settings → GitHub. Independent
      of sign-in (anonymous probes still get the 60/hr public limit). */
  githubEnabled: boolean;
  /** Phase 13 — master AI Features toggle. When false, ALL AI-derived
      data is hidden in the UI: categories (Phase 9), enrichment
      (Phase 13), donut chart, category pills, friendly names,
      summaries, use cases, similar packages, tags. Default true. */
  aiFeaturesEnabled: boolean;
  /** Phase 15 — when true, the backend's auto-check scheduler wakes
      every 24h and calls `update_check_now`. Default off; the user
      opts in via Settings → Network → Updates. Suppressed (no fetch)
      while Offline Mode is on, regardless of this flag. */
  updateAutoCheck: boolean;
  /** v0.4.0 — when true, the Trending tab + PackageDetail fetch
      historical install trends from `brew-browser.zerologic.com/trending-
      history/*` to power per-row inline sparklines and per-package
      charts. Off by default — distinct trust boundary from the always-on
      formulae.brew.sh paths. Suppressed by Offline Mode regardless. */
  enhancedTrendingEnabled: boolean;
  /** v0.5.0 — when true, the backend shells out to the official
      `brew vulns --json` subcommand to surface CVEs against installed
      formulae (OSV.dev via the GIT ecosystem). When `githubEnabled` is
      also on, GHSA-prefixed results are enriched via api.github.com.
      Off by default — distinct trust boundary (OSV is operated by
      Google, separate from formulae.brew.sh). Suppressed by Offline
      Mode regardless. */
  vulnerabilityScanningEnabled: boolean;
  /** When true, the app refreshes AI categories + descriptions live from
      `brew-browser.zerologic.com/enrichment/*` (a tiny version probe, the full
      categories.json when newer, and per-token entries on demand), overlaying
      the bundled baseline. Off by default — same first-party host as Enhanced
      Trending, new `…/enrichment/*` path; only the viewed package name is sent.
      Suppressed by Offline Mode regardless. */
  liveEnrichmentEnabled: boolean;

  /** v0.7.0 — opt-in live refresh of the curated Bundles recipe set. When on,
      the app fetches the latest `bundles.json` from
      `brew-browser.zerologic.com/bundles/bundles.json` (one static-file GET, no
      package names sent) and replaces its list on a non-empty success; any
      error keeps the bundled copy. Off by default; same first-party host as
      Live enrichment, new `…/bundles/*` path. Suppressed by Offline Mode
      regardless. Shared settings key with the native shell. */
  liveBundlesEnabled: boolean;
}

/** Defaults matching the Rust `Settings::default()`. Used when seeding
    the settings store before the first `settingsGet` resolves so the UI
    doesn't have to render an empty state. */
export const SETTINGS_DEFAULTS: Settings = {
  paranoidMode: false,
  catalogAutoRefresh: "off",
  catalogStaleBannerDays: 14,
  caskIconMode: "all",
  trendingTtlMinutes: 60,
  // Phase 12c — anonymous GitHub stats opt-in. Off by default per the
  // "zero outbound unless user consented" posture.
  githubEnabled: false,
  // Phase 13 — AI-enriched rendering. ON by default so users get the
  // friendly names, summaries, and categories out of the box.
  aiFeaturesEnabled: true,
  // Phase 15 — auto-check for new brew-browser releases. Off by
  // default per the "zero outbound unless user consented" posture.
  updateAutoCheck: false,
  // v0.4.0 — opt-in enhanced trending history. Off by default; new
  // trust boundary (project infra vs. Homebrew first-party).
  enhancedTrendingEnabled: false,
  // v0.5.0 — opt-in vulnerability scanning via `brew vulns`. Off by
  // default; new trust boundary (OSV.dev + GHSA).
  vulnerabilityScanningEnabled: false,
  // Opt-in live refresh of categories + descriptions. Off by default; same
  // first-party host as Enhanced Trending, new /enrichment/* path.
  liveEnrichmentEnabled: false,
  // v0.7.0 — opt-in live refresh of the Bundles recipe set. Off by default;
  // same first-party host, new /bundles/* path.
  liveBundlesEnabled: false,
};

// =========================================================
// 2.10.1 Vulnerability scanning (v0.5.0)
// =========================================================

/**
 * Severity label as reported by `brew vulns` (OSV-derived). The
 * backend `#[serde(other)]` catch-all maps any unrecognized value to
 * `"unknown"` so a future OSV addition or brew-vulns formatting change
 * never silently drops an entry.
 *
 * Wire shape is lowercase (matches the Rust `Severity` enum's
 * `#[serde(rename_all = "lowercase")]`).
 */
export type Severity = "critical" | "high" | "medium" | "low" | "unknown";

/**
 * One vulnerability entry produced by `brew vulns --json` (optionally
 * enriched by the backend's GHSA layer when `githubEnabled` is on).
 *
 * Every field is defensively populated by the backend — `id` is `""`
 * when the upstream advisory has no canonical identifier, `references`
 * is `[]` when none were published, etc. The UI should treat empties
 * as "not available" rather than rendering placeholder strings.
 */
export interface RawVuln {
  /** CVE or GHSA identifier (e.g. `CVE-2024-1234`, `GHSA-xxxx-xxxx-xxxx`).
      Empty when the upstream entry has no canonical ID. */
  id: string;
  severity: Severity;
  /** One-line title. Suitable for toasts and list rows. */
  summary: string;
  /** Multi-line body. May be markdown — render with the same sanitizer
      the PackageDetail enrichment text uses. */
  details: string;
  /** Patched version range (or single version), when known. When
      non-null the UI can offer a one-click upgrade affordance. */
  fixedIn: string | null;
  /** External references — typically advisory URL + upstream commit. */
  references: string[];
  /** ISO-8601 publish date when the advisory was first published.
      Null for very new or backfilled entries. */
  published: string | null;
}

/**
 * One scan record for a single installed `(kind, name, version)`. An
 * empty `vulns` vec is a positive "clean at this version" signal,
 * distinct from "no record exists at all".
 *
 * Backend wire shape mirrors the Rust `ScanRecord` struct
 * (`#[serde(rename_all = "camelCase")]`).
 */
export interface ScanRecord {
  /** ISO-8601 timestamp the record was produced by `brew vulns`. */
  scannedAt: string;
  vulns: RawVuln[];
}

/**
 * Full-install-set scan report returned by `vulns_scan_all`. `entries`
 * is keyed by the backend's storage-key form `"{kind}:{name}:{version}"`
 * — frontend consumers should treat that as opaque and re-key on
 * `(kind, name)` if they need version-agnostic lookup (the frontend
 * store does this via `parseKey`).
 *
 * `source === "cache"` means the install-set fingerprint matched the
 * last successful scan and the backend served the previous report
 * without re-shelling `brew vulns`. `"live"` means a fresh scan ran.
 */
export interface VulnScanReport {
  entries: Record<string, ScanRecord>;
  scannedAt: string;
  source: "live" | "cache";
  installFingerprint: string;
}

// =========================================================
// 2.11 GitHub (Phase 12c + 12e)
// =========================================================

/**
 * Anonymous (or token-authenticated) repo metadata fetched from
 * `api.github.com/repos/{owner}/{repo}`. The backend caches the
 * response on disk for 24h, keyed by the validated owner/repo pair.
 *
 * `null`-able fields are absent on real-world repos: a repo with no
 * GitHub release will have `lastReleaseTag === null`, a live repo
 * will have `archivedAt === null`, etc.
 */
export interface RepoStats {
  owner: string;
  repo: string;
  stars: number;
  forks: number;
  openIssues: number;
  lastReleaseTag: string | null;
  lastReleaseDate: string | null;
  archived: boolean;
  archivedAt: string | null;
  licenseSpdx: string | null;
  defaultBranch: string;
  primaryLanguage: string | null;
}

/**
 * Sign-in status surface returned by `githubStatus`.
 *
 * **Token is never on the wire** — only the derived "what can the
 * session do?" view is. See `github::auth::GithubStatusDto` in the
 * backend for the matching Rust struct and the regression test that
 * pins the wire shape.
 */
export interface GithubStatus {
  signedIn: boolean;
  username: string | null;
  scopes: string[];
}

/**
 * Result of `githubSigninStart` — payload the frontend uses to show
 * the user code and drive the polling loop.
 */
export interface DeviceFlowStart {
  /** Short human-readable code (e.g. `WDJB-MJHT`) to type at
      `verificationUri`. */
  userCode: string;
  /** URL to open in the browser (usually `github.com/login/device`). */
  verificationUri: string;
  /** Seconds until `deviceCode` expires. After this, polling will
      return `expired`. */
  expiresIn: number;
  /** Server-recommended polling cadence in seconds. Must be honoured. */
  interval: number;
  /** Opaque code passed to `githubSigninPoll`. Never shown to the user. */
  deviceCode: string;
}

/**
 * Discriminated union returned by each `githubSigninPoll` call.
 *
 * The `slowDown` variant means GitHub asked us to back off — the
 * frontend should double its polling interval before the next call,
 * per RFC 8628 §3.5.
 */
export type DeviceFlowPoll =
  | { kind: "pending" }
  | { kind: "slowDown" }
  | { kind: "approved"; username: string | null; scopes: string[] }
  | { kind: "denied" }
  | { kind: "expired" };

/**
 * Result of `githubCreateIssue` — the freshly-minted issue's number
 * and canonical `html_url`. Returned by the create-issue backend
 * command (Phase 12f). The frontend opens `htmlUrl` via `safeOpenUrl`
 * after a successful submission.
 */
export interface CreatedIssue {
  number: number;
  htmlUrl: string;
}

// =========================================================
// 2.12 Updater (Phase 15)
// =========================================================

/**
 * A newer brew-browser version surfaced by the manifest at
 * `brew-browser.zerologic.com/updater.json`. Held by the updater store
 * once a check returns `available`. Matches the camelCase wire shape
 * the backend's `UpdateCheckOutcome::Available` flattens onto when
 * serde-tagged with `kind`.
 *
 * `notes` is the raw `notes` field from the manifest — free-form text
 * (we publish a "See release notes at <url>" sentence by default), so
 * UI renders it as-is.
 *
 * No `sha256` here: the manifest sha256 is verified inside the plugin
 * before signature verification; never exposed to the renderer.
 */
export interface UpdateInfo {
  version: string;
  currentVersion: string;
  notes: string | null;
  pubDate: string | null;
  skipped: boolean;
}

/**
 * Tagged union returned by `update_check_now`. Matches the backend's
 * `UpdateCheckOutcome` serde shape exactly: `{ kind, ...fields }` with
 * the `Available` fields flattened next to the discriminator (not
 * nested under `.info`). The store narrows on `kind` and lifts the
 * flat fields into the strongly-typed `UpdateInfo` for downstream
 * consumers.
 *
 *   - `upToDate` — manifest version ≤ running version, nothing to show.
 *   - `available` — newer version exists (and isn't on the user's
 *     skip-list); UI surfaces the indicator + the install action.
 *
 * `blocked` is **not** a wire variant — Offline Mode surfaces as
 * `BrewError::ParanoidModeBlocked` instead, so the toast routes
 * through the same channel as every other gated call.
 */
export type UpdateCheckOutcome =
  | { kind: "upToDate" }
  | {
      kind: "available";
      version: string;
      currentVersion: string;
      notes: string | null;
      pubDate: string | null;
      skipped: boolean;
    };

// =========================================================
// 3.3 Error model
// =========================================================

export type BrewErrorPayload =
  | { code: "brew_not_found" }
  | { code: "brew_exit_non_zero"; command: string; exitCode: number; stderrExcerpt: string; friendlyMessage?: string }
  | { code: "json_parse";         command: string; message: string; rawExcerpt: string }
  | { code: "io";                 message: string }
  | { code: "network";            url: string; message: string }
  | { code: "http_status";        url: string; status: number }
  | { code: "invalid_argument";   message: string }
  | { code: "job_not_found";      jobId: string }
  | { code: "canceled" }
  | { code: "brewfile_not_found"; id: string }
  | { code: "internal";           message: string }
  | { code: "paranoid_mode_blocked"; feature: string }
  | { code: "feature_disabled";    feature: string }
  | { code: "github_rate_limited"; resetAt: number }
  | { code: "keychain_unavailable"; message: string }
  | { code: "auth_required" }
  | { code: "scope_required"; scope: string }
  | { code: "hash_mismatch"; expected: string; actual: string }
  | { code: "signature_verification_failed"; message: string }
  | { code: "downgrade_rejected"; current: string; target: string }
  | { code: "vulns_not_installed"; installCommand: string };

/** Type-narrowing helper: is the thrown value a BrewErrorPayload? */
export function isBrewError(e: unknown): e is BrewErrorPayload {
  return (
    typeof e === "object" &&
    e !== null &&
    "code" in e &&
    typeof (e as { code: unknown }).code === "string"
  );
}

/** Human-readable message for a BrewError. */
export function brewErrorMessage(e: BrewErrorPayload, locale: "en" | "ru" = "en"): string {
  if (locale === "ru") {
    switch (e.code) {
      case "brew_not_found":      return "Homebrew не найден в PATH.";
      case "brew_exit_non_zero":  return e.friendlyMessage ?? `brew завершился с кодом ${e.exitCode}: ${e.stderrExcerpt}`;
      case "json_parse":          return `Не удалось разобрать вывод brew: ${e.message}`;
      case "io":                  return `Ошибка ввода-вывода: ${e.message}`;
      case "network":             return `Сетевая ошибка: ${e.message}`;
      case "http_status":         return `HTTP ${e.status} от ${e.url}`;
      case "invalid_argument":    return `Недопустимый аргумент: ${e.message}`;
      case "job_not_found":       return `Задача ${e.jobId} не найдена.`;
      case "canceled":            return "Операция отменена.";
      case "brewfile_not_found":  return `Brewfile «${e.id}» не найден.`;
      case "internal":            return `Внутренняя ошибка: ${e.message}`;
      case "paranoid_mode_blocked":
        return `Офлайн-режим включён — функция «${e.feature}» заблокирована. Отключите его в разделе «Настройки → Сеть».`;
      case "feature_disabled":
        return `Функция «${e.feature}» отключена. Включите её в разделе «Настройки → Сеть».`;
      case "github_rate_limited": {
        const reset = e.resetAt > 0 ? new Date(e.resetAt * 1000).toLocaleTimeString("ru-RU") : "скоро";
        return `Достигнут лимит запросов GitHub API. Лимит сбросится в ${reset}. Войдите в GitHub, чтобы снять ограничение.`;
      }
      case "keychain_unavailable":
        return `${keyringNameCapitalized} недоступен: ${e.message}`;
      case "auth_required":
        return "Войдите в GitHub, чтобы использовать эту функцию.";
      case "scope_required":
        return `Требуется разрешение GitHub «${e.scope}». Войдите ещё раз, чтобы выдать его.`;
      case "hash_mismatch":
        return `Обновление отменено: хэш загруженного файла не совпал с манифестом (ожидалось ${e.expected.slice(0, 12)}…, получено ${e.actual.slice(0, 12)}…).`;
      case "signature_verification_failed":
        return `Обновление отменено: подпись не прошла проверку (${e.message}).`;
      case "downgrade_rejected":
        return `Обновление отклонено: ${e.target} не новее установленной версии (${e.current}).`;
      case "vulns_not_installed":
        return `Подкоманда brew vulns не установлена. Нажмите «Установить brew-vulns» или выполните \`${e.installCommand}\`, чтобы включить проверку.`;
    }
  }
  switch (e.code) {
    case "brew_not_found":      return "Homebrew not found on PATH.";
    case "brew_exit_non_zero":  return e.friendlyMessage ?? `brew exited ${e.exitCode}: ${e.stderrExcerpt}`;
    case "json_parse":          return `Failed to parse brew output: ${e.message}`;
    case "io":                  return `I/O error: ${e.message}`;
    case "network":             return `Network error: ${e.message}`;
    case "http_status":         return `HTTP ${e.status} from ${e.url}`;
    case "invalid_argument":    return `Invalid argument: ${e.message}`;
    case "job_not_found":       return `Job ${e.jobId} not found.`;
    case "canceled":            return "Operation canceled.";
    case "brewfile_not_found":  return `Brewfile "${e.id}" not found.`;
    case "internal":            return `Internal error: ${e.message}`;
    case "paranoid_mode_blocked":
      return `Offline Mode is on — ${e.feature} is blocked. Disable it in Settings → Network.`;
    case "feature_disabled":
      return `${e.feature} is disabled. Enable it in Settings → Network.`;
    case "github_rate_limited": {
      const reset = e.resetAt > 0 ? new Date(e.resetAt * 1000).toLocaleTimeString() : "soon";
      return `GitHub API rate limit reached. Resets at ${reset}. Sign in to lift the limit.`;
    }
    case "keychain_unavailable":
      return `${keyringNameCapitalized} unavailable: ${e.message}`;
    case "auth_required":
      return "Sign in to GitHub to use this feature.";
    case "scope_required":
      return `GitHub permission "${e.scope}" required. Sign in again to grant it.`;
    case "hash_mismatch":
      return `Update aborted: downloaded artifact hash didn't match the manifest (expected ${e.expected.slice(0, 12)}…, got ${e.actual.slice(0, 12)}…).`;
    case "signature_verification_failed":
      return `Update aborted: signature verification failed (${e.message}).`;
    case "downgrade_rejected":
      return `Update refused: ${e.target} is not newer than the installed version (${e.current}).`;
    case "vulns_not_installed":
      return `brew vulns subcommand not installed. Click 'Install brew-vulns' or run \`${e.installCommand}\` to enable scanning.`;
  }
}

// =========================================================
// UI-only types (frontend stores, command palette, etc.)
// =========================================================

export type SidebarSection =
  | "dashboard"
  | "library"
  | "discover"
  | "trending"
  | "snapshots"
  | "services"
  | "activity"
  | "bundles";

export type ThemePreference = "light" | "dark" | "system";

/** Settings modal subsection. Kept in sync with Settings.svelte's
    internal section list — use this when deep-linking via
    `ui.openSettings(section)`. */
export type SettingsSection =
  | "appearance"
  | "network"
  | "github"
  | "brew"
  | "activity"
  | "about";

/** A job tracked locally on the frontend (status + accumulated lines). */
export interface ActivityJob {
  jobId: string;
  label: string;             // human-friendly: "Installing wget"
  command: string;
  startedAt: string;
  status: "running" | "succeeded" | "failed" | "canceled";
  lines: ActivityLine[];
  exitCode?: number;
  durationMs?: number;
  /** Backend-generated friendly message for known environmental/upstream failures. */
  friendlyMessage?: string;
  /** Best-effort live progress from brew's `==>` markers (running jobs). */
  progress?: JobProgress;
}

export interface JobProgress {
  phase: string;             // "Pouring" | "Downloading" | "Installing" | …
  package: string;           // current package (may be empty)
  current: number;           // 1-based index of the current unit
  total: number | null;      // total units when known, else null
}

export interface ActivityLine {
  stream: "stdout" | "stderr";
  text: string;
  ts: string;
}

/** Classification of an activity job into a package-change kind.
 *  `other` = not a per-package change (tap update / Brewfile bundle) and is
 *  excluded from the "Recent changes" feed. Mirrors the native (Swift) enum. */
export type ChangeKind = "installed" | "upgraded" | "uninstalled" | "other";

/** A single derived "recent change" — a pure projection of an {@link ActivityJob},
 *  NOT a separately-persisted record. Carries the action kind, affected package
 *  (null for bulk upgrades), an optional bulk `count`, a normalized timestamp
 *  (epoch ms — Tauri from ISO `startedAt`, native from epoch-seconds), and the
 *  terminal status. Deliberately carries NO version delta: the activity log
 *  records no structured old→new version, so neither shell fabricates one. */
export interface RecentChange {
  jobId: string;
  kind: Exclude<ChangeKind, "other">;
  /** Affected package name, or null for a bulk upgrade (no per-package names). */
  package: string | null;
  /** Number of packages for a bulk upgrade ("Upgrading N packages"); null for
   *  single-package changes and for "Upgrading all packages" (count unknown). */
  count: number | null;
  /** Job start time normalized to epoch milliseconds. */
  timestamp: number;
  status: "succeeded" | "failed" | "canceled";
}

// =========================================================
// Bundles M1 — capability profile + readiness
// =========================================================

/** Machine capabilities probed with zero installs by `system_profile`.
 *  Mirrors the Rust `SystemProfile` struct (and the Swift one) byte-for-byte
 *  on the wire. `ramGB`/`freeDiskGB` are whole GiB rounded to the nearest GB. */
export interface SystemProfile {
  ramGB: number;
  arch: "apple-silicon" | "intel" | "linux";
  chip: string;
  cpuCores: number;
  gpu: "metal" | "cuda" | "none" | "unknown";
  freeDiskGB: number;
  osVersion: string;
}

/** What a bundle needs from the host. Consumed by `readiness()`; `null`
 *  requires means "runs anywhere" (always ready). */
export interface BundleRequires {
  minRamGB: number;
  recommendedRamGB: number;
  minDiskGB: number;
  arch: "any" | "apple-silicon" | "intel" | "linux";
  gpu: "none" | "preferred" | "required";
}

/** Readiness verdict for a bundle against a profile. `"blocked"` is advisory
 *  — M3's UI still allows install behind a confirm. */
export type ReadinessVerdict = "ready" | "marginal" | "blocked";

/** A verdict plus a human-readable one-line reason. */
export interface Readiness {
  verdict: ReadinessVerdict;
  reason: string;
}

// =========================================================
// Bundles M2 — curated recipe contract
// =========================================================

/** One package inside a bundle. `kind` is a plain string (not `PackageKind`)
 *  so an unexpected value in a live-refreshed recipe degrades gracefully.
 *  Mirrors the Rust `BundlePackage`. */
export interface BundlePackage {
  name: string;
  kind: string;
}

/** A post-install setup step. Which fields apply depends on `kind`
 *  (`service` | `open` | `reveal` | `command` | `note`); all but `kind` are
 *  optional. `command` steps always carry `external: true` — the app never
 *  auto-runs a shell. Mirrors the Rust `SetupStep`. */
export interface SetupStep {
  kind: string;
  service?: string;
  label?: string;
  url?: string;
  path?: string;
  run?: string;
  external?: boolean;
  text?: string;
}

/** An external reference link (docs, homepage, source). */
export interface BundleLink {
  label: string;
  url: string;
}

/** A curated bundle recipe. See `recipes/recipe.schema.json` for the authoring
 *  contract. `capabilityNotes` maps a RAM-tier (integer-as-string key) to a
 *  human note the readiness gate surfaces. Mirrors the Rust `Bundle`. */
export interface Bundle {
  id: string;
  name: string;
  tagline: string;
  /** Optional 2–4 sentence intent paragraph ("what is this / why"), distinct
   *  from the short one-line `tagline` and from the cautionary `caveats`.
   *  Rendered as body copy under the tagline in the detail pane. Absent on
   *  recipes authored before the field was added. */
  description?: string;
  category: string;
  icon?: string | null;
  packages: BundlePackage[];
  tap?: string | null;
  requires?: BundleRequires | null;
  capabilityNotes: Record<string, string>;
  setup: SetupStep[];
  caveats?: string | null;
  links: BundleLink[];
  maintainer?: string | null;
  addedIn?: string | null;
}

/** Command-palette item — either a verb (action) or a package. */
export type PaletteItem =
  | { kind: "command"; id: string; label: string; shortcut?: string; section?: string; run: () => void | Promise<void> }
  | { kind: "package"; name: string; pkgKind: PackageKind; installed: boolean; description?: string | null };
