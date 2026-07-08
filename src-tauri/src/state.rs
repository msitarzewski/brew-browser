//! Tauri-managed application state.
//!
//! - `brew_path` is detected once at startup.
//! - `brew_write_lock` serializes every WRITE invocation of `brew`.
//!   Reads bypass it (per `decisions.md` and `backendApi.md` §5).
//! - `jobs` tracks in-flight streaming children so `cancel_job` can find them.
//! - `trending_cache` is a small per-window TTL cache for `formulae.brew.sh`.
//! - `installed_cache` is invalidated after every WRITE so the next
//!   `brew_list` reflects reality.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use tokio::sync::{oneshot, Mutex, RwLock};
use uuid::Uuid;

use crate::brew::paths::resolve_brew_path;
use crate::catalog::Catalog;
use crate::commands::categories::CategoriesData;
use crate::commands::disk_usage::CachedDiskUsage;
use crate::commands::services::CachedServices;
use crate::commands::settings::{self, SettingsLoadState};
use crate::commands::updater::UpdaterState;
use crate::enrichment::EnrichmentData;
use crate::error::BrewError;
use crate::trending::cache::TrendingCache;
use crate::trending::history::cache::TrendingHistoryCache;
use crate::types::{BrewEnvironment, PackageList};
use crate::vulns::cache::VulnsCache;

/// Per-job handle stored in `AppState.jobs`. The streaming task holds
/// the actual `Child`; this struct holds enough to identify and cancel it.
pub struct JobHandle {
    /// PID of the spawned brew child. Surfaced for diagnostics
    /// (currently consumed only by future "show pid in console" features).
    #[allow(dead_code)]
    pub child_id: u32,
    /// Wall-clock instant the job began. Used for "elapsed" displays
    /// in future drawer headers.
    #[allow(dead_code)]
    pub started_at: Instant,
    /// Sender used to ask the streaming task to kill its child.
    /// `take()`-d on first cancel so subsequent calls are a no-op.
    pub cancel_tx: Option<oneshot::Sender<()>>,
}

/// Shared application state. Registered via `Builder::manage()`.
pub struct AppState {
    /// Path to the resolved `brew` binary. `None` if brew wasn't found
    /// at startup — commands consult this and return `BrewError::BrewNotFound`.
    pub brew_path: RwLock<Option<PathBuf>>,

    /// Cached brew environment (version, prefix).
    pub brew_env: RwLock<BrewEnvironment>,

    /// Single coarse write lock. Held for the duration of any
    /// state-mutating brew invocation. Trade-off accepted: at UI scale
    /// (one user, one window) the queueing is invisible.
    pub brew_write_lock: Arc<Mutex<()>>,

    /// In-flight streaming jobs, keyed by job_id.
    pub jobs: Arc<Mutex<HashMap<Uuid, JobHandle>>>,

    /// Trending analytics cache (per-window TTL).
    pub trending_cache: Arc<Mutex<TrendingCache>>,

    /// v0.4.0 — opt-in trending-history cache for the
    /// `brew-browser.zerologic.com/trending-history/*` endpoint.
    /// Separate from `trending_cache` because the trust boundary is
    /// different (project infra vs. Homebrew first-party) and the TTL
    /// is longer (6h vs. 1h default).
    pub trending_history_cache: Arc<Mutex<TrendingHistoryCache>>,

    /// v0.5.0 — opt-in vulnerability-scan cache for `brew vulns`
    /// output. Persisted to `<app_data_dir>/vulns_cache.json` so the
    /// install-set fingerprint survives across app launches and we
    /// don't re-shell out to brew-vulns on every startup when nothing
    /// has changed. Loaded lazily on first scan (avoids paying the
    /// disk-read cost when the user never opts in).
    pub vulns_cache: Arc<Mutex<VulnsCache>>,

    /// Resolved app-data directory for Brewfiles.
    pub brewfiles_dir: PathBuf,

    /// Resolved app-data root for caches (icons, etc.).
    /// Currently: `~/Library/Application Support/brew-browser/`.
    /// `cask_icon` writes converted PNGs to `<cache_dir>/icons/<token>.png`.
    pub cache_dir: PathBuf,

