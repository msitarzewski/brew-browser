//! Per-package vulnerability scan cache (in-memory + on-disk).
//!
//! Two distinct freshness checks live here:
//!
//! 1. **Per-package TTL** (`VULNS_CACHE_TTL` = 6h). A scan record for
//!    `(kind, name, version)` is "fresh" if it was written within the
//!    last 6 hours. Beyond that, the next `brew vulns` invocation
//!    refreshes the entry. Matches the trending-history TTL — OSV
//!    publishes at most a handful of new advisories per day, so anything
//!    within the same six-hour window is effectively immutable.
//!
//! 2. **Install-set fingerprint** (see [`crate::vulns::fingerprint`]).
//!    The whole-scan skip optimization: if the current install
//!    fingerprint matches the one recorded at the last scan AND the
//!    fingerprint scan itself is within TTL, the backend skips
//!    re-invoking `brew vulns` entirely. Cached per-package answers
//!    stay valid because the install set hasn't changed.
//!
//! Persistence path: `<app_data_dir>/vulns_cache.json`. Written via
//! [`crate::util::fs::atomic_write`] for crash safety. Bounded at
//! [`MAX_VULNS_CACHE_BYTES`] on both read and write — a runaway scan
//! (or a hand-edited file) can't OOM the backend.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::BrewError;
use crate::types::PackageKind;
use crate::util::fs::{atomic_write, read_capped};
use crate::vulns::client::RawVuln;

/// Per-package freshness window. Six hours matches the trending-history
/// cache — long enough that the typical Refresh-and-Refresh-again user
/// pattern hits the cache, short enough that "scan after a brew update"
/// always pulls a fresh OSV view.
pub const VULNS_CACHE_TTL: Duration = Duration::from_secs(6 * 60 * 60);

/// Hard cap on persisted entries. Most users have under 200 installed
/// formulae; 1000 leaves plenty of headroom for power users plus a
/// dependency closure scan without unbounded growth. Eviction is
/// LRU-by-scanned-at when the map exceeds the cap.
pub const VULNS_CACHE_MAX_ENTRIES: usize = 1000;

/// 1 MiB cap on the on-disk cache file. Defense against a corrupted
/// or hostile `vulns_cache.json`. With 1000 entries × ~1 KB each =
/// 1 MB at worst case, this is comfortably above realistic load.
pub const MAX_VULNS_CACHE_BYTES: u64 = 1024 * 1024;

/// Bump when the on-disk format changes in a way that requires
/// migration. v0 means "no file at all"; v1 is the initial shape.
pub const VULNS_CACHE_SCHEMA_VERSION: u32 = 1;

/// On-disk shape. Serialized as JSON with camelCase keys to match the
/// rest of the persisted state. Every field has `#[serde(default)]` so
/// older files (v0 → first launch) and forward-compat fields read
/// cleanly.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct VulnsCacheFile {
    /// Schema version of this file. See [`VULNS_CACHE_SCHEMA_VERSION`].
    /// A future bump triggers a one-shot migration in [`VulnsCache::load`].
    pub schema_version: u32,

    /// SHA-256 fingerprint of the install set at the last full scan.
    /// Empty string before the first scan.
    pub install_fingerprint: String,

    /// Wall-clock instant the fingerprint was last verified by a
    /// successful `brew vulns` run. `None` before the first scan.
    pub fingerprint_scanned_at: Option<DateTime<Utc>>,

    /// Per-package scan records. Key is `"{kind}:{name}:{version}"`
    /// so the map serializes cleanly as JSON (HashMap keys must be
    /// strings). The structured form is reconstructable via
    /// [`VulnKey::parse`].
    pub entries: HashMap<String, ScanRecord>,
}

/// One scan record for a single installed `(kind, name, version)`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ScanRecord {
    /// Wall-clock instant `brew vulns` produced this record.
    pub scanned_at: DateTime<Utc>,
    /// Vulnerabilities reported. Empty vec = scan completed and the
    /// package is known-clean at this version (a positive signal,
    /// distinct from "no record exists").
    pub vulns: Vec<RawVuln>,
}

