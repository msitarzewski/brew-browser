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

use crate::brew::exec::{run_brew_capture, run_brew_streaming};
use crate::commands::info::validate_package_name;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::{BrewStreamEvent, BundlePackage, JobResult, PackageKind};

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

/// `brew pin <kind> <name>` / `brew unpin <kind> <name>`. Pinning holds a
/// package back so `brew upgrade` (including `--greedy`) skips it — the in-app
/// "stop nagging me about this one" hold for #90/#134. Current Homebrew pins
/// both formulae and casks, so the kind flag disambiguates a name that exists
/// as both. `pinned == true` pins; `false` unpins.
fn pin_args(name: &str, kind: PackageKind, pinned: bool) -> Vec<String> {
    let verb = if pinned { "pin" } else { "unpin" };
    vec![verb.to_string(), kind_flag(kind).to_string(), name.to_string()]
}

/// Build the `brew install` invocation(s) for a whole bundle.
///
/// Homebrew's `--formula` / `--cask` flags each mean "treat ALL named
/// arguments as this kind" — they're mutually exclusive, so a single mixed
/// `brew install --formula A --cask B` is NOT accepted (verified: brew prints
/// usage). We therefore emit one grouped invocation per kind present:
///   - `["install", "--formula", <f1>, <f2>, ...]`
///   - `["install", "--cask", <c1>, <c2>, ...]`
/// Formulae first, casks second, each preserving the recipe's declared order.
/// A group is omitted when empty; an empty package list yields no steps. The
/// caller runs the steps sequentially, streaming each into Activity.
///
/// Kind is the free-form string from the recipe; anything that isn't `"cask"`
/// is treated as a formula (the command validates kinds up-front, so in
/// practice only `formula`/`cask` reach here).
fn install_bundle_args(packages: &[BundlePackage]) -> Vec<Vec<String>> {
    let mut formulae: Vec<String> = Vec::new();
    let mut casks: Vec<String> = Vec::new();
    for p in packages {
        match p.kind.as_str() {
            "cask" => casks.push(p.name.clone()),
            _ => formulae.push(p.name.clone()),
        }
    }

    let mut steps: Vec<Vec<String>> = Vec::new();
    if !formulae.is_empty() {
        let mut args = vec!["install".to_string(), "--formula".to_string()];
        args.extend(formulae);
        steps.push(args);
    }
    if !casks.is_empty() {
        let mut args = vec!["install".to_string(), "--cask".to_string()];
        args.extend(casks);
        steps.push(args);
    }
    steps
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

/// Install every package in a bundle (Bundles M3). Mirrors `brew_upgrade_many`:
/// validate every name, take the write lock once, stream into Activity, and
/// invalidate caches once brew has run.
///
/// Because `--formula`/`--cask` can't be mixed in one invocation (see
/// `install_bundle_args`), a bundle with both kinds runs as two sequential
/// streamed steps under the SAME write lock — formulae first, then casks. If
/// the formula step fails (non-zero exit), the cask step is skipped and that
/// failing `JobResult` is returned. Each step emits its own `Started`→`Exit`
/// lifecycle on the shared channel, so the frontend surfaces one Activity job
/// per step.
///
/// Empty list → InvalidArgument. Every `kind` must be `formula` or `cask`; an
/// unknown kind is rejected rather than silently coerced. Names go through the
/// same allowlist regex as `brew_install` to block shell-metacharacter injection.
#[tauri::command]
pub async fn brew_install_bundle(
    packages: Vec<BundlePackage>,
    on_event: Channel<BrewStreamEvent>,
    state: State<'_, AppState>,
) -> Result<JobResult, BrewError> {
    if packages.is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "brew_install_bundle requires at least one package".to_string(),
        });
    }
    for p in &packages {
        validate_package_name(&p.name)?;
        if p.kind != "formula" && p.kind != "cask" {
            return Err(BrewError::InvalidArgument {
                message: format!("package '{}' has unknown kind '{}'", p.name, p.kind),
            });
        }
    }
    let path = state.require_brew_path().await?;

    let steps = install_bundle_args(&packages);
    let jobs = state.jobs.clone();
    let lock = state.brew_write_lock.clone();

    // Hold the write lock across BOTH steps so nothing interleaves between the
    // formula and cask installs of a single bundle.
    let _guard = lock.lock_owned().await;

    let mut ran_any = false;
    let mut last: Option<JobResult> = None;
    for args in steps {
        let display = display_for(&args);
        match run_brew_streaming(&path, args, display, on_event.clone(), jobs.clone()).await {
            Ok(result) => {
                ran_any = true;
                let succeeded = result.success;
                last = Some(result);
                // A failed step (e.g. formulae) means we skip the rest.
                if !succeeded {
                    break;
                }
            }
            Err(e) => {
                // Spawn failure. Reflect any partial state before propagating.
                if ran_any {
                    state.invalidate_caches().await;
                }
                return Err(e);
            }
        }
    }

    if ran_any {
        state.invalidate_caches().await;
    }
    // `packages` is non-empty and every kind is valid, so at least one step ran.
    Ok(last.expect("at least one install step ran for a non-empty bundle"))
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