    /// Resolved app-data root — the OS-canonical
    /// `~/Library/Application Support/brew-browser/` directory that owns
    /// both `cache_dir` and `brewfiles_dir`. Surfaced separately from
    /// `cache_dir` (even though today they happen to be the same path)
    /// so the security gates that check "is this path inside our app
    /// data dir?" stay correct if either subdir is relocated later.
    /// Used by the brewfile import/export sandbox checks
    /// (`is_safe_export_target`).
    pub app_data_dir: PathBuf,

    /// Cached package list for cross-referencing (e.g. trending
    /// "installed" flag). Invalidated after every WRITE.
    pub installed_cache: RwLock<Option<PackageList>>,

    /// Parsed `categories.json` payload, memoised across calls. Filled lazily
    /// on the first `categories_data` invocation. The JSON itself is baked
    /// into the binary via `include_str!`, so this is purely a parse cache.
    pub categories_cache: Arc<Mutex<Option<Arc<CategoriesData>>>>,

    /// Parsed `enrichment.json.gz` payload (Phase 13), memoised across
    /// calls. Filled lazily on the first `enrichment_data` invocation.
    /// The gzip stream is baked into the binary via `include_bytes!`, so
    /// this is purely a decode+parse cache.
    pub enrichment_cache: Arc<Mutex<Option<Arc<EnrichmentData>>>>,

    /// Locale-specific enrichment copies, memoised after merging a small
    /// `enrichment.<locale>.json.gz` overlay over the base bundle. The
    /// base cache above remains canonical and untouched.
    pub enrichment_locale_cache: Arc<Mutex<HashMap<String, Arc<EnrichmentData>>>>,

    /// Disk-usage report cache. Filled by `disk_usage`, invalidated by
    /// `disk_usage_clear_cache`. TTL is checked inside the command itself
    /// (60 s) so concurrent callers don't double-spawn `du` on each other.
    pub disk_usage_cache: Arc<Mutex<Option<CachedDiskUsage>>>,

    /// `brew services list` result, memoised for ~5 s so the Services tab
    /// renders instantly after the first probe. Invalidated automatically
    /// by start/stop/restart so post-action lists are fresh.
    pub services_cache: Arc<Mutex<Option<CachedServices>>>,

    /// Active catalog (Phase 12a). Outer `RwLock` lets `catalog_refresh`
    /// swap the inner Arc atomically without blocking concurrent readers
    /// beyond the brief moment they need to clone the Arc. Readers should
    /// `read().await` and clone the Arc immediately; writers
    /// (`catalog_refresh` only) take `write().await` and replace.
    pub catalog: RwLock<Arc<Catalog>>,

    /// Single-flight mutex for `catalog_refresh`. Held for the duration
    /// of the refresh (network fetch + parse + write + swap). A second
    /// click on Refresh while one is in flight returns
    /// `BrewError::InvalidArgument` immediately rather than queueing.
    pub catalog_refresh_in_flight: Arc<Mutex<()>>,

    /// Persisted user settings (Phase 12d). Three-state container that
    /// distinguishes file-absent (defaults apply) from file-corrupt
    /// (fail closed — every outbound call denied until repaired).
    /// `require_network` consults this on the first line of every
    /// network-touching command.
    pub settings: Arc<RwLock<SettingsLoadState>>,

    /// Phase 15 — in-memory mirror of the latest update check + cached
    /// `Available` payload. The auto-check scheduler updates this on
    /// every wake, and `update_install` validates the caller-supplied
    /// version arg against the cached entry to defend against UI
    /// staleness. See `crate::commands::updater::UpdaterState` for the
    /// shape and the rationale.
    pub updater_state: Arc<RwLock<UpdaterState>>,
}

