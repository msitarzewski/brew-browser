/**
 * Typed `invoke()` wrappers for every backend command in `memory-bank/backendApi.md`.
 *
 * Convention: each function resolves with the typed result, or *throws* a
 * `BrewErrorPayload`-shaped object on backend error. Callers should use
 * `try/catch` and `isBrewError(e)` to narrow.
 *
 * Streaming commands additionally take an `onEvent(BrewStreamEvent)` callback
 * — the underlying Tauri `Channel<T>` is wired up here so callers don't have
 * to import `@tauri-apps/api/core` directly.
 *
 * NOTE: backend may not be implemented yet. If `invoke()` itself throws (e.g.
 * unknown command) the error propagates — callers should handle that case
 * gracefully (show "Backend not ready" rather than crashing).
 */

import { invoke, Channel } from "@tauri-apps/api/core";

import type {
  BrewEnvironment,
  Brewfile,
  Bundle,
  BundlePackage,
  BrewfileCheckReport,
  BrewfileId,
  BrewfileSummary,
  BrewStreamEvent,
  Cask,
  CatalogEntrySummary,
  CatalogSummary,
  ReverseDependents,
  CategoriesData,
  CreatedIssue,
  DeviceFlowPoll,
  CleanupPreview,
  DeviceFlowStart,
  DiskUsageReport,
  EnrichmentData,
  EnrichmentEntry,
  LiveEnrichmentVersion,
  Formula,
  GithubStatus,
  JobResult,
  OutdatedPackage,
  Package,
  PackageDetail,
  PackageKind,
  PackageList,
  RawVuln,
  RepoStats,
  SearchResults,
  Service,
  Settings,
  SystemProfile,
  SystemStatus,
  TrendingHistoryIndex,
  TrendingHistorySeries,
  TrendingReport,
  TrendingWindow,
  UpdateCheckOutcome,
  VulnScanReport,
} from "./types";

// ============================================================
// Phase 1 — read-only browser
// ============================================================

export function brewDoctor(): Promise<BrewEnvironment> {
  return invoke<BrewEnvironment>("brew_doctor");
}

/**
 * Cheap local probe for the onboarding gate: is brew resolved (and where),
 * and are the Xcode Command Line Tools present? Reads the backend's cached
 * brew path — no filesystem re-scan, no network, no gates.
 */
export function systemStatus(): Promise<SystemStatus> {
  return invoke<SystemStatus>("system_status");
}

/**
 * Re-run brew detection and write the result into backend state so every
 * brew-dependent command sees the recovered binary — the onboarding view
 * polls this until the user's Homebrew install lands, then the app comes
 * alive without a relaunch.
 */
export function brewRedetect(): Promise<SystemStatus> {
  return invoke<SystemStatus>("brew_redetect");
}

/**
 * Open Terminal.app with the official Homebrew install one-liner pre-typed
 * (a fixed constant on the backend — zero interpolation). Throws a typed
 * `BrewErrorPayload` when osascript fails (e.g. Automation permission
 * denied); callers fall back to the copy-to-clipboard affordance.
 */
export function openTerminalInstall(): Promise<void> {
  return invoke<void>("open_terminal_install");
}

/**
 * Read the installed package list (formulae + casks).
 *
 * Pass `force: true` to bypass the backend's `installed_cache` —
 * needed when the user explicitly clicks Refresh, OR after any
 * in-app action that mutates the brew install set (install,
 * uninstall, upgrade, snapshot restore). Without the bypass, brew
 * commands run from the user's terminal don't get reflected in the
 * app until process restart.
 */
export function brewList(force = false): Promise<PackageList> {
  return invoke<PackageList>("brew_list", { force });
}

export function brewInfo(name: string, kind: PackageKind): Promise<PackageDetail> {
  return invoke<PackageDetail>("brew_info", { name, kind });
}

export function brewOutdated(): Promise<OutdatedPackage[]> {
  return invoke<OutdatedPackage[]>("brew_outdated");
}

// ============================================================
// Phase 2 — search
// ============================================================

export function brewSearch(query: string): Promise<SearchResults> {
  return invoke<SearchResults>("brew_search", { query });
}

export function brewSearchDesc(query: string): Promise<SearchResults> {
  return invoke<SearchResults>("brew_search_desc", { query });
}

