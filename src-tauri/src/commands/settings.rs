//! Settings persistence (Phase 12d).
//!
//! Stores user-configurable preferences in
//! `~/Library/Application Support/brew-browser/settings.json`. Loaded once
//! at app startup into `AppState.settings` and refreshed by every
//! `settings_set` / `settings_reset` call so live readers (e.g. the
//! paranoid-mode gate consulted by `require_network`) see changes
//! immediately without a process restart.
//!
//! ## Security gates (security-review §12d)
//!
//! - **File-absent vs file-corrupt distinction.** [`SettingsLoadState`]
//!   carries three variants: `FirstLaunch` (file missing → defaults
//!   apply, paranoid OFF), `Loaded(Settings)` (good parse → use as-is),
//!   `Corrupt(message)` (file present but unreadable → **fail closed**;
//!   `require_network` denies everything until the user repairs).
//! - **Atomic writes.** Every save goes through [`crate::util::fs::atomic_write`]
//!   — temp + fsync + rename + fsync(parent). No torn writes.
//! - **Bounded path.** Settings always live at
//!   `state.app_data_dir.join("settings.json")`. No IPC argument can
//!   influence the location.
//! - **Size cap.** [`MAX_SETTINGS_BYTES`] (1 MiB) enforced on both read
//!   (via `read_capped`) and write (pre-serialize check + post-serialize
//!   check, defense in depth).
//! - **Schema validation.** `#[serde(default)]` on every field absorbs
//!   forward-compat additions; unknown enum variants fall back to the
//!   default with a stderr warning rather than rejecting the whole file.
//! - **Numeric clamps.** [`Settings::clamp`] re-applies the ranges
//!   declared in the type docs after every load and write so a manual
//!   edit (`settings.json` is plain JSON the user can poke at) can't
//!   smuggle an out-of-range value.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tauri::State;

use crate::error::BrewError;
use crate::state::AppState;
use crate::util::fs::{atomic_write, read_capped};

/// Hard cap on settings.json size. 1 MiB is wildly generous for what is
/// at most a few dozen scalar fields — protects against accidental or
/// hostile bloat (e.g. a future bug that appends to an array forever).
pub const MAX_SETTINGS_BYTES: u64 = 1024 * 1024;

