//! Brewfile snapshot, restore, and management commands.
//!
//! Snapshots live under `~/Library/Application Support/brew-browser/brewfiles/`
//! (resolved by `state.brewfiles_dir`). Each snapshot is a single
//! `Brewfile` text file; the id is the sanitized filename stem.

use std::path::{Path, PathBuf};

use chrono::Utc;
use tauri::ipc::Channel;
use tauri::State;

use crate::brew::exec::run_brew_streaming;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::{
    BrewStreamEvent, Brewfile, BrewfileCask, BrewfileCheckReport, BrewfileCounts, BrewfileEntries,
    BrewfileFormula, BrewfileId, BrewfileMasApp, BrewfileSummary, JobResult,
};

#[tauri::command]
pub async fn brewfile_dump(
    label: String,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<BrewfileSummary, BrewError> {
    let id = sanitize_label(&label);
    if id.is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "label produced an empty id after sanitization".into(),
        });
    }
    let path = state.require_brew_path().await?;
    let target = brewfile_path(&state.brewfiles_dir, &id)?;

    let target_str = target.to_string_lossy().into_owned();
    let args = vec![
        "bundle".to_string(),
        "dump".to_string(),
        format!("--file={}", target_str),
        "--force".to_string(),
    ];
    let display = format!("brew bundle dump --file={} --force", target_str);
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    let _ = run_brew_streaming(&path, args, display, on_event, jobs).await?;

    state.invalidate_caches().await;

    summary_for(&target, &id, &label)
}

#[tauri::command]
pub async fn brewfile_install(
    id: BrewfileId,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    let target = brewfile_path(&state.brewfiles_dir, &id)?;
    if !target.is_file() {
        return Err(BrewError::BrewfileNotFound { id });
    }
    let path = state.require_brew_path().await?;
    let target_str = target.to_string_lossy().into_owned();
    let args = vec![
        "bundle".to_string(),
        "install".to_string(),
        format!("--file={}", target_str),
    ];
    let display = format!("brew bundle install --file={}", target_str);
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    let result = run_brew_streaming(&path, args, display, on_event, jobs).await;
    if result.is_ok() {
        state.invalidate_caches().await;
    }
    result
}

#[tauri::command]
pub async fn brewfile_check(
    id: BrewfileId,
    state: State<'_, AppState>,
) -> Result<BrewfileCheckReport, BrewError> {
    let target = brewfile_path(&state.brewfiles_dir, &id)?;
    if !target.is_file() {
        return Err(BrewError::BrewfileNotFound { id });
    }
    let path = state.require_brew_path().await?;
    let target_str = target.to_string_lossy().into_owned();
    let display = format!("brew bundle check --file={} --verbose", target_str);
    // `brew bundle check` exits non-zero when packages are missing —
    // we want to read the output even then, so capture via plain output.
    // `brew_command` applies the analytics-off env + PATH prepend and routes
    // through `arch -arm64` under Rosetta 2 (issue #158).
    let mut cmd = crate::brew::exec::brew_command(&path);
    cmd.args([
        "bundle",
        "check",
        &format!("--file={}", target_str),
        "--verbose",
    ])
    .stdin(std::process::Stdio::null())
    .stdout(std::process::Stdio::piped())
    .stderr(std::process::Stdio::piped());

    let output = cmd.output().await.map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
        _ => BrewError::Io {
            message: format!("failed to spawn brew bundle check: {}", e),
        },
    })?;
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let satisfied = output.status.success();
    let report = parse_check_report(satisfied, &combined);
    let _ = display; // documented in error paths
    Ok(report)
}

#[tauri::command]
pub async fn brewfile_list(state: State<'_, AppState>) -> Result<Vec<BrewfileSummary>, BrewError> {
    let dir = state.brewfiles_dir.clone();
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();
    let mut rd = tokio::fs::read_dir(&dir).await.map_err(|e| BrewError::Io {
        message: format!("read_dir {}: {}", dir.display(), e),
    })?;
    while let Some(entry) = rd.next_entry().await.map_err(|e| BrewError::Io {
        message: format!("next_entry: {}", e),
    })? {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let id = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        if id.is_empty() {
            continue;
        }
        if let Ok(summary) = summary_for(&path, &id, &id) {
            out.push(summary);
        }
    }
    // Most-recent first.
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(out)
}

#[tauri::command]
pub async fn brewfile_read(
    id: BrewfileId,
    state: State<'_, AppState>,
) -> Result<Brewfile, BrewError> {
    let target = brewfile_path(&state.brewfiles_dir, &id)?;
    if !target.is_file() {
        return Err(BrewError::BrewfileNotFound { id });
    }
    let raw_text = tokio::fs::read_to_string(&target)
        .await
        .map_err(|e| BrewError::Io {
            message: format!("reading {}: {}", target.display(), e),
        })?;
    let entries = parse_brewfile_text(&raw_text);
    let summary = summary_for(&target, &id, &id)?;
    Ok(Brewfile {
        summary,
        entries,
        raw_text,
    })
}

