//! `brew_doctor` — startup probe for the brew CLI.
//!
//! Onboarding additions (missing-Homebrew first launch):
//! - `system_status()` — cheap local snapshot: is brew resolved, where,
//!   and are the Xcode Command Line Tools present? No network, no gates.
//! - `brew_redetect()` — re-runs `resolve_brew_path()` and writes the
//!   result into `AppState.brew_path` so the app recovers the moment a
//!   user finishes installing Homebrew, without a relaunch.
//! - `open_terminal_install()` — opens Terminal.app with the official
//!   Homebrew install one-liner pre-typed. The script is a FIXED
//!   constant — zero interpolation — so there is no injection surface.

use serde::Serialize;
use std::path::PathBuf;
use tauri::State;

use crate::brew::exec::run_brew_capture;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::BrewEnvironment;

#[tauri::command]
pub async fn brew_doctor(state: State<'_, AppState>) -> Result<BrewEnvironment, BrewError> {
    let path = match state.brew_path.read().await.clone() {
        Some(p) => p,
        None => {
            return Ok(BrewEnvironment {
                installed: false,
                version: None,
                prefix: None,
                path_used: None,
            });
        }
    };

    let version_out = run_brew_capture(&path, &["--version"], "brew --version")
        .await
        .ok();
    let version = version_out.and_then(|s| {
        // First line, format: "Homebrew 5.1.13"
        s.lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1).map(|v| v.to_string()))
    });

    let prefix = run_brew_capture(&path, &["--prefix"], "brew --prefix")
        .await
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let env = BrewEnvironment {
        installed: true,
        version,
        prefix,
        path_used: Some(path.to_string_lossy().into_owned()),
    };

    {
        let mut cached = state.brew_env.write().await;
        *cached = env.clone();
    }

    Ok(env)
}

// ---------- Onboarding: system status + redetect + Terminal launch ----------

/// Snapshot for the missing-Homebrew onboarding gate. Matches
/// `SystemStatus` in `src/lib/types.ts` (camelCase wire shape).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemStatus {
    pub brew_found: bool,
    pub brew_path: Option<String>,
    pub clt_found: bool,
    /// True when the app itself is running under Rosetta 2 (an Intel build on
    /// an Apple Silicon Mac). Drives the "install the Apple Silicon build"
    /// banner — brew can't install into the arm `/opt/homebrew` prefix from a
    /// translated process without the `arch -arm64` stopgap. See issue #158.
    pub rosetta_translated: bool,
}

impl SystemStatus {
    fn from_brew_path(path: Option<PathBuf>, clt_found: bool) -> Self {
        Self {
            brew_found: path.is_some(),
            brew_path: path.map(|p| p.to_string_lossy().into_owned()),
            clt_found,
            rosetta_translated: crate::system::profile::is_translated(),
        }
    }
}

/// Probe for the Xcode Command Line Tools: `xcode-select -p` exits 0
/// when a developer directory is configured. Local check only — no
/// network, so no paranoid gate. Non-macOS platforms report `true`
/// (the concept doesn't exist there; brew's own deps differ).
#[cfg(target_os = "macos")]
async fn clt_found() -> bool {
    tokio::process::Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(not(target_os = "macos"))]
async fn clt_found() -> bool {
    true
}

/// Cheap local status read for the onboarding gate. Consults the cached
/// `brew_path` (set at startup or by the last `brew_redetect`) — it does
/// NOT re-scan the filesystem; that's `brew_redetect`'s job.
#[tauri::command]
pub async fn system_status(state: State<'_, AppState>) -> Result<SystemStatus, BrewError> {
    let path = state.brew_path.read().await.clone();
    Ok(SystemStatus::from_brew_path(path, clt_found().await))
}

/// Re-run brew detection and persist the result into `AppState.brew_path`
/// so every `require_brew_path()` caller sees the recovered binary — the
/// onboarding view polls this until the user's install lands on disk,
/// and the app comes alive without a relaunch.
#[tauri::command]
pub async fn brew_redetect(state: State<'_, AppState>) -> Result<SystemStatus, BrewError> {
    let path = state.redetect_brew_path().await;
    Ok(SystemStatus::from_brew_path(path, clt_found().await))
}