/**
 * In-process union search across catalog + AI summary + friendly name +
 * upstream desc + category labels + enrichment tags.
 *
 * Strictly more powerful than `brew_search` for the brew-browser
 * Discover UX: matches a query against everything we have in-memory,
 * scores by field-weight (name > friendly > category > summary > desc
 * > tag), and returns the same `SearchResults` shape with each hit's
 * best description pre-populated so the row renders without a second
 * round-trip.
 *
 * Multi-term queries AND across fields. Cap is 200 hits split between
 * formulae and casks.
 */
export function localSearch(query: string, locale?: string): Promise<SearchResults> {
  return invoke<SearchResults>("local_search", { query, locale });
}

// ============================================================
// Phase 3 — install / uninstall / upgrade (streaming)
// ============================================================

/** Helper: wires a Tauri Channel<BrewStreamEvent> to a callback. */
function makeChannel(onEvent: (evt: BrewStreamEvent) => void): Channel<BrewStreamEvent> {
  const channel = new Channel<BrewStreamEvent>();
  channel.onmessage = onEvent;
  return channel;
}

export function brewInstall(
  name: string,
  kind: PackageKind,
  force = false,
  onEvent: (evt: BrewStreamEvent) => void,
  adopt = false,
): Promise<JobResult> {
  return invoke<JobResult>("brew_install", {
    name,
    kind,
    force,
    adopt,
    onEvent: makeChannel(onEvent),
  });
}

export function brewUninstall(
  name: string,
  kind: PackageKind,
  zap: boolean,
  onEvent: (evt: BrewStreamEvent) => void,
  ignoreDependencies = false,
): Promise<JobResult> {
  return invoke<JobResult>("brew_uninstall", {
    name,
    kind,
    zap,
    ignoreDependencies,
    onEvent: makeChannel(onEvent),
  });
}

export function brewUpgrade(
  name: string | null,
  onEvent: (evt: BrewStreamEvent) => void,
  greedy = false,
): Promise<JobResult> {
  return invoke<JobResult>("brew_upgrade", {
    name,
    greedy,
    onEvent: makeChannel(onEvent),
  });
}

/**
 * Upgrade a curated subset of packages in a single
 * `brew upgrade <a> <b> ...` invocation.
 *
 * Backed by the `brew_upgrade_many` IPC. Empty `names` is rejected
 * server-side with `invalid_argument` — use `brewUpgrade(null)` for
 * the "upgrade everything" path instead.
 */
export function brewUpgradeMany(
  names: string[],
  onEvent: (evt: BrewStreamEvent) => void,
  greedy = false,
): Promise<JobResult> {
  return invoke<JobResult>("brew_upgrade_many", {
    names,
    greedy,
    onEvent: makeChannel(onEvent),
  });
}

/**
 * Issue #47 — `brew autoremove`: remove formulae that were pulled in only as
 * dependencies and are no longer needed. Confirm-gated in the UI; streams like
 * the other write commands.
 */
export function brewAutoremove(
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brew_autoremove", {
    onEvent: makeChannel(onEvent),
  });
}

export function brewUpdate(
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brew_update", {
    onEvent: makeChannel(onEvent),
  });
}

/**
 * Issue #90 (folds in #134) — `brew pin`/`unpin` a package so `brew upgrade`
 * (including `--greedy`) skips it. Non-streaming: pin is an instant flip, so
 * this resolves once done rather than emitting Activity events. `pinned=true`
 * pins, `false` unpins. On success the backend invalidates its caches, so
 * callers should reload the package list to pick up the new pin state.
 */
export function brewSetPinned(
  name: string,
  kind: PackageKind,
  pinned: boolean,
): Promise<void> {
  return invoke<void>("brew_set_pinned", { name, kind, pinned });
}

/** Issue #80 — stream `brew doctor` diagnostics into the Activity drawer.
 *  (Distinct from the onboarding `brewDoctor()` env probe above.) A non-zero
 *  exit from advisories is reported by the backend as effective-success. */
export function brewDoctorStream(
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brew_doctor_stream", {
    onEvent: makeChannel(onEvent),
  });
}

/** Issue #80 — stream `brew cleanup --prune=all [--scrub] [--verbose]`. The
 *  caller MUST confirm first (destructive of cached downloads). `scrub` is
 *  opt-in (default off) — it also removes the latest versions' downloads. */