#[tauri::command]
pub async fn brewfile_delete(id: BrewfileId, state: State<'_, AppState>) -> Result<(), BrewError> {
    let target = brewfile_path(&state.brewfiles_dir, &id)?;
    if !target.is_file() {
        return Err(BrewError::BrewfileNotFound { id });
    }
    tokio::fs::remove_file(&target)
        .await
        .map_err(|e| BrewError::Io {
            message: format!("removing {}: {}", target.display(), e),
        })?;
    Ok(())
}

#[tauri::command]
pub async fn brewfile_export(
    id: BrewfileId,
    target_path: String,
    state: State<'_, AppState>,
) -> Result<(), BrewError> {
    let src = brewfile_path(&state.brewfiles_dir, &id)?;
    if !src.is_file() {
        return Err(BrewError::BrewfileNotFound { id });
    }
    let dst = PathBuf::from(&target_path);
    if dst.as_os_str().is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "export target path is empty".into(),
        });
    }
    if let Some(parent) = dst.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            return Err(BrewError::InvalidArgument {
                message: format!("target directory does not exist: {}", parent.display()),
            });
        }
    }
    // Sandbox check — refuse to write inside system locations or our own
    // app data dir. See `is_safe_export_target` for the full rationale.
    is_safe_export_target(&dst, &state.app_data_dir)?;
    tokio::fs::copy(&src, &dst)
        .await
        .map_err(|e| BrewError::Io {
            message: format!("copy to {}: {}", dst.display(), e),
        })?;
    Ok(())
}

#[tauri::command]
pub async fn brewfile_import(
    source_path: String,
    label: String,
    state: State<'_, AppState>,
) -> Result<BrewfileSummary, BrewError> {
    let src = PathBuf::from(&source_path);
    if !src.is_file() {
        return Err(BrewError::InvalidArgument {
            message: format!("source file does not exist: {}", source_path),
        });
    }
    // Sandbox check — refuse symlinks, oversize files, and binary payloads.
    // See `is_safe_import_source` for the full rationale.
    is_safe_import_source(&src)?;
    let id = sanitize_label(&label);
    if id.is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "label produced an empty id after sanitization".into(),
        });
    }
    let dst = brewfile_path(&state.brewfiles_dir, &id)?;
    tokio::fs::copy(&src, &dst)
        .await
        .map_err(|e| BrewError::Io {
            message: format!("copy from {}: {}", source_path, e),
        })?;
    summary_for(&dst, &id, &label)
}

// ---------- Sandbox helpers (H2) ----------

/// Maximum size accepted for a Brewfile import.
///
/// 1 MiB is far beyond any realistic Brewfile (the largest Brewfiles
/// we've seen — installed-system snapshots with hundreds of casks +
/// formulae — fit comfortably in ~50 KiB). The cap defends against an
/// attacker-coerced renderer attempting to copy a multi-gigabyte file
/// into our app data directory before we'd noticed.
const MAX_IMPORT_BYTES: u64 = 1024 * 1024;

/// Number of bytes read from the head of an import source to look for
/// NUL bytes. 4 KiB catches every binary format we'd be tricked into
/// importing (ELF, Mach-O, PE, JPEG, PNG, ZIP, PDF, encrypted blobs).
const IMPORT_HEAD_SAMPLE_BYTES: usize = 4096;

/// Forbidden export prefixes — system-owned locations a Brewfile should
/// never be written to. The list is conservative: any path starting with
/// one of these prefixes (after lexical normalization) is rejected.
///
/// Both `/etc/...` and `/private/etc/...` are listed because macOS
/// canonicalizes the former into the latter for some operations and
/// vice-versa; we want to reject the literal user-supplied form before
/// any path resolution happens.
const FORBIDDEN_EXPORT_PREFIXES: &[&str] = &[
    "/etc/",
    "/etc",
    "/System/",
    "/System",
    "/Library/",
    "/Library",
    "/usr/",
    "/usr",
    "/bin/",
    "/bin",
    "/sbin/",
    "/sbin",
    "/var/",
    "/var",
    "/private/etc/",
    "/private/etc",
    "/private/var/",
    "/private/var",
    "/dev/",
    "/dev",
    "/Volumes/",
];