/// Structured key for a cache entry. Stored as the stringified
/// `"{kind}:{name}:{version}"` form on disk but exposed as a typed
/// struct in memory for ergonomic access.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct VulnKey {
    pub kind: PackageKind,
    pub name: String,
    pub version: String,
}

impl VulnKey {
    /// Serialize to the on-disk key form.
    pub fn to_storage_key(&self) -> String {
        format!("{}:{}:{}", kind_token(self.kind), self.name, self.version)
    }

    /// Parse the on-disk key form. Returns `None` for malformed input;
    /// callers should drop unparseable entries (probably from a future
    /// schema or a corrupted file) rather than fail-open.
    ///
    /// Currently uncalled (cache loading treats stored keys as opaque
    /// strings); kept as the documented inverse of `to_storage_key`.
    #[allow(dead_code)]
    pub fn parse(s: &str) -> Option<Self> {
        // Split on the first two `:` so names with `@` (openssl@3) or
        // versions with `:` (rare but possible for epoch-style versions)
        // round-trip cleanly. Brew formula names allow `:` per
        // formulae.brew.sh? Defensive: cap splits to 3 segments and
        // join the trailing remainder back into the version.
        let mut parts = s.splitn(3, ':');
        let kind_str = parts.next()?;
        let name = parts.next()?;
        let version = parts.next()?;
        let kind = match kind_str {
            "formula" => PackageKind::Formula,
            "cask" => PackageKind::Cask,
            _ => return None,
        };
        Some(VulnKey {
            kind,
            name: name.to_string(),
            version: version.to_string(),
        })
    }
}

fn kind_token(k: PackageKind) -> &'static str {
    match k {
        PackageKind::Formula => "formula",
        PackageKind::Cask => "cask",
    }
}

/// In-memory cache wrapper. Holds the parsed file plus a dirty flag so
/// the caller can decide when to flush (typically after every mutation
/// that survives a scan run).
#[derive(Debug, Default)]
pub struct VulnsCache {
    pub file: VulnsCacheFile,
    pub dirty: bool,
}

impl VulnsCache {
    /// Build a fresh empty cache with the current schema version stamped.
    pub fn new_empty() -> Self {
        Self {
            file: VulnsCacheFile {
                schema_version: VULNS_CACHE_SCHEMA_VERSION,
                ..Default::default()
            },
            dirty: false,
        }
    }

    /// Load from `<app_data_dir>/vulns_cache.json`. Returns an empty
    /// cache when the file is missing, malformed, oversize, or from a
    /// future schema — log-and-continue rather than fail-closed,
    /// because losing the cache only costs one re-scan.
    pub async fn load(app_data_dir: &Path) -> Self {
        let path = cache_path(app_data_dir);
        if !path.exists() {
            return Self::new_empty();
        }
        match read_capped(&path, MAX_VULNS_CACHE_BYTES).await {
            Ok(bytes) => match serde_json::from_slice::<VulnsCacheFile>(&bytes) {
                Ok(file) => {
                    if file.schema_version > VULNS_CACHE_SCHEMA_VERSION {
                        tracing::warn!(
                            "vulns cache: schema {} newer than supported {}; ignoring",
                            file.schema_version,
                            VULNS_CACHE_SCHEMA_VERSION
                        );
                        return Self::new_empty();
                    }
                    Self { file, dirty: false }
                }
                Err(e) => {
                    tracing::warn!("vulns cache: parse failed ({e}); starting empty");
                    Self::new_empty()
                }
            },
            Err(e) => {
                tracing::warn!("vulns cache: read failed ({e}); starting empty");
                Self::new_empty()
            }
        }
    }

