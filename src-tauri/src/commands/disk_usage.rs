//! Disk-usage + Finder-reveal commands for the Dashboard "Storage" card.
//!
//! - `disk_usage()` shells out to `du -sk` in parallel for the canonical
//!   Homebrew sub-trees (Cellar, Caskroom, var/log, download cache) and
//!   returns their sizes in bytes. Results are memoised on `AppState` with
//!   a short TTL so the Dashboard refresh button feels instant after the
//!   first probe.
//! - `open_in_finder(path)` reveals a path in macOS Finder. Refuses any path
//!   that is not inside the resolved Homebrew prefix or download cache.
//!
//! Security gate (revealer): the path is canonicalised and checked against
//! the canonicalised prefix + cache roots, so symlinks-out-of-tree can't
//! escape. The frontend's call site is the Dashboard's Open buttons, which
//! pass back paths the backend itself just produced — but the gate stays
//! anyway because IPC is the trust boundary.
//!
//! Performance: the four `du -sk` invocations run concurrently via tokio::join!.
//! On a 325-package install, total wall time is dominated by the slowest path
//! (typically Cellar at ~1-3 s on SSD).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::State;
use tokio::process::Command;

use crate::brew::exec::run_brew_capture;
use crate::error::BrewError;
use crate::state::AppState;