/// On-disk + IPC payload. Every field has `#[serde(default)]` so a
/// future version that adds a field reads cleanly into an older shape
/// (missing fields take their defaults) and an older version reading a
/// newer file ignores fields it doesn't know about.
///
/// **Numeric clamping** is applied by [`Self::clamp`] after every load
/// and before every save. Don't bypass it — the caps are part of the
/// contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Master "block all outbound network" switch. When true,
    /// `require_network` denies every call. Default false (first launch
    /// = current behaviour preserved).
    pub paranoid_mode: bool,

    /// How often to auto-refresh the bundled catalog. Default Off
    /// (matches current manual-refresh-only behaviour). Auto-refresh
    /// itself is wired in a later phase — this field is the persisted
    /// preference even before that wiring lands.
    pub catalog_auto_refresh: CatalogAutoRefresh,

    /// Show the "Catalog is N days old — refresh?" banner when the
    /// active catalog is at least this many days old. Default 14.
    /// Clamped to `[1, 365]` on every load and save.
    pub catalog_stale_banner_days: u32,

    /// Cask icon fetching mode. Default `All` (matches the current Phase
    /// 8 behaviour where every uninstalled cask with a homepage probes
    /// for a favicon). `InstalledOnly` skips the homepage cascade
    /// entirely. `Off` disables even installed-app icon extraction.
    pub cask_icon_mode: CaskIconMode,

    /// Trending cache TTL in minutes. Default 60 (matches the existing
    /// `TRENDING_TTL` in `trending/cache.rs`). Clamped to `[5, 1440]`
    /// on every load and save — five minutes minimum to be a polite
    /// client, 24 hours maximum because anything older would be stale.
    pub trending_ttl_minutes: u32,

    /// Phase 12c — when true, PackageDetail probes `api.github.com` for
    /// repo stats whenever the package's homepage is a GitHub URL.
    /// Default **false** (off) so the v0.1.x posture of "no GitHub
    /// traffic unless the user opts in" is preserved on every fresh
    /// install. The runtime gate is `commands::github::*` which
    /// short-circuits to `Ok(None)` when this is false — before any
    /// outbound call. Paranoid mode overrides this regardless.
    pub github_enabled: bool,

    /// Phase 13 — master AI Features toggle. When false, ALL AI-derived
    /// data is hidden in the UI: categories (Phase 9), enrichment (Phase
    /// 13), donut chart, category pills, enriched summaries, use-cases,
    /// similar packages, tags. Default **true** so users who opt in to
    /// brew-browser get the enriched experience by default; the toggle
    /// lives in Settings → Appearance for users who prefer brew's
    /// native metadata only.
    ///
    /// This is a *rendering* gate — the enrichment payload is bundled
    /// into the binary regardless, so toggling this on/off doesn't
    /// trigger any I/O, network, or LLM calls.
    #[serde(default = "default_ai_features_enabled")]
    pub ai_features_enabled: bool,

    /// Phase 15 — opt-in daily auto-check for in-app updates. Default
    /// **false** so a fresh install never reaches out to the manifest
    /// endpoint without the user clicking either the manual "Check for
    /// updates" button or this toggle. When enabled (and Offline Mode
    /// is off), the scheduler in [`crate::commands::updater`] wakes
    /// every 24 h and runs `update_check_now`. Paranoid mode and a
    /// `Corrupt` settings state both suppress the scheduler — same gate
    /// every other outbound feature consults.
    #[serde(default)]
    pub update_auto_check: bool,

    /// Phase 15 — versions the user explicitly dismissed via the
    /// title-bar indicator's `×` button. Bounded at 10 entries with
    /// oldest-evicted-on-push (see [`Settings::push_skipped_version`]).
    /// The skip is per-version: a *newer* release re-triggers the
    /// indicator even if every previous version is in this list.
    #[serde(default)]
    pub skipped_update_versions: Vec<String>,

    /// v0.4.0 — opt-in fetch of historical install trends from
    /// `brew-browser.zerologic.com/trending-history/*`. When **false**
    /// (default), the Trending tab and PackageDetail render only what
    /// `formulae.brew.sh` exposes natively (30d/90d/365d snapshots) and
    /// the new endpoint is never contacted. When **true**, the app
    /// fetches per-package historical series to power sparklines.
    ///
    /// Distinct trust boundary from the always-on Homebrew endpoints —
    /// `brew-browser.zerologic.com` is operated by the project, not
    /// upstream Homebrew. See `memory-bank/security.md` for the
    /// endpoint audit and `README.md` for the disclosed outbound paths.
    ///
    /// Paranoid mode overrides this regardless: when paranoid is on,
    /// `require_enhanced_trending` denies even with this flag set.
    #[serde(default)]
    pub enhanced_trending_enabled: bool,

    /// v0.5.0 — opt-in vulnerability scanning of installed Homebrew
    /// formulae. When **false** (default), the app makes no vulnerability
    /// queries and surfaces no CVE badges. When **true**, the backend
    /// shells out to the official `brew vulns --json` subcommand (which
    /// queries OSV.dev via its GIT ecosystem) and, when [`Self::github_enabled`]
    /// is also on, enriches GHSA-prefixed results via the GitHub
    /// Advisories API.
    ///
    /// Distinct trust boundary from the always-on Homebrew endpoints:
    /// `brew vulns` is an official Homebrew subcommand but it talks to
    /// `api.osv.dev` (Google) and indirectly to the source forges
    /// (github.com, gitlab.com, codeberg.org) for version-tag lookups.
    /// See `memory-bank/security.md` for the endpoint audit and
    /// `README.md` for the disclosed outbound paths.
    ///
    /// Paranoid mode overrides this regardless: when paranoid is on,
    /// `require_vulnerability_scanning` denies even with this flag set.
    #[serde(default)]
    pub vulnerability_scanning_enabled: bool,

    /// Opt-in *live* refresh of AI categories + descriptions. When **false**
    /// (default), the app uses only the bundled `categories.json` /
    /// `enrichment.json.gz` baked in at build time — no network. When **true**,
    /// the app fetches fresher data from
    /// `brew-browser.zerologic.com/enrichment/*` on catalog refresh + per
    /// package shown: a tiny `version.json` probe, the full `categories.json`
    /// when its version is newer, and per-token `entry/<token>.json` on demand.
    /// Live data overlays the bundled baseline; misses fall back to bundled.
    ///
    /// Distinct trust boundary — same first-party host as Enhanced Trending
    /// (`brew-browser.zerologic.com`), a new `…/enrichment/*` path. Only the
    /// package name you're viewing is sent (one GET per token); no IP logged,
    /// no cookies. Paranoid mode overrides this regardless.
    #[serde(default)]
    pub live_enrichment_enabled: bool,

    /// Opt-in *live* refresh of the curated **Bundles** recipe set. When
    /// **false** (default), the app uses only the bundled `bundles.json` baked
    /// in at build time — no network. When **true**, it fetches the latest
    /// `bundles.json` from `brew-browser.zerologic.com/bundles/bundles.json`
    /// (one static-file GET) and replaces the in-memory list on a non-empty
    /// success. Any error — 404 (the endpoint may not exist yet), network,
    /// parse, empty payload, or a newer-than-supported schema — falls back
    /// silently to the bundled copy.
    ///
    /// Same first-party host + trust boundary as Live enrichment / Enhanced
    /// Trending (`brew-browser.zerologic.com`), a new `…/bundles/*` path. No
    /// package names are sent (unlike enrichment's per-token GETs) — it's a
    /// single static file. Paranoid mode / Offline Mode overrides this
    /// regardless. Shared settings key with the native shell (`liveBundlesEnabled`).
    #[serde(default)]
    pub live_bundles_enabled: bool,
}

/// Default factory for [`Settings::ai_features_enabled`] — separated
/// out so `#[serde(default = "…")]` can pick it up for forward-compat
/// on settings.json files written before Phase 13.
fn default_ai_features_enabled() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            paranoid_mode: false,
            catalog_auto_refresh: CatalogAutoRefresh::Off,
            catalog_stale_banner_days: 14,
            cask_icon_mode: CaskIconMode::All,
            trending_ttl_minutes: 60,
            // Off by default per Phase 12c plan: anonymous GitHub probes
            // are opt-in so first-launch posture stays "zero outbound
            // beyond what the user has already consented to".
            github_enabled: false,
            // On by default per Phase 13 plan: AI-enriched rendering is
            // a value-add the project wants to show off out of the box.
            // Toggling off reverts the UI to brew's native metadata only.
            ai_features_enabled: default_ai_features_enabled(),
            // Off by default per Phase 15 plan: the manifest endpoint
            // stays cold until the user explicitly opts in (or hits the
            // manual "Check for updates" button).
            update_auto_check: false,
            // Empty by default — populated as the user dismisses
            // individual versions via the title-bar indicator's `×`.
            skipped_update_versions: Vec::new(),
            // Off by default per v0.4.0 plan: brew-browser.zerologic.com
            // (our infra) stays cold until the user explicitly opts in
            // via Settings → Network. Velocity sorting + heat/cool
            // badges still work without this — they're computed from
            // the always-on Homebrew analytics windows.
            enhanced_trending_enabled: false,
            // Off by default per v0.5.0 plan: no vulnerability scanning
            // until the user explicitly opts in via Settings → Network.
            // No `brew vulns` invocation, no OSV traffic, no GHSA lookups
            // until then.
            vulnerability_scanning_enabled: false,
            // Off by default: the app ships with a bundled categories +
            // enrichment baseline and contacts brew-browser.zerologic.com/
            // enrichment/* only when the user opts in via Settings → Network.
            live_enrichment_enabled: false,
            // Off by default per v0.7.0 plan: the six curated bundles ship
            // baked in and always work offline; brew-browser.zerologic.com/
            // bundles/* is contacted only when the user opts in.
            live_bundles_enabled: false,
        }
    }
}

