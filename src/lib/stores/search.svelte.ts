/**
 * Search store — drives the Discover view + the command-palette index search.
 * Debounced query → `local_search` (the in-process union scan across
 * catalog + enrichment + categories). Replaced `brew_search` in v0.3.1:
 * brew's own search only matches package names; local_search matches
 * name + AI-curated friendlyName + AI summary + upstream desc + category
 * labels + enrichment tags, with field-weighted scoring.
 *
 * `brewSearch` remains exposed in api.ts for any future caller that
 * explicitly wants brew's view (none today — kept for parity).
 */

import { localSearch } from "$lib/api";
import { t } from "$lib/i18n/messages";
import { ui } from "$lib/stores/ui.svelte";
import { isBrewError, type SearchResults } from "$lib/types";

class SearchStore {
  query: string = $state("");
  results: SearchResults | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);
  recent: string[] = $state([]);

  private debounceTimer: ReturnType<typeof setTimeout> | null = null;

  setQuery(q: string) {
    this.query = q;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    if (q.length < 2) {
      this.results = null;
      this.error = null;
      return;
    }
    this.debounceTimer = setTimeout(() => this.run(q), 300);
  }

  async run(q: string) {
    if (!q || q.length < 2) return;
    this.loading = true;
    this.error = null;
    try {
      this.results = await localSearch(q, ui.locale);
      // push to recent (dedupe, cap 8)
      this.recent = [q, ...this.recent.filter((r) => r !== q)].slice(0, 8);
    } catch (e) {
      if (isBrewError(e)) {
        this.error = `${t("discover.searchFailed", ui.locale)}: ${e.code}`;
      } else {
        this.error = `${t("trending.error.backend", ui.locale, { error: String(e) })}`;
      }
      this.results = null;
    } finally {
      this.loading = false;
    }
  }

  clear() {
    this.query = "";
    this.results = null;
    this.error = null;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
  }
}

export const search = new SearchStore();