impl AppState {
    /// Build the state at startup. Resolves `brew`, creates the
    /// brewfiles directory, and primes caches.
    pub fn build() -> Result<Self, BrewError> {
        let brew_path = resolve_brew_path();
        let brewfiles_dir = resolve_brewfiles_dir()?;
        if !brewfiles_dir.exists() {
            std::fs::create_dir_all(&brewfiles_dir).map_err(|e| BrewError::Io {
                message: format!(
                    "could not create brewfiles dir {}: {}",
                    brewfiles_dir.display(),
                    e
                ),
            })?;
        }
        let cache_dir = resolve_cache_dir()?;
        if !cache_dir.exists() {
            std::fs::create_dir_all(&cache_dir).map_err(|e| BrewError::Io {
                message: format!("could not create cache dir {}: {}", cache_dir.display(), e),
            })?;
        }
        let app_data_dir = resolve_app_data_dir()?;

        // Load the bundled catalog synchronously — it's `include_bytes!`d
        // so there's no I/O. A user-refreshed copy on disk, if present,
        // is loaded in the background by `upgrade_catalog_from_user_data`
        // so startup stays sync and never blocks on disk reads.
        // `load_bundled` may fail only if the bundled snapshot is itself
        // corrupt (would have failed at compile time), so we treat any
        // failure here as fatal in dev and ship an empty catalog in
        // release rather than refusing to launch.
        let bundled = Catalog::load_bundled().unwrap_or_else(|e| {
            tracing::error!(
                "catalog: bundled snapshot failed to parse at startup ({}); serving empty catalog",
                e
            );
            Catalog {
                formulae: Default::default(),
                casks: Default::default(),
                as_of: String::new(),
                source: crate::catalog::CatalogSource::Bundled,
                formula_count: 0,
                cask_count: 0,
                corrupt: true,
            }
        });

        // Load settings synchronously at startup. The loader handles
        // file-absent (FirstLaunch → defaults), file-corrupt (Corrupt →
        // fail closed in `require_network`), and good parse (Loaded(s)).
        // Tracing warnings for corrupt cases happen inside the loader.
        let settings_state = settings::load_at_startup(&app_data_dir);
        if matches!(settings_state, SettingsLoadState::Corrupt { .. }) {
            tracing::warn!(
                "settings: load failed at startup; require_network will deny outbound calls until user resets"
            );
        }

        Ok(Self {
            brew_path: RwLock::new(brew_path),
            brew_env: RwLock::new(BrewEnvironment::default()),
            brew_write_lock: Arc::new(Mutex::new(())),
            jobs: Arc::new(Mutex::new(HashMap::new())),
            trending_cache: Arc::new(Mutex::new(TrendingCache::default())),
            trending_history_cache: Arc::new(Mutex::new(TrendingHistoryCache::default())),
            // v0.5.0 — start with an empty cache; the IPC layer hydrates
            // from disk on first opt-in scan (lazy load avoids paying the
            // file-read cost when the user never enables the feature).
            vulns_cache: Arc::new(Mutex::new(VulnsCache::new_empty())),
            brewfiles_dir,
            cache_dir,
            app_data_dir,
            installed_cache: RwLock::new(None),
            categories_cache: Arc::new(Mutex::new(None)),
            enrichment_cache: Arc::new(Mutex::new(None)),
            enrichment_locale_cache: Arc::new(Mutex::new(HashMap::new())),
            disk_usage_cache: Arc::new(Mutex::new(None)),
            services_cache: Arc::new(Mutex::new(None)),
            catalog: RwLock::new(Arc::new(bundled)),
            catalog_refresh_in_flight: Arc::new(Mutex::new(())),
            settings: Arc::new(RwLock::new(settings_state)),
            updater_state: crate::commands::updater::empty_state(),
        })
    }

    /// Async upgrade: if `<app_data_dir>/catalog/` holds a complete
    /// user-refreshed copy, swap the in-state catalog Arc to it. Called
    /// once at startup from `initialize` (spawned on a tokio task so it
    /// doesn't block the setup hook). Quietly does nothing when there
    /// is no user-refreshed copy. Corrupt user-data is cleaned up by
    /// [`Catalog::resolve_active`] which we call instead of
    /// `load_user_data` directly.
    pub async fn upgrade_catalog_from_user_data(&self) {
        // `resolve_active` returns user-data if good, else bundled. We
        // only swap when the result is actually user-refreshed — bundled
        // is what we started with.
        let resolved = Catalog::resolve_active(&self.app_data_dir).await;
        if resolved.source == crate::catalog::CatalogSource::UserRefreshed {
            let mut guard = self.catalog.write().await;
            *guard = Arc::new(resolved);
        }
    }

    /// Invalidate caches that depend on filesystem / brew state.
    /// Call after every successful WRITE.
    pub async fn invalidate_caches(&self) {
        let mut cache = self.installed_cache.write().await;
        *cache = None;
    }

    /// Return the resolved brew binary path, or BrewNotFound.
    pub async fn require_brew_path(&self) -> Result<PathBuf, BrewError> {
        self.brew_path
            .read()
            .await
            .clone()
            .ok_or(BrewError::BrewNotFound)
    }