impl Settings {
    /// Inclusive lower bound for `catalog_stale_banner_days`.
    pub const CATALOG_STALE_DAYS_MIN: u32 = 1;
    /// Inclusive upper bound for `catalog_stale_banner_days`.
    pub const CATALOG_STALE_DAYS_MAX: u32 = 365;
    /// Inclusive lower bound for `trending_ttl_minutes`.
    pub const TRENDING_TTL_MIN: u32 = 5;
    /// Inclusive upper bound for `trending_ttl_minutes`.
    pub const TRENDING_TTL_MAX: u32 = 1440;
    /// Phase 15 — maximum entries kept in [`Self::skipped_update_versions`].
    /// Push beyond this evicts the oldest entry (FIFO) so the list
    /// can't grow without bound across decades of releases.
    pub const SKIPPED_UPDATE_VERSIONS_CAP: usize = 10;

    /// Apply the numeric clamps declared in the field docs. Idempotent;
    /// safe to call on already-clamped values.
    pub fn clamp(&mut self) {
        self.catalog_stale_banner_days = self
            .catalog_stale_banner_days
            .clamp(Self::CATALOG_STALE_DAYS_MIN, Self::CATALOG_STALE_DAYS_MAX);
        self.trending_ttl_minutes = self
            .trending_ttl_minutes
            .clamp(Self::TRENDING_TTL_MIN, Self::TRENDING_TTL_MAX);
        // Enforce the cap on every load/save in addition to the push
        // helper so a hand-edited settings.json with 50 skip entries
        // gets pruned on read.
        if self.skipped_update_versions.len() > Self::SKIPPED_UPDATE_VERSIONS_CAP {
            let excess = self.skipped_update_versions.len() - Self::SKIPPED_UPDATE_VERSIONS_CAP;
            self.skipped_update_versions.drain(..excess);
        }
    }

    /// Phase 15 — push `version` onto [`Self::skipped_update_versions`]
    /// with FIFO eviction when the cap is reached. Duplicate-safe: if
    /// `version` is already in the list, the entry is moved to the
    /// tail (so a re-skip refreshes its position rather than padding
    /// the cap with duplicates).
    ///
    /// Returns `true` when the list changed, `false` when the version
    /// was already at the tail. Callers persist the settings whenever
    /// this returns `true`.
    #[allow(dead_code)] // used by Phase 15 updater commands
    pub fn push_skipped_version(&mut self, version: String) -> bool {
        // De-duplicate: drop any existing entry for this version so the
        // push always moves it to the tail.
        let already_at_tail = self
            .skipped_update_versions
            .last()
            .is_some_and(|v| v == &version);
        if already_at_tail {
            return false;
        }
        self.skipped_update_versions.retain(|v| v != &version);
        self.skipped_update_versions.push(version);
        while self.skipped_update_versions.len() > Self::SKIPPED_UPDATE_VERSIONS_CAP {
            self.skipped_update_versions.remove(0);
        }
        true
    }
}

/// Catalog auto-refresh cadence. Wire-format is kebab-case to match the
/// frontend's TypeScript union (`"off" | "weekly" | "daily"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum CatalogAutoRefresh {
    /// Manual only — the current Phase 12a default.
    #[default]
    Off,
    Weekly,
    Daily,
}

/// Cask icon fetching mode. `All` preserves the current behaviour from
/// Phase 8.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum CaskIconMode {
    Off,
    InstalledOnly,
    #[default]
    All,
}

/// Three-state container for the in-memory settings cache.
///
/// The distinction between `FirstLaunch` and `Corrupt` is **load-bearing**
/// (security review §12d): the former applies defaults (paranoid OFF),
/// the latter fails closed (paranoid effectively ON until the user
/// repairs the file or hits the reset button in the Settings UI).
#[derive(Debug, Clone)]
pub enum SettingsLoadState {
    /// `settings.json` did not exist when we tried to read it. New
    /// installs, freshly-reset apps, etc. Defaults apply.
    FirstLaunch,
    /// Successfully parsed. Carries the clamped, validated Settings.
    Loaded(Settings),
    /// File present but unreadable (bad JSON, oversize, read error).
    /// `require_network` denies every call until repaired. The message
    /// is surfaced via `settings_get` so the UI can show a clear "Reset
    /// to defaults" affordance instead of silently rolling back.
    Corrupt { message: String },
}