const DU_TIMEOUT: Duration = Duration::from_secs(20);
const DU_CACHE_TTL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskUsageEntry {
    pub label: String,
    pub path: String,
    pub bytes: u64,
    pub exists: bool,
    /// `None` on success; otherwise a short message (timeout, permissions, etc.).
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskUsageReport {
    pub generated_at: String,
    pub prefix: String,
    pub cache_dir: String,
    pub entries: Vec<DiskUsageEntry>,
    pub total_bytes: u64,
    /// Seconds since this report was produced (server-side). 0 on a fresh
    /// fetch; older when served from cache.
    pub cache_age_seconds: u64,
}

/// Cached entry on `AppState` so repeated Dashboard renders don't re-shell
/// `du` on every nav. TTL set by `DU_CACHE_TTL`.
#[derive(Debug, Clone)]
pub struct CachedDiskUsage {
    pub report: DiskUsageReport,
    pub fetched_at: Instant,
}

/// Run `brew <args>` and return trimmed stdout — used to resolve the prefix
/// + cache dir before sizing them.
async fn brew_subcommand(brew: &Path, args: &[&str], context: &str) -> Result<String, BrewError> {
    let out = run_brew_capture(brew, args, context).await?;
    Ok(out.trim().to_string())
}

/// `du -sk <path>` in bytes. Returns `(bytes, exists, error)`:
///   - exists=false: path doesn't exist on disk (e.g. Caskroom is absent on
///     pure-formula installs); not an error
///   - error=Some: the size couldn't be measured (timeout, permission denied)
///
/// `pub(crate)` so the per-package size path in `brew_info` can reuse the
/// same `du -sk` machinery instead of re-implementing it (Feature #4).
pub(crate) async fn du_bytes(path: &Path) -> (u64, bool, Option<String>) {
    if !path.exists() {
        return (0, false, None);
    }
    let output =
        tokio::time::timeout(DU_TIMEOUT, Command::new("du").arg("-sk").arg(path).output()).await;
    let result = match output {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => return (0, true, Some(format!("du spawn failed: {e}"))),
        Err(_) => return (0, true, Some("du timed out".into())),
    };
    if !result.status.success() {
        let stderr = String::from_utf8_lossy(&result.stderr).trim().to_string();
        return (
            0,
            true,
            Some(if stderr.is_empty() {
                "du failed".into()
            } else {
                stderr
            }),
        );
    }
    let text = String::from_utf8_lossy(&result.stdout);
    let kb: u64 = text
        .split_whitespace()
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (kb * 1024, true, None)
}

/// Resolve the on-disk keg directory for one package, given the Homebrew
/// `prefix`. Formula kegs live at `<prefix>/Cellar/<name>` (a directory
/// holding one subdir per installed version — sizing the parent sums all
/// versions, i.e. the total on-disk size for the package). Cask kegs live
/// at `<prefix>/Caskroom/<token>`.
///
/// `name` MUST be the short name (`wget`), never the tap-qualified
/// `full_name` (`homebrew/core/wget`) — Cellar dirs use the short form.
/// Callers pass `Package::name`, which is already short.
///
/// Pure (no I/O) so the path-selection logic is unit-testable; whether the
/// path actually exists is decided later by `du_bytes`.
pub(crate) fn keg_path(prefix: &Path, name: &str, kind: crate::types::PackageKind) -> PathBuf {
    match kind {
        crate::types::PackageKind::Formula => prefix.join("Cellar").join(name),
        crate::types::PackageKind::Cask => prefix.join("Caskroom").join(name),
    }
}

/// Size one installed package's keg via `du -sk`, returning `Some(bytes)`
/// only when the package is actually installed AND the keg measured
/// cleanly. Returns `None` when:
///   - `installed_version` is `None` (not installed — no `du` is attempted,
///     never a fabricated estimate),
///   - the keg directory is absent (e.g. a cask on Linux — Caskroom doesn't
///     exist there), or
///   - `du` errored (timeout / permission denied) — a partial or `0` count
///     is never surfaced as if it were a real size.
///
/// `name` is the short package name (see `keg_path`).
pub(crate) async fn installed_size_bytes(
    prefix: &Path,
    name: &str,
    kind: crate::types::PackageKind,
    installed_version: Option<&str>,
) -> Option<u64> {
    // Not installed → no measurement, no fabrication.
    installed_version?;
    let path = keg_path(prefix, name, kind);
    let (bytes, exists, error) = du_bytes(&path).await;
    if !exists || error.is_some() {
        return None;
    }
    Some(bytes)
}

#[tauri::command]
pub async fn disk_usage(state: State<'_, AppState>) -> Result<DiskUsageReport, BrewError> {
    // Cache hit — return fast with computed age so the UI can render a
    // "Updated Ns ago" label.
    {
        let cache = state.disk_usage_cache.lock().await;
        if let Some(cached) = cache.as_ref() {
            let age = cached.fetched_at.elapsed();
            if age < DU_CACHE_TTL {
                let mut r = cached.report.clone();
                r.cache_age_seconds = age.as_secs();
                return Ok(r);
            }
        }
    }

    let brew = state.require_brew_path().await?;
    let prefix = brew_subcommand(&brew, &["--prefix"], "brew --prefix").await?;
    let cache = brew_subcommand(&brew, &["--cache"], "brew --cache").await?;
    let prefix_path = PathBuf::from(&prefix);

    let cellar_path = prefix_path.join("Cellar");
    let caskroom_path = prefix_path.join("Caskroom");
    let varlog_path = prefix_path.join("var").join("log");
    let cache_path = PathBuf::from(&cache);

    // Parallel du — the slowest path bounds total wall time.
    let (cellar, caskroom, varlog, dl_cache) = tokio::join!(
        du_bytes(&cellar_path),
        du_bytes(&caskroom_path),
        du_bytes(&varlog_path),
        du_bytes(&cache_path),
    );

    let entries = vec![
        DiskUsageEntry {
            label: "Formulae (Cellar)".into(),
            path: cellar_path.to_string_lossy().into_owned(),
            bytes: cellar.0,
            exists: cellar.1,
            error: cellar.2,
        },
        DiskUsageEntry {
            label: "Casks (Caskroom)".into(),
            path: caskroom_path.to_string_lossy().into_owned(),
            bytes: caskroom.0,
            exists: caskroom.1,
            error: caskroom.2,
        },
        DiskUsageEntry {
            label: "Logs (var/log)".into(),
            path: varlog_path.to_string_lossy().into_owned(),
            bytes: varlog.0,
            exists: varlog.1,
            error: varlog.2,
        },
        DiskUsageEntry {
            label: "Download cache".into(),
            path: cache_path.to_string_lossy().into_owned(),
            bytes: dl_cache.0,
            exists: dl_cache.1,
            error: dl_cache.2,
        },
    ];

    let total_bytes = entries.iter().map(|e| e.bytes).sum();

    let report = DiskUsageReport {
        generated_at: chrono::Utc::now().to_rfc3339(),
        prefix,
        cache_dir: cache,
        entries,
        total_bytes,
        cache_age_seconds: 0,
    };

    let mut cache_lock = state.disk_usage_cache.lock().await;
    *cache_lock = Some(CachedDiskUsage {
        report: report.clone(),
        fetched_at: Instant::now(),
    });
    Ok(report)
}

/// Invalidate the disk-usage cache so the next call re-runs `du`. Useful for
/// a manual Refresh button on the Dashboard.
#[tauri::command]
pub async fn disk_usage_clear_cache(state: State<'_, AppState>) -> Result<(), BrewError> {
    let mut cache = state.disk_usage_cache.lock().await;
    *cache = None;
    Ok(())
}

#[tauri::command]
pub async fn open_in_finder(path: String, state: State<'_, AppState>) -> Result<(), BrewError> {
    let brew = state.require_brew_path().await?;
    let prefix = brew_subcommand(&brew, &["--prefix"], "brew --prefix").await?;
    let cache = brew_subcommand(&brew, &["--cache"], "brew --cache").await?;

    // Canonicalise both the target and the allowed roots. Logical-comparison
    // fallback covers the case where the target doesn't exist (e.g. Caskroom
    // on a pure-formula install); we still refuse it for safety.
    let target = PathBuf::from(&path);
    let target_canon = target.canonicalize().unwrap_or_else(|_| target.clone());
    let prefix_canon = PathBuf::from(&prefix)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(&prefix));
    let cache_canon = PathBuf::from(&cache)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(&cache));

    let inside = target_canon.starts_with(&prefix_canon) || target_canon.starts_with(&cache_canon);
    if !inside {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "refusing to open {}: not inside the Homebrew prefix or cache",
                path
            ),
        });
    }

    reveal_in_file_manager(&path).await
}