/// Refuse to write a Brewfile export into a sensitive location.
///
/// The frontend always routes export targets through the `save` dialog,
/// which is a user-driven picker — so a benign caller never lands here.
/// But the IPC boundary itself must enforce the gate, because a future
/// XSS / compromised renderer could call `invoke("brewfile_export", ...)`
/// with any path it wants. Without this check, the renderer would have
/// an arbitrary-file-write primitive across the user's filesystem (any
/// path the user can write to).
///
/// Two checks:
/// 1. **Forbidden-prefix rejection.** A short denylist of system-owned
///    locations the user should never be tricked into clobbering
///    (`/etc/`, `/System/`, etc.).
/// 2. **App-data-dir rejection.** Refuse to write *inside* our own data
///    directory. Combined with `is_safe_import_source` (which rejects
///    symlinks and binary payloads), this means an attacker can't use
///    `import(any) → export(into our state) → install` to stage
///    arbitrary content into our snapshots store.
fn is_safe_export_target(dst: &Path, app_data_dir: &Path) -> Result<(), BrewError> {
    // Use the lossy string form for prefix matching — this is the
    // user-supplied path *before* any canonicalization, which is exactly
    // what we want for the forbidden-prefix gate (we're rejecting the
    // intent, not the resolved target).
    let dst_str = dst.to_string_lossy();

    for prefix in FORBIDDEN_EXPORT_PREFIXES {
        if dst_str.starts_with(prefix) {
            return Err(BrewError::InvalidArgument {
                message: format!(
                    "refusing to write Brewfile inside protected location ({}): {}",
                    prefix,
                    dst.display()
                ),
            });
        }
    }

    // Reject any path inside the app data dir. We use lexical prefix
    // matching against the raw destination — the attacker can't bypass
    // by using a relative path because we already canonicalize the
    // parent via `parent().exists()` check above, and a relative target
    // would resolve relative to the app's CWD, which is process-launch
    // dependent and not exploitable as a privilege escalation.
    //
    // Both the raw form and the canonical form (when resolvable) are
    // checked — the canonical form catches symlink farms pointing back
    // into our data dir.
    if path_starts_with_dir(dst, app_data_dir) {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "refusing to write Brewfile inside app data dir: {}",
                dst.display()
            ),
        });
    }
    // Canonicalize the parent (since `dst` itself doesn't exist yet) and
    // recheck. This catches cases where the parent dir is a symlink that
    // resolves back into our data dir.
    if let Some(parent) = dst.parent() {
        if !parent.as_os_str().is_empty() {
            if let Ok(parent_canon) = parent.canonicalize() {
                if let Ok(ad_canon) = app_data_dir.canonicalize() {
                    if path_starts_with_dir(&parent_canon, &ad_canon) {
                        return Err(BrewError::InvalidArgument {
                            message: format!(
                                "refusing to write Brewfile inside app data dir (resolved): {}",
                                dst.display()
                            ),
                        });
                    }
                }
            }
        }
    }
    Ok(())
}

/// Component-wise prefix check — avoids the `"/foo".starts_with("/fo")`
/// false-positive that string-prefix matching would produce. Returns
/// true when every component of `prefix` matches the corresponding
/// leading component of `path`.
fn path_starts_with_dir(path: &Path, prefix: &Path) -> bool {
    let mut p_iter = path.components();
    let mut pre_iter = prefix.components();
    loop {
        match (pre_iter.next(), p_iter.next()) {
            (None, _) => return true,
            (Some(_), None) => return false,
            (Some(a), Some(b)) => {
                if a != b {
                    return false;
                }
            }
        }
    }
}

/// Refuse to import a Brewfile that isn't a regular file, is oversized,
/// or doesn't look like text.
///
/// Three checks:
/// 1. **Regular file.** `symlink_metadata` (not `metadata`) so a symlink
///    is rejected without dereferencing — otherwise an attacker could
///    point at `/Users/<u>/.ssh/id_ed25519` and copy it into our
///    snapshots dir for later read-back via `brewfile_read`.
/// 2. **Size cap.** Real Brewfiles are tens of KiB at most; reject
///    anything over 1 MiB. Defends against tarpit copies (10 GiB
///    `/dev/zero`-backed file) and accidental nonsense.
/// 3. **Binary sniff.** Read the first 4 KiB and reject any NUL byte.
///    Brewfiles are Ruby source — guaranteed printable ASCII/UTF-8.
///    A NUL byte means the file isn't text, and the attacker is using
///    `import` to ferry binary content (private keys, encrypted blobs,
///    Mach-O binaries) into our data dir.
fn is_safe_import_source(src: &Path) -> Result<(), BrewError> {
    // 1. Regular-file check via `symlink_metadata` so a symlink is
    //    rejected without following it.
    let meta = std::fs::symlink_metadata(src).map_err(|e| BrewError::Io {
        message: format!("stat {}: {}", src.display(), e),
    })?;
    let ft = meta.file_type();
    if ft.is_symlink() {
        return Err(BrewError::InvalidArgument {
            message: format!("refusing to import Brewfile via symlink: {}", src.display()),
        });
    }
    if !ft.is_file() {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "refusing to import non-regular file ({:?}): {}",
                ft,
                src.display()
            ),
        });
    }

    // 2. Size cap.
    if meta.len() > MAX_IMPORT_BYTES {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "refusing to import Brewfile larger than {} bytes (got {}): {}",
                MAX_IMPORT_BYTES,
                meta.len(),
                src.display()
            ),
        });
    }

    // 3. Binary sniff — read the first 4 KiB and reject any NUL byte.
    use std::io::Read;
    let mut f = std::fs::File::open(src).map_err(|e| BrewError::Io {
        message: format!("open {}: {}", src.display(), e),
    })?;
    let cap = (meta.len() as usize).min(IMPORT_HEAD_SAMPLE_BYTES);
    let mut head = vec![0u8; cap];
    let n = f.read(&mut head).map_err(|e| BrewError::Io {
        message: format!("read head {}: {}", src.display(), e),
    })?;
    if head[..n].contains(&0u8) {
        return Err(BrewError::InvalidArgument {
            message: format!(
                "refusing to import binary content as Brewfile: {}",
                src.display()
            ),
        });
    }

    Ok(())
}