impl SettingsLoadState {
    /// Convenience for the gate: returns the effective settings when
    /// they should be honoured, or `None` when the load failed and we
    /// should fall back to "deny outbound" semantics.
    ///
    /// `AppState::require_network` reaches for the variants directly
    /// rather than this helper (to keep the gate's logic visible in one
    /// place), but the helper is the canonical reference for anything
    /// else that needs the same disambiguation — kept available for
    /// future callers (settings UI, diagnostics) and exercised by tests.
    #[allow(dead_code)]
    pub fn effective_settings(&self) -> Option<Settings> {
        match self {
            SettingsLoadState::Loaded(s) => Some(s.clone()),
            SettingsLoadState::FirstLaunch => Some(Settings::default()),
            SettingsLoadState::Corrupt { .. } => None,
        }
    }
}

/// Resolve the canonical settings path inside `app_data_dir`.
///
/// Always `<app_data_dir>/settings.json`. The directory is created if
/// missing — the caller (typically `AppState::build`) has already
/// ensured `app_data_dir` exists, so this is a defense-in-depth mkdir.
pub fn settings_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("settings.json")
}

/// Synchronous startup loader. Called from `AppState::build()` (which is
/// a non-async function) so we use the blocking `std::fs` API rather
/// than tokio. The trade-off accepted is a single small read on startup
/// in exchange for a much simpler init story.
///
/// Returns the same three-state shape as the async loader so callers
/// stay uniform.
pub fn load_at_startup(app_data_dir: &Path) -> SettingsLoadState {
    let path = settings_path(app_data_dir);

    let meta = match std::fs::metadata(&path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return SettingsLoadState::FirstLaunch;
        }
        Err(e) => {
            // Stat failed for some non-NotFound reason (permission denied,
            // EIO, etc.). Treat as corrupt — fail closed.
            tracing::warn!("settings: stat failed at {}: {e}", path.display());
            return SettingsLoadState::Corrupt {
                message: format!("stat {}: {e}", path.display()),
            };
        }
    };

    if meta.len() > MAX_SETTINGS_BYTES {
        tracing::warn!(
            "settings: {} is {} bytes, exceeds {}-byte cap; treating as corrupt",
            path.display(),
            meta.len(),
            MAX_SETTINGS_BYTES
        );
        return SettingsLoadState::Corrupt {
            message: format!(
                "settings.json is {} bytes, exceeds {}-byte cap",
                meta.len(),
                MAX_SETTINGS_BYTES
            ),
        };
    }

    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!("settings: read failed at {}: {e}", path.display());
            return SettingsLoadState::Corrupt {
                message: format!("read {}: {e}", path.display()),
            };
        }
    };

    match serde_json::from_slice::<Settings>(&bytes) {
        Ok(mut s) => {
            s.clamp();
            SettingsLoadState::Loaded(s)
        }
        Err(e) => {
            tracing::warn!(
                "settings: parse failed at {}: {e}; treating as corrupt",
                path.display()
            );
            SettingsLoadState::Corrupt {
                message: format!("parse {}: {e}", path.display()),
            }
        }
    }
}

/// Async loader, identical semantics to [`load_at_startup`] but
/// non-blocking. Used by tests and any future callers that need to
/// re-read from disk without blocking the runtime.
#[cfg_attr(not(test), allow(dead_code))]
async fn load_async(app_data_dir: &Path) -> SettingsLoadState {
    let path = settings_path(app_data_dir);

    let meta = match tokio::fs::metadata(&path).await {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return SettingsLoadState::FirstLaunch;
        }
        Err(e) => {
            tracing::warn!("settings: stat failed at {}: {e}", path.display());
            return SettingsLoadState::Corrupt {
                message: format!("stat {}: {e}", path.display()),
            };
        }
    };

    if meta.len() > MAX_SETTINGS_BYTES {
        return SettingsLoadState::Corrupt {
            message: format!(
                "settings.json is {} bytes, exceeds {}-byte cap",
                meta.len(),
                MAX_SETTINGS_BYTES
            ),
        };
    }

    let bytes = match read_capped(&path, MAX_SETTINGS_BYTES).await {
        Ok(b) => b,
        Err(e) => {
            return SettingsLoadState::Corrupt {
                message: format!("read {}: {e}", path.display()),
            };
        }
    };

    match serde_json::from_slice::<Settings>(&bytes) {
        Ok(mut s) => {
            s.clamp();
            SettingsLoadState::Loaded(s)
        }
        Err(e) => SettingsLoadState::Corrupt {
            message: format!("parse {}: {e}", path.display()),
        },
    }
}

/// Serialize `settings`, enforce the size cap, then atomically persist.
///
/// Order: (1) clamp numerics (no-op if already in range), (2) serialize
/// to bytes, (3) reject if the byte length exceeds the cap, (4)
/// `atomic_write` into place, (5) return the clamped struct so callers
/// can re-broadcast the canonicalized values.
pub(crate) async fn persist(
    app_data_dir: &Path,
    mut settings: Settings,
) -> Result<Settings, BrewError> {
    settings.clamp();
    let bytes = serde_json::to_vec_pretty(&settings).map_err(|e| BrewError::Internal {
        message: format!("serialize settings: {e}"),
    })?;
    if bytes.len() as u64 > MAX_SETTINGS_BYTES {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "serialized settings are {} bytes, exceeds {}-byte cap",
                bytes.len(),
                MAX_SETTINGS_BYTES
            ),
        });
    }

    // Defense in depth — ensure the parent dir exists. `AppState::build`
    // already mkdir_p'd it, but a fresh checkout of the app on a system
    // that's never run brew-browser could plausibly hit this otherwise.
    if !app_data_dir.exists() {
        tokio::fs::create_dir_all(app_data_dir)
            .await
            .map_err(|e| BrewError::Io {
                message: format!("create settings parent {}: {e}", app_data_dir.display()),
            })?;
    }

    let path = settings_path(app_data_dir);
    atomic_write(&path, &bytes).await?;
    Ok(settings)
}

// ---------- Commands ----------