    /// Overwrite the cached brew path. Split out from
    /// [`Self::redetect_brew_path`] so tests can exercise the RwLock
    /// update without depending on the host filesystem.
    pub async fn set_brew_path(&self, path: Option<PathBuf>) {
        let mut guard = self.brew_path.write().await;
        *guard = path;
    }

    /// Re-run brew detection and write the result into `brew_path`.
    /// Lets the app recover from a missing-brew startup without a
    /// relaunch — the onboarding gate polls `brew_redetect` until the
    /// user's Homebrew install lands on disk. Returns the freshly
    /// detected path so the caller can build its status DTO without a
    /// second lock acquisition.
    pub async fn redetect_brew_path(&self) -> Option<PathBuf> {
        let detected = resolve_brew_path();
        self.set_brew_path(detected.clone()).await;
        detected
    }

    /// Consult paranoid mode + settings load state. Returns `Ok(())` if
    /// the outbound call is allowed, or `BrewError::ParanoidModeBlocked`
    /// otherwise. **Every outbound command must call this as its first
    /// line** — see the security review §12d "Cross-cutting concerns".
    ///
    /// Three cases:
    /// - `Loaded(s)` with `paranoid_mode == false` → allow.
    /// - `FirstLaunch` → allow (defaults apply, paranoid OFF — preserves
    ///   the v0.1.0 behaviour for users with no settings file yet).
    /// - `Loaded(s)` with `paranoid_mode == true` OR `Corrupt(...)` →
    ///   deny. Corrupt is a deliberate fail-closed: we don't know what
    ///   the user wanted, so we don't make outbound calls until they
    ///   repair the file (or hit Reset to defaults in the UI).
    pub async fn require_network(&self, feature: &'static str) -> Result<(), BrewError> {
        let guard = self.settings.read().await;
        match &*guard {
            SettingsLoadState::Loaded(s) if !s.paranoid_mode => Ok(()),
            SettingsLoadState::FirstLaunch => Ok(()),
            SettingsLoadState::Loaded(_) | SettingsLoadState::Corrupt { .. } => {
                Err(BrewError::ParanoidModeBlocked {
                    feature: feature.to_string(),
                })
            }
        }
    }

    /// v0.4.0 — composed gate for endpoints that are *both* network-
    /// gated by paranoid mode AND opt-in via a per-feature toggle. Used
    /// by [`crate::commands::trending::trending_history_fetch`] and
    /// future features hitting `brew-browser.zerologic.com/*`.
    ///
    /// Returns:
    /// - `Ok(())` if paranoid is OFF **and** `enhanced_trending_enabled`
    ///   is `true`.
    /// - `Err(ParanoidModeBlocked { feature })` if paranoid would deny
    ///   `require_network` (master switch wins; the per-feature toggle
    ///   is irrelevant when paranoid is on).
    /// - `Err(FeatureDisabled { feature })` if paranoid allows but the
    ///   per-feature toggle is off (or `FirstLaunch` — fresh-install
    ///   posture is opt-in only).
    ///
    /// Fail-closed on `Corrupt` is handled by the inner `require_network`
    /// call — `Corrupt` always denies first with `ParanoidModeBlocked`.
    pub async fn require_enhanced_trending(&self) -> Result<(), BrewError> {
        // Master paranoid gate first — same error variant other endpoints
        // use, so the frontend toast routing stays uniform.
        self.require_network("trending_history").await?;
        // Per-feature opt-in gate. FirstLaunch defaults are `false` for
        // this field by design (see Settings::default in commands/settings.rs).
        let guard = self.settings.read().await;
        match &*guard {
            SettingsLoadState::Loaded(s) if s.enhanced_trending_enabled => Ok(()),
            _ => Err(BrewError::FeatureDisabled {
                feature: "trending_history".to_string(),
            }),
        }
    }

    /// Composed gate for the opt-in live enrichment surface (fresh categories +
    /// descriptions fetched from `brew-browser.zerologic.com/enrichment/*`).
    /// Mirrors [`Self::require_enhanced_trending`]: master paranoid switch
    /// first, then the per-feature `live_enrichment_enabled` toggle. Used by
    /// the `enrichment_live_*` commands before any network call.
    ///
    /// Fail-closed on `Corrupt` is handled by the inner `require_network` call.
    pub async fn require_live_enrichment(&self) -> Result<(), BrewError> {
        self.require_network("live_enrichment").await?;
        let guard = self.settings.read().await;
        match &*guard {
            SettingsLoadState::Loaded(s) if s.live_enrichment_enabled => Ok(()),
            _ => Err(BrewError::FeatureDisabled {
                feature: "live_enrichment".to_string(),
            }),
        }
    }