export function brewCleanup(
  scrub: boolean,
  verbose: boolean,
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brew_cleanup", {
    scrub,
    verbose,
    onEvent: makeChannel(onEvent),
  });
}

export function cancelJob(jobId: string): Promise<void> {
  return invoke<void>("cancel_job", { jobId });
}

// ============================================================
// Phase 4 — Brewfile snapshot + restore
// ============================================================

export function brewfileDump(
  label: string,
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<BrewfileSummary> {
  return invoke<BrewfileSummary>("brewfile_dump", {
    label,
    onEvent: makeChannel(onEvent),
  });
}

export function brewfileInstall(
  id: BrewfileId,
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brewfile_install", {
    id,
    onEvent: makeChannel(onEvent),
  });
}

export function brewfileCheck(id: BrewfileId): Promise<BrewfileCheckReport> {
  return invoke<BrewfileCheckReport>("brewfile_check", { id });
}

export function brewfileList(): Promise<BrewfileSummary[]> {
  return invoke<BrewfileSummary[]>("brewfile_list");
}

export function brewfileRead(id: BrewfileId): Promise<Brewfile> {
  return invoke<Brewfile>("brewfile_read", { id });
}

export function brewfileDelete(id: BrewfileId): Promise<void> {
  return invoke<void>("brewfile_delete", { id });
}

export function brewfileExport(id: BrewfileId, targetPath: string): Promise<void> {
  return invoke<void>("brewfile_export", { id, targetPath });
}

export function brewfileImport(sourcePath: string, label: string): Promise<BrewfileSummary> {
  return invoke<BrewfileSummary>("brewfile_import", { sourcePath, label });
}

// ============================================================
// Phase 6 — trending
// ============================================================

export function trendingFetch(window: TrendingWindow): Promise<TrendingReport> {
  return invoke<TrendingReport>("trending_fetch", { window });
}

export function trendingClearCache(): Promise<void> {
  return invoke<void>("trending_clear_cache");
}

// ----- v0.4.0: opt-in history endpoint (brew-browser.zerologic.com) -----

/**
 * Fetch the trending-history summary blob — top-N packages with
 * server-precomputed velocity index + compact sparkline. Single fetch
 * on Trending tab mount; powers inline sparklines on every row.
 *
 * Throws `feature_disabled` when `enhancedTrendingEnabled` is off, and
 * `paranoid_mode_blocked` when Offline Mode is on. Falls back to stale
 * cache on transient network failure (same contract as `trendingFetch`).
 */
export function trendingHistoryIndex(): Promise<TrendingHistoryIndex> {
  return invoke<TrendingHistoryIndex>("trending_history_index");
}

/**
 * Fetch the per-package historical series — full set of seed-bucket +
 * daily points. Called on demand from PackageDetail's sparkline.
 *
 * Cached for 6h per (name, kind) on a 500-entry LRU.
 */
export function trendingHistoryFetch(
  name: string,
  kind: PackageKind,
): Promise<TrendingHistorySeries> {
  return invoke<TrendingHistorySeries>("trending_history_fetch", { name, kind });
}

// ============================================================
// Phase 7 — cask icons
// ============================================================

/**
 * Fetch a cask icon as a base64 data URL (e.g. `data:image/png;base64,…`).
 *
 * Returns `null` when the cask has no resolvable icon (no .app bundle,
 * extraction failed, or network unavailable). Backend (`cask_icon`) handles
 * its own disk caching; the frontend keeps an in-memory layer via the
 * `iconCache` store to avoid re-invoking on every PackageRow render.
 *
 * Only meaningful for `kind === "cask"` — formulae are CLI tools and have
 * no icon. Callers should gate on kind before invoking.
 */
export function caskIcon(token: string): Promise<string | null> {
  return invoke<string | null>("cask_icon", { token });
}

/**
 * Fetch a homepage-derived icon (favicon) for a cask that has no installed
 * `.app` bundle. Returns a base64 data URL on success, `null` on miss/error.
 *
 * Same return semantics as `caskIcon` — the iconCache store treats `null` as
 * sticky so a known-missing cask won't keep retrying within the session. The
 * backend (`cask_icon_from_homepage`) handles its own disk cache (7-day TTL)
 * keyed by token, so calling twice for the same cask = cache hit on the
 * backend.
 *
 * Routing happens in `iconCache.getIcon(pkg)` via `pkg.iconSource.kind`; call
 * sites typically don't invoke this directly.
 */