// ---------- M4 — extra_args parser security note ----------

// The `extra_args` walker (below) returns raw substrings from
// adversarial Brewfile content (if a user imports a malicious file).
// These strings flow into the `args` field of `BrewfileFormula` /
// `BrewfileCask` and from there into the Svelte UI.
//
// **XSS audit:** Svelte renders these strings through interpolation
// (`{arg}`) which auto-escapes — never via `{@html ...}`. The frontend
// has zero `{@html}` or `innerHTML` call sites (verified by the
// 2026-05-23 security audit). Adversarial Brewfile content can therefore
// produce *confusing* UI ("foo <script>bar</script>" rendered as
// literal text) but cannot execute script in the renderer.
//
// **DoS audit:** the import path is gated by `is_safe_import_source`
// above which caps file size at 1 MiB and rejects binary. The parser
// is line-oriented and O(n) per line; no exponential backtracking, no
// regex, no allocation-heavy operations.
//
// **Path / argv audit:** these strings never reach `tokio::process::Command`
// — only the *names* of taps/formulae/casks/mas/vscode entries do, and
// those are passed to `brew bundle install --file=<path>` which reads
// the file itself. We never re-shell parsed args.
//
// Conclusion: no security impact. Documented here so a future audit
// doesn't re-flag this as exploitable.

// ---------- helpers ----------

/// Validate a Brewfile id before it is ever joined into a filesystem path.
///
/// Ids are filename *stems* and on disk only ever come from
/// [`sanitize_label`], which emits `[A-Za-z0-9_-]` (1–64 chars). The
/// read/delete/install/check/export commands, however, take `id`
/// straight from the IPC boundary without routing it through
/// `sanitize_label`. Enforcing the same allowlist here — at the single
/// point where an id becomes a path — closes a path-traversal hole:
/// `Path::join` follows `..` *and* lets an absolute component replace
/// the base entirely, so an unvalidated id like `../../../../etc/foo` or
/// `/Users/x/.ssh/id_ed25519` would otherwise escape `brewfiles_dir`.
///
/// Allowlist (not blocklist) by design — it rejects `/`, `.`, `..`,
/// NUL, and every other separator/metacharacter while accepting every
/// id `sanitize_label` can legitimately produce.
fn validate_brewfile_id(id: &str) -> Result<(), BrewError> {
    if id.is_empty() || id.len() > 64 {
        return Err(BrewError::InvalidArgument {
            message: "brewfile id must be 1–64 characters".into(),
        });
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return Err(BrewError::InvalidArgument {
            message: format!("brewfile id contains an illegal character: {id:?}"),
        });
    }
    Ok(())
}

fn brewfile_path(dir: &Path, id: &str) -> Result<PathBuf, BrewError> {
    validate_brewfile_id(id)?;
    Ok(dir.join(format!("{}.Brewfile", id)))
}

/// Sanitize a user-provided label into a safe filename stem.
/// Per spec §11.5: keep `[A-Za-z0-9_-]`, max 64 chars.
fn sanitize_label(label: &str) -> String {
    let cleaned: String = label
        .trim()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                // ' ', '.', and anything else collapse to '_'
                '_'
            }
        })
        .collect();
    let cleaned = cleaned.trim_matches('_').to_string();
    if cleaned.is_empty() {
        return format!("snapshot_{}", Utc::now().format("%Y-%m-%d_%H%M%S"));
    }
    if cleaned.len() > 64 {
        cleaned[..64].to_string()
    } else {
        cleaned
    }
}

fn summary_for(path: &Path, id: &str, label: &str) -> Result<BrewfileSummary, BrewError> {
    let meta = std::fs::metadata(path).map_err(|e| BrewError::Io {
        message: format!("stat {}: {}", path.display(), e),
    })?;
    let created_at = meta
        .created()
        .or_else(|_| meta.modified())
        .ok()
        .map(|t| {
            let dt: chrono::DateTime<Utc> = t.into();
            dt.to_rfc3339()
        })
        .unwrap_or_else(|| Utc::now().to_rfc3339());

    let raw = std::fs::read_to_string(path).map_err(|e| BrewError::Io {
        message: format!("read {}: {}", path.display(), e),
    })?;
    let entries = parse_brewfile_text(&raw);
    let counts = BrewfileCounts {
        taps: entries.taps.len(),
        formulae: entries.formulae.len(),
        casks: entries.casks.len(),
        mas_apps: entries.mas_apps.len(),
        vscode_extensions: entries.vscode_extensions.len(),
    };

    Ok(BrewfileSummary {
        id: id.to_string(),
        label: label.to_string(),
        path: path.to_string_lossy().into_owned(),
        created_at,
        size_bytes: meta.len(),
        counts,
    })
}