/// AppleScript handed to `osascript` verbatim. FIXED constant — nothing
/// is ever interpolated into this string, so there is no path for user
/// or package data to reach the shell. The inner command is the official
/// Homebrew install one-liner from <https://brew.sh>; Terminal displays
/// it pre-typed (and running) in a fresh window via `do script`.
#[cfg(target_os = "macos")]
const TERMINAL_INSTALL_SCRIPT: &str = r#"tell application "Terminal"
	activate
	do script "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
end tell"#;

/// Open Terminal.app with the Homebrew install one-liner pre-typed.
///
/// Failure surfaces as a typed `BrewError` (`Io` when osascript can't
/// spawn, `Internal` on a non-zero exit — e.g. the user denied the
/// Automation permission prompt) so the frontend can fall back to its
/// copy-to-clipboard affordance, which is the primary path anyway.
#[tauri::command]
pub async fn open_terminal_install() -> Result<(), BrewError> {
    #[cfg(target_os = "macos")]
    {
        let status = tokio::process::Command::new("/usr/bin/osascript")
            .arg("-e")
            .arg(TERMINAL_INSTALL_SCRIPT)
            .status()
            .await
            .map_err(|e| BrewError::Io {
                message: format!("failed to spawn osascript: {e}"),
            })?;
        if !status.success() {
            return Err(BrewError::Internal {
                message: format!("osascript exited with {:?}", status.code()),
            });
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(BrewError::Internal {
            message: "open_terminal_install is only available on macOS".into(),
        })
    }
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn system_status_serializes_with_camel_case_fields() {
        let s = SystemStatus {
            brew_found: true,
            brew_path: Some("/opt/homebrew/bin/brew".into()),
            clt_found: false,
            rosetta_translated: true,
        };
        let v: Value = serde_json::to_value(&s).unwrap();
        // Critical: must be camelCase for the frontend's SystemStatus type.
        assert_eq!(v["brewFound"], true);
        assert_eq!(v["brewPath"], "/opt/homebrew/bin/brew");
        assert_eq!(v["cltFound"], false);
        assert_eq!(v["rosettaTranslated"], true);
        assert!(
            v.get("rosetta_translated").is_none(),
            "must not emit snake_case `rosetta_translated`"
        );
        assert!(
            v.get("brew_found").is_none(),
            "must not emit snake_case `brew_found`"
        );
        assert!(
            v.get("brew_path").is_none(),
            "must not emit snake_case `brew_path`"
        );
        assert!(
            v.get("clt_found").is_none(),
            "must not emit snake_case `clt_found`"
        );
    }

    #[test]
    fn system_status_serializes_missing_brew_as_null_path() {
        let s = SystemStatus {
            brew_found: false,
            brew_path: None,
            clt_found: true,
            rosetta_translated: false,
        };
        let v: Value = serde_json::to_value(&s).unwrap();
        assert_eq!(v["brewFound"], false);
        // Frontend type is `string | null` — None must serialize to null,
        // not be omitted.
        assert!(v["brewPath"].is_null());
        assert_eq!(v["cltFound"], true);
    }

    #[test]
    fn from_brew_path_maps_some_and_none_consistently() {
        let some = SystemStatus::from_brew_path(Some(PathBuf::from("/usr/local/bin/brew")), true);
        assert!(some.brew_found);
        assert_eq!(some.brew_path.as_deref(), Some("/usr/local/bin/brew"));

        let none = SystemStatus::from_brew_path(None, true);
        assert!(!none.brew_found);
        assert!(none.brew_path.is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn terminal_install_script_is_the_fixed_official_one_liner() {
        // Defense in depth: the script must stay a fixed constant with the
        // official install URL and no interpolation markers. If someone
        // ever turns this into a format string, these assertions fire.
        assert!(TERMINAL_INSTALL_SCRIPT
            .contains("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"));
        assert!(TERMINAL_INSTALL_SCRIPT.starts_with("tell application \"Terminal\""));
        assert!(TERMINAL_INSTALL_SCRIPT.ends_with("end tell"));
        assert!(
            !TERMINAL_INSTALL_SCRIPT.contains("{}"),
            "no format placeholders allowed"
        );
        assert!(
            !TERMINAL_INSTALL_SCRIPT.contains("{0}"),
            "no format placeholders allowed"
        );
    }
}