export function caskIconFromHomepage(token: string, homepage: string): Promise<string | null> {
  return invoke<string | null>("cask_icon_from_homepage", { token, homepage });
}

// ============================================================
// Phase 12a — catalog (bundled + user-refreshed)
// ============================================================

/**
 * Cheap summary of the active catalog (counts, source, age). Used by
 * the Dashboard catalog line and Discover stale banner. Pure in-memory
 * read on the backend — no I/O.
 */
export function catalogSummary(): Promise<CatalogSummary> {
  return invoke<CatalogSummary>("catalog_summary");
}

/**
 * Fetch fresh `formula.json` + `cask.json` from `formulae.brew.sh`,
 * write them to the user-data catalog dir, and swap the active catalog
 * to the user-refreshed copy. Returns the new summary.
 *
 * Subject to the paranoid-mode gate; throws `paranoid_mode_blocked`
 * when "Block all outbound" is on. Single-flight enforced — a second
 * concurrent call fast-fails with `invalid_argument`.
 */
export function catalogRefresh(): Promise<CatalogSummary> {
  return invoke<CatalogSummary>("catalog_refresh");
}

/** Look up a single formula by name. `null` on miss. */
export function catalogLookupFormula(name: string): Promise<Formula | null> {
  return invoke<Formula | null>("catalog_lookup_formula", { name });
}

/** Look up a single cask by token. `null` on miss. */
export function catalogLookupCask(name: string): Promise<Cask | null> {
  return invoke<Cask | null>("catalog_lookup_cask", { name });
}

/** Light per-entry list of every formula in the active catalog. */
export function catalogFormulaeSummary(): Promise<CatalogEntrySummary[]> {
  return invoke<CatalogEntrySummary[]>("catalog_formulae_summary");
}

/** Light per-entry list of every cask in the active catalog. */
export function catalogCasksSummary(): Promise<CatalogEntrySummary[]> {
  return invoke<CatalogEntrySummary[]>("catalog_casks_summary");
}

/**
 * Reverse dependencies — every catalog entry that depends on `name`.
 * Pure catalog-graph inversion (no `brew` subprocess, no network). Cask
 * dependents are included only on macOS (the backend gates them behind
 * `cfg!(target_os = "macos")`); on Linux the result is the
 * formula→formula graph alone.
 */
export function catalogReverseDependents(name: string): Promise<ReverseDependents> {
  return invoke<ReverseDependents>("catalog_reverse_dependents", { name });
}

// ============================================================
// Phase 9 — categories
// ============================================================

/**
 * Fetch the bundled `categories.json` payload (19 categories + 15,974
 * categorized tokens). The backend embeds the JSON at compile time via
 * `include_str!` and memoises the parsed result, so subsequent invocations
 * within the same process are effectively free.
 *
 * Frontend callers should hit this via the `categoriesStore` rather than
 * invoking directly — the store caches across components and exposes the
 * derived helpers used by Discover / Library / Trending.
 */
export function categoriesData(): Promise<CategoriesData> {
  return invoke<CategoriesData>("categories_data");
}

// ============================================================
// Phase 13 — enrichment (LLM-baked metadata, bundled at build time)
// ============================================================

/**
 * Fetch the bundled `enrichment.json.gz` payload. The backend
 * `include_bytes!`s the gzip stream and parses on first call, memoising
 * on AppState. Returns a placeholder shape (empty entries map) when
 * the build was made without running `tools/enrich/enrich.py` first.
 *
 * The frontend store (`enrichmentStore`) wraps this and adds the AI
 * Features toggle gate; components should reach for the store, not
 * this raw wrapper.
 */
export function enrichmentData(locale?: string): Promise<EnrichmentData> {
  return invoke<EnrichmentData>("enrichment_data", { locale });
}

/**
 * Look up the enrichment entry for a single token. Returns `null` when
 * the token isn't in the bundle (placeholder build, brand-new package,
 * etc.). The backend validates the token against `validate_package_name`
 * first so an IPC caller can't probe with shell metacharacters.
 */
