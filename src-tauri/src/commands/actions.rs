//! Streaming write-side commands: install, uninstall, upgrade, update, cancel.
//!
//! Every write command in this module:
//! 1. Acquires the global `brew_write_lock` for the duration of the spawn.
//! 2. Runs through `run_brew_streaming`, which emits the full
//!    `BrewStreamEvent` lifecycle to the provided `Channel`.
//! 3. Invalidates `installed_cache` on success.

use tauri::ipc::Channel;
use tauri::State;
use uuid::Uuid;

use crate::brew::exec::run_brew_streaming;
use crate::commands::info::validate_package_name;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::{BrewStreamEvent, JobResult, PackageKind};

// ---------- Pure argv builders ----------
//
// The flag logic for each write command lives in these pure functions so it
// is unit-testable without spawning brew or wiring a Channel/AppState. The
// commands below call them, then derive the user-facing display string with
// `display_for`.

fn kind_flag(kind: PackageKind) -> &'static str {
    match kind {
        PackageKind::Formula => "--formula",
        PackageKind::Cask => "--cask",
    }
}

/// `brew install <kind> <name> [--adopt] [--force]`. `--adopt` is cask-only:
/// it takes over a matching app already present on disk instead of erroring
/// with "It seems there is already an App at…" — the in-app fix for #13/#102.
/// `--force` overwrites instead of adopting (the heavier hammer).
fn install_args(name: &str, kind: PackageKind, force: bool, adopt: bool) -> Vec<String> {
    let mut args = vec![
        "install".to_string(),
        kind_flag(kind).to_string(),
        name.to_string(),
    ];
    if adopt && matches!(kind, PackageKind::Cask) {
        args.push("--adopt".to_string());
    }
    if force {
        args.push("--force".to_string());
    }
    args
}

/// `brew uninstall <kind> <name> [--zap] [--ignore-dependencies]`. `--zap` is
/// cask-only (removes leftover files). `--ignore-dependencies` forces removal
/// even when another installed package still requires it — the in-app escape
/// for "Refusing to uninstall … because it is required by…" (#100).
fn uninstall_args(
    name: &str,
    kind: PackageKind,
    zap: bool,
    ignore_dependencies: bool,
) -> Vec<String> {
    let mut args = vec![
        "uninstall".to_string(),
        kind_flag(kind).to_string(),
        name.to_string(),
    ];
    if zap && matches!(kind, PackageKind::Cask) {
        args.push("--zap".to_string());
    }
    if ignore_dependencies {
        args.push("--ignore-dependencies".to_string());
    }
    args
}

/// `brew upgrade [names...] [--greedy]`. Empty `names` upgrades everything.
/// `--greedy` also upgrades casks that self-update (`auto_updates` / `version
/// :latest`), which brew otherwise skips — the option requested in #47/#31.
fn upgrade_args(names: &[String], greedy: bool) -> Vec<String> {
    let mut args = vec!["upgrade".to_string()];
    args.extend(names.iter().cloned());
    if greedy {
        args.push("--greedy".to_string());
    }
    args
}

/// User-facing command string for the Activity log, derived from the argv.
fn display_for(args: &[String]) -> String {
    format!("brew {}", args.join(" "))
}

#[tauri::command]
pub async fn brew_install(
    name: String,
    kind: PackageKind,
    force: bool,
    adopt: bool,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    validate_package_name(&name)?;
    let path = state.require_brew_path().await?;

    let args = install_args(&name, kind, force, adopt);
    let display = display_for(&args);
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
pub async fn brew_uninstall(
    name: String,
    kind: PackageKind,
    zap: bool,
    ignore_dependencies: bool,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    validate_package_name(&name)?;
    let path = state.require_brew_path().await?;

    let args = uninstall_args(&name, kind, zap, ignore_dependencies);
    let display = display_for(&args);
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
pub async fn brew_upgrade(
    name: Option<String>,
    greedy: bool,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    if let Some(n) = name.as_ref() {
        validate_package_name(n)?;
    }
    let path = state.require_brew_path().await?;

    let names: Vec<String> = name.into_iter().collect();
    let args = upgrade_args(&names, greedy);
    let display = display_for(&args);
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    let result = run_brew_streaming(&path, args, display, on_event, jobs).await;

    if result.is_ok() {
        state.invalidate_caches().await;
    }
    result
}

/// Upgrade a specific *set* of packages in one `brew upgrade <a> <b> ...`
/// invocation. Used by the Dashboard's curated "Upgrade…" modal where
/// the user has checked the subset they want upgraded (vs the
/// `brew_upgrade(None)` "upgrade everything" path).
///
/// Empty list → InvalidArgument (the caller should use `brew_upgrade(None)`
/// instead). Validates every name through the same allowlist regex as
/// `brew_install` to prevent shell-metacharacter injection.
#[tauri::command]
pub async fn brew_upgrade_many(
    names: Vec<String>,
    greedy: bool,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    if names.is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "brew_upgrade_many requires at least one package name; \
                      use brew_upgrade(None) to upgrade everything"
                .to_string(),
        });
    }
    for n in &names {
        validate_package_name(n)?;
    }
    let path = state.require_brew_path().await?;

    let args = upgrade_args(&names, greedy);
    let display = display_for(&args);
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
pub async fn brew_update(
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    let path = state.require_brew_path().await?;

    let args = vec!["update".to_string()];
    let display = "brew update".to_string();
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    let result = run_brew_streaming(&path, args, display, on_event, jobs).await;

    if result.is_ok() {
        state.invalidate_caches().await;
    }
    result
}