    /// v0.5.0 — composed gate for the vulnerability-scanning surface
    /// (`brew vulns` subprocess + OSV roundtrip + optional GHSA enrich).
    /// Composes the master paranoid switch with the per-feature
    /// `vulnerability_scanning_enabled` toggle. Used by
    /// [`crate::commands::vulns::*`] before any subprocess spawn or
    /// network call.
    ///
    /// Returns:
    /// - `Ok(())` if paranoid is OFF **and** `vulnerability_scanning_enabled`
    ///   is `true`.
    /// - `Err(ParanoidModeBlocked { feature })` if paranoid would deny
    ///   `require_network` (master switch wins; the per-feature toggle
    ///   is irrelevant when paranoid is on).
    /// - `Err(FeatureDisabled { feature })` if paranoid allows but the
    ///   per-feature toggle is off (or `FirstLaunch` — fresh-install
    ///   posture is opt-in only).
    ///
    /// Fail-closed on `Corrupt` is handled by the inner `require_network`
    /// call — `Corrupt` always denies first with `ParanoidModeBlocked`.
    pub async fn require_vulnerability_scanning(&self) -> Result<(), BrewError> {
        self.require_network("vulnerability_scanning").await?;
        let guard = self.settings.read().await;
        match &*guard {
            SettingsLoadState::Loaded(s) if s.vulnerability_scanning_enabled => Ok(()),
            _ => Err(BrewError::FeatureDisabled {
                feature: "vulnerability_scanning".to_string(),
            }),
        }
    }
}

/// Resolve `~/Library/Application Support/brew-browser/brewfiles/`.
fn resolve_brewfiles_dir() -> Result<PathBuf, BrewError> {
    let mut base = dirs::data_dir().ok_or_else(|| BrewError::Internal {
        message: "could not resolve OS data dir".into(),
    })?;
    base.push("brew-browser");
    base.push("brewfiles");
    Ok(base)
}

/// Resolve `~/Library/Application Support/brew-browser/` for caches
/// (icons, etc.). The `cask_icon` command writes converted PNGs to
/// `<cache_dir>/icons/<token>.png`.
fn resolve_cache_dir() -> Result<PathBuf, BrewError> {
    let mut base = dirs::data_dir().ok_or_else(|| BrewError::Internal {
        message: "could not resolve OS data dir".into(),
    })?;
    base.push("brew-browser");
    Ok(base)
}

/// Resolve the canonical app-data root for security gates:
/// `~/Library/Application Support/brew-browser/`. Used by the brewfile
/// import/export sandbox checks to refuse writes anywhere inside our own
/// state directory.
fn resolve_app_data_dir() -> Result<PathBuf, BrewError> {
    let mut base = dirs::data_dir().ok_or_else(|| BrewError::Internal {
        message: "could not resolve OS data dir".into(),
    })?;
    base.push("brew-browser");
    Ok(base)
}

