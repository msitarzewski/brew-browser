//! brew-browser — Tauri 2 backend entrypoint.
//!
//! Module layout per `memory-bank/backendApi.md` §9. This file is the
//! Tauri Builder + invoke_handler registration; every command lives
//! in `commands::*`.

mod brew;
mod bundles_live;
mod catalog;
mod commands;
mod enrichment;
mod error;
mod github;
mod state;
mod system;
mod trending;
mod types;
mod util;
mod vulns;

use bundles_live::bundles_live;
use commands::*;
use system::profile::system_profile;

// =============================================================
// Phase 15 — Updater minisign public key
// =============================================================
//
// The public key half of the minisign keypair used to sign release
// .dmg artifacts. Public keys are public by design — embedding them
// in the binary is the standard pattern for offline-verified updates
// (Sparkle, Tauri, every shipping Mac auto-updater).
//
// **Placeholder.** Replace before cutting a release. The real key is
// generated per `BUILD.md` instructions:
//
//     tauri signer generate -w ~/.config/brew-browser/updater.key
//
// The matching public key the command prints is what goes here.
// Keep the private key chmod 600 outside the repo — it's the only
// thing standing between a compromised brew-browser.zerologic.com
// and a malicious binary push.
//
// Real minisign public key, set 2026-05-25 for v0.3.0. The matching
// private key lives at `~/.config/brew-browser/updater.key` (chmod 600,
// outside the repo). The signature verification at install time
// validates every downloaded `.app.tar.gz` against this pubkey; any
// mismatch aborts the install with no on-disk side effects.
//
// `tauri.conf.json` carries the same value for the plugin to consume
// at startup; keep both in sync. The plugin parses Tauri's base64-of-
// minisign-blob format directly — what you see here is exactly what
// `tauri signer generate -w …` printed.
const UPDATER_PUBKEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDczMzVERDBGRDAzQTRBNkEKUldScVNqclFEOTAxYy9DYTg5QThJR2JWWHJZSWdWMXRkckFlUDAyVHpxcjgwWXVHaUQ2VlNGcHgK";

