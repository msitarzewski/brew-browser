/**
 * Categories store — lazy-loads the bundled `categories.json` via the
 * `categories_data` Tauri command and exposes derived helpers for tile
 * rendering, filtering, and per-package lookup.
 *
 * Singleton: import `categories` from this module everywhere; the store
 * fetches once per process and caches the result.
 */

import { categoriesData, enrichmentLiveCategories, enrichmentLiveVersion } from "$lib/api";
import { messages, type Locale } from "$lib/i18n/messages";
import { settings } from "$lib/stores/settings.svelte";
import { isLinux } from "$lib/util/platform";
import { GENERAL_KEY, subgroupsFor, type Subgroup } from "$lib/util/subcategories";
import type { CategoriesData, PackageKind } from "$lib/types";

interface CategoryTile {
  slug: string;
  label: string;
  icon: string;
  count: number;
}

class CategoriesStore {
  data: CategoriesData | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);

  private loadPromise: Promise<void> | null = null;

  /** Lazy-load on first access. Safe to call repeatedly — only fetches once. */
  async ensureLoaded(): Promise<void> {
    if (this.data || this.loadPromise) {
      return this.loadPromise ?? Promise.resolve();
    }
    this.loading = true;
    this.error = null;
    this.loadPromise = (async () => {
      try {
        this.data = await categoriesData();
      } catch (e) {
        this.error = `Failed to load categories: ${String(e)}`;
      } finally {
        this.loading = false;
        this.loadPromise = null;
      }
    })();
    return this.loadPromise;
  }

  /** Opt-in gate: live categories need the toggle, network (not paranoid),
   *  and AI features on (categories are an AI feature). */
  private get liveAllowed(): boolean {
    return (
      settings.effective.liveEnrichmentEnabled === true &&
      settings.effective.paranoidMode !== true &&
      settings.effective.aiFeaturesEnabled === true
    );
  }

  /** Pull the live categories file only when the served version is newer than
   *  what we hold, replacing the bundled/cached data. Soft-fail (keeps current
   *  data on any error). Called on catalog refresh. Returns true if updated. */
  async refreshLiveIfNewer(): Promise<boolean> {
    if (!this.liveAllowed) return false;
    await this.ensureLoaded();
    try {
      const probe = await enrichmentLiveVersion();
      const have = this.data?.version ?? "";
      // Versions are ISO/date strings — lexicographic compare is chronological.
      if (probe.categoriesVersion <= have) return false;
      const fresh = await enrichmentLiveCategories();
      this.data = fresh;
      return true;
    } catch {
      return false; // keep current data
    }
  }

  /**
   * Categories of a given token, in declared order. Returns an empty array if
   * the token is uncategorized OR the data isn't loaded yet.
   */
  categoriesOf(name: string, kind: PackageKind): string[] {
    if (!this.data) return [];
    const map = kind === "cask" ? this.data.casks : this.data.formulae;
    return map[name] ?? [];
  }

  /**
   * Sorted tile list for the Discover grid. `developer-tools` first (largest),
   * `uncategorized` always last, the rest by descending count.
   *
   * Linux: the bundled categories.json is platform-agnostic and carries cask
   * tokens, but casks don't exist on Linux — they're excluded from the tile
   * counts so the numbers match the (cask-free) browse lists.
   */
  tiles = $derived.by<CategoryTile[]>(() => {
    if (!this.data) return [];
    const counts = new Map<string, number>();
    if (!isLinux) {
      for (const cats of Object.values(this.data.casks)) {
        for (const c of cats) counts.set(c, (counts.get(c) ?? 0) + 1);
      }
    }
    for (const cats of Object.values(this.data.formulae)) {
      for (const c of cats) counts.set(c, (counts.get(c) ?? 0) + 1);
    }
    const out: CategoryTile[] = [];
    for (const [slug, meta] of Object.entries(this.data.categories)) {
      out.push({ slug, label: meta.label, icon: meta.icon, count: counts.get(slug) ?? 0 });
    }
    out.sort((a, b) => {
      if (a.slug === "uncategorized") return 1;
      if (b.slug === "uncategorized") return -1;
      return b.count - a.count;
    });
    return out;
  });

  /**
   * All tokens that belong to a given category, with their kind. Used by the
   * filtered view after a tile click. Returns deterministic alphabetical order.
   */
  tokensInCategory(slug: string): Array<{ name: string; kind: PackageKind }> {
    if (!this.data) return [];
    const out: Array<{ name: string; kind: PackageKind }> = [];
    for (const [name, cats] of Object.entries(this.data.casks)) {
      if (cats.includes(slug)) out.push({ name, kind: "cask" });
    }
    for (const [name, cats] of Object.entries(this.data.formulae)) {
      if (cats.includes(slug)) out.push({ name, kind: "formula" });
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
  }

  /**
   * Feature #6 — sub-categories. Given a SINGLE selected category slug, group
   * its members by their OTHER co-assigned category slugs (multi-label
   * membership is the only genuine second-level signal in the flat
   * `categories.json` — there is no taxonomy tree; see
   * `util/subcategories.ts` for the full rationale). Members carrying ONLY
   * the selected slug land in a pinned-last "General <Label>" bucket.
   *
   * Pure pass-through to {@link subgroupsFor}, threading the in-memory data
   * and the Linux cask gate so callers don't re-implement either. Returns an
   * empty list when data isn't loaded. Callers MUST only invoke this for a
   * single selected category — multi-chip / search views stay flat.
   *
   * Linux: cask members are excluded from every sub-group and from the
   * counts, matching the cask-free browse list (Discover.svelte browseItems).
   * Native (macOS-only) implements the identical derivation for parity.
   */
  subgroupsInCategory(slug: string, locale: Locale = "en"): Subgroup[] {
    const groups = subgroupsFor(this.data, slug, isLinux);
    if (locale === "en") return groups;
    const selectedLabel = this.labelOf(slug, locale);
    return groups.map((group) => {
      if (group.key === GENERAL_KEY) {
        return { ...group, label: `Общее: ${selectedLabel}` };
      }
      return { ...group, label: `${selectedLabel} + ${this.labelOf(group.key, locale)}` };
    });
  }

  /** Pretty label for a slug. Falls back to the slug if data isn't loaded. */
  labelOf(slug: string, locale: Locale = "en"): string {
    const label = this.data?.categories[slug]?.label ?? slug;
    if (locale === "en") return label;
    return (messages[locale] as Record<string, string>)[label] ?? label;
  }

  /**
   * Phase 13 — central gate for all category-driven UI. When the master
   * AI Features toggle is OFF, every consumer should treat categories
   * as if they don't exist (donut chart hidden, chip filters hidden,
   * Discover tile grid hidden, PackageDetail Categories row hidden).
   *
   * Components read this as `categories.visible` and `{#if categories.visible}`
   * around any category-rendering branch.
   */
  get visible(): boolean {
    return settings.effective.aiFeaturesEnabled;
  }
}

export const categories = new CategoriesStore();
