//! GHSA enrichment layer for `brew vulns` output.
//!
//! `brew vulns` (Step 2) gives us the canonical CVE/GHSA identifier and a
//! severity label, but the title/details/patched-version-range fields are
//! often sparse — OSV's record can be a one-line stub when the upstream
//! advisory lives on GitHub. This module fills the gap by fetching
//! `GET https://api.github.com/advisories/{ghsa_id}` for any GHSA-prefixed
//! entry and merging the richer fields back into the [`RawVuln`].
//!
//! ## Trust boundary + opt-in gating
//!
//! GitHub is a separate trust boundary from `brew vulns` (which talks to
//! `api.osv.dev` via the official subcommand). The same master toggle that
//! gates anonymous repo stats (`settings.github_enabled`) gates enrichment:
//! if the user hasn't opted in to GitHub traffic, [`enrich`] is a no-op.
//! The caller is also expected to have passed the
//! `require_vulnerability_scanning` gate first — enrichment runs *inside*
//! a scan, so the outer gate already covered "is this feature on?".
//!
//! ## Best-effort semantics
//!
//! Every per-entry fetch is best-effort: a 404 (advisory withdrawn), a 429
//! (rate-limited), a network blip, or a parse failure all leave the
//! original vuln unchanged and continue to the next entry. The function
//! NEVER returns `Err` for an individual fetch failure — the only error
//! path is "could not load settings" (which the caller already failed
//! against), and even that returns `Ok(())` to keep the scan flow simple.
//!
//! ## Cache (`<app_data_dir>/ghsa_cache.json`)
//!
//! Advisories are mostly append-only (new CVEs add to the ecosystem;
//! published advisories rarely change content), so a 7-day TTL is
//! conservative. The cache survives across launches via the same
//! `atomic_write` + `read_capped` crash-safe pattern the vulns cache uses,
//! capped at 500 entries with LRU-by-fetched-at eviction. Schema is
//! versioned for forward-compat with the same fail-soft-to-empty behaviour
//! as [`crate::vulns::cache::VulnsCache`].

#![deny(clippy::print_stdout, clippy::print_stderr, clippy::dbg_macro)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::commands::settings::SettingsLoadState;
use crate::error::BrewError;
use crate::github::auth::read_token;
use crate::state::AppState;
use crate::util::fs::{atomic_write, read_capped};
use crate::vulns::client::RawVuln;

// ---------- Constants ----------

/// 7-day freshness window. Advisories are effectively immutable once
/// published (text fixes are rare and not security-critical), so the TTL
/// is set deliberately long — the cache hit rate dominates the user
/// experience for any user who scans more than once a week.
pub const GHSA_CACHE_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// Hard cap on persisted entries. 500 covers a power-user install set
/// (most users see <50 GHSAs across all installed formulae) with plenty
/// of headroom for transient spikes. Eviction is LRU by `fetched_at`.
pub const GHSA_CACHE_MAX_ENTRIES: usize = 500;

/// 2 MiB cap on the on-disk cache file. Each entry serializes to ~3-4 KiB
/// (summary + description are the bulk); 500 × 4 KiB = 2 MB worst case.
pub const MAX_GHSA_CACHE_BYTES: u64 = 2 * 1024 * 1024;

/// Bump when the on-disk shape changes incompatibly. v1 is the initial
/// shape. Forward-newer files load as empty (fail-soft, matches
/// [`crate::vulns::cache::VULNS_CACHE_SCHEMA_VERSION`] behaviour).
pub const GHSA_CACHE_SCHEMA_VERSION: u32 = 1;

/// Cap on a single advisory response body. 256 KiB is well above the
/// realistic payload (~5-10 KiB) and small enough that a runaway response
/// can't OOM the backend. Defense in depth against a hostile redirect or
/// a future api.github.com regression that pads responses.
const MAX_RESPONSE_BYTES: u64 = 256 * 1024;

/// HTTP timeout per advisory fetch. Short enough that a hanging request
/// can't stall an in-progress scan; long enough for a healthy round-trip
/// to api.github.com from a typical home connection.
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

const USER_AGENT: &str = concat!(
    "brew-browser/",
    env!("CARGO_PKG_VERSION"),
    " (+https://github.com/msitarzewski/brew-browser)"
);