    /// Persist the cache atomically. No-op when not dirty so caller
    /// loops can `save_if_dirty` cheaply.
    pub async fn save_if_dirty(&mut self, app_data_dir: &Path) -> Result<(), BrewError> {
        if !self.dirty {
            return Ok(());
        }
        let path = cache_path(app_data_dir);
        let bytes = serde_json::to_vec(&self.file).map_err(|e| BrewError::Io {
            message: format!("vulns cache: serialize: {e}"),
        })?;
        if bytes.len() as u64 > MAX_VULNS_CACHE_BYTES {
            return Err(BrewError::Io {
                message: format!(
                    "vulns cache: serialized size {} exceeds cap {}",
                    bytes.len(),
                    MAX_VULNS_CACHE_BYTES
                ),
            });
        }
        atomic_write(&path, &bytes).await?;
        self.dirty = false;
        Ok(())
    }

    /// Lookup a record. Returns `None` if absent OR stale.
    ///
    /// No production caller since the scan flow moved to whole-set
    /// fingerprint skips; exercised by the tests below and kept as the
    /// per-key TTL counterpart of the stale-tolerant lookup.
    #[allow(dead_code)]
    pub fn get_fresh(&self, key: &VulnKey) -> Option<&ScanRecord> {
        let rec = self.file.entries.get(&key.to_storage_key())?;
        if record_is_fresh(rec) {
            Some(rec)
        } else {
            None
        }
    }

    /// Lookup a record regardless of freshness. Useful for the
    /// "serve stale on fetch failure" path.
    #[allow(dead_code)]
    pub fn get_any(&self, key: &VulnKey) -> Option<&ScanRecord> {
        self.file.entries.get(&key.to_storage_key())
    }

    /// Insert or replace a record. Marks the cache dirty. Evicts the
    /// oldest entry when the map would exceed [`VULNS_CACHE_MAX_ENTRIES`].
    pub fn put(&mut self, key: VulnKey, vulns: Vec<RawVuln>) {
        let storage_key = key.to_storage_key();
        if !self.file.entries.contains_key(&storage_key)
            && self.file.entries.len() >= VULNS_CACHE_MAX_ENTRIES
        {
            // Find and evict the oldest entry by scanned_at. O(n) but
            // n ≤ 1000 and eviction happens at most once per insert.
            if let Some(oldest_key) = self
                .file
                .entries
                .iter()
                .min_by_key(|(_, v)| v.scanned_at)
                .map(|(k, _)| k.clone())
            {
                self.file.entries.remove(&oldest_key);
            }
        }
        self.file.entries.insert(
            storage_key,
            ScanRecord {
                scanned_at: Utc::now(),
                vulns,
            },
        );
        self.dirty = true;
    }

    /// Replace ALL per-package entries with the given full-scan results.
    ///
    /// A full `brew vulns` run is authoritative for the entire install: the
    /// packages it returns ARE the complete set of currently-vulnerable
    /// packages. Merging each result via [`Self::put`] (the old behavior) and
    /// returning the whole cache left stale records — old versions of a package
    /// and packages OSV no longer flags — accumulating across scans, which
    /// inflated the Exposure rollup far above the raw `brew vulns` count (a real
    /// bug: 33 findings surfaced vs 17 actually reported). Clearing first drops
    /// that cruft so the cache always mirrors the latest scan, exactly like the
    /// native shell's wholesale `vulnFindings = findings`. Fingerprint state is
    /// preserved (set separately via [`Self::record_fingerprint`]).
    pub fn replace_full_scan(
        &mut self,
        records: impl IntoIterator<Item = (VulnKey, Vec<RawVuln>)>,
    ) {
        self.file.entries.clear();
        let now = Utc::now();
        for (key, vulns) in records {
            self.file.entries.insert(
                key.to_storage_key(),
                ScanRecord {
                    scanned_at: now,
                    vulns,
                },
            );
        }
        self.dirty = true;
    }

    /// Drop an entry by key. Marks dirty if anything was removed.
    /// Called after a successful upgrade/uninstall so the next scan
    /// can't surface a CVE for a version the user no longer has.
    pub fn invalidate(&mut self, key: &VulnKey) -> bool {
        let removed = self.file.entries.remove(&key.to_storage_key()).is_some();
        if removed {
            self.dirty = true;
        }
        removed
    }