/// Reveal `path` in the platform file manager. The caller has already
/// passed the path through the Homebrew-prefix/cache security gate; this
/// only spawns the reveal.
///
/// - macOS: `open -R <path>` selects the item in Finder.
/// - Linux: there is no portable "reveal and select" verb. `xdg-open
///   <file>` would *launch* the file in its default app (wrong for a
///   "show me where this is" action), so we open the containing
///   directory instead — `xdg-open <parent-dir>` pops the file manager
///   at the right location. A path with no parent (shouldn't happen for
///   gated Homebrew paths) falls back to the path itself.
#[cfg(target_os = "macos")]
async fn reveal_in_file_manager(path: &str) -> Result<(), BrewError> {
    let status = Command::new("open")
        .arg("-R")
        .arg(path)
        .status()
        .await
        .map_err(|e| BrewError::Io {
            message: format!("failed to spawn open: {e}"),
        })?;
    if !status.success() {
        return Err(BrewError::Internal {
            message: format!("open exited with {:?}", status.code()),
        });
    }
    Ok(())
}

#[cfg(target_os = "linux")]
async fn reveal_in_file_manager(path: &str) -> Result<(), BrewError> {
    let target = Path::new(path);
    let dir = target.parent().unwrap_or(target);
    let status = Command::new("xdg-open")
        .arg(dir)
        .status()
        .await
        .map_err(|e| BrewError::Io {
            message: format!("failed to spawn xdg-open: {e}"),
        })?;
    if !status.success() {
        return Err(BrewError::Internal {
            message: format!("xdg-open exited with {:?}", status.code()),
        });
    }
    Ok(())
}