pub fn updater_pubkey() -> &'static str {
    UPDATER_PUBKEY
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Best-effort tracing setup — silent if RUST_LOG is unset.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                tracing_subscriber::EnvFilter::new("warn,brew_browser_lib=info")
            }),
        )
        .try_init();

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        // Phase 15 — register the updater plugin. The endpoint URL and
        // public key are configured in `tauri.conf.json`; the plugin
        // pulls them from the parsed Config at startup. Our IPC
        // wrappers in `commands::updater` route every check + install
        // through `state.require_network("update_check")` first so
        // Offline Mode kills the path even though the plugin itself
        // would otherwise try the manifest endpoint.
        .plugin(tauri_plugin_updater::Builder::new().build())
        // Issue #17 — persist the window's size + position across launches.
        // The plugin restores saved geometry on launch and saves on a clean
        // exit. We ALSO save eagerly on every resize/move (see
        // `.on_window_event` below) so geometry survives dev hot-reloads,
        // force-quits, and crashes — not just a graceful Cmd-Q. Default
        // StateFlags cover size + position (plus maximized/fullscreen).
        .plugin(tauri_plugin_window_state::Builder::default().build());

    // The native menu is macOS-idiomatic: on macOS it populates the
    // global menu bar at the top of the screen. On Linux/GTK there is
    // no global menu bar, so Tauri renders it as an in-window GTK
    // MenuBar strip — redundant (every action is reachable from the
    // in-app UI) and it clashes with the transparent-window config
    // (the strip paints see-through). Gate it to macOS so Linux gets a
    // clean chromeless window. Discovered during the v0.6.0 Linux
    // bring-up.
    #[cfg(target_os = "macos")]
    let builder = builder
        .menu(build_app_menu)
        .on_menu_event(handle_menu_event);

    builder
        .setup(|app| {
            state::initialize(app)?;
            // Phase 15 — spawn the auto-check scheduler. The task
            // sleeps for 24h between wakes, re-reads the live settings
            // on each cycle (so a user toggling auto-check off mid-run
            // is honoured on the next wake), and runs the check only
            // when both `update_auto_check` is on AND `paranoid_mode`
            // is off. Backoff on failure: 1h → 6h → 24h.
            commands::updater::spawn_auto_check_scheduler(app.handle().clone());
            #[cfg(target_os = "macos")]
            {
                // Apply NSVisualEffectView to the main window so it picks up the
                // native macOS "frosted glass" appearance. Material::HudWindow
                // gives a slightly heavier blur that looks good behind the
                // sidebar and main panes; the WebView background must be set
                // transparent in CSS (see app.css :root) for the blur to show.
                use tauri::Manager;
                use window_vibrancy::{
                    apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState,
                };
                if let Some(window) = app.get_webview_window("main") {
                    let _ = apply_vibrancy(
                        &window,
                        NSVisualEffectMaterial::HudWindow,
                        Some(NSVisualEffectState::Active),
                        None,
                    );
                }
            }
            Ok(())
        })
        // Persist window geometry shortly after a resize/move settles, not only
        // on a clean exit — so size/position survive dev hot-reloads,
        // force-quits, and crashes (issue #17), WITHOUT writing on every drag
        // tick. macOS fires Resized/Moved continuously during a drag, so we
        // debounce: each event bumps a generation counter and schedules a save
        // 400ms out; only the last event in the burst still matches the counter
        // and actually writes the ~200-byte state file.
        .on_window_event(|window, event| {
            use std::sync::atomic::{AtomicU64, Ordering};
            use tauri::Manager;
            use tauri_plugin_window_state::{AppHandleExt, StateFlags};

            static RESIZE_GEN: AtomicU64 = AtomicU64::new(0);
            const DEBOUNCE: std::time::Duration = std::time::Duration::from_millis(400);

            if matches!(
                event,
                tauri::WindowEvent::Resized(_) | tauri::WindowEvent::Moved(_)
            ) {
                let my_gen = RESIZE_GEN.fetch_add(1, Ordering::SeqCst) + 1;
                let app = window.app_handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(DEBOUNCE).await;
                    // Skip if a newer resize/move arrived during the wait —
                    // only the final geometry of the burst is written.
                    if RESIZE_GEN.load(Ordering::SeqCst) == my_gen {
                        let _ = app.save_window_state(StateFlags::all());
                    }
                });
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_version,
            brew_doctor,
            system_status,
            brew_redetect,
            open_terminal_install,
            brew_get_analytics,
            brew_set_analytics,
            brew_list,
            brew_outdated,
            brew_info,
            brew_search,
            brew_search_desc,
            local_search,
            brew_install,
            brew_uninstall,
            brew_upgrade,
            brew_upgrade_many,
            brew_update,
            brew_doctor_stream,
            brew_cleanup,
            brew_autoremove,
            brew_set_pinned,
            cancel_job,
            brewfile_dump,
            brewfile_install,
            brewfile_check,
            brewfile_list,
            brewfile_read,
            brewfile_delete,
            brewfile_export,
            brewfile_import,
            trending_fetch,
            trending_clear_cache,
            trending_history_index,
            trending_history_fetch,
            cask_icon,
            cask_icon_from_homepage,
            catalog_summary,
            catalog_refresh,
            catalog_lookup_formula,
            catalog_lookup_cask,
            catalog_formulae_summary,
            catalog_casks_summary,
            catalog_reverse_dependents,
            categories_data,
            enrichment_data,
            enrichment_lookup,
            enrichment_live_version,
            enrichment_live_categories,
            enrichment_live_entry,
            disk_usage,
            disk_usage_clear_cache,
            brew_cleanup_preview,
            open_in_finder,
            services_list,
            services_clear_cache,
            services_start,
            services_stop,
            services_restart,
            settings_get,
            settings_set,
            settings_reset,
            github_repo_stats,
            github_status,
            github_signin_start,
            github_signin_poll,
            github_signout,
            github_star,
            github_unstar,
            github_is_starred,
            github_watch,
            github_unwatch,
            github_create_issue,
            update_check_now,
            update_install,
            update_skip,
            update_relaunch,
            vulns_scan_all,
            vulns_scan_one,
            vulns_install_helper,
            vulns_invalidate,
            system_profile,
            bundles,
            brew_install_bundle,
            bundles_live,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// =============================================================
// Native macOS menu (Phase 12+)
// =============================================================
//
// macOS apps have a system menu bar above the screen, not inside the window.
// The "App" menu is the first item (named after the app) and is where users
// expect to find "About <App>" and "Settings…". Per Tauri 2 conventions we
// build the menu in a closure passed to `.menu(...)` on the Builder, and
// dispatch click events from `.on_menu_event(...)`.
//
// The menu items emit Tauri events that the frontend listens for via
// `listen()` and turns into store-state updates (`ui.openAbout()` /
// `ui.openSettings()`). This keeps the menu definition Rust-side and the
// modal rendering entirely in Svelte.

const MENU_EVENT_ABOUT: &str = "brew-browser/menu/about";
const MENU_EVENT_SETTINGS: &str = "brew-browser/menu/settings";

fn build_app_menu<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
) -> tauri::Result<tauri::menu::Menu<R>> {
    use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};

    let pkg = app.package_info();

    // App menu: About (custom — opens our in-app modal), Settings…, ─, Hide
    // / Hide-Others / Show-All, ─, Quit. The native PredefinedMenuItem::about
    // would open the OS dialog; we route through our own modal instead via
    // a MenuItemBuilder + the menu event so the donate CTA + Anthropic
    // credits render in our UI.
    let about_item = MenuItemBuilder::new(format!("About {}", pkg.name))
        .id(MENU_EVENT_ABOUT)
        .build(app)?;
    let settings_item = MenuItemBuilder::new("Settings…")
        .id(MENU_EVENT_SETTINGS)
        .accelerator("CmdOrCtrl+,")
        .build(app)?;

    let app_submenu = SubmenuBuilder::new(app, pkg.name.clone())
        .item(&about_item)
        .separator()
        .item(&settings_item)
        .separator()
        .item(&PredefinedMenuItem::hide(app, None)?)
        .item(&PredefinedMenuItem::hide_others(app, None)?)
        .item(&PredefinedMenuItem::show_all(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::quit(app, None)?)
        .build()?;

    // Standard ancillary menus — Edit (copy/paste/etc.) + Window. Pure
    // PredefinedMenuItems so we don't have to reinvent them.
    let edit_submenu = SubmenuBuilder::new(app, "Edit")
        .item(&PredefinedMenuItem::undo(app, None)?)
        .item(&PredefinedMenuItem::redo(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .item(&PredefinedMenuItem::select_all(app, None)?)
        .build()?;

    let window_submenu = SubmenuBuilder::new(app, "Window")
        .item(&PredefinedMenuItem::minimize(app, None)?)
        .item(&PredefinedMenuItem::maximize(app, None)?)
        .separator()
        .item(&PredefinedMenuItem::close_window(app, None)?)
        .build()?;

    MenuBuilder::new(app)
        .item(&app_submenu)
        .item(&edit_submenu)
        .item(&window_submenu)
        .build()
}

fn handle_menu_event<R: tauri::Runtime>(app: &tauri::AppHandle<R>, event: tauri::menu::MenuEvent) {
    use tauri::Emitter;
    match event.id().as_ref() {
        MENU_EVENT_ABOUT => {
            let _ = app.emit("menu:about", ());
        }
        MENU_EVENT_SETTINGS => {
            let _ = app.emit("menu:settings", ());
        }
        _ => {}
    }
}
