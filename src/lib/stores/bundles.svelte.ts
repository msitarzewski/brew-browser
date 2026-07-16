/**
 * Bundles store — lazy-loads the curated bundle recipes via the `bundles`
 * Tauri command (backed by the embedded `bundles.json`), holds them, and pairs
 * each with the M1 `SystemProfile` to compute capability readiness client-side.
 *
 * Singleton: import `bundles` from this module everywhere; the store fetches
 * bundles + profile once per process and caches the result.
 */

import { bundles as fetchBundles, bundlesLive, systemProfile } from "$lib/api";
import { settings } from "$lib/stores/settings.svelte";
import { ui } from "$lib/stores/ui.svelte";
import { t } from "$lib/i18n/messages";
import type { Bundle, Readiness, SystemProfile } from "$lib/types";
import { readiness } from "$lib/util/readiness";
import { shouldReplaceWithLive } from "$lib/util/liveBundles";

/** localStorage key that overrides the probed RAM so Marginal/Blocked states
 *  are reachable on a big dev box (e.g. the 128 GB Mac). Set e.g.
 *  `localStorage["brewbrowser.fakeRamGB"] = "8"` and reload. Mirrors the Rust
 *  `BREWBROWSER_FAKE_RAM_GB` env override. */
const FAKE_RAM_KEY = "brewbrowser.fakeRamGB";

class BundlesStore {
  list: Bundle[] = $state([]);
  profile: SystemProfile | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);
  loaded: boolean = $state(false);
  locale: string | null = $state(null);

  private loadPromise: Promise<void> | null = null;

  /**
   * Load bundles + the system profile. Idempotent: concurrent or repeat calls
   * share the same in-flight fetch and skip re-fetching once loaded (pass
   * `force` to refetch). Never throws — a load failure lands in `error`.
   */
  async load(force = false): Promise<void> {
    const locale = ui.locale;
    if (this.loaded && this.locale === locale && !force) return;
    if (this.loadPromise) return this.loadPromise;

    this.loading = true;
    this.error = null;
    const p = (async () => {
      try {
        const [list, profile] = await Promise.all([fetchBundles(locale), systemProfile()]);
        this.list = list;
        this.profile = this.applyRamOverride(profile);
        this.loaded = true;
        this.locale = locale;
      } catch (e) {
        this.error = `${t("bundles.loadFailed", ui.locale)}: ${String(e)}`;
      } finally {
        this.loading = false;
        this.loadPromise = null;
      }
    })();
    this.loadPromise = p;
    // M5 — the bundled list shows as soon as `p` settles; if the user opted
    // in, silently refresh from the project host in the background and replace
    // on a non-empty success. Fire-and-forget so a slow/absent endpoint never
    // delays the cards.
    void p.then(() => this.refreshLive());
    return p;
  }

  /** Opt-in gate for the live refresh: the toggle on AND not in Offline Mode.
   *  The backend re-checks both (paranoid/offline + toggle) — this just avoids
   *  a guaranteed-rejected round-trip. */
  private get liveAllowed(): boolean {
    return (
      settings.effective.liveBundlesEnabled === true &&
      settings.effective.paranoidMode !== true
    );
  }

  /**
   * Pull the latest `bundles.json` from the project host and replace the list
   * on a non-empty success. Soft-fail: any error (disabled, network, 404,
   * parse, newer-than-supported schema) or an EMPTY payload keeps the bundled
   * copy — the shipped set is never wiped. Returns true if it replaced.
   */
  async refreshLive(): Promise<boolean> {
    if (!this.liveAllowed) return false;
    try {
      const live = await bundlesLive(ui.locale);
      if (shouldReplaceWithLive(live)) {
        this.list = live;
        return true;
      }
      return false; // empty payload → keep bundled
    } catch {
      return false; // keep bundled on any failure
    }
  }

  /** Apply the debug RAM override to a freshly-probed profile, if set + valid. */
  private applyRamOverride(profile: SystemProfile): SystemProfile {
    try {
      const raw = localStorage.getItem(FAKE_RAM_KEY);
      if (raw === null) return profile;
      const fake = Number.parseInt(raw, 10);
      if (Number.isNaN(fake)) return profile;
      return { ...profile, ramGB: fake };
    } catch {
      // localStorage unavailable (SSR/prerender) — no override.
      return profile;
    }
  }

  /**
   * Capability readiness of a bundle against the probed profile. Falls back to
   * a permissive "ready" verdict until the profile has loaded (the UI shows
   * pills only once loaded, but this keeps the function total).
   */
  readinessFor(bundle: Bundle): Readiness {
    if (!this.profile) return { verdict: "ready", reason: "Ready." };
    return readiness(bundle.requires ?? null, bundle.capabilityNotes ?? null, this.profile);
  }

  /** Look up a single bundle by id. Returns undefined if not loaded/absent. */
  byId(id: string): Bundle | undefined {
    return this.list.find((b) => b.id === id);
  }
}

export const bundles = new BundlesStore();