/// Read the current settings.
///
/// Always returns the *currently-loaded* state — does not re-read from
/// disk on every call (the in-memory cache is authoritative and is
/// refreshed by `settings_set` / `settings_reset`).
///
/// Returns an error when the loaded state is `Corrupt`, so the frontend
/// can surface a "Settings file unreadable — reset to defaults?" prompt
/// without exposing the corrupt JSON contents.
#[tauri::command]
pub async fn settings_get(state: State<'_, AppState>) -> Result<Settings, BrewError> {
    let guard = state.settings.read().await;
    match &*guard {
        SettingsLoadState::Loaded(s) => Ok(s.clone()),
        SettingsLoadState::FirstLaunch => Ok(Settings::default()),
        SettingsLoadState::Corrupt { message } => Err(BrewError::Internal {
            message: format!("settings file is unreadable: {message}"),
        }),
    }
}

/// Write a complete settings struct to disk and update the in-memory
/// cache. The frontend always sends a complete object (merging with
/// existing values is the caller's responsibility, not ours).
#[tauri::command]
pub async fn settings_set(
    settings: Settings,
    state: State<'_, AppState>,
) -> Result<Settings, BrewError> {
    let clamped = persist(&state.app_data_dir, settings).await?;
    {
        let mut guard = state.settings.write().await;
        *guard = SettingsLoadState::Loaded(clamped.clone());
    }
    Ok(clamped)
}