    /// Record the install-set fingerprint after a successful full
    /// scan. Pairs with [`Self::should_skip_full_scan`] on the next
    /// scan invocation.
    pub fn record_fingerprint(&mut self, fingerprint: String) {
        self.file.install_fingerprint = fingerprint;
        self.file.fingerprint_scanned_at = Some(Utc::now());
        self.dirty = true;
    }

    /// Whole-scan skip predicate: the install set hasn't changed since
    /// the last full scan AND that scan happened within TTL.
    pub fn should_skip_full_scan(&self, current_fingerprint: &str) -> bool {
        if self.file.install_fingerprint != current_fingerprint
            || self.file.install_fingerprint.is_empty()
        {
            return false;
        }
        match self.file.fingerprint_scanned_at {
            Some(ts) => fingerprint_is_fresh(ts),
            None => false,
        }
    }
}

/// Resolve the on-disk cache path under `<app_data_dir>/vulns_cache.json`.
pub fn cache_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("vulns_cache.json")
}

/// Per-record freshness check. Pulled out so the predicate is easy to
/// stub in tests if we ever need a synthetic clock. (Only caller is
/// `get_fresh`, itself currently test-only — see there.)
#[allow(dead_code)]
fn record_is_fresh(rec: &ScanRecord) -> bool {
    elapsed_since(rec.scanned_at) < VULNS_CACHE_TTL
}

fn fingerprint_is_fresh(ts: DateTime<Utc>) -> bool {
    elapsed_since(ts) < VULNS_CACHE_TTL
}