/// `brew pin`/`unpin` a single package (issue #90, folds in #134). Fast and
/// non-streaming — pin is an instant metadata flip with trivial output, so it
/// runs through `run_brew_capture` and returns once done rather than spawning a
/// tracked Activity job. Still serialized behind the write lock (so it can't
/// race a concurrent upgrade) and invalidates caches on success so the pinned
/// badge and the honest "updates available" count re-derive from fresh
/// `brew info`/`brew outdated` data. A non-zero exit (e.g. package not
/// installed) surfaces as a friendly `BrewExitNonZero`, same as the other
/// write commands.
#[tauri::command]
pub async fn brew_set_pinned(
    name: String,
    kind: PackageKind,
    pinned: bool,
    state: State<'_, AppState>,
) -> Result<(), BrewError> {
    validate_package_name(&name)?;
    let path = state.require_brew_path().await?;

    let args = pin_args(&name, kind, pinned);
    let str_args: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let display = display_for(&args);
    let lock = state.brew_write_lock.clone();

    let _guard = lock.lock_owned().await;
    run_brew_capture(&path, &str_args, &display).await?;
    state.invalidate_caches().await;
    Ok(())
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

    #[test]
    fn pin_formula_and_cask() {
        assert_eq!(
            pin_args("wget", PackageKind::Formula, true),
            svec(&["pin", "--formula", "wget"])
        );
        // Casks pin too in current Homebrew — the actual #90/#134 case.
        assert_eq!(
            pin_args("google-chrome", PackageKind::Cask, true),
            svec(&["pin", "--cask", "google-chrome"])
        );
    }

    fn pkg(name: &str, kind: &str) -> BundlePackage {
        BundlePackage { name: name.to_string(), kind: kind.to_string() }
    }

    #[test]
    fn install_bundle_mixed_kinds_split_into_two_grouped_steps() {
        // local-llm: ollama (formula) + open-webui (cask). Interleaved flags
        // don't work in brew, so we emit one grouped invocation per kind,
        // formulae first. (Verified: `brew install --formula X --cask Y`
        // prints usage — the flags mean "treat ALL args as this kind".)
        assert_eq!(
            install_bundle_args(&[pkg("ollama", "formula"), pkg("open-webui", "cask")]),
            vec![
                svec(&["install", "--formula", "ollama"]),
                svec(&["install", "--cask", "open-webui"]),
            ]
        );
    }

    #[test]
    fn install_bundle_all_formulae_is_one_step() {
        // media: ffmpeg + yt-dlp + mpv, all formulae → a single invocation.
        assert_eq!(
            install_bundle_args(&[pkg("ffmpeg", "formula"), pkg("yt-dlp", "formula"), pkg("mpv", "formula")]),
            vec![svec(&["install", "--formula", "ffmpeg", "yt-dlp", "mpv"])]
        );
    }

    #[test]
    fn install_bundle_all_casks_is_one_step() {
        // graphics: inkscape + gimp + krita, all casks → a single invocation.
        assert_eq!(
            install_bundle_args(&[pkg("inkscape", "cask"), pkg("gimp", "cask"), pkg("krita", "cask")]),
            vec![svec(&["install", "--cask", "inkscape", "gimp", "krita"])]
        );
    }

    #[test]
    fn install_bundle_empty_has_no_steps() {
        assert!(install_bundle_args(&[]).is_empty());
    }

    #[test]
    fn unpin_uses_unpin_verb() {
        assert_eq!(
            pin_args("google-chrome", PackageKind::Cask, false),
            svec(&["unpin", "--cask", "google-chrome"])
        );
    }
}