/// `brew doctor` — streamed diagnostics (issue #80). Read-only: surfaces
/// advisories in the Activity drawer, touches nothing. brew doctor exits 1
/// when it finds advisories; `run_brew_streaming` (via `doctor_advisory_exit`)
/// treats that non-zero exit as effective-success, so a doctor run that found
/// warnings completes cleanly with the advisory text in the log rather than
/// throwing a "doctor failed" error. Takes the write lock only to serialize
/// streamed brew jobs (no two brew processes stomping each other's output).
#[tauri::command]
pub async fn brew_doctor_stream(
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    let path = state.require_brew_path().await?;

    let args = vec!["doctor".to_string()];
    let display = "brew doctor".to_string();
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    // No cache invalidation — doctor is read-only.
    run_brew_streaming(&path, args, display, on_event, jobs).await
}

/// `brew cleanup --prune=all [--scrub] [--verbose]` — reclaim cache space (issue
/// #80). Destructive of CACHED DOWNLOADS only; installed packages are untouched.
/// `scrub` (opt-in, default off in the UI) also removes the LATEST versions'
/// downloads — more aggressive, so it's a deliberate toggle rather than the
/// default. `verbose` lists every file removed. The UI confirm-gates this with
/// the reclaimable estimate (see `brew_cleanup_preview`). On success the
/// disk-usage cache is dropped so the Storage card re-measures.
#[tauri::command]
pub async fn brew_cleanup(
    scrub: bool,
    verbose: bool,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    let path = state.require_brew_path().await?;

    let mut args = vec!["cleanup".to_string(), "--prune=all".to_string()];
    if scrub {
        args.push("--scrub".to_string());
    }
    if verbose {
        args.push("--verbose".to_string());
    }
    let display = format!(
        "brew cleanup --prune=all{}{}",
        if scrub { " --scrub" } else { "" },
        if verbose { " --verbose" } else { "" }
    );
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    let result = run_brew_streaming(&path, args, display, on_event, jobs).await;

    if result.is_ok() {
        // The on-disk cache shrank; drop the cached disk-usage report so the
        // Storage card re-measures. Installed packages are unchanged, so the
        // installed_cache is left intact.
        *state.disk_usage_cache.lock().await = None;
    }
    result
}

/// `brew autoremove` — remove formulae that were installed only as
/// dependencies and are no longer needed by anything (issue #47). Streams like
/// the other write commands and is confirm-gated in the UI. Changes the install
/// set, so caches are invalidated on success.
#[tauri::command]
pub async fn brew_autoremove(
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    let path = state.require_brew_path().await?;

    let args = vec!["autoremove".to_string()];
    let display = "brew autoremove".to_string();
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
pub async fn cancel_job(job_id: Uuid, state: State<'_, AppState>) -> Result<(), BrewError> {
    let mut map = state.jobs.lock().await;
    let handle = map.get_mut(&job_id).ok_or_else(|| BrewError::JobNotFound {
        job_id: job_id.to_string(),
    })?;

    if let Some(tx) = handle.cancel_tx.take() {
        let _ = tx.send(());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn svec(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn install_adopt_is_cask_only() {
        assert_eq!(
            install_args("cursor", PackageKind::Cask, false, true),
            svec(&["install", "--cask", "cursor", "--adopt"])
        );
        // Formulae have no on-disk app to adopt → flag is dropped.
        assert_eq!(
            install_args("wget", PackageKind::Formula, false, true),
            svec(&["install", "--formula", "wget"])
        );
    }

    #[test]
    fn install_adopt_and_force_order() {
        // --adopt before --force; both present when both requested.
        assert_eq!(
            install_args("cursor", PackageKind::Cask, true, true),
            svec(&["install", "--cask", "cursor", "--adopt", "--force"])
        );
    }

    #[test]
    fn install_plain_unchanged() {
        assert_eq!(
            install_args("cursor", PackageKind::Cask, false, false),
            svec(&["install", "--cask", "cursor"])
        );
    }

    #[test]
    fn uninstall_ignore_dependencies_force_remove() {
        assert_eq!(
            uninstall_args("gstreamer-runtime", PackageKind::Cask, false, true),
            svec(&[
                "uninstall",
                "--cask",
                "gstreamer-runtime",
                "--ignore-dependencies"
            ])
        );
    }

    #[test]
    fn uninstall_zap_is_cask_only() {
        // --zap dropped for a formula; --ignore-dependencies still applies.
        assert_eq!(
            uninstall_args("foo", PackageKind::Formula, true, true),
            svec(&["uninstall", "--formula", "foo", "--ignore-dependencies"])
        );
    }

    #[test]
    fn upgrade_all_greedy() {
        assert_eq!(upgrade_args(&[], true), svec(&["upgrade", "--greedy"]));
    }

    #[test]
    fn upgrade_named_without_greedy() {
        assert_eq!(
            upgrade_args(&["wget".to_string()], false),
            svec(&["upgrade", "wget"])
        );
    }

    #[test]
    fn upgrade_many_greedy() {
        assert_eq!(
            upgrade_args(&["a".to_string(), "b".to_string()], true),
            svec(&["upgrade", "a", "b", "--greedy"])
        );
    }

    #[test]
    fn display_renders_brew_prefix() {
        assert_eq!(
            display_for(&install_args("cursor", PackageKind::Cask, false, true)),
            "brew install --cask cursor --adopt"
        );
    }
}