export function enrichmentLookup(name: string, locale?: string): Promise<EnrichmentEntry | null> {
  return invoke<EnrichmentEntry | null>("enrichment_lookup", { name, locale });
}

// ============================================================
// Live enrichment (opt-in) — fresh categories/descriptions from
// brew-browser.zerologic.com/enrichment/*. Each is gated server-side by
// require_live_enrichment (paranoid + the liveEnrichmentEnabled toggle) and
// soft-fails; callers overlay results on the bundled baseline.
// ============================================================

/** Freshness probe: `{version, generatedAt, categoriesVersion}`. */
export function enrichmentLiveVersion(): Promise<LiveEnrichmentVersion> {
  return invoke<LiveEnrichmentVersion>("enrichment_live_version");
}

/** Full live categories file — pulled only when its version is newer. */
export function enrichmentLiveCategories(): Promise<CategoriesData> {
  return invoke<CategoriesData>("enrichment_live_categories");
}

/** Per-token live enrichment, fetched on demand for a shown package. */
export function enrichmentLiveEntry(name: string): Promise<EnrichmentEntry> {
  return invoke<EnrichmentEntry>("enrichment_live_entry", { name });
}

// ============================================================
// Dashboard — disk usage + Finder reveal
// ============================================================

/**
 * Probe disk usage for the four canonical Homebrew sub-trees (Cellar,
 * Caskroom, var/log, download cache). Backend caches the result for ~60 s
 * to keep Dashboard renders cheap.
 */
export function diskUsage(): Promise<DiskUsageReport> {
  return invoke<DiskUsageReport>("disk_usage");
}

/** Force the next `diskUsage()` call to re-run `du` instead of using cache. */
export function diskUsageClearCache(): Promise<void> {
  return invoke<void>("disk_usage_clear_cache");
}

/** Issue #80 — dry-run estimate of what `brew cleanup --prune=all` would free.
 *  Best-effort; `reclaimableBytes` is null when brew reported no figure. */
export function brewCleanupPreview(): Promise<CleanupPreview> {
  return invoke<CleanupPreview>("brew_cleanup_preview");
}

/**
 * Reveal a path in macOS Finder. Backend gates against paths outside the
 * Homebrew prefix and cache, so the frontend can only request paths the
 * disk-usage report itself surfaced.
 */
export function openInFinder(path: string): Promise<void> {
  return invoke<void>("open_in_finder", { path });
}

// ============================================================
// Services (brew services)
// ============================================================

export function servicesList(): Promise<Service[]> {
  return invoke<Service[]>("services_list");
}

export function servicesClearCache(): Promise<void> {
  return invoke<void>("services_clear_cache");
}

export function servicesStart(name: string): Promise<void> {
  return invoke<void>("services_start", { name });
}

export function servicesStop(name: string): Promise<void> {
  return invoke<void>("services_stop", { name });
}

export function servicesRestart(name: string): Promise<void> {
  return invoke<void>("services_restart", { name });
}

// ============================================================
// Phase 12b — Settings (brew analytics + app version)
// ============================================================

/**
 * Read the user's current Homebrew analytics posture.
 *
 * Shells `brew analytics state` and parses the first line of stdout.
 * Throws `BrewErrorPayload` with `code === "internal"` if brew prints
 * anything unrecognised (a defensive behaviour per the Phase 12 security
 * review — we'd rather surface "unexpected output" than guess).
 */
export function brewGetAnalytics(): Promise<boolean> {
  return invoke<boolean>("brew_get_analytics");
}

/**
 * Set the user's Homebrew analytics posture. Takes the brew write lock
 * because `brew analytics on|off` mutates global brew state.
 */
export function brewSetAnalytics(enabled: boolean): Promise<void> {
  return invoke<void>("brew_set_analytics", { enabled });
}

/**
 * App version string from `tauri::App::package_info()` — the source of
 * truth is `Cargo.toml` (mirrored by `tauri.conf.json`). Cheaper and
 * more honest than reading `package.json` from the renderer.
 */
export function appVersion(): Promise<string> {
  return invoke<string>("app_version");
}

// ============================================================
// Phase 12d — Settings persistence
// ============================================================