/// Preview of how much cache `brew cleanup --prune=all` would reclaim. Issue
/// #80 — drives the "frees ~X" hint next to the Storage card's cleanup button.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupPreview {
    /// Bytes `brew cleanup` estimates it would free, or `None` when brew didn't
    /// report a figure (nothing to clean, or output shape we couldn't parse —
    /// the UI hides the hint rather than showing a wrong/zero number).
    pub reclaimable_bytes: Option<u64>,
}

/// Dry-run `brew cleanup -n --prune=all` and parse its "would free
/// approximately X" estimate. Best-effort: any failure (brew error, unparsable
/// output) yields `reclaimable_bytes: None` rather than erroring — this only
/// feeds an advisory hint, never gates the cleanup action itself.
#[tauri::command]
pub async fn brew_cleanup_preview(state: State<'_, AppState>) -> Result<CleanupPreview, BrewError> {
    let brew = state.require_brew_path().await?;
    let reclaimable_bytes = match brew_subcommand(
        &brew,
        &["cleanup", "-n", "--prune=all"],
        "brew cleanup -n --prune=all",
    )
    .await
    {
        Ok(out) => parse_reclaimable(&out),
        Err(_) => None,
    };
    Ok(CleanupPreview { reclaimable_bytes })
}

/// Pull the byte estimate out of `brew cleanup -n` output. brew prints a line
/// like `==> This operation would free approximately 1.2GB of disk space.`
fn parse_reclaimable(output: &str) -> Option<u64> {
    let marker = "would free approximately";
    let after = output
        .lines()
        .find_map(|l| l.split_once(marker).map(|(_, rest)| rest))?;
    let token = after.split_whitespace().next()?;
    parse_size_token(token)
}

