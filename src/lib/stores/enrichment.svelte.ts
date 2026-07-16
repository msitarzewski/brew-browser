/**
 * Enrichment store (Phase 13) — lazy-loads the bundled `enrichment.json.gz`
 * payload via the `enrichment_data` Tauri command and exposes per-token
 * lookup helpers.
 *
 * **AI Features toggle gate.** Every public lookup checks
 * `settings.effective.aiFeaturesEnabled` and short-circuits to `null`
 * when the user has the toggle off — so UI components don't have to
 * re-implement the gate at every call site.
 *
 * Singleton: import `enrichment` from this module everywhere; the store
 * fetches once per process and caches the result.
 */

import { enrichmentData, enrichmentLiveEntry } from "$lib/api";
import { settings } from "$lib/stores/settings.svelte";
import { ui } from "$lib/stores/ui.svelte";
import { bareToken } from "$lib/util/token";
import type { EnrichmentData, EnrichmentEntry } from "$lib/types";

function mergeLiveWithLocalized(
  live: EnrichmentEntry | undefined,
  localized: EnrichmentEntry | undefined,
): EnrichmentEntry | undefined {
  if (!live) return localized;
  if (!localized || ui.locale !== "ru") return live;

  return {
    friendlyName: localized.friendlyName ?? live.friendlyName,
    summary: localized.summary ?? live.summary,
    useCases: localized.useCases.length > 0 ? localized.useCases : live.useCases,
    similar: live.similar.length > 0 ? live.similar : localized.similar,
    tags: live.tags.length > 0 ? live.tags : localized.tags,
    searchTerms: localized.searchTerms ?? live.searchTerms,
  };
}

class EnrichmentStore {
  data: EnrichmentData | null = $state(null);
  dataLocale: string | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);

  private loadPromise: Promise<void> | null = null;

  /** Live overlay: per-token entries fetched from the opt-in endpoint,
      layered over the bundled `data.entries`. Empty unless the user opted in. */
  liveEntries: Record<string, EnrichmentEntry> = $state({});
  private liveAttempted = new Set<string>();

  /** Lazy-load on first access. Safe to call repeatedly — only fetches once.
      Failures are recorded on `this.error` but never rethrown; the store
      stays usable with `data === null` and lookups return `null`. */
  async ensureLoaded(): Promise<void> {
    const locale = ui.locale;
    if ((this.data && this.dataLocale === locale) || this.loadPromise) {
      return this.loadPromise ?? Promise.resolve();
    }
    this.loading = true;
    this.error = null;
    this.loadPromise = (async () => {
      try {
        this.data = await enrichmentData(locale);
        this.dataLocale = locale;
      } catch (e) {
        this.error = `Failed to load enrichment: ${String(e)}`;
      } finally {
        this.loading = false;
        this.loadPromise = null;
      }
    })();
    return this.loadPromise;
  }

  /** Returns the enrichment entry for a token, OR null when:
   *  - AI features toggle is off
   *  - Data not loaded
   *  - No entry for this token (empty placeholder catalog)
   */
  lookup(token: string): EnrichmentEntry | null {
    if (!settings.effective.aiFeaturesEnabled) return null;
    if (this.data && this.dataLocale !== ui.locale) {
      void this.ensureLoaded();
    }
    // Live overlay wins over the bundled baseline.
    const hit = mergeLiveWithLocalized(this.liveEntries[token], this.data?.entries[token]);
    if (hit) return hit;
    // Tap-qualified token (`user/tap/name`) → retry the bare name the
    // enrichment is keyed by (live overlay still preferred over bundled).
    const bare = bareToken(token);
    if (bare === token) return null;
    return mergeLiveWithLocalized(this.liveEntries[bare], this.data?.entries[bare]) ?? null;
  }

  /** Friendly-name short-circuit: returns `friendlyName` if available AND
   *  the AI toggle is on; else null. Components that only want the
   *  display-name override can skip the full lookup + null-checks.
   */
  friendlyName(token: string): string | null {
    const e = this.lookup(token);
    if (!e) return null;
    return e.friendlyName ?? null;
  }

  /** Summary short-circuit: returns the AI-generated 1-2 sentence
   *  "what + when" description when AI Features is on AND the bundle
   *  has an entry; else null. Used by list-view Description columns
   *  with `summary > upstream desc > null` fallback semantics.
   */
  summaryOf(token: string): string | null {
    const e = this.lookup(token);
    if (!e) return null;
    return e.summary ?? null;
  }

  /** True when the AI Features toggle is on AND we have data loaded.
   *  Components use this to short-circuit render branches without
   *  re-deriving the gate. */
  get visible(): boolean {
    return settings.effective.aiFeaturesEnabled && this.data !== null;
  }

  /** Opt-in gate: live enrichment needs the toggle, network (not paranoid),
   *  and AI features on (enrichment is an AI feature). */
  private get liveAllowed(): boolean {
    return (
      settings.effective.liveEnrichmentEnabled === true &&
      settings.effective.paranoidMode !== true &&
      settings.effective.aiFeaturesEnabled === true
    );
  }

  /** Fetch a token's live enrichment on demand (e.g. when its detail panel
   *  opens) and overlay it on the bundled entry. Soft-fail + deduped: each
   *  token is attempted at most once per refresh cycle; a 404 (unknown token)
   *  is normal and leaves the bundled entry in place. */
  async ensureLive(token: string): Promise<void> {
    if (!this.liveAllowed) return;
    // Tap-qualified tokens (`user/tap/name`) carry a `/` the served path +
    // allowlist reject; fetch, dedupe, and key by the bare name — matching
    // `lookup`'s bare fallback and the native build's `ensureLiveEnrichment`.
    const key = bareToken(token);
    if (this.liveAttempted.has(key)) return;
    this.liveAttempted.add(key);
    try {
      const entry = await enrichmentLiveEntry(key);
      this.liveEntries = { ...this.liveEntries, [key]: entry };
    } catch {
      // keep bundled
    }
  }

  /** Drop the live overlay so the next `ensureLive` re-fetches fresh data.
   *  Called on catalog refresh (the served tree may have changed). */
  resetLive(): void {
    this.liveAttempted.clear();
    this.liveEntries = {};
  }
}

export const enrichment = new EnrichmentStore();