/**
 * Read the currently-loaded settings.
 *
 * Throws a `BrewErrorPayload` with `code === "internal"` when the
 * settings file on disk is unparseable — in that case the backend is
 * already failing closed (`require_network` denies all outbound calls
 * until the user resets). The Settings UI should catch the throw and
 * show a "Settings file unreadable — Reset to defaults?" affordance
 * that calls `settingsReset()`.
 */
export function settingsGet(): Promise<Settings> {
  return invoke<Settings>("settings_get");
}

/**
 * Persist a complete settings object. Returns the canonicalized
 * settings (numerics clamped, etc.) so the caller can re-broadcast the
 * authoritative values to the store.
 */
export function settingsSet(settings: Settings): Promise<Settings> {
  return invoke<Settings>("settings_set", { settings });
}

/**
 * Overwrite `settings.json` with defaults. Used by the "Reset to
 * defaults" button in Settings → Network when the file is corrupt or
 * the user wants to start fresh.
 */
export function settingsReset(): Promise<Settings> {
  return invoke<Settings>("settings_reset");
}

// ============================================================
// Phase 12c + 12e — GitHub integration
// ============================================================

/**
 * Fetch repo stats for `homepage`. Returns `null` when:
 * - The user hasn't enabled GitHub stats in Settings (the toggle
 *   defaults off).
 * - `homepage` doesn't parse as a `github.com/<owner>/<repo>` URL.
 * - The repo returns 404.
 *
 * Throws `BrewErrorPayload` with `code === "paranoid_mode_blocked"`
 * when paranoid mode is on (regardless of the GitHub toggle), or
 * `"github_rate_limited"` when the anonymous 60/hr per-IP cap is hit.
 *
 * Backend handles its own 24h disk cache, so calling twice for the
 * same homepage = cache hit on the backend.
 */
export function githubRepoStats(homepage: string): Promise<RepoStats | null> {
  return invoke<RepoStats | null>("github_repo_stats", { homepage });
}

/**
 * Read the current sign-in status. Reads from the macOS Keychain only —
 * no network call. The DTO contains `{ signedIn, username, scopes }`,
 * never the token. Callers should `loadStatus()` on mount + after each
 * sign-in / sign-out.
 */
export function githubStatus(): Promise<GithubStatus> {
  return invoke<GithubStatus>("github_status");
}

/**
 * Begin a GitHub Device Flow sign-in. POSTs to
 * `github.com/login/device/code` and returns the user code +
 * verification URI to show in the DeviceFlowModal.
 *
 * Subject to the paranoid-mode gate — the sign-in handshake itself is
 * outbound and gets blocked when "Block all outbound" is on.
 */
export function githubSigninStart(): Promise<DeviceFlowStart> {
  return invoke<DeviceFlowStart>("github_signin_start");
}

/**
 * Poll the token endpoint once with the opaque `deviceCode` returned
 * by `githubSigninStart`. Returns a tagged union — caller drives the
 * polling loop using the `interval` from the start response and
 * doubles it on `slowDown` per RFC 8628 §3.5.
 */
export function githubSigninPoll(deviceCode: string): Promise<DeviceFlowPoll> {
  return invoke<DeviceFlowPoll>("github_signin_poll", { deviceCode });
}

/**
 * Delete the stored OAuth token (and cached username/scopes) from the
 * macOS Keychain. Idempotent.
 */
export function githubSignout(): Promise<void> {
  return invoke<void>("github_signout");
}

// ============================================================
// Phase 12f — GitHub authed actions (star / watch / file issue)
// ============================================================
//
// Every wrapper below talks to a backend command that runs the same
// five-step gate chain before any network call: paranoid-mode → URL
// allowlist → auth-required (Keychain) → scope-required (`public_repo`)
// → action. Errors surface as typed `BrewErrorPayload`:
//
//   - `paranoid_mode_blocked` — Paranoid Mode is on; route to Settings.
//   - `invalid_argument`      — `homepage` isn't a github.com/<o>/<r>.
//   - `auth_required`         — no token in Keychain; sign in.
//   - `scope_required`        — token lacks `public_repo`; re-grant.
//   - `github_rate_limited`   — bucket exhausted; no retry, no backoff.

/**
 * Star the repo whose URL matches `homepage`. The backend validates
 * the URL is `github.com/<owner>/<repo>` before any network call.
 */
export function githubStar(homepage: string): Promise<void> {
  return invoke<void>("github_star", { homepage });
}

