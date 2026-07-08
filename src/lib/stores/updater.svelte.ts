/**
 * Updater store (Phase 15).
 *
 * Mirrors backend `update_*` commands into the renderer. Two consumers:
 *
 *   - `UpdateIndicator.svelte` — the title-bar pill. Renders only when
 *     `available !== null` AND Offline Mode is off (the second gate is
 *     evaluated in the component against `settings.effective.paranoidMode`).
 *   - `SettingsSectionUpdates.svelte` — the Settings → Network →
 *     Updates subsection. Owns the manual "Check for updates now"
 *     button, the auto-check toggle, and the install action.
 *
 * **No update info on disk in this store.** The skip-list, last-checked
 * timestamp, and the cached "available" entry all live on the backend
 * inside `settings.json`. This store just shadows the most recent
 * outcome so the UI doesn't have to re-IPC on every render.
 *
 * Failure modes handled here (everything else propagates to the caller):
 *
 *   - `paranoid_mode_blocked` → swallowed silently into `available = null`
 *     because the indicator must hide in Offline Mode anyway, and the
 *     Settings card shows its own "Disabled by Offline Mode" tooltip
 *     on the button.
 *   - any other `BrewError` → stored on `error` for the Settings card
 *     to surface inline with a "Try again" button.
 */

import { updateCheckNow, updateInstall, updateRelaunch, updateSkip } from "$lib/api";
import { ui } from "$lib/stores/ui.svelte";
import { isBrewError, brewErrorMessage, type UpdateInfo } from "$lib/types";

class UpdaterStore {
  /** Epoch millis of the most recent check (success OR error). `null`
      until the first check completes. Surfaced in the Settings card as
      a "Last checked: …" line for the curious user. */
  lastChecked: number | null = $state(null);

  /** The currently-known available update, or `null` when up-to-date /
      blocked / never-checked. Reactive — the title-bar indicator's
      visibility tracks the transition from `null` ↔ a value. */
  available: UpdateInfo | null = $state(null);

  /** True while `checkNow()` is in flight. The Settings button uses
      this to render a spinner inline. */
  checking: boolean = $state(false);

  /** True while `install()` is in flight. The Settings card swaps
      its install button for a progress indicator; the title-bar
      indicator swaps its × for a small spinner so the user sees
      activity even when they navigated away from Settings. */
  installing: boolean = $state(false);

  /** True after a successful install. Surfaced as a "Relaunch now"
      affordance in the Settings card. The Settings card's button
      calls `relaunch()` which fires the `update_relaunch` IPC; the
      backend schedules `tauri::AppHandle::restart()` on a short
      delay so the IPC response arrives before the process dies. */
  installComplete: boolean = $state(false);

  /** Human-readable error from the most recent op (`checkNow` or
      `install`), or `null`. Cleared by the next successful op. */
  error: string | null = $state(null);

  /**
   * Manually check the manifest. Updates `available` based on the
   * outcome; the title-bar indicator's visibility falls out of that.
   * Idempotent — safe to spam-click the Settings button.
   *
   * Maps `paranoid_mode_blocked` to a silent `available = null` because
   * Offline Mode hides the indicator anyway and the Settings button
   * surfaces its own disabled-state tooltip.
   */
  async checkNow(): Promise<void> {
    if (this.checking) return;
    this.checking = true;
    this.error = null;
    try {
      const outcome = await updateCheckNow();
      this.lastChecked = Date.now();
      switch (outcome.kind) {
        case "available":
          this.available = {
            version: outcome.version,
            currentVersion: outcome.currentVersion,
            notes: outcome.notes,
            pubDate: outcome.pubDate,
            skipped: outcome.skipped,
          };
          break;
        case "upToDate":
          this.available = null;
          break;
      }
    } catch (e) {
      this.lastChecked = Date.now();
      if (isBrewError(e) && e.code === "paranoid_mode_blocked") {
        // Hide the indicator; don't surface a confusing error in
        // the Settings card (the button's own tooltip explains why).
        this.available = null;
        this.error = null;
      } else if (isBrewError(e)) {
        this.error = brewErrorMessage(e, ui.locale);
      } else {
        this.error = String(e);
      }
    } finally {
      this.checking = false;
    }
  }

  /**
   * Download + verify + install the named version. The backend
   * cross-checks `version` against the cached "available" entry, so
   * passing a stale version fast-fails with `invalid_argument`.
   *
   * On success: flips `installComplete = true` and leaves `available`
   * intact so the Settings card can render its "Relaunch now"
   * affordance. The title-bar indicator continues to render until
   * the user relaunches or dismisses.
   *
   * On failure: stashes the message on `error` and clears the
   * `installing` flag so the Settings card can show its retry path.
   */
  async install(version: string): Promise<void> {
    if (this.installing) return;
    this.installing = true;
    this.installComplete = false;
    this.error = null;
    try {
      await updateInstall(version);
      this.installComplete = true;
    } catch (e) {
      if (isBrewError(e)) {
        this.error = brewErrorMessage(e, ui.locale);
      } else {
        this.error = String(e);
      }
    } finally {
      this.installing = false;
    }
  }

  /**
   * Add `version` to the backend's skip-list. The title-bar indicator
   * hides as soon as `available` flips to `null`; a future release
   * (any version newer than this one) re-triggers the indicator.
   *
   * Optimistic — clears `available` before the IPC resolves so the
   * pill disappears immediately. The skip-list write itself is
   * eventually consistent on the backend; if the IPC fails (e.g.
   * Offline Mode flipped on between the indicator render and the ×
   * click, blocking the settings write) the indicator stays hidden
   * for this session and re-checks on the next launch.
   */
  async skip(version: string): Promise<void> {
    // Optimistic update — indicator disappears immediately.
    this.available = null;
    try {
      await updateSkip(version);
    } catch (e) {
      // Best-effort: don't restore the indicator on failure (the user
      // explicitly asked to dismiss; better to keep their click than
      // surface a confusing "we couldn't dismiss" toast).
      if (isBrewError(e)) {
        this.error = brewErrorMessage(e, ui.locale);
      } else {
        this.error = String(e);
      }
    }
  }

  /**
   * Relaunch the app after a successful install. Fires the backend's
   * `update_relaunch` IPC, which schedules `tauri::AppHandle::restart()`
   * on a short delay so the IPC response arrives before the process
   * dies. The renderer's pending `await` is expected to be torn down
   * mid-call — we don't wait on it.
   */
  async relaunch(): Promise<void> {
    try {
      await updateRelaunch();
    } catch (e) {
      // The process may have already started restarting and the IPC
      // socket closed mid-call. Treat any error here as benign — if
      // the restart actually failed, the user will notice immediately.
      if (isBrewError(e)) {
        this.error = brewErrorMessage(e, ui.locale);
      } else {
        this.error = String(e);
      }
    }
  }

  /** Reset post-install / post-error UI to its baseline. Useful from
      the Settings card when the user dismisses an error and wants to
      check again. */
  clearError(): void {
    this.error = null;
  }
}

/** Module-level singleton. Components import { updater } and read
    `updater.available`, etc. as Svelte 5 reactive state. */
export const updater = new UpdaterStore();