/// API base. Overridable for tests via [`fetch_advisory_with`].
const API_BASE: &str = "https://api.github.com";

// ---------- Cache shape (on-disk) ----------

/// Persisted advisory blob — only the fields we actually merge into
/// [`RawVuln`]. `#[serde(default)]` on every field so a future api.github.com
/// schema addition (or a hand-edited cache file) parses cleanly.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct GhsaAdvisory {
    /// One-line title as published by the advisory author.
    pub summary: String,
    /// Multi-line markdown body. Rendered by the same sanitizer the
    /// PackageDetail enrichment text uses.
    pub description: String,
    /// Raw GHSA severity string ("low" / "medium" / "high" / "critical").
    /// Preserved verbatim — the [`crate::vulns::client::Severity`] enum
    /// normalises this when we merge.
    pub severity: String,
    /// External references (advisory URL, patch commit URLs, etc.).
    pub references: Vec<String>,
    /// First patched version, flattened across all vulnerable products
    /// in the advisory. None when the advisory has no fix yet.
    pub first_patched_version: Option<String>,
}

/// One cache entry. The `fetched_at` timestamp drives both TTL freshness
/// and LRU eviction.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GhsaCacheEntry {
    pub fetched_at: DateTime<Utc>,
    pub advisory: GhsaAdvisory,
}

/// On-disk shape. Mirrors [`crate::vulns::cache::VulnsCacheFile`] in
/// layout (schema version + entries map) for predictability across the
/// `vulns/` submodule. `#[serde(default)]` on every field so older files
/// and missing fields read cleanly.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GhsaCacheFile {
    pub schema_version: u32,
    /// Keyed by GHSA id (e.g. `"GHSA-xxxx-xxxx-xxxx"`). HashMap key
    /// constraint forces stringly-typed keys on JSON — the validated GHSA
    /// id is already a safe string so no escaping is needed.
    pub entries: HashMap<String, GhsaCacheEntry>,
    /// Monotonic counter of successful network inserts. Surfaced as a
    /// testable seam so the "non-GHSA IDs don't get fetched" test can
    /// assert "no network call happened" without mocking the HTTP layer.
    /// Persisted so cross-launch totals stay meaningful for diagnostics.
    pub fetch_count: u64,
}

/// In-memory cache wrapper. Holds the parsed file plus a dirty flag so
/// the caller batches writes after a multi-entry enrich pass.
#[derive(Debug, Default)]
pub struct GhsaCache {
    pub file: GhsaCacheFile,
    pub dirty: bool,
}

impl GhsaCache {
    /// Build a fresh empty cache stamped with the current schema version.
    pub fn new_empty() -> Self {
        Self {
            file: GhsaCacheFile {
                schema_version: GHSA_CACHE_SCHEMA_VERSION,
                ..Default::default()
            },
            dirty: false,
        }
    }

    /// Load from `<app_data_dir>/ghsa_cache.json`. Fail-soft on every
    /// branch (missing, oversize, malformed, future schema) — losing the
    /// cache only costs a few HTTP calls.
    pub async fn load(app_data_dir: &Path) -> Self {
        let path = cache_path(app_data_dir);
        if !path.exists() {
            return Self::new_empty();
        }
        match read_capped(&path, MAX_GHSA_CACHE_BYTES).await {
            Ok(bytes) => match serde_json::from_slice::<GhsaCacheFile>(&bytes) {
                Ok(file) => {
                    if file.schema_version > GHSA_CACHE_SCHEMA_VERSION {
                        tracing::warn!(
                            "ghsa cache: schema {} newer than supported {}; ignoring",
                            file.schema_version,
                            GHSA_CACHE_SCHEMA_VERSION
                        );
                        return Self::new_empty();
                    }
                    Self { file, dirty: false }
                }
                Err(e) => {
                    tracing::warn!("ghsa cache: parse failed ({e}); starting empty");
                    Self::new_empty()
                }
            },
            Err(e) => {
                tracing::warn!("ghsa cache: read failed ({e}); starting empty");
                Self::new_empty()
            }
        }
    }