/**
 * Unstar — idempotent on the GitHub side (unstarring a repo you
 * weren't starring returns 204 too).
 */
export function githubUnstar(homepage: string): Promise<void> {
  return invoke<void>("github_unstar", { homepage });
}

/**
 * Check whether the signed-in user has starred `homepage`. Returns
 * a boolean — backend maps 204 → true, 404 → false.
 */
export function githubIsStarred(homepage: string): Promise<boolean> {
  return invoke<boolean>("github_is_starred", { homepage });
}

/**
 * Watch the repo (`subscribed: true, ignored: false`). The GitHub
 * UI calls this "All activity".
 */
export function githubWatch(homepage: string): Promise<void> {
  return invoke<void>("github_watch", { homepage });
}

/** Stop watching — idempotent. */
export function githubUnwatch(homepage: string): Promise<void> {
  return invoke<void>("github_unwatch", { homepage });
}

/**
 * File an issue against the repo. Backend sanitises and caps:
 *   - title:  ≤ 256 chars, control chars stripped (except tab).
 *   - body:   ≤ 64 KiB, null bytes stripped (markdown otherwise).
 *   - labels: ≤ 10, each ≤ 50 chars matching `^[A-Za-z0-9_./-]+$`.
 *
 * Returns the new issue's `{ number, htmlUrl }` so the caller can
 * `safeOpenUrl(result.htmlUrl)` to show the user the result.
 */
export function githubCreateIssue(
  homepage: string,
  title: string,
  body: string,
  labels: string[],
): Promise<CreatedIssue> {
  return invoke<CreatedIssue>("github_create_issue", {
    homepage,
    title,
    body,
    labels,
  });
}

// ============================================================
// Phase 15 — in-app updater
// ============================================================

/**
 * Check the manifest at `brew-browser.zerologic.com/updater.json` for
 * a newer release. Backend handles the version comparison, the
 * skip-list consultation, and the URL allowlist on the artifact URL
 * declared in the manifest.
 *
 * Throws `BrewErrorPayload` with `code === "paranoid_mode_blocked"`
 * (feature: "update_check") when Offline Mode is on; the store maps
 * this into `{ kind: "blocked" }` for UI ergonomics. Other typed
 * errors (network failure, malformed manifest, signature mismatch)
 * propagate to the caller for inline display.
 */
export function updateCheckNow(): Promise<UpdateCheckOutcome> {
  return invoke<UpdateCheckOutcome>("update_check_now");
}

/**
 * Download, verify, and install the named version. The backend
 * cross-checks `version` against the cached "available" entry from
 * the most recent `update_check_now` call — a stale UI request for
 * the wrong version fast-fails with `invalid_argument` rather than
 * downloading the wrong .dmg.
 *
 * Subject to the same Offline Mode gate as `update_check_now`. Long-
 * running; the renderer should disable the install button while in
 * flight and surface progress via the updater store's `installing`
 * flag. (Streaming progress events, if added later, would slot in
 * here with the same Channel-based pattern used by brew_install.)
 */
export function updateInstall(version: string): Promise<void> {
  return invoke<void>("update_install", { version });
}

/**
 * Add `version` to the skip-list so the title-bar indicator stops
 * surfacing for this release. A future release (any version newer
 * than the skipped one) re-triggers the indicator.
 *
 * The backend persists the skip-list inside `settings.json` as
 * `skipped_update_versions` (capped at 10, oldest evicted). If the
 * Backend Architect ends up exposing this through `settings_set`
 * instead of a dedicated command, this wrapper is the single
 * integration point to adjust.
 */
export function updateSkip(version: string): Promise<void> {
  return invoke<void>("update_skip", { version });
}

/**
 * Restart the running brew-browser process so the freshly-installed
 * .app picks up. Called from the "Relaunch now" affordance in the
 * Settings card after `updateInstall` resolves.
 *
 * The backend schedules `tauri::AppHandle::restart()` on a short
 * timer so the IPC response arrives before the process dies; the
 * renderer's pending `await` is expected to be torn down by the
 * restart (caller treats any error as benign).
 */
export function updateRelaunch(): Promise<void> {
  return invoke<void>("update_relaunch");
}

// ============================================================
// v0.5.0 — opt-in vulnerability scanning (brew vulns)
// ============================================================