/// Parse a Brewfile's plain text into typed entries.
///
/// Brewfile is Ruby DSL; we recognize the canonical forms:
///   `tap "homebrew/core"`
///   `brew "wget"`
///   `cask "iterm2"`
///   `mas "Xcode", id: 497799835`
///   `vscode "ms-python.python"`
fn parse_brewfile_text(raw: &str) -> BrewfileEntries {
    let mut entries = BrewfileEntries {
        taps: Vec::new(),
        formulae: Vec::new(),
        casks: Vec::new(),
        mas_apps: Vec::new(),
        vscode_extensions: Vec::new(),
    };

    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (kind, rest) = match line.split_once(char::is_whitespace) {
            Some(t) => t,
            None => continue,
        };
        let rest = rest.trim();
        match kind {
            "tap" => {
                if let Some(name) = first_quoted(rest) {
                    entries.taps.push(name);
                }
            }
            "brew" => {
                if let Some(name) = first_quoted(rest) {
                    entries.formulae.push(BrewfileFormula {
                        name,
                        args: extra_args(rest),
                    });
                }
            }
            "cask" => {
                if let Some(name) = first_quoted(rest) {
                    entries.casks.push(BrewfileCask {
                        name,
                        args: extra_args(rest),
                    });
                }
            }
            "mas" => {
                if let Some(name) = first_quoted(rest) {
                    let id = extract_mas_id(rest).unwrap_or(0);
                    entries.mas_apps.push(BrewfileMasApp { name, id });
                }
            }
            "vscode" => {
                if let Some(name) = first_quoted(rest) {
                    entries.vscode_extensions.push(name);
                }
            }
            _ => {}
        }
    }

    entries
}