    /// Persist if dirty. Atomic write + size cap on serialization.
    pub async fn save_if_dirty(&mut self, app_data_dir: &Path) -> Result<(), BrewError> {
        if !self.dirty {
            return Ok(());
        }
        let path = cache_path(app_data_dir);
        let bytes = serde_json::to_vec(&self.file).map_err(|e| BrewError::Io {
            message: format!("ghsa cache: serialize: {e}"),
        })?;
        if bytes.len() as u64 > MAX_GHSA_CACHE_BYTES {
            return Err(BrewError::Io {
                message: format!(
                    "ghsa cache: serialized size {} exceeds cap {}",
                    bytes.len(),
                    MAX_GHSA_CACHE_BYTES
                ),
            });
        }
        atomic_write(&path, &bytes).await?;
        self.dirty = false;
        Ok(())
    }

    /// Lookup a fresh entry by GHSA id. Returns `None` if absent or stale.
    pub fn get_fresh(&self, ghsa_id: &str) -> Option<&GhsaAdvisory> {
        let entry = self.file.entries.get(ghsa_id)?;
        if entry_is_fresh(entry) {
            Some(&entry.advisory)
        } else {
            None
        }
    }

    /// Insert (or replace) an advisory. Marks dirty; evicts the oldest
    /// entry on cap overflow. Also bumps `fetch_count` — the test seam
    /// the "no fetch for non-GHSA" case asserts against.
    pub fn put(&mut self, ghsa_id: String, advisory: GhsaAdvisory) {
        if !self.file.entries.contains_key(&ghsa_id)
            && self.file.entries.len() >= GHSA_CACHE_MAX_ENTRIES
        {
            // Evict oldest by fetched_at. O(n) but n ≤ 500 and eviction
            // happens at most once per insert.
            if let Some(oldest) = self
                .file
                .entries
                .iter()
                .min_by_key(|(_, v)| v.fetched_at)
                .map(|(k, _)| k.clone())
            {
                self.file.entries.remove(&oldest);
            }
        }
        self.file.entries.insert(
            ghsa_id,
            GhsaCacheEntry {
                fetched_at: Utc::now(),
                advisory,
            },
        );
        self.file.fetch_count = self.file.fetch_count.saturating_add(1);
        self.dirty = true;
    }
}

/// Resolve `<app_data_dir>/ghsa_cache.json`.
pub fn cache_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("ghsa_cache.json")
}

fn entry_is_fresh(entry: &GhsaCacheEntry) -> bool {
    let delta = Utc::now() - entry.fetched_at;
    delta.to_std().unwrap_or(Duration::ZERO) < GHSA_CACHE_TTL
}

// ---------- GHSA id validation ----------

/// Validate the canonical GHSA id format: `GHSA-xxxx-xxxx-xxxx` where each
/// `xxxx` is 4 alphanumerics. Defense in depth: even though only the path
/// component is interpolated and reqwest URL-encodes it, an early reject
/// keeps malformed inputs out of cache keys and log lines.
fn is_valid_ghsa_id(id: &str) -> bool {
    // Layout check: prefix + three 4-char groups separated by `-`.
    if !id.starts_with("GHSA-") {
        return false;
    }
    let rest = &id["GHSA-".len()..];
    let parts: Vec<&str> = rest.split('-').collect();
    if parts.len() != 3 {
        return false;
    }
    parts
        .iter()
        .all(|p| p.len() == 4 && p.chars().all(|c| c.is_ascii_alphanumeric()))
}

// ---------- Raw API response shapes ----------

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RawAdvisory {
    summary: String,
    description: String,
    severity: String,
    references: Vec<RawReference>,
    vulnerabilities: Vec<RawVulnerableProduct>,
}

/// A reference from the advisory API. The global advisories endpoint
/// (`/advisories/{ghsa_id}`) returns `references` as an array of **plain URL
/// strings** — NOT `[{ "url": … }]` objects, which an earlier version assumed
/// (that mismatch made the whole `RawAdvisory` parse fail, silently disabling
/// enrichment). Untagged so we tolerate BOTH shapes: a bare string, or an
/// object with a `url` field (the GraphQL/object shape), future-proofing
/// against either endpoint variant.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawReference {
    Url(String),
    Object { url: String },
}