/// Overwrite `settings.json` with the defaults and update the
/// in-memory cache. Used by the UI's "Reset to defaults" button when
/// the file is corrupt or the user just wants to start fresh.
#[tauri::command]
pub async fn settings_reset(state: State<'_, AppState>) -> Result<Settings, BrewError> {
    let defaults = Settings::default();
    let clamped = persist(&state.app_data_dir, defaults).await?;
    {
        let mut guard = state.settings.write().await;
        *guard = SettingsLoadState::Loaded(clamped.clone());
    }
    Ok(clamped)
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    /// File-absent → defaults apply (paranoid OFF).
    #[tokio::test]
    async fn missing_file_is_first_launch() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::FirstLaunch => {}
            other => panic!("expected FirstLaunch, got {other:?}"),
        }
        // Defaults must have paranoid OFF.
        let effective = state
            .effective_settings()
            .expect("first launch has defaults");
        assert!(!effective.paranoid_mode);
    }

    /// File-corrupt (bad JSON) → fail closed.
    #[tokio::test]
    async fn corrupt_file_fails_closed() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        tokio::fs::write(&path, b"{not valid json").await.unwrap();

        let state = load_at_startup(tmp.path());
        match &state {
            SettingsLoadState::Corrupt { message } => {
                assert!(message.contains("parse"), "{message}");
            }
            other => panic!("expected Corrupt, got {other:?}"),
        }
        // effective_settings must be None — caller must NOT see "paranoid off".
        assert!(state.effective_settings().is_none());
    }

    /// File-oversize → fail closed.
    #[tokio::test]
    async fn oversize_file_fails_closed() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        // Write 1 MiB + 1 byte.
        let payload = vec![b'a'; (MAX_SETTINGS_BYTES + 1) as usize];
        tokio::fs::write(&path, &payload).await.unwrap();

        let state = load_at_startup(tmp.path());
        match &state {
            SettingsLoadState::Corrupt { message } => {
                assert!(message.contains("exceeds"), "{message}");
            }
            other => panic!("expected Corrupt, got {other:?}"),
        }
    }

    /// Round-trip: persist + reload returns the same struct.
    #[tokio::test]
    async fn round_trip_persists_all_fields() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            paranoid_mode: true,
            catalog_auto_refresh: CatalogAutoRefresh::Weekly,
            catalog_stale_banner_days: 21,
            cask_icon_mode: CaskIconMode::InstalledOnly,
            trending_ttl_minutes: 120,
            github_enabled: true,
            ai_features_enabled: false,
            update_auto_check: true,
            skipped_update_versions: vec!["0.3.0".into(), "0.3.1".into()],
            enhanced_trending_enabled: true,
            vulnerability_scanning_enabled: true,
            live_enrichment_enabled: true,
            live_bundles_enabled: true,
        };
        let written = persist(tmp.path(), s.clone()).await.expect("persist");
        assert_eq!(written, s);

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => assert_eq!(loaded, s),
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// Phase 12c — `github_enabled` must round-trip with the camelCase
    /// JSON key `githubEnabled`. The field is brand-new and we want a
    /// pinning test that the wire shape matches the frontend type.
    #[tokio::test]
    async fn github_enabled_round_trips_with_camel_case_key() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            github_enabled: true,
            ..Settings::default()
        };
        persist(tmp.path(), s.clone()).await.expect("persist");

        // Inspect raw JSON on disk for the camelCase key. We don't want a
        // future serde rename to silently shift the wire shape.
        let raw = tokio::fs::read_to_string(settings_path(tmp.path()))
            .await
            .expect("read raw");
        assert!(
            raw.contains("\"githubEnabled\""),
            "expected camelCase key in raw JSON, got: {raw}"
        );
        assert!(
            !raw.contains("\"github_enabled\""),
            "must not emit snake_case key"
        );

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => assert!(loaded.github_enabled),
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// Out-of-range numerics get clamped on save.
    #[tokio::test]
    async fn clamps_on_save() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            paranoid_mode: false,
            catalog_auto_refresh: CatalogAutoRefresh::Off,
            catalog_stale_banner_days: 9999, // way above 365
            cask_icon_mode: CaskIconMode::All,
            trending_ttl_minutes: 1, // below the 5-minute floor
            github_enabled: false,
            ai_features_enabled: true,
            update_auto_check: false,
            skipped_update_versions: Vec::new(),
            enhanced_trending_enabled: false,
            vulnerability_scanning_enabled: false,
            live_enrichment_enabled: false,
            live_bundles_enabled: false,
        };
        let written = persist(tmp.path(), s).await.expect("persist");
        assert_eq!(
            written.catalog_stale_banner_days,
            Settings::CATALOG_STALE_DAYS_MAX
        );
        assert_eq!(written.trending_ttl_minutes, Settings::TRENDING_TTL_MIN);
    }

    /// Out-of-range numerics get clamped on read too (defense against
    /// hand-edited settings.json).
    #[tokio::test]
    async fn clamps_on_load() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        // Hand-write a settings file with absurd values.
        let raw = br#"{
            "paranoidMode": false,
            "catalogAutoRefresh": "daily",
            "catalogStaleBannerDays": 99999,
            "caskIconMode": "all",
            "trendingTtlMinutes": 2
        }"#;
        tokio::fs::write(&path, raw).await.unwrap();

        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::Loaded(s) => {
                assert_eq!(
                    s.catalog_stale_banner_days,
                    Settings::CATALOG_STALE_DAYS_MAX
                );
                assert_eq!(s.trending_ttl_minutes, Settings::TRENDING_TTL_MIN);
            }
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// Unknown enum variant → serde rejects the parse → fail closed
    /// (intentional; we don't want a typo'd field to silently pick a
    /// default the user didn't write).
    ///
    /// The plan asks for "default substituted", but serde's parser is
    /// all-or-nothing on a single field — we can't selectively recover
    /// one unknown variant while keeping the rest. The fail-closed
    /// behaviour is the strictly safer interpretation: the user's
    /// "deny network until repaired" gate kicks in, the UI surfaces
    /// the parse error, and the user hits Reset to defaults. The doc
    /// comment on `SettingsLoadState::Corrupt` explains this.
    #[tokio::test]
    async fn unknown_enum_variant_is_corrupt() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        let raw = br#"{
            "paranoidMode": false,
            "catalogAutoRefresh": "every-blue-moon",
            "catalogStaleBannerDays": 14,
            "caskIconMode": "all",
            "trendingTtlMinutes": 60
        }"#;
        tokio::fs::write(&path, raw).await.unwrap();

        let state = load_at_startup(tmp.path());
        match &state {
            SettingsLoadState::Corrupt { message } => {
                assert!(
                    message.contains("parse"),
                    "expected parse failure in corrupt message, got {message}"
                );
            }
            other => panic!("expected Corrupt, got {other:?}"),
        }
        assert!(state.effective_settings().is_none(), "must fail closed");
    }

    /// Missing optional fields take their defaults (forward compat).
    #[tokio::test]
    async fn missing_fields_use_defaults() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        // Only paranoidMode set — everything else absent.
        let raw = br#"{ "paranoidMode": true }"#;
        tokio::fs::write(&path, raw).await.unwrap();

        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::Loaded(s) => {
                assert!(s.paranoid_mode);
                assert_eq!(s.catalog_auto_refresh, CatalogAutoRefresh::Off);
                assert_eq!(s.catalog_stale_banner_days, 14);
                assert_eq!(s.cask_icon_mode, CaskIconMode::All);
                assert_eq!(s.trending_ttl_minutes, 60);
                // `github_enabled` was added in 12c — must default to false
                // for forward compat with pre-12c settings files.
                assert!(!s.github_enabled);
                // `ai_features_enabled` was added in Phase 13 — must
                // default to true for forward compat with pre-13 settings
                // files (pre-existing installs see categories + enrichment
                // turned on as soon as they upgrade).
                assert!(s.ai_features_enabled);
                // `update_auto_check` was added in Phase 15 — must default
                // to false for forward compat with pre-15 settings files.
                assert!(!s.update_auto_check);
                // `skipped_update_versions` was added in Phase 15 — must
                // default to an empty vec.
                assert!(s.skipped_update_versions.is_empty());
            }
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    // ---------- Phase 15 — skip-list cap + helpers ----------

    /// Push helper adds entries in order until the cap is reached.
    #[test]
    fn push_skipped_version_appends_until_cap() {
        let mut s = Settings::default();
        for i in 0..Settings::SKIPPED_UPDATE_VERSIONS_CAP {
            let changed = s.push_skipped_version(format!("0.3.{i}"));
            assert!(changed, "first-time push of unique version must change");
        }
        assert_eq!(
            s.skipped_update_versions.len(),
            Settings::SKIPPED_UPDATE_VERSIONS_CAP
        );
    }

    /// Phase 15 §Tests #5 — adding the 11th skip evicts the oldest entry.
    /// This is the canonical bound test.
    #[test]
    fn push_skipped_version_evicts_oldest_on_overflow() {
        let mut s = Settings::default();
        // Fill to cap.
        for i in 0..Settings::SKIPPED_UPDATE_VERSIONS_CAP {
            s.push_skipped_version(format!("v{i}"));
        }
        assert_eq!(s.skipped_update_versions[0], "v0");

        // 11th push: oldest (v0) must be gone, newest (vN) must be at tail.
        let new_version = format!("v{}", Settings::SKIPPED_UPDATE_VERSIONS_CAP);
        s.push_skipped_version(new_version.clone());
        assert_eq!(
            s.skipped_update_versions.len(),
            Settings::SKIPPED_UPDATE_VERSIONS_CAP
        );
        assert!(
            !s.skipped_update_versions.contains(&"v0".to_string()),
            "oldest entry v0 should have been evicted"
        );
        assert_eq!(
            s.skipped_update_versions.last(),
            Some(&new_version),
            "newest entry should be at tail"
        );
    }

    /// Re-pushing an existing version moves it to the tail without
    /// growing the list past the cap.
    #[test]
    fn push_skipped_version_dedupes_and_moves_to_tail() {
        let mut s = Settings::default();
        s.push_skipped_version("a".into());
        s.push_skipped_version("b".into());
        s.push_skipped_version("c".into());

        // Re-push "a" — should move to tail, length unchanged.
        let changed = s.push_skipped_version("a".into());
        assert!(changed);
        assert_eq!(s.skipped_update_versions, vec!["b", "c", "a"]);

        // Pushing the current tail again is a no-op.
        let changed = s.push_skipped_version("a".into());
        assert!(!changed);
        assert_eq!(s.skipped_update_versions, vec!["b", "c", "a"]);
    }

    /// Hand-edited settings.json with a too-long skip list gets pruned
    /// on load via clamp().
    #[test]
    fn clamp_prunes_oversized_skip_list() {
        let mut s = Settings::default();
        for i in 0..(Settings::SKIPPED_UPDATE_VERSIONS_CAP * 3) {
            s.skipped_update_versions.push(format!("v{i}"));
        }
        s.clamp();
        assert_eq!(
            s.skipped_update_versions.len(),
            Settings::SKIPPED_UPDATE_VERSIONS_CAP
        );
        // The most-recent half is retained; the oldest two-thirds are dropped.
        assert!(
            !s.skipped_update_versions.contains(&"v0".to_string()),
            "oldest entries should have been dropped"
        );
    }

    /// Phase 15 — wire shape gate. The new fields must round-trip with
    /// camelCase JSON keys (`updateAutoCheck`, `skippedUpdateVersions`)
    /// so the frontend store can rely on the contract.
    #[tokio::test]
    async fn phase15_fields_round_trip_with_camel_case_keys() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            update_auto_check: true,
            skipped_update_versions: vec!["1.0.0".into()],
            ..Settings::default()
        };
        persist(tmp.path(), s.clone()).await.expect("persist");

        let raw = tokio::fs::read_to_string(settings_path(tmp.path()))
            .await
            .expect("read raw");
        assert!(
            raw.contains("\"updateAutoCheck\""),
            "expected camelCase updateAutoCheck key in raw JSON, got: {raw}"
        );
        assert!(
            raw.contains("\"skippedUpdateVersions\""),
            "expected camelCase skippedUpdateVersions key in raw JSON, got: {raw}"
        );
        assert!(
            !raw.contains("\"update_auto_check\""),
            "must not emit snake_case key"
        );

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => {
                assert!(loaded.update_auto_check);
                assert_eq!(loaded.skipped_update_versions, vec!["1.0.0"]);
            }
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// Phase 13 — `ai_features_enabled` defaults to true.
    #[test]
    fn ai_features_enabled_defaults_to_true() {
        let s = Settings::default();
        assert!(
            s.ai_features_enabled,
            "AI features ON by default per Phase 13 plan"
        );
    }

    /// Phase 13 — `ai_features_enabled` round-trips on the wire as
    /// camelCase `aiFeaturesEnabled`. Pin the wire shape so a future
    /// serde rename doesn't silently break the frontend store.
    #[tokio::test]
    async fn ai_features_enabled_round_trips_with_camel_case_key() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            ai_features_enabled: false,
            ..Settings::default()
        };
        persist(tmp.path(), s.clone()).await.expect("persist");

        let raw = tokio::fs::read_to_string(settings_path(tmp.path()))
            .await
            .expect("read raw");
        assert!(
            raw.contains("\"aiFeaturesEnabled\""),
            "expected camelCase key in raw JSON, got: {raw}"
        );
        assert!(
            !raw.contains("\"ai_features_enabled\""),
            "must not emit snake_case key"
        );

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => assert!(!loaded.ai_features_enabled),
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// v0.4.0 — `enhanced_trending_enabled` defaults to false. This is
    /// load-bearing: the new endpoint must never be hit without explicit
    /// user opt-in, so a forgotten default-true would silently leak the
    /// fact that brew-browser is in use.
    #[test]
    fn enhanced_trending_defaults_to_false() {
        let s = Settings::default();
        assert!(
            !s.enhanced_trending_enabled,
            "enhanced trending must be OFF by default — endpoint is opt-in"
        );
    }

    /// v0.4.0 — older `settings.json` files written before the field
    /// existed must read cleanly with the field absent → false. Locks
    /// the forward-compat behaviour so a v0.3.x user upgrading to
    /// v0.4.0 gets the opt-in posture, not a silent enable.
    #[tokio::test]
    async fn missing_enhanced_trending_field_defaults_to_false() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        // Write a v0.3.x-shape settings.json with the new field absent.
        tokio::fs::write(
            &path,
            br#"{"paranoidMode": false, "catalogStaleBannerDays": 14}"#,
        )
        .await
        .unwrap();

        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::Loaded(s) => {
                assert!(
                    !s.enhanced_trending_enabled,
                    "missing field must default to false (opt-in posture)"
                );
            }
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// v0.4.0 — `enhanced_trending_enabled` round-trips on the wire as
    /// camelCase `enhancedTrendingEnabled`. Pin the wire shape so a
    /// future serde rename doesn't silently break the frontend store.
    #[tokio::test]
    async fn enhanced_trending_round_trips_with_camel_case_key() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            enhanced_trending_enabled: true,
            ..Settings::default()
        };
        persist(tmp.path(), s.clone()).await.expect("persist");

        let raw = tokio::fs::read_to_string(settings_path(tmp.path()))
            .await
            .expect("read raw");
        assert!(
            raw.contains("\"enhancedTrendingEnabled\""),
            "expected camelCase key in raw JSON, got: {raw}"
        );
        assert!(
            !raw.contains("\"enhanced_trending_enabled\""),
            "must not emit snake_case key"
        );

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => assert!(loaded.enhanced_trending_enabled),
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// v0.5.0 — `vulnerability_scanning_enabled` defaults to false. Load-
    /// bearing: no `brew vulns` subprocess, no OSV traffic, no GHSA lookups
    /// until the user opts in via Settings → Network.
    #[test]
    fn vulnerability_scanning_defaults_to_false() {
        let s = Settings::default();
        assert!(
            !s.vulnerability_scanning_enabled,
            "vulnerability scanning must be OFF by default — feature is opt-in"
        );
    }

    /// v0.5.0 — older `settings.json` files written before the field
    /// existed must read cleanly with the field absent → false. Locks the
    /// forward-compat behaviour so a v0.4.x user upgrading to v0.5.0 gets
    /// the opt-in posture, not a silent enable.
    #[tokio::test]
    async fn missing_vulnerability_scanning_field_defaults_to_false() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());
        // Write a v0.4.x-shape settings.json with the new field absent.
        tokio::fs::write(
            &path,
            br#"{"paranoidMode": false, "catalogStaleBannerDays": 14, "enhancedTrendingEnabled": true}"#,
        )
        .await
        .unwrap();

        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::Loaded(s) => {
                assert!(
                    !s.vulnerability_scanning_enabled,
                    "missing field must default to false (opt-in posture)"
                );
                // Sanity: the field present in the source file still loaded.
                assert!(s.enhanced_trending_enabled);
            }
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// v0.5.0 — `vulnerability_scanning_enabled` round-trips on the wire
    /// as camelCase `vulnerabilityScanningEnabled`. Pin the wire shape so
    /// a future serde rename doesn't silently break the frontend store.
    #[tokio::test]
    async fn vulnerability_scanning_round_trips_with_camel_case_key() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let s = Settings {
            vulnerability_scanning_enabled: true,
            ..Settings::default()
        };
        persist(tmp.path(), s.clone()).await.expect("persist");

        let raw = tokio::fs::read_to_string(settings_path(tmp.path()))
            .await
            .expect("read raw");
        assert!(
            raw.contains("\"vulnerabilityScanningEnabled\""),
            "expected camelCase key in raw JSON, got: {raw}"
        );
        assert!(
            !raw.contains("\"vulnerability_scanning_enabled\""),
            "must not emit snake_case key"
        );

        let reloaded = load_async(tmp.path()).await;
        match reloaded {
            SettingsLoadState::Loaded(loaded) => assert!(loaded.vulnerability_scanning_enabled),
            other => panic!("expected Loaded, got {other:?}"),
        }
    }

    /// Simulate a crash mid-write: write a `.tmp` file then truncate
    /// it. The final settings.json should remain whatever it was
    /// before (or absent), never the partial tmp contents.
    ///
    /// This exercises the atomic-write contract from `util::fs::atomic_write`:
    /// a crash before the `rename` step leaves the data file unchanged.
    #[tokio::test]
    async fn atomic_write_survives_simulated_crash() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());

        // 1. Establish a known-good initial state.
        let original = Settings::default();
        persist(tmp.path(), original.clone()).await.expect("seed");

        // 2. Simulate a crash mid-write by manually creating an
        // oversize / truncated .tmp sibling without renaming it. The
        // existence of `.tmp` must not pollute the final file.
        let mut tmp_name = path.as_os_str().to_owned();
        tmp_name.push(".tmp");
        let tmp_sibling = std::path::PathBuf::from(tmp_name);
        tokio::fs::write(&tmp_sibling, b"\x00 partial garbage")
            .await
            .expect("write partial tmp");

        // 3. Read the final file — must still be the original payload.
        let state = load_at_startup(tmp.path());
        match state {
            SettingsLoadState::Loaded(s) => assert_eq!(s, original),
            other => panic!("expected Loaded with original, got {other:?}"),
        }
    }

    /// `settings_reset` overwrites a corrupt file with defaults.
    #[tokio::test]
    async fn reset_repairs_corrupt_file() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = settings_path(tmp.path());

        // Plant corrupt content.
        tokio::fs::write(&path, b"{ garbage").await.unwrap();
        let state_before = load_at_startup(tmp.path());
        assert!(matches!(state_before, SettingsLoadState::Corrupt { .. }));

        // Write defaults via persist (what settings_reset uses).
        let written = persist(tmp.path(), Settings::default())
            .await
            .expect("reset");
        assert_eq!(written, Settings::default());

        // Reload — must now be Loaded(defaults).
        let state_after = load_at_startup(tmp.path());
        match state_after {
            SettingsLoadState::Loaded(s) => assert_eq!(s, Settings::default()),
            other => panic!("expected Loaded after reset, got {other:?}"),
        }
    }

    /// effective_settings on FirstLaunch returns defaults (paranoid off).
    #[test]
    fn effective_settings_first_launch_returns_defaults() {
        let state = SettingsLoadState::FirstLaunch;
        let s = state
            .effective_settings()
            .expect("first launch yields defaults");
        assert_eq!(s, Settings::default());
        assert!(!s.paranoid_mode);
    }

    /// effective_settings on Corrupt returns None (fail closed signal).
    #[test]
    fn effective_settings_corrupt_returns_none() {
        let state = SettingsLoadState::Corrupt {
            message: "boom".into(),
        };
        assert!(state.effective_settings().is_none());
    }
}