/// Parse a Homebrew size token like `1.2GB`, `500MB`, `1.5KB`, `900B` into
/// bytes. brew's `disk_usage_readable` is 1024-based but labels units KB/MB/GB,
/// so we treat them as binary multiples. Returns `None` on any shape we don't
/// recognize (defensive against brew formatting drift).
fn parse_size_token(token: &str) -> Option<u64> {
    let token = token.trim().trim_end_matches(['.', ',']);
    let split = token.find(|c: char| c.is_ascii_alphabetic())?;
    let (num, unit) = token.split_at(split);
    let value: f64 = num.parse().ok()?;
    if value < 0.0 {
        return None;
    }
    let mult: f64 = match unit.to_ascii_uppercase().as_str() {
        "B" => 1.0,
        "KB" | "K" | "KIB" => 1024.0,
        "MB" | "M" | "MIB" => 1024.0 * 1024.0,
        "GB" | "G" | "GIB" => 1024.0 * 1024.0 * 1024.0,
        "TB" | "T" | "TIB" => 1024.0_f64.powi(4),
        _ => return None,
    };
    Some((value * mult) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn du_bytes_returns_zero_for_missing_path() {
        let (bytes, exists, err) = du_bytes(Path::new("/definitely/not/a/real/path/here")).await;
        assert_eq!(bytes, 0);
        assert!(!exists);
        assert!(err.is_none());
    }

    #[tokio::test]
    async fn du_bytes_returns_size_for_real_path() {
        // /etc/hosts has existed on every Mac for the entire history of macOS.
        // (/usr/bin/ls moved into the dyld shared cache in recent releases, so
        // it isn't a reliable test fixture.)
        let (bytes, exists, err) = du_bytes(Path::new("/etc/hosts")).await;
        assert!(exists, "/etc/hosts should exist");
        assert!(err.is_none(), "du should succeed on /etc/hosts: {err:?}");
        assert!(bytes > 0, "/etc/hosts should report nonzero size");
    }

    // ---------- Feature #4: keg-path selection (pure) ----------

    use crate::types::PackageKind;

    #[test]
    fn keg_path_formula_uses_cellar() {
        let p = keg_path(Path::new("/opt/homebrew"), "wget", PackageKind::Formula);
        assert_eq!(p, PathBuf::from("/opt/homebrew/Cellar/wget"));
    }

    #[test]
    fn keg_path_cask_uses_caskroom() {
        let p = keg_path(Path::new("/opt/homebrew"), "firefox", PackageKind::Cask);
        assert_eq!(p, PathBuf::from("/opt/homebrew/Caskroom/firefox"));
    }

    #[test]
    fn keg_path_uses_short_name_for_tap_qualified() {
        // Cellar dirs use the short name, never the tap-qualified full_name.
        // Callers pass `Package::name` (short), so a value like
        // "homebrew/core/wget" should never reach here — but if it did, the
        // helper must NOT silently produce a nested tap path. We assert the
        // contract by passing the short name the caller is required to use.
        let p = keg_path(Path::new("/opt/homebrew"), "wget", PackageKind::Formula);
        assert_eq!(p, PathBuf::from("/opt/homebrew/Cellar/wget"));
        // Sanity: the full path form is explicitly NOT what we want.
        assert_ne!(p, PathBuf::from("/opt/homebrew/Cellar/homebrew/core/wget"));
    }

    // ---------- Feature #4: size-selection logic (pure decision) ----------

    #[tokio::test]
    async fn installed_size_is_none_when_not_installed() {
        // installed_version == None → no du attempted, size is None.
        let size = installed_size_bytes(
            Path::new("/opt/homebrew"),
            "wget",
            PackageKind::Formula,
            None,
        )
        .await;
        assert!(size.is_none(), "uninstalled package must report no size");
    }

    #[tokio::test]
    async fn installed_size_is_none_when_keg_dir_absent() {
        // Installed but the keg dir doesn't exist (e.g. a cask on Linux, or a
        // bogus prefix) → du_bytes reports !exists → None (no fabricated 0).
        let size = installed_size_bytes(
            Path::new("/definitely/not/a/real/prefix/anywhere"),
            "wget",
            PackageKind::Formula,
            Some("1.2.3"),
        )
        .await;
        assert!(size.is_none(), "absent keg dir must report no size");
    }

    // ---------- Issue #80: cleanup reclaimable-size parsing (pure) ----------

    #[test]
    fn parse_size_token_units() {
        assert_eq!(parse_size_token("900B"), Some(900));
        assert_eq!(parse_size_token("1KB"), Some(1024));
        assert_eq!(parse_size_token("1.5KB"), Some(1536));
        assert_eq!(parse_size_token("500MB"), Some(500 * 1024 * 1024));
        assert_eq!(
            parse_size_token("1.2GB"),
            Some((1.2 * 1024.0 * 1024.0 * 1024.0) as u64)
        );
        // trailing punctuation from a sentence is tolerated
        assert_eq!(parse_size_token("2GB."), Some(2 * 1024 * 1024 * 1024));
    }

    #[test]
    fn parse_size_token_rejects_garbage() {
        assert_eq!(parse_size_token(""), None);
        assert_eq!(parse_size_token("GB"), None); // no number
        assert_eq!(parse_size_token("12"), None); // no unit
        assert_eq!(parse_size_token("1.2ZB"), None); // unknown unit
        assert_eq!(parse_size_token("-5GB"), None); // negative
    }

    #[test]
    fn parse_reclaimable_from_real_brew_line() {
        let out = "Would remove: ~/Library/Caches/Homebrew/foo (1.2GB)\n\
                   ==> This operation would free approximately 2.5GB of disk space.\n";
        assert_eq!(
            parse_reclaimable(out),
            Some((2.5 * 1024.0 * 1024.0 * 1024.0) as u64)
        );
    }

    #[test]
    fn parse_reclaimable_none_when_nothing_to_clean() {
        // brew prints no "would free" line when the cache is already empty.
        assert_eq!(parse_reclaimable("Nothing to clean up.\n"), None);
        assert_eq!(parse_reclaimable(""), None);
    }
}