impl RawReference {
    fn into_url(self) -> String {
        match self {
            RawReference::Url(u) => u,
            RawReference::Object { url } => url,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RawVulnerableProduct {
    first_patched_version: Option<String>,
}

impl From<RawAdvisory> for GhsaAdvisory {
    fn from(raw: RawAdvisory) -> Self {
        let refs = raw
            .references
            .into_iter()
            .map(RawReference::into_url)
            .filter(|u| !u.is_empty())
            .collect();
        let first_patched = raw
            .vulnerabilities
            .into_iter()
            .find_map(|v| v.first_patched_version.filter(|s| !s.is_empty()));
        GhsaAdvisory {
            summary: raw.summary,
            description: raw.description,
            severity: raw.severity,
            references: refs,
            first_patched_version: first_patched,
        }
    }
}

// ---------- Public API ----------

/// Best-effort GHSA enrichment over `vulns`.
///
/// For each entry whose `id` is a valid GHSA, fills `summary`, `details`,
/// `fixed_in`, and `references` from the corresponding
/// `api.github.com/advisories/{id}` response (or the local cache when
/// fresh). Non-GHSA ids (CVE-prefixed, etc.) pass through unchanged and
/// trigger no network call.
///
/// No-op when `settings.github_enabled == false` — the per-feature
/// GitHub master toggle. The caller is also expected to have passed
/// [`AppState::require_vulnerability_scanning`] before calling this.
///
/// Returns `Ok(())` even on individual fetch failures (404, 429, network
/// blips, parse failures) — the original vuln stays put and the next entry
/// is tried. The only `Err` path is a cache-save failure at the very end.
pub async fn enrich(state: &AppState, vulns: &mut [RawVuln]) -> Result<(), BrewError> {
    // Defensive recheck of the GitHub master toggle — even though the
    // caller already passed `require_vulnerability_scanning`, GitHub
    // enrichment is gated by an independent settings toggle (a user can
    // opt in to vulnerability scanning but opt out of GitHub traffic;
    // OSV.dev queries continue, GHSA enrichment doesn't).
    {
        let guard = state.settings.read().await;
        match &*guard {
            SettingsLoadState::Loaded(s) if !s.github_enabled => return Ok(()),
            SettingsLoadState::FirstLaunch | SettingsLoadState::Corrupt { .. } => return Ok(()),
            SettingsLoadState::Loaded(_) => {}
        }
    }

    // Early-exit when there's nothing to enrich. Avoids loading the
    // cache file from disk for a CVE-only scan.
    if !vulns.iter().any(|v| is_valid_ghsa_id(&v.id)) {
        return Ok(());
    }

    let mut cache = GhsaCache::load(&state.app_data_dir).await;
    let client = build_client()?;
    // Token is read once up front. A keychain miss is non-fatal — we
    // just fall back to anonymous rate limit (60/hr).
    let token = read_token().ok().flatten();

    for v in vulns.iter_mut() {
        if !is_valid_ghsa_id(&v.id) {
            continue;
        }

        // Cache hit?
        if let Some(adv) = cache.get_fresh(&v.id).cloned() {
            merge_into(v, &adv);
            continue;
        }

        // Cache miss — fetch + cache. Failures stay local to this entry.
        match fetch_advisory_with(&client, API_BASE, &v.id, token.as_ref()).await {
            Ok(Some(adv)) => {
                merge_into(v, &adv);
                cache.put(v.id.clone(), adv);
            }
            Ok(None) => {
                // 404 — withdrawn or never existed. Leave the vuln as-is.
            }
            Err(e) => {
                tracing::warn!("ghsa enrich: fetch {} failed: {e:?}", v.id);
            }
        }
    }

    cache.save_if_dirty(&state.app_data_dir).await
}

/// Merge richer advisory fields into the [`RawVuln`]. Only non-empty
/// fields overwrite — a sparse advisory must not clobber a well-populated
/// OSV record.
fn merge_into(vuln: &mut RawVuln, advisory: &GhsaAdvisory) {
    if !advisory.summary.is_empty() {
        vuln.summary = advisory.summary.clone();
    }
    if !advisory.description.is_empty() {
        vuln.details = advisory.description.clone();
    }
    if vuln.fixed_in.is_none() {
        if let Some(fp) = &advisory.first_patched_version {
            vuln.fixed_in = Some(fp.clone());
        }
    }
    for r in &advisory.references {
        if !r.is_empty() && !vuln.references.iter().any(|x| x == r) {
            vuln.references.push(r.clone());
        }
    }
}

// ---------- HTTP ----------

/// Build the reqwest client used for advisory fetches. Identical UA shape
/// to [`crate::github::stats`] so server-side rate accounting groups the
/// two endpoints together (they share the per-IP 60/hr anonymous budget).
fn build_client() -> Result<reqwest::Client, BrewError> {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| BrewError::Network {
            url: API_BASE.into(),
            message: format!("ghsa client build: {e}"),
        })
}

/// Counter incremented by [`fetch_advisory_with`] every time it actually
/// initiates a network request. Used by the unit tests to assert that
/// non-GHSA ids never reach the HTTP layer.
///
/// Sits at module scope rather than in a struct so the test seam works
/// regardless of whether the caller goes through [`enrich`] (which builds
/// its own client) or calls [`fetch_advisory_with`] directly.
static FETCH_ATTEMPTS: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
fn fetch_attempts() -> u64 {
    FETCH_ATTEMPTS.load(Ordering::Relaxed)
}

#[cfg(test)]
fn reset_fetch_attempts() {
    FETCH_ATTEMPTS.store(0, Ordering::Relaxed);
}

/// Fetch a single advisory by GHSA id from an injectable API base.
///
/// Returns:
/// - `Ok(Some(advisory))` — 200 + parseable body.
/// - `Ok(None)` — 404 (withdrawn / unknown id) OR 429/403 (rate limited).
///   Both treated as "skip and continue" so a quota hit doesn't error a
///   whole batch.
/// - `Err(...)` — network failure or body-cap violation. Caller logs and
///   moves on.
async fn fetch_advisory_with(
    client: &reqwest::Client,
    api_base: &str,
    ghsa_id: &str,
    token: Option<&crate::github::auth::Token>,
) -> Result<Option<GhsaAdvisory>, BrewError> {
    FETCH_ATTEMPTS.fetch_add(1, Ordering::Relaxed);

    let url = format!("{api_base}/advisories/{ghsa_id}");
    let mut req = client
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(t) = token {
        req = req.header("Authorization", format!("Bearer {}", t.as_str()));
    }
    let resp = req.send().await.map_err(|e| BrewError::Network {
        url: url.clone(),
        message: e.to_string(),
    })?;

    match resp.status().as_u16() {
        200 => {}
        404 => {
            tracing::warn!("ghsa enrich: 404 for {ghsa_id} (withdrawn?)");
            return Ok(None);
        }
        429 | 403 => {
            tracing::warn!(
                "ghsa enrich: rate limited fetching {ghsa_id} ({})",
                resp.status().as_u16()
            );
            return Ok(None);
        }
        s => {
            return Err(BrewError::HttpStatus { url, status: s });
        }
    }

    // Body cap — refuse oversize before allocating.
    if let Some(len) = resp.content_length() {
        if len > MAX_RESPONSE_BYTES {
            return Err(BrewError::Network {
                url,
                message: format!("body length {len} exceeds {MAX_RESPONSE_BYTES}"),
            });
        }
    }
    let bytes = resp.bytes().await.map_err(|e| BrewError::Network {
        url: url.clone(),
        message: format!("body: {e}"),
    })?;
    if (bytes.len() as u64) > MAX_RESPONSE_BYTES {
        return Err(BrewError::Network {
            url,
            message: format!("body length {} exceeds {MAX_RESPONSE_BYTES}", bytes.len()),
        });
    }

    let raw: RawAdvisory = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("ghsa enrich: parse {ghsa_id}: {e}");
            return Ok(None);
        }
    };
    Ok(Some(raw.into()))
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::settings::Settings;
    use crate::vulns::client::Severity;