fn elapsed_since(ts: DateTime<Utc>) -> Duration {
    let delta = Utc::now() - ts;
    // chrono returns a signed duration; clamp negative drift (clock
    // moved backwards) to zero so the freshness window never falsely
    // expires.
    delta.to_std().unwrap_or(Duration::ZERO)
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vulns::client::{RawVuln, Severity};

    fn key(name: &str, version: &str) -> VulnKey {
        VulnKey {
            kind: PackageKind::Formula,
            name: name.into(),
            version: version.into(),
        }
    }

    fn vuln(id: &str) -> RawVuln {
        RawVuln {
            id: id.into(),
            severity: Severity::High,
            summary: "boom".into(),
            ..Default::default()
        }
    }

    #[test]
    fn ttl_is_six_hours() {
        assert_eq!(VULNS_CACHE_TTL, Duration::from_secs(6 * 60 * 60));
    }

    #[test]
    fn empty_cache_has_no_entries() {
        let c = VulnsCache::new_empty();
        assert!(c.get_fresh(&key("curl", "8.4.0")).is_none());
        assert_eq!(c.file.schema_version, VULNS_CACHE_SCHEMA_VERSION);
        assert!(!c.dirty);
    }

    #[test]
    fn put_then_get_fresh_returns_record() {
        let mut c = VulnsCache::new_empty();
        c.put(key("openssl@3", "3.2.0"), vec![vuln("GHSA-1234")]);
        let got = c
            .get_fresh(&key("openssl@3", "3.2.0"))
            .expect("just-inserted");
        assert_eq!(got.vulns.len(), 1);
        assert_eq!(got.vulns[0].id, "GHSA-1234");
        assert!(c.dirty, "put must dirty the cache");
    }

    #[test]
    fn put_with_empty_vulns_records_clean_state() {
        // Empty vec ≠ absence: it means "we scanned and found nothing".
        // The UI uses this to render a positive "no known vulns" signal.
        let mut c = VulnsCache::new_empty();
        c.put(key("ripgrep", "14.1.0"), vec![]);
        let got = c.get_fresh(&key("ripgrep", "14.1.0")).expect("present");
        assert!(got.vulns.is_empty());
    }

    #[test]
    fn replace_full_scan_drops_stale_entries() {
        // Regression for the Exposure over-count: a full scan must REPLACE the
        // cache, not accumulate. Prior scans left stale records.
        let mut c = VulnsCache::new_empty();
        c.put(key("augeas", "1.14.0"), vec![vuln("CVE-OLD")]); // old version
        c.put(
            key("ghostscript", "10.0"),
            vec![vuln("CVE-GONE-1"), vuln("CVE-GONE-2")],
        ); // no longer flagged
        assert_eq!(c.file.entries.len(), 2);

        // Fresh full scan: only augeas@1.14.1 with two findings.
        c.replace_full_scan([(key("augeas", "1.14.1"), vec![vuln("CVE-A"), vuln("CVE-B")])]);

        assert_eq!(c.file.entries.len(), 1, "stale entries must be cleared");
        assert!(c.get_any(&key("augeas", "1.14.1")).is_some());
        assert!(
            c.get_any(&key("augeas", "1.14.0")).is_none(),
            "old version dropped"
        );
        assert!(
            c.get_any(&key("ghostscript", "10.0")).is_none(),
            "no-longer-flagged dropped"
        );
        let total: usize = c.file.entries.values().map(|r| r.vulns.len()).sum();
        assert_eq!(
            total, 2,
            "finding total reflects the scan, not the accumulation"
        );
        assert!(c.dirty);
    }

    #[test]
    fn invalidate_removes_entry_and_dirties() {
        let mut c = VulnsCache::new_empty();
        c.put(key("curl", "8.4.0"), vec![vuln("CVE-1")]);
        c.dirty = false;
        assert!(c.invalidate(&key("curl", "8.4.0")));
        assert!(c.get_fresh(&key("curl", "8.4.0")).is_none());
        assert!(c.dirty);
    }

    #[test]
    fn invalidate_missing_key_is_noop() {
        let mut c = VulnsCache::new_empty();
        assert!(!c.invalidate(&key("nope", "1.0.0")));
        assert!(!c.dirty, "missing-key invalidate must not dirty");
    }

    #[test]
    fn evicts_oldest_at_cap() {
        let mut c = VulnsCache::new_empty();
        // Synthesize entries by hand-mutating the map so we can control
        // scanned_at — calling put() N times would use Utc::now()
        // which is monotonic-ish but doesn't give us a deterministic
        // "oldest" without sleeping.
        for i in 0..VULNS_CACHE_MAX_ENTRIES {
            let storage = format!("formula:pkg{i}:1.0.0");
            c.file.entries.insert(
                storage,
                ScanRecord {
                    scanned_at: Utc::now() + chrono::Duration::seconds(i as i64),
                    vulns: vec![],
                },
            );
        }
        assert_eq!(c.file.entries.len(), VULNS_CACHE_MAX_ENTRIES);

        // pkg0 is the oldest (lowest scanned_at). Inserting one more
        // should evict it.
        c.put(key("newcomer", "1.0.0"), vec![]);
        assert_eq!(c.file.entries.len(), VULNS_CACHE_MAX_ENTRIES);
        assert!(c.get_fresh(&key("newcomer", "1.0.0")).is_some());
        assert!(
            !c.file.entries.contains_key("formula:pkg0:1.0.0"),
            "pkg0 (oldest) must have been evicted"
        );
    }

    #[test]
    fn fingerprint_skip_requires_match_and_recency() {
        let mut c = VulnsCache::new_empty();
        // Empty cache: skip predicate is false (no recorded fingerprint).
        assert!(!c.should_skip_full_scan("abc123"));

        c.record_fingerprint("abc123".into());
        // Matching fingerprint + fresh timestamp → skip.
        assert!(c.should_skip_full_scan("abc123"));
        // Different fingerprint → must scan.
        assert!(!c.should_skip_full_scan("different"));
    }

    #[test]
    fn fingerprint_skip_false_when_fingerprint_empty() {
        let mut c = VulnsCache::new_empty();
        // Defense in depth: even if a caller somehow passes an empty
        // fingerprint AND the cache has empty fingerprint, never skip.
        // A first-launch user would otherwise skip the scan they
        // explicitly asked for.
        c.file.install_fingerprint = String::new();
        c.file.fingerprint_scanned_at = Some(Utc::now());
        assert!(!c.should_skip_full_scan(""));
    }

    #[test]
    fn vuln_key_round_trips_through_storage_form() {
        let original = key("openssl@3", "3.2.0");
        let stored = original.to_storage_key();
        assert_eq!(stored, "formula:openssl@3:3.2.0");
        let parsed = VulnKey::parse(&stored).expect("parse");
        assert_eq!(parsed, original);
    }

    #[test]
    fn vuln_key_parses_versions_with_colons() {
        // Defensive: epoch-style versions exist in Debian world. The
        // splitn(3) call must keep the version intact even when it
        // contains a `:`.
        let stored = "formula:weird:1:2.0";
        let parsed = VulnKey::parse(stored).expect("parse");
        assert_eq!(parsed.name, "weird");
        assert_eq!(parsed.version, "1:2.0");
    }

    #[test]
    fn vuln_key_rejects_unknown_kind() {
        assert!(VulnKey::parse("widget:foo:1.0.0").is_none());
        assert!(VulnKey::parse("").is_none());
        assert!(VulnKey::parse("formula").is_none());
        assert!(VulnKey::parse("formula:foo").is_none());
    }

    #[tokio::test]
    async fn save_and_load_round_trips() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut c = VulnsCache::new_empty();
        c.put(key("openssl@3", "3.2.0"), vec![vuln("GHSA-xxxx")]);
        c.record_fingerprint("abc123".into());

        c.save_if_dirty(tmp.path()).await.expect("save");
        assert!(!c.dirty, "save_if_dirty must clear the dirty flag");
        assert!(cache_path(tmp.path()).exists());

        let loaded = VulnsCache::load(tmp.path()).await;
        assert_eq!(loaded.file.install_fingerprint, "abc123");
        assert!(loaded.file.fingerprint_scanned_at.is_some());
        let rec = loaded
            .get_fresh(&key("openssl@3", "3.2.0"))
            .expect("present after reload");
        assert_eq!(rec.vulns[0].id, "GHSA-xxxx");
    }

    #[tokio::test]
    async fn save_if_dirty_is_noop_when_clean() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut c = VulnsCache::new_empty();
        // No mutations → no dirty bit → save is a no-op and no file.
        c.save_if_dirty(tmp.path()).await.expect("noop save");
        assert!(!cache_path(tmp.path()).exists());
    }

    #[tokio::test]
    async fn load_returns_empty_when_file_missing() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let c = VulnsCache::load(tmp.path()).await;
        assert!(c.file.entries.is_empty());
        assert_eq!(c.file.schema_version, VULNS_CACHE_SCHEMA_VERSION);
    }

    #[tokio::test]
    async fn load_returns_empty_when_file_corrupt() {
        let tmp = tempfile::tempdir().expect("tempdir");
        tokio::fs::write(cache_path(tmp.path()), b"{not json")
            .await
            .unwrap();
        let c = VulnsCache::load(tmp.path()).await;
        // Fail-soft: corrupt cache file → empty cache, not a panic.
        // Losing the cache only costs one re-scan.
        assert!(c.file.entries.is_empty());
    }

    #[tokio::test]
    async fn load_returns_empty_when_schema_newer_than_supported() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let future = VulnsCacheFile {
            schema_version: VULNS_CACHE_SCHEMA_VERSION + 1,
            install_fingerprint: "future".into(),
            ..Default::default()
        };
        let bytes = serde_json::to_vec(&future).unwrap();
        tokio::fs::write(cache_path(tmp.path()), bytes)
            .await
            .unwrap();
        let c = VulnsCache::load(tmp.path()).await;
        // Forward-compat: a v0.5.1 cache file must not crash v0.5.0.
        // Drop it and start fresh — same outcome as the corrupt case.
        assert!(c.file.entries.is_empty());
        assert_eq!(c.file.install_fingerprint, "");
    }
}
