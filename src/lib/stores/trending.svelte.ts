/**
 * Trending store — fetches top-N trending packages per window with cache TTL display.
 */

import { trendingClearCache, trendingFetch } from "$lib/api";
import { t } from "$lib/i18n/messages";
import { ui } from "$lib/stores/ui.svelte";
import { isBrewError, type TrendingReport, type TrendingWindow } from "$lib/types";

class TrendingStore {
  window: TrendingWindow = $state("30d");
  report: TrendingReport | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);
  /** local wall-clock of last successful fetch */
  fetchedAtMs: number | null = $state(null);

  async load(force = false) {
    if (this.loading) return;
    this.loading = true;
    this.error = null;
    try {
      // The backend has a 1-hour cache. The Refresh button's whole purpose is to
      // bust it, so when `force` is set we clear the cache first; otherwise a
      // refresh would just return the same report with a stale cacheAgeSeconds.
      if (force) {
        try {
          await trendingClearCache();
        } catch {
          // Cache-clear failures shouldn't block the fetch — best-effort only.
        }
      }
      this.report = await trendingFetch(this.window);
      this.fetchedAtMs = Date.now();
    } catch (e) {
      if (isBrewError(e)) {
        this.error = e.code === "network"
          ? t("trending.error.network", ui.locale)
          : t("trending.error.failed", ui.locale, { error: e.code });
      } else {
        this.error = t("trending.error.backend", ui.locale, { error: String(e) });
      }
    } finally {
      this.loading = false;
    }
  }

  setWindow(w: TrendingWindow) {
    if (w === this.window) return;
    this.window = w;
    this.report = null;
    this.load();
  }
}

export const trending = new TrendingStore();