    /// Build a minimal AppState with a specific settings slot. Mirrors
    /// the helper in `state.rs::tests` — we can't import the private
    /// helper, so a small duplicate lives here.
    async fn state_with(slot: SettingsLoadState) -> AppState {
        let state = AppState::build().expect("AppState::build");
        {
            let mut guard = state.settings.write().await;
            *guard = slot;
        }
        state
    }

    /// Redirect the AppState's `app_data_dir` to a fresh tempdir so cache
    /// reads/writes don't touch the real `~/Library/Application Support`.
    /// `app_data_dir` is `pub`, so we can mutate it directly via a small
    /// `unsafe`-free assignment after construction.
    async fn state_with_tempdir(slot: SettingsLoadState) -> (AppState, tempfile::TempDir) {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut state = state_with(slot).await;
        state.app_data_dir = tmp.path().to_path_buf();
        (state, tmp)
    }

    fn ghsa_vuln(id: &str) -> RawVuln {
        RawVuln {
            id: id.into(),
            severity: Severity::High,
            summary: "stub".into(),
            details: "stub details".into(),
            ..Default::default()
        }
    }

    // ---------- TTL constant tripwire ----------

    #[test]
    fn cache_ttl_is_seven_days() {
        assert_eq!(GHSA_CACHE_TTL, Duration::from_secs(7 * 24 * 60 * 60));
    }