/// Tauri setup hook — instantiates and manages `AppState`. After the
/// state is built (with the bundled catalog loaded synchronously),
/// kicks off a background task that upgrades to the user-refreshed
/// catalog if one is on disk.
pub fn initialize<R: tauri::Runtime>(
    app: &mut tauri::App<R>,
) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::Manager;
    let state = AppState::build()?;
    app.manage(state);

    // Spawn the catalog upgrade. The handle is registered above, so
    // pulling it out of `app.state()` here gives us the same Arc-shared
    // value the commands will see.
    //
    // After the upgrade attempt, run the auto-refresh check
    // (Phase 13 — Finding 2). It returns immediately when the user has
    // not opted in (`catalog_auto_refresh = Off`, the default) so the
    // happy-path startup cost is one settings RwLock read + one Arc
    // clone — well under a millisecond. Both run on the same background
    // task to keep the order deterministic (upgrade first so the
    // auto-refresh sees the freshest known `as_of` before deciding).
    let app_handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        let state: tauri::State<AppState> = app_handle.state();
        state.upgrade_catalog_from_user_data().await;
        crate::commands::catalog::maybe_auto_refresh_catalog(&state).await;
    });

    Ok(())
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::settings::Settings;

    /// Build a minimal AppState whose only meaningful field is `settings`.
    /// All other fields use whatever `AppState::build` resolves — for the
    /// gate-only tests below the brew-path lookup, catalog load, etc., are
    /// irrelevant. Settings slot is overwritten *after* construction so we
    /// don't depend on whatever happens to be on disk for the test user.
    async fn build_state_with(slot: SettingsLoadState) -> AppState {
        let state = AppState::build().expect("AppState::build");
        {
            let mut guard = state.settings.write().await;
            *guard = slot;
        }
        state
    }

    #[tokio::test]
    async fn require_network_allows_first_launch() {
        let state = build_state_with(SettingsLoadState::FirstLaunch).await;
        assert!(state.require_network("trending_fetch").await.is_ok());
    }

    #[tokio::test]
    async fn require_network_allows_loaded_with_paranoid_off() {
        let s = Settings {
            paranoid_mode: false,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        assert!(state.require_network("catalog_refresh").await.is_ok());
    }

    #[tokio::test]
    async fn require_network_blocks_when_paranoid_on() {
        let s = Settings {
            paranoid_mode: true,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        let r = state.require_network("trending_fetch").await;
        match r {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "trending_fetch");
            }
            other => panic!("expected ParanoidModeBlocked, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_network_blocks_when_corrupt() {
        // Fail-closed: corrupt settings file → deny even though paranoid
        // would default false. This is the load-bearing security gate from
        // the §12d review.
        let state = build_state_with(SettingsLoadState::Corrupt {
            message: "bad json".into(),
        })
        .await;
        let r = state.require_network("cask_icon_from_homepage").await;
        match r {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "cask_icon_from_homepage");
            }
            other => panic!("expected ParanoidModeBlocked from corrupt, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_network_feature_string_round_trips() {
        // The static-str argument must be carried verbatim into the error
        // so the frontend can route the toast to the right setting.
        let state = build_state_with(SettingsLoadState::Corrupt {
            message: "x".into(),
        })
        .await;
        for feat in [
            "trending_fetch",
            "cask_icon_from_homepage",
            "catalog_refresh",
        ] {
            let r = state.require_network(feat).await;
            match r {
                Err(BrewError::ParanoidModeBlocked { feature }) => {
                    assert_eq!(feature, feat);
                }
                other => panic!("expected block for {feat}, got {other:?}"),
            }
        }
    }

    // ---------- v0.4.0: require_enhanced_trending ----------

    #[tokio::test]
    async fn require_enhanced_trending_allows_when_toggle_on_and_paranoid_off() {
        let s = Settings {
            paranoid_mode: false,
            enhanced_trending_enabled: true,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        assert!(state.require_enhanced_trending().await.is_ok());
    }

    #[tokio::test]
    async fn require_enhanced_trending_blocks_when_toggle_off() {
        // Toggle off → FeatureDisabled (NOT ParanoidModeBlocked — the
        // cure is a different setting toggle).
        let s = Settings {
            paranoid_mode: false,
            enhanced_trending_enabled: false,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        match state.require_enhanced_trending().await {
            Err(BrewError::FeatureDisabled { feature }) => {
                assert_eq!(feature, "trending_history");
            }
            other => panic!("expected FeatureDisabled, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_enhanced_trending_blocks_when_paranoid_on_even_if_toggle_on() {
        // Master switch wins. Frontend should route to Offline Mode
        // toggle, not the per-feature toggle.
        let s = Settings {
            paranoid_mode: true,
            enhanced_trending_enabled: true,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        match state.require_enhanced_trending().await {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "trending_history");
            }
            other => panic!("expected ParanoidModeBlocked, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_enhanced_trending_blocks_on_first_launch() {
        // FirstLaunch → require_network allows but the per-feature
        // toggle defaults to false → FeatureDisabled. Critical for
        // first-install posture: zero zerologic.com traffic until opt-in.
        let state = build_state_with(SettingsLoadState::FirstLaunch).await;
        match state.require_enhanced_trending().await {
            Err(BrewError::FeatureDisabled { feature }) => {
                assert_eq!(feature, "trending_history");
            }
            other => panic!("expected FeatureDisabled, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_enhanced_trending_blocks_when_corrupt() {
        // Corrupt → paranoid gate fires first with ParanoidModeBlocked.
        // Important: this is the same error code other endpoints emit
        // on Corrupt, so the toast UX stays uniform across features.
        let state = build_state_with(SettingsLoadState::Corrupt {
            message: "boom".into(),
        })
        .await;
        match state.require_enhanced_trending().await {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "trending_history");
            }
            other => panic!("expected ParanoidModeBlocked from corrupt, got {other:?}"),
        }
    }

    // ---------- v0.5.0: require_vulnerability_scanning ----------

    #[tokio::test]
    async fn require_vulnerability_scanning_allows_when_toggle_on_and_paranoid_off() {
        let s = Settings {
            paranoid_mode: false,
            vulnerability_scanning_enabled: true,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        assert!(state.require_vulnerability_scanning().await.is_ok());
    }

    #[tokio::test]
    async fn require_vulnerability_scanning_blocks_when_toggle_off() {
        // Toggle off → FeatureDisabled (NOT ParanoidModeBlocked — the
        // cure is a different setting toggle).
        let s = Settings {
            paranoid_mode: false,
            vulnerability_scanning_enabled: false,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        match state.require_vulnerability_scanning().await {
            Err(BrewError::FeatureDisabled { feature }) => {
                assert_eq!(feature, "vulnerability_scanning");
            }
            other => panic!("expected FeatureDisabled, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_vulnerability_scanning_blocks_when_paranoid_on_even_if_toggle_on() {
        // Master switch wins. Frontend should route to Offline Mode
        // toggle, not the per-feature toggle.
        let s = Settings {
            paranoid_mode: true,
            vulnerability_scanning_enabled: true,
            ..Settings::default()
        };
        let state = build_state_with(SettingsLoadState::Loaded(s)).await;
        match state.require_vulnerability_scanning().await {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "vulnerability_scanning");
            }
            other => panic!("expected ParanoidModeBlocked, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_vulnerability_scanning_blocks_on_first_launch() {
        // FirstLaunch → require_network allows but the per-feature
        // toggle defaults to false → FeatureDisabled. Critical for
        // first-install posture: zero `brew vulns` invocations and zero
        // OSV traffic until opt-in.
        let state = build_state_with(SettingsLoadState::FirstLaunch).await;
        match state.require_vulnerability_scanning().await {
            Err(BrewError::FeatureDisabled { feature }) => {
                assert_eq!(feature, "vulnerability_scanning");
            }
            other => panic!("expected FeatureDisabled, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_vulnerability_scanning_blocks_when_corrupt() {
        // Corrupt → paranoid gate fires first with ParanoidModeBlocked,
        // same as every other composed gate. Keeps the toast routing
        // uniform across features.
        let state = build_state_with(SettingsLoadState::Corrupt {
            message: "boom".into(),
        })
        .await;
        match state.require_vulnerability_scanning().await {
            Err(BrewError::ParanoidModeBlocked { feature }) => {
                assert_eq!(feature, "vulnerability_scanning");
            }
            other => panic!("expected ParanoidModeBlocked from corrupt, got {other:?}"),
        }
    }

    // ---------- onboarding: set_brew_path / redetect_brew_path ----------

    #[tokio::test]
    async fn set_brew_path_updates_the_rwlock() {
        let state = AppState::build().expect("AppState::build");
        // Simulate a brew-less startup regardless of what build() found.
        state.set_brew_path(None).await;
        match state.require_brew_path().await {
            Err(BrewError::BrewNotFound) => {}
            other => panic!("expected BrewNotFound after set_brew_path(None), got {other:?}"),
        }
        // Setter round-trips an arbitrary path verbatim.
        let p = PathBuf::from("/tmp/fake-brew-for-test");
        state.set_brew_path(Some(p.clone())).await;
        assert_eq!(state.require_brew_path().await.expect("path set"), p);
    }

    #[tokio::test]
    async fn redetect_brew_path_writes_resolution_into_state() {
        // `resolve_brew_path` is filesystem-bound, so we assert agreement
        // rather than a fixed value: after forcing None, redetect must
        // leave the RwLock holding exactly what the resolver returns
        // (Some on a dev host with brew, None on a brew-less CI host).
        let state = AppState::build().expect("AppState::build");
        state.set_brew_path(None).await;
        let detected = state.redetect_brew_path().await;
        let cached = state.brew_path.read().await.clone();
        assert_eq!(
            cached, detected,
            "redetect must write its result into brew_path"
        );
        assert_eq!(detected, resolve_brew_path());
    }
}