/**
 * Full-install-set vulnerability scan. Gated end-to-end by
 * `vulnerabilityScanningEnabled` AND `paranoidMode === false` on the
 * backend.
 *
 * `force=true` bypasses the install-set-fingerprint skip predicate
 * (the Security tab's Refresh button uses this). When `false`, a
 * matching fingerprint serves the previous report from disk without
 * re-shelling — `report.source === "cache"` flags that path.
 *
 * Throws `feature_disabled` when the toggle is off,
 * `paranoid_mode_blocked` when Offline Mode is on, and
 * `vulns_not_installed` when the `brew vulns` subcommand hasn't been
 * installed yet (the UI shows the install affordance in that case).
 */
export function vulnsScanAll(force: boolean): Promise<VulnScanReport> {
  return invoke<VulnScanReport>("vulns_scan_all", { force });
}

/**
 * Scan a single formula by name. Used by the PackageDetail
 * "Check vulnerabilities" affordance. Gated identically to the full
 * scan. Caches the result on the backend when the installed version
 * is resolvable from `installed_cache`.
 */
export function vulnsScanOne(name: string): Promise<RawVuln[]> {
  return invoke<RawVuln[]>("vulns_scan_one", { name });
}

/**
 * One-click installer for the `brew vulns` subcommand. Runs
 * `brew install homebrew/brew-vulns/brew-vulns`. Returns the captured
 * stdout for Activity-drawer surfacing.
 *
 * **Gating note:** consults the master Offline Mode gate only — the
 * per-feature toggle is bypassed so users can install the helper
 * *before* flipping the toggle on (chicken-and-egg otherwise).
 */
export function vulnsInstallHelper(): Promise<string> {
  return invoke<string>("vulns_install_helper");
}

/**
 * Drop a single cache entry. Called by post-upgrade / post-uninstall
 * hooks so a CVE record for a version the user no longer has can't
 * outlive the version it referenced. Ungated — local cleanup is
 * always safe.
 */
export function vulnsInvalidate(
  kind: PackageKind,
  name: string,
  version: string,
): Promise<void> {
  return invoke<void>("vulns_invalidate", { kind, name, version });
}

/**
 * Bundles M1 — probe the host's capabilities (RAM, arch, disk, GPU class)
 * with zero installs. Small payload; the client-side `readiness()` gate in
 * `$lib/util/readiness` consumes it against each bundle's `requires`.
 */
export function systemProfile(): Promise<SystemProfile> {
  return invoke<SystemProfile>("system_profile");
}

/**
 * Bundles M2 — load the curated bundle recipes embedded in the app. A single
 * malformed recipe is skipped backend-side, so this always resolves with the
 * valid ones (never throws for a bad recipe). Readiness is computed
 * client-side via `$lib/util/readiness` against `systemProfile()`.
 */
export function bundles(locale?: string): Promise<Bundle[]> {
  return invoke<Bundle[]>("bundles", { locale });
}

/**
 * Bundles M5 — opt-in live refresh of the recipe set from the project host
 * (`brew-browser.zerologic.com/bundles/bundles.json`, one static-file GET).
 * Gated backend-side on the `liveBundlesEnabled` toggle + network (paranoid/
 * offline). Rejects on any failure (disabled, network, 404, parse, or a
 * newer-than-supported schema) — callers keep the bundled copy and replace
 * only on a non-empty result.
 */
export function bundlesLive(locale?: string): Promise<Bundle[]> {
  return invoke<Bundle[]>("bundles_live", { locale });
}

/**
 * Bundles M3 — install every package in a bundle. Mirrors `brewUpgradeMany`:
 * one streamed job (into Activity) that installs the set, then the caller
 * reloads `packages`. Because brew's `--formula`/`--cask` flags can't be mixed
 * in one invocation, a bundle with both kinds streams as two sequential steps
 * (formulae, then casks) — each emits its own `started`→`exit` lifecycle on
 * this channel, so the handler must cope with more than one `jobId`.
 */
export function brewInstallBundle(
  packages: BundlePackage[],
  onEvent: (evt: BrewStreamEvent) => void,
): Promise<JobResult> {
  return invoke<JobResult>("brew_install_bundle", {
    packages,
    onEvent: makeChannel(onEvent),
  });
}

// ============================================================
// Re-exports for convenience
// ============================================================

export type { Package };