    // ---------- GHSA id validation ----------

    #[test]
    fn ghsa_id_accepts_canonical_form() {
        assert!(is_valid_ghsa_id("GHSA-abcd-1234-wxyz"));
        assert!(is_valid_ghsa_id("GHSA-0000-0000-0000"));
        assert!(is_valid_ghsa_id("GHSA-AAAA-bbbb-CCCC"));
    }

    #[test]
    fn ghsa_id_rejects_malformed_inputs() {
        // Defense in depth — these must never reach the URL builder.
        let bad = [
            "",
            "GHSA-",
            "GHSA-abc-1234-wxyz",        // group too short
            "GHSA-abcd-1234",            // missing group
            "ghsa-abcd-1234-wxyz",       // wrong case prefix
            "GHSA-abcd-1234-wxyz-extra", // too many groups
            "GHSA-ab/d-1234-wxyz",       // slash → would break URL pathing
            "GHSA-ab.d-1234-wxyz",       // dot
            "CVE-2024-1",
            "GHSA-abcd-1234-wxy", // group too short by 1
            "../etc/passwd",
        ];
        for id in bad {
            assert!(!is_valid_ghsa_id(id), "must reject: {id}");
        }
    }

    // ---------- Settings gating ----------

    #[tokio::test]
    async fn enrich_skips_when_github_disabled() {
        reset_fetch_attempts();
        let s = Settings {
            paranoid_mode: false,
            github_enabled: false,
            ..Settings::default()
        };
        let (state, _tmp) = state_with_tempdir(SettingsLoadState::Loaded(s)).await;
        let mut vulns = vec![ghsa_vuln("GHSA-abcd-1234-wxyz")];
        let original = vulns.clone();
        enrich(&state, &mut vulns).await.expect("ok");
        assert_eq!(vulns, original, "github_enabled=false must be a no-op");
        assert_eq!(fetch_attempts(), 0, "no HTTP attempt should have been made");
    }

    #[tokio::test]
    async fn enrich_skips_on_first_launch_posture() {
        // FirstLaunch defaults github_enabled to false. Enrich must
        // honour that even though the *passed* settings shape isn't
        // explicitly Loaded — the master toggle defaults to off.
        reset_fetch_attempts();
        let (state, _tmp) = state_with_tempdir(SettingsLoadState::FirstLaunch).await;
        let mut vulns = vec![ghsa_vuln("GHSA-abcd-1234-wxyz")];
        let original = vulns.clone();
        enrich(&state, &mut vulns).await.expect("ok");
        assert_eq!(vulns, original);
        assert_eq!(fetch_attempts(), 0);
    }

    #[tokio::test]
    async fn enrich_passes_through_non_ghsa() {
        // CVE-prefixed (or any non-GHSA) ids must NOT trigger a fetch —
        // the advisories endpoint only knows GHSA ids, and we don't
        // want to burn rate-limit budget on guaranteed-404 calls.
        reset_fetch_attempts();
        let s = Settings {
            paranoid_mode: false,
            github_enabled: true,
            ..Settings::default()
        };
        let (state, _tmp) = state_with_tempdir(SettingsLoadState::Loaded(s)).await;
        let mut vulns = vec![ghsa_vuln("CVE-2024-1"), ghsa_vuln("CVE-2024-99999")];
        let original = vulns.clone();
        enrich(&state, &mut vulns).await.expect("ok");
        assert_eq!(vulns, original, "CVE entries must be untouched");
        assert_eq!(
            fetch_attempts(),
            0,
            "no fetch should be made when no GHSA ids are present"
        );

        // Cache file must not exist either — we early-exit before load.
        assert!(
            !cache_path(&state.app_data_dir).exists(),
            "no cache write expected when nothing to enrich"
        );
    }

    // ---------- Cache round-trip ----------