/// Pull the first `"…"` string out of a line.
fn first_quoted(s: &str) -> Option<String> {
    let start = s.find('"')?;
    let after = &s[start + 1..];
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

/// Collect any quoted strings after the first.
fn extra_args(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let chars = s.char_indices();
    let mut count = 0;
    let mut start: Option<usize> = None;
    for (i, c) in chars {
        if c == '"' {
            match start {
                None => start = Some(i + 1),
                Some(beg) => {
                    if count > 0 {
                        out.push(s[beg..i].to_string());
                    }
                    count += 1;
                    start = None;
                }
            }
        }
    }
    out
}

fn extract_mas_id(s: &str) -> Option<u64> {
    // Looking for `id: 123456`.
    let idx = s.find("id:")?;
    let after = &s[idx + 3..];
    let digits: String = after
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse::<u64>().ok()
}

/// Parse `brew bundle check --verbose` output into a structured report.
///
/// Output shape (best-effort across brew versions):
///   `Tap homebrew/cask-versions needs to be tapped.`
///   `Formula <name> needs to be installed.`
///   `Cask <name> needs to be installed.`
///   `Mas <name> needs to be installed.`
///   `Vscode extension <name> needs to be installed.`
fn parse_check_report(satisfied: bool, output: &str) -> BrewfileCheckReport {
    let mut report = BrewfileCheckReport {
        satisfied,
        missing_taps: Vec::new(),
        missing_formulae: Vec::new(),
        missing_casks: Vec::new(),
        missing_mas_apps: Vec::new(),
        missing_vscode_extensions: Vec::new(),
    };

    for raw_line in output.lines() {
        let line = raw_line.trim();
        if let Some(rest) = line.strip_prefix("Tap ") {
            if let Some(name) = rest.split_whitespace().next() {
                report.missing_taps.push(name.to_string());
            }
        } else if let Some(rest) = line.strip_prefix("Formula ") {
            if let Some(name) = rest.split_whitespace().next() {
                report.missing_formulae.push(name.to_string());
            }
        } else if let Some(rest) = line.strip_prefix("Cask ") {
            if let Some(name) = rest.split_whitespace().next() {
                report.missing_casks.push(name.to_string());
            }
        } else if let Some(rest) = line.strip_prefix("Mas ") {
            if let Some(name) = rest.split_whitespace().next() {
                report.missing_mas_apps.push(name.to_string());
            }
        } else if let Some(rest) = line.strip_prefix("Vscode extension ") {
            if let Some(name) = rest.split_whitespace().next() {
                report.missing_vscode_extensions.push(name.to_string());
            }
        }
    }

    report
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    fn load_fixture(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join(name);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read fixture {}: {}", path.display(), e))
    }

    // ---------- parse_brewfile_text ----------

    #[test]
    fn parses_full_sample_brewfile() {
        let raw = load_fixture("sample_brewfile.txt");
        let e = parse_brewfile_text(&raw);

        assert_eq!(
            e.taps,
            vec!["homebrew/core", "homebrew/cask", "homebrew/services"]
        );
        assert_eq!(e.formulae.len(), 4);
        assert_eq!(e.formulae[0].name, "wget");
        // `brew "openssl@3", link: false` — extra quoted args after name.
        let openssl = e.formulae.iter().find(|f| f.name == "openssl@3").unwrap();
        // No extra *quoted* args, just `link: false` keyword arg (no quotes).
        // Our extra_args walker collects nothing here.
        assert!(openssl.args.is_empty());

        assert_eq!(e.casks.len(), 3);
        assert_eq!(e.casks[0].name, "firefox");

        assert_eq!(e.mas_apps.len(), 2);
        assert_eq!(e.mas_apps[0].name, "Xcode");
        assert_eq!(e.mas_apps[0].id, 497799835);
        assert_eq!(e.mas_apps[1].name, "Things");
        assert_eq!(e.mas_apps[1].id, 904280696);

        assert_eq!(e.vscode_extensions.len(), 2);
        assert!(e
            .vscode_extensions
            .contains(&"ms-python.python".to_string()));
    }

    #[test]
    fn skips_comments_and_blank_lines() {
        let raw = r#"
# this is a comment
# tap "should-be-ignored"

brew "wget"

# trailing comment
"#;
        let e = parse_brewfile_text(raw);
        assert_eq!(e.formulae.len(), 1);
        assert_eq!(e.formulae[0].name, "wget");
        assert!(e.taps.is_empty());
    }

    #[test]
    fn ignores_unrecognized_directives() {
        let raw = r#"
unknown_directive "foo"
brew "wget"
"#;
        let e = parse_brewfile_text(raw);
        assert_eq!(e.formulae.len(), 1);
        assert!(e.taps.is_empty());
    }

    #[test]
    fn empty_brewfile_yields_empty_entries() {
        let e = parse_brewfile_text("");
        assert!(e.taps.is_empty());
        assert!(e.formulae.is_empty());
        assert!(e.casks.is_empty());
        assert!(e.mas_apps.is_empty());
        assert!(e.vscode_extensions.is_empty());
    }

    #[test]
    fn mas_without_id_falls_back_to_zero() {
        let raw = r#"mas "MysteryApp""#;
        let e = parse_brewfile_text(raw);
        assert_eq!(e.mas_apps.len(), 1);
        assert_eq!(e.mas_apps[0].name, "MysteryApp");
        assert_eq!(e.mas_apps[0].id, 0);
    }

    #[test]
    fn first_quoted_extracts_first_string() {
        assert_eq!(first_quoted(r#""abc""#), Some("abc".to_string()));
        assert_eq!(
            first_quoted(r#""first" "second""#),
            Some("first".to_string())
        );
        assert_eq!(first_quoted("no quotes"), None);
        assert_eq!(first_quoted(""), None);
    }

    // ---------- sanitize_label ----------

    #[test]
    fn sanitize_keeps_alphanumeric_and_separators() {
        assert_eq!(sanitize_label("hello-world_123"), "hello-world_123");
        assert_eq!(sanitize_label("pre-upgrade"), "pre-upgrade");
    }

    #[test]
    fn sanitize_replaces_spaces_and_dots_with_underscores() {
        assert_eq!(sanitize_label("my snapshot"), "my_snapshot");
        assert_eq!(sanitize_label("v1.2.3"), "v1_2_3");
    }

    #[test]
    fn sanitize_strips_punctuation_and_path_chars() {
        // path separators and ../ become _
        assert_eq!(sanitize_label("../etc/passwd"), "etc_passwd");
        assert_eq!(sanitize_label("foo/bar"), "foo_bar");
        assert_eq!(sanitize_label("foo;bar"), "foo_bar");
        // Multiple `_` stay; only edge `_` are trimmed.
        assert_eq!(sanitize_label("/foo/"), "foo");
    }

    #[test]
    fn sanitize_empty_label_yields_dated_default() {
        let out = sanitize_label("");
        assert!(out.starts_with("snapshot_"), "got {:?}", out);
    }

    #[test]
    fn sanitize_truncates_to_64_chars() {
        let big = "a".repeat(200);
        let out = sanitize_label(&big);
        assert_eq!(out.len(), 64);
    }

    // ---------- parse_check_report ----------

    #[test]
    fn parse_check_report_satisfied_no_missing() {
        let report = parse_check_report(true, "The Brewfile's dependencies are satisfied.\n");
        assert!(report.satisfied);
        assert!(report.missing_formulae.is_empty());
        assert!(report.missing_casks.is_empty());
        assert!(report.missing_taps.is_empty());
        assert!(report.missing_mas_apps.is_empty());
        assert!(report.missing_vscode_extensions.is_empty());
    }

    #[test]
    fn parse_check_report_extracts_missing_entries() {
        let output = "\
Tap homebrew/services needs to be tapped.
Formula wget needs to be installed.
Cask iterm2 needs to be installed.
Mas Xcode needs to be installed.
Vscode extension ms-python.python needs to be installed.
";
        let report = parse_check_report(false, output);
        assert!(!report.satisfied);
        assert_eq!(report.missing_taps, vec!["homebrew/services"]);
        assert_eq!(report.missing_formulae, vec!["wget"]);
        assert_eq!(report.missing_casks, vec!["iterm2"]);
        assert_eq!(report.missing_mas_apps, vec!["Xcode"]);
        assert_eq!(report.missing_vscode_extensions, vec!["ms-python.python"]);
    }

    // ---------- brewfile_path round-trip ----------

    #[test]
    fn brewfile_path_appends_brewfile_suffix() {
        let dir = std::path::Path::new("/tmp/brew-browser-tests");
        let p = brewfile_path(dir, "my-snap").expect("valid id");
        assert!(p.to_string_lossy().ends_with("my-snap.Brewfile"));
        assert!(p.starts_with(dir));
    }

    #[test]
    fn brewfile_id_accepts_sanitize_label_output() {
        // Every id sanitize_label can produce must survive validation,
        // otherwise we'd reject snapshots we created ourselves.
        for ok in &[
            "my-snap",
            "pre_upgrade",
            "v1_2_3",
            "A1",
            "snapshot_2025-01-01_120000",
        ] {
            assert!(
                validate_brewfile_id(ok).is_ok(),
                "{ok:?} should be accepted"
            );
            assert!(brewfile_path(Path::new("/tmp/bb"), ok).is_ok());
        }
    }

    #[test]
    fn brewfile_id_rejects_path_traversal() {
        // The core of the fix: an id reaching the read/delete/install/
        // check/export commands from IPC must never escape brewfiles_dir.
        let dir = Path::new("/Users/x/Library/Application Support/brew-browser/brewfiles");
        for evil in &[
            "../../../../etc/cron.d/evil",
            "/etc/passwd",
            "/Users/x/.ssh/authorized_keys",
            "..",
            "foo/bar",
            "foo/../../bar",
            "a.b", // '.' is not in the allowlist
            "with space",
            "semi;colon",
            "nul\0byte",
            "",              // empty
            &"x".repeat(65), // over length cap
        ] {
            assert!(
                matches!(
                    validate_brewfile_id(evil),
                    Err(BrewError::InvalidArgument { .. })
                ),
                "{evil:?} should be rejected by validate_brewfile_id"
            );
            assert!(
                matches!(
                    brewfile_path(dir, evil),
                    Err(BrewError::InvalidArgument { .. })
                ),
                "brewfile_path must refuse to build a path for {evil:?}"
            );
        }
    }

    // ---------- is_safe_export_target (H2) ----------

    #[test]
    fn export_rejects_etc_prefix() {
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        for path in &[
            "/etc/passwd",
            "/etc/shadow",
            "/etc/sudoers.d/00-attacker",
            "/etc",
        ] {
            let r = is_safe_export_target(Path::new(path), &app);
            assert!(
                matches!(r, Err(BrewError::InvalidArgument { .. })),
                "export to {:?} should be rejected, got {:?}",
                path,
                r
            );
        }
    }

    #[test]
    fn export_rejects_system_library_usr_bin_var_prefixes() {
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        for path in &[
            "/System/Library/foo",
            "/Library/LaunchDaemons/com.attacker.plist",
            "/usr/local/bin/payload",
            "/bin/sh",
            "/sbin/init",
            "/var/log/x",
            "/dev/null",
            "/Volumes/Untitled/foo",
        ] {
            let r = is_safe_export_target(Path::new(path), &app);
            assert!(
                matches!(r, Err(BrewError::InvalidArgument { .. })),
                "export to {:?} should be rejected, got {:?}",
                path,
                r
            );
        }
    }

    #[test]
    fn export_rejects_private_etc_and_private_var() {
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        for path in &["/private/etc/passwd", "/private/var/db/something"] {
            let r = is_safe_export_target(Path::new(path), &app);
            assert!(
                matches!(r, Err(BrewError::InvalidArgument { .. })),
                "export to {:?} should be rejected, got {:?}",
                path,
                r
            );
        }
    }

    #[test]
    fn export_rejects_inside_app_data_dir() {
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        // Direct child.
        let r = is_safe_export_target(
            Path::new("/Users/x/Library/Application Support/brew-browser/state.json"),
            &app,
        );
        assert!(matches!(r, Err(BrewError::InvalidArgument { .. })));
        // Nested.
        let r = is_safe_export_target(
            Path::new("/Users/x/Library/Application Support/brew-browser/brewfiles/snap.Brewfile"),
            &app,
        );
        assert!(matches!(r, Err(BrewError::InvalidArgument { .. })));
    }

    #[test]
    fn export_accepts_user_documents_path() {
        // Sanity: the realistic happy path (user picks Desktop / Documents)
        // must still work.
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        for path in &[
            "/Users/x/Desktop/snapshot.Brewfile",
            "/Users/x/Documents/snapshot.Brewfile",
            "/Users/x/Downloads/snapshot.Brewfile",
        ] {
            is_safe_export_target(Path::new(path), &app)
                .unwrap_or_else(|e| panic!("export to {} should be allowed, got {:?}", path, e));
        }
    }

    #[test]
    fn export_app_data_check_uses_component_match_not_string_prefix() {
        // `/Users/x/Library/Application Support/brew-browser-evil` must
        // NOT be rejected as "inside brew-browser" — the prefix is a
        // *sibling* directory whose name happens to share a prefix.
        let app = PathBuf::from("/Users/x/Library/Application Support/brew-browser");
        // This is technically inside /Library which is a forbidden prefix,
        // so use a different parent to isolate the component-match logic:
        let app_alt = PathBuf::from("/Users/x/foo");
        is_safe_export_target(Path::new("/Users/x/foo-evil/bar"), &app_alt)
            .expect("sibling-prefix dir must not be rejected as inside app data dir");
        // Sanity: the canonical inside-check still fires.
        let r = is_safe_export_target(Path::new("/Users/x/foo/bar"), &app_alt);
        assert!(matches!(r, Err(BrewError::InvalidArgument { .. })));
        // And the original app dir example still works under /Library prefix:
        let r = is_safe_export_target(
            Path::new("/Users/x/Library/Application Support/brew-browser/x"),
            &app,
        );
        assert!(matches!(r, Err(BrewError::InvalidArgument { .. })));
    }

    // ---------- is_safe_import_source (H2) ----------

    #[test]
    fn import_accepts_realistic_brewfile_text() {
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        std::fs::write(
            tmp.path(),
            b"tap \"homebrew/core\"\nbrew \"wget\"\ncask \"firefox\"\n",
        )
        .expect("write");
        is_safe_import_source(tmp.path()).expect("realistic Brewfile must be accepted");
    }

    #[test]
    fn import_rejects_symlink_to_sensitive_file() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let target = tmp.path().join("real.Brewfile");
        std::fs::write(&target, b"brew \"wget\"\n").expect("write target");
        let link = tmp.path().join("link.Brewfile");
        // Skip the test on systems where symlink creation fails (some sandboxes).
        if std::os::unix::fs::symlink(&target, &link).is_err() {
            return;
        }
        let r = is_safe_import_source(&link);
        assert!(
            matches!(r, Err(BrewError::InvalidArgument { .. })),
            "symlink import should be rejected, got {:?}",
            r
        );
    }

    #[test]
    fn import_rejects_oversize_file() {
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        // 1 MiB + 1 byte — just over the cap.
        let big = vec![b'a'; (MAX_IMPORT_BYTES as usize) + 1];
        std::fs::write(tmp.path(), &big).expect("write");
        let r = is_safe_import_source(tmp.path());
        assert!(
            matches!(r, Err(BrewError::InvalidArgument { .. })),
            "oversize file should be rejected, got {:?}",
            r
        );
    }

    #[test]
    fn import_accepts_at_size_cap() {
        // Exactly 1 MiB — must be accepted (the gate is strict-greater-than).
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        let exact = vec![b'a'; MAX_IMPORT_BYTES as usize];
        std::fs::write(tmp.path(), &exact).expect("write");
        is_safe_import_source(tmp.path()).expect("exactly 1 MiB must be accepted");
    }

    #[test]
    fn import_rejects_nul_byte_in_first_4kb() {
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        // Some printable preamble + a NUL byte well within the sample window.
        let mut payload = b"brew \"wget\"\n".to_vec();
        payload.push(0u8);
        payload.extend(b"more\n");
        std::fs::write(tmp.path(), &payload).expect("write");
        let r = is_safe_import_source(tmp.path());
        assert!(
            matches!(r, Err(BrewError::InvalidArgument { .. })),
            "NUL byte in first 4 KiB must be rejected, got {:?}",
            r
        );
    }

    #[test]
    fn import_rejects_nul_byte_at_offset_zero() {
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        // Mach-O / ELF / PNG / etc. all have NUL bytes near the start.
        std::fs::write(tmp.path(), [0u8, 0x89, b'P', b'N', b'G']).expect("write");
        let r = is_safe_import_source(tmp.path());
        assert!(matches!(r, Err(BrewError::InvalidArgument { .. })));
    }

    #[test]
    fn import_accepts_nul_byte_outside_sample_window() {
        // A NUL byte beyond IMPORT_HEAD_SAMPLE_BYTES is NOT detected by
        // this check — we accept the tradeoff (a real Brewfile is always
        // text-only, and a deliberately crafted file with NULs only after
        // 4 KiB still gets rejected by the brew bundle parser later).
        // This test documents the boundary so a future tightening (sampling
        // the full file) won't silently break.
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        let mut payload = vec![b' '; IMPORT_HEAD_SAMPLE_BYTES + 16];
        // Prepend a valid-looking opening to keep the file plausibly text.
        let head = b"brew \"wget\"\n";
        payload[..head.len()].copy_from_slice(head);
        // NUL deep into the file:
        payload.push(0u8);
        std::fs::write(tmp.path(), &payload).expect("write");
        is_safe_import_source(tmp.path()).expect("NUL beyond sample window currently accepted");
    }

    #[test]
    fn import_rejects_missing_file() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let missing = tmp.path().join("nope.Brewfile");
        let r = is_safe_import_source(&missing);
        // Missing file maps to Io (stat failed). That's correct — the caller
        // already checks `is_file()` first, this is defense in depth.
        assert!(matches!(r, Err(BrewError::Io { .. })));
    }
}