    #[tokio::test]
    async fn cache_round_trips() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut c = GhsaCache::new_empty();
        let adv = GhsaAdvisory {
            summary: "Buffer overflow".into(),
            description: "Long-form details".into(),
            severity: "high".into(),
            references: vec!["https://example.com/adv".into()],
            first_patched_version: Some("3.2.1".into()),
        };
        c.put("GHSA-abcd-1234-wxyz".into(), adv.clone());
        c.save_if_dirty(tmp.path()).await.expect("save");
        assert!(!c.dirty, "save_if_dirty must clear dirty");
        assert!(cache_path(tmp.path()).exists());

        let loaded = GhsaCache::load(tmp.path()).await;
        let got = loaded
            .get_fresh("GHSA-abcd-1234-wxyz")
            .expect("present after reload");
        assert_eq!(got, &adv);
        assert_eq!(loaded.file.fetch_count, 1);
    }

    #[tokio::test]
    async fn cache_load_handles_corrupt_file() {
        let tmp = tempfile::tempdir().expect("tempdir");
        tokio::fs::write(cache_path(tmp.path()), b"{not json")
            .await
            .unwrap();
        let c = GhsaCache::load(tmp.path()).await;
        // Fail-soft: corrupt file → empty cache.
        assert!(c.file.entries.is_empty());
        assert_eq!(c.file.schema_version, GHSA_CACHE_SCHEMA_VERSION);
    }

    #[tokio::test]
    async fn cache_load_handles_future_schema() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let future = GhsaCacheFile {
            schema_version: GHSA_CACHE_SCHEMA_VERSION + 1,
            entries: HashMap::new(),
            fetch_count: 99,
        };
        let bytes = serde_json::to_vec(&future).unwrap();
        tokio::fs::write(cache_path(tmp.path()), bytes)
            .await
            .unwrap();
        let c = GhsaCache::load(tmp.path()).await;
        // Forward-compat: future schema → drop, start fresh.
        assert!(c.file.entries.is_empty());
        assert_eq!(c.file.fetch_count, 0);
    }

    #[test]
    fn cache_evicts_oldest_at_cap() {
        let mut c = GhsaCache::new_empty();
        // Hand-fill the map so scanned_at is deterministic.
        for i in 0..GHSA_CACHE_MAX_ENTRIES {
            let id = format!("GHSA-pkg{i:04}-0000-0000");
            c.file.entries.insert(
                id,
                GhsaCacheEntry {
                    fetched_at: Utc::now() + chrono::Duration::seconds(i as i64),
                    advisory: GhsaAdvisory::default(),
                },
            );
        }
        assert_eq!(c.file.entries.len(), GHSA_CACHE_MAX_ENTRIES);

        // pkg0000 is the oldest (lowest fetched_at). Inserting a new
        // entry must evict it.
        c.put("GHSA-newr-comr-1234".into(), GhsaAdvisory::default());
        assert_eq!(c.file.entries.len(), GHSA_CACHE_MAX_ENTRIES);
        assert!(
            !c.file.entries.contains_key("GHSA-pkg0000-0000-0000"),
            "oldest entry must have been evicted"
        );
        assert!(c.file.entries.contains_key("GHSA-newr-comr-1234"));
    }

    // ---------- RawAdvisory parsing (defensive) ----------

    #[test]
    fn ghsa_advisory_parses_with_defaults() {
        // Empty object → every field at default. Forward-compat for a
        // future api.github.com schema that drops a field we currently
        // expect.
        let raw: RawAdvisory = serde_json::from_str("{}").expect("parse");
        let adv: GhsaAdvisory = raw.into();
        assert_eq!(adv.summary, "");
        assert_eq!(adv.description, "");
        assert_eq!(adv.severity, "");
        assert!(adv.references.is_empty());
        assert!(adv.first_patched_version.is_none());
    }

    #[test]
    fn ghsa_advisory_ignores_unknown_fields() {
        // Fixture matches the REAL `GET /advisories/{ghsa_id}` shape captured
        // from api.github.com: `references` is an array of plain STRINGS (not
        // `[{url}]`), and `vulnerabilities[]` carries extra keys (package,
        // vulnerable_version_range, …) we ignore. Forward-compat: extra
        // top-level fields must not break parsing.
        let json = r#"{
            "summary": "boom",
            "description": "details",
            "severity": "high",
            "references": ["https://example.com/x", "https://example.com/y"],
            "vulnerabilities": [{"first_patched_version": "1.0.0", "package": {"name": "p"}, "vulnerable_version_range": "< 1.0.0"}],
            "new_field_added_in_2027": {"nested": true},
            "another_unknown": [1, 2, 3]
        }"#;
        let raw: RawAdvisory = serde_json::from_str(json).expect("parse");
        let adv: GhsaAdvisory = raw.into();
        assert_eq!(adv.summary, "boom");
        assert_eq!(adv.description, "details");
        assert_eq!(adv.severity, "high");
        assert_eq!(
            adv.references,
            vec!["https://example.com/x".to_string(), "https://example.com/y".to_string()]
        );
        assert_eq!(adv.first_patched_version.as_deref(), Some("1.0.0"));
    }

    #[test]
    fn ghsa_advisory_references_accept_string_and_object_shapes() {
        // Defensive: tolerate BOTH the real string-array shape AND the
        // object-array (`[{url}]`) shape, so neither endpoint variant nor a
        // future change silently disables enrichment again.
        let strings: RawAdvisory =
            serde_json::from_str(r#"{"references": ["https://a/1"]}"#).expect("string-array");
        assert_eq!(GhsaAdvisory::from(strings).references, vec!["https://a/1"]);

        let objects: RawAdvisory =
            serde_json::from_str(r#"{"references": [{"url": "https://b/2"}]}"#).expect("object-array");
        assert_eq!(GhsaAdvisory::from(objects).references, vec!["https://b/2"]);
    }

    #[test]
    fn ghsa_advisory_picks_first_non_empty_patched_version() {
        // The first vulnerability with a non-empty first_patched_version
        // wins. Defensive against advisories with leading entries that
        // have no fix yet.
        let json = r#"{
            "vulnerabilities": [
                {"first_patched_version": null},
                {"first_patched_version": ""},
                {"first_patched_version": "2.0.0"},
                {"first_patched_version": "3.0.0"}
            ]
        }"#;
        let raw: RawAdvisory = serde_json::from_str(json).expect("parse");
        let adv: GhsaAdvisory = raw.into();
        assert_eq!(adv.first_patched_version.as_deref(), Some("2.0.0"));
    }

    // ---------- merge_into semantics ----------

    #[test]
    fn merge_only_overwrites_non_empty_fields() {
        // A sparse advisory must NOT clobber a well-populated OSV record.
        let mut v = RawVuln {
            id: "GHSA-abcd-1234-wxyz".into(),
            severity: Severity::High,
            summary: "OSV summary".into(),
            details: "OSV details".into(),
            fixed_in: Some("2.0.0".into()),
            references: vec!["https://osv.example/x".into()],
            ..Default::default()
        };
        let sparse = GhsaAdvisory::default();
        merge_into(&mut v, &sparse);
        assert_eq!(v.summary, "OSV summary");
        assert_eq!(v.details, "OSV details");
        assert_eq!(v.fixed_in.as_deref(), Some("2.0.0"));
        assert_eq!(v.references, vec!["https://osv.example/x"]);
    }

    #[test]
    fn merge_dedupes_references() {
        let mut v = RawVuln {
            references: vec!["https://example.com/a".into()],
            ..Default::default()
        };
        let adv = GhsaAdvisory {
            references: vec![
                "https://example.com/a".into(), // dup
                "https://example.com/b".into(), // new
            ],
            ..Default::default()
        };
        merge_into(&mut v, &adv);
        assert_eq!(
            v.references,
            vec![
                "https://example.com/a".to_string(),
                "https://example.com/b".to_string()
            ]
        );
    }

    #[test]
    fn merge_preserves_existing_fixed_in() {
        // OSV already told us the fix is "2.0.0". A GHSA "3.0.0" must
        // not silently override — fixed_in is only set when the vuln
        // had nothing.
        let mut v = RawVuln {
            fixed_in: Some("2.0.0".into()),
            ..Default::default()
        };
        let adv = GhsaAdvisory {
            first_patched_version: Some("3.0.0".into()),
            ..Default::default()
        };
        merge_into(&mut v, &adv);
        assert_eq!(v.fixed_in.as_deref(), Some("2.0.0"));
    }
}
