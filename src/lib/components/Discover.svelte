<script lang="ts">
  import SearchIcon from "@lucide/svelte/icons/search";
  import XIcon from "@lucide/svelte/icons/x";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Loader from "@lucide/svelte/icons/loader-2";
  import AlertTriangle from "@lucide/svelte/icons/alert-triangle";
  import Pill from "./Pill.svelte";
  import PackageRowIcon from "./PackageRowIcon.svelte";
  import Input from "./Input.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import InfoButton from "./InfoButton.svelte";
  import { search } from "$lib/stores/search.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { categories } from "$lib/stores/categories.svelte";
  import { catalog } from "$lib/stores/catalog.svelte";
  import { discover } from "$lib/stores/discover.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { t, ruPlural } from "$lib/i18n/messages";
  import { resolveCategoryIcon } from "$lib/util/categoryIcon";
  import { isLinux } from "$lib/util/platform";
  import type { PackageKind, SearchHit } from "$lib/types";

  // Lazy-load categories + catalog summary on mount. The stores guard
  // against duplicate fetches; we ensure both are primed for the stale
  // banner and the chip filters.
  categories.ensureLoaded();
  catalog.ensureLoaded();
  // Per-token desc maps power the subtitle fallback when AI Features
  // is off or the token isn't in the enrichment bundle.
  void catalog.ensureSummariesLoaded();
  // Enrichment store is referenced in row markup via `friendlyOf()`;
  // load once so the lookups start returning hits as soon as data lands.
  enrichment.ensureLoaded();

  // ────────────────────────────────────────────────────────────────
  // Phase 12a — stale-catalog banner
  //
  // Session-scoped dismissal. We deliberately don't persist this — the
  // banner is meant to nudge, and a stale catalog the user shrugged at
  // last week is probably still worth surfacing on the next launch.
  let bannerDismissed = $state(false);

  /** Returns the AI-enriched friendly_name for a token when the user has
   *  AI Features on AND the enrichment store has a hit. Null otherwise.
   *  Called inline from row markup (sync Map.get under the hood — no IPC,
   *  no per-row $derived needed). */
  function friendlyOf(token: string): string | null {
    return enrichment.friendlyName(token);
  }

  /** Description-column content for a Discover row. Preference order:
   *    1. AI-generated summary (1-2 sentence "what + when", Tier A
   *       enrichment) when AI Features is on AND token is in the bundle
   *    2. Upstream Homebrew `desc` (from the catalog summary maps —
   *       `catalog_formulae_summary` / `catalog_casks_summary`)
   *    3. null (empty desc cell)
   *
   *  The friendly-subtitle below the token stays as a separate, shorter
   *  scan-aid handled by `friendlyOf` above — different concept.
   *
   *  Sync — both lookups read pre-loaded in-memory state. */
  function descOf(token: string, kind: PackageKind): string | null {
    return enrichment.summaryOf(token) ?? catalog.descOf(token, kind);
  }

  /**
   * Deprecation / disabled badge for a Discover row (Feature #2). Discover
   * rows render off `SearchHit` / category tokens (no `Package`), so the
   * bundled-catalog status is the source — `catalog.statusOf()`. `disabled`
   * wins over `deprecated` when both are set (the stronger danger state).
   * Returns null when the token isn't flagged (no badge, no placeholder).
   * Catalog-sourced → flags-only; the replacement "use X instead" link is
   * PackageDetail-only (brew info carries it; the catalog doesn't).
   */
  function deprecationBadgeOf(
    token: string,
    kind: PackageKind,
  ): { label: string; tone: "warning" | "danger"; title: string } | null {
    const s = catalog.statusOf(token, kind);
    if (!s) return null;
    if (s.disabled) {
      return {
        label: t("disabled", ui.locale),
        tone: "danger",
        title: s.reason
          ? t("discover.disabledReason", ui.locale, { reason: s.reason })
          : t("discover.disabledDefault", ui.locale),
      };
    }
    return {
      label: t("deprecated", ui.locale),
      tone: "warning",
      title: s.reason
        ? t("discover.deprecatedReason", ui.locale, { reason: s.reason })
        : t("discover.deprecatedDefault", ui.locale),
    };
  }

  async function refreshFromBanner() {
    const ok = await catalog.refresh();
    if (ok) {
      bannerDismissed = true;
      toast.success(t("discover.catalogRefreshed", ui.locale), t("discover.catalogFetched", ui.locale));
    } else if (catalog.refreshError) {
      toast.error(t("Catalog refresh failed", ui.locale), catalog.refreshError);
    }
  }

  function openHit(h: { name: string; kind: PackageKind }) {
    ui.selectPackage(h.name, h.kind);
  }

  function handleKey(e: KeyboardEvent) {
    if (e.key === "Enter") {
      search.run(search.query);
    }
  }

  function fmt(n: number): string {
    return n.toLocaleString(ui.locale === "ru" ? "ru-RU" : undefined);
  }

  function catalogStaleText(days: number): string {
    if (ui.locale === "ru") {
      return `Каталог устарел на ${days} ${ruPlural(days, "день", "дня", "дней")}. Новые пакеты и сведения об устаревании могут отсутствовать.`;
    }
    return `Catalog is ${days} ${days === 1 ? "day" : "days"} old. Newer packages and deprecations may be missing.`;
  }

  /**
   * Search-results filtered by the currently-selected category chips. A package
   * matches if ANY of its categories are in the active selection (OR logic),
   * which matches user intent for "narrow down by domain".
   */
  function chipMatch(name: string, kind: PackageKind): boolean {
    if (!discover.hasFilter) return true;
    const cats = categories.categoriesOf(name, kind);
    for (const c of cats) {
      if (discover.selectedCategories.has(c)) return true;
    }
    return false;
  }

  let allHits = $derived<SearchHit[]>(
    [
      ...(search.results?.formulae ?? []),
      ...(search.results?.casks ?? []),
    ].filter((h) => chipMatch(h.name, h.kind)),
  );

  /**
   * Browse-mode list (no search query): union of all packages whose categories
   * intersect the selected chips. Sorted alphabetically for stable scan order.
   *
   * Linux: the bundled categories.json still carries cask tokens (it's
   * platform-agnostic data), but casks don't exist on Linux — skip them so
   * browse mode never lists uninstallable cask-only apps.
   */
  let browseItems = $derived.by<Array<{ name: string; kind: PackageKind }>>(() => {
    if (!discover.hasFilter || !categories.data) return [];
    const set = new Set<string>();
    const out: Array<{ name: string; kind: PackageKind }> = [];
    for (const slug of discover.selectedCategories) {
      for (const pkg of categories.tokensInCategory(slug)) {
        if (isLinux && pkg.kind === "cask") continue;
        const key = `${pkg.kind}:${pkg.name}`;
        if (!set.has(key)) {
          set.add(key);
          out.push(pkg);
        }
      }
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
  });

  /** Header label for the filtered browse view. */
  let browseTitle = $derived.by(() => {
    if (discover.selectedCategories.size === 1) {
      const [slug] = discover.selectedCategories;
      return categories.labelOf(slug, ui.locale);
    }
    const n = discover.selectedCategories.size;
    return ui.locale === "ru"
      ? `${n} ${ruPlural(n, "категория", "категории", "категорий")}`
      : `${n} categories`;
  });

  let catalogItemCount = $derived(
    (isLinux ? 0 : Object.keys(categories.data?.casks ?? {}).length) +
      Object.keys(categories.data?.formulae ?? {}).length,
  );

  /**
   * Feature #6 — sub-categories. Co-occurrence sub-grouping is ONLY defined
   * for a single selected category; multi-chip selections stay flat
   * (`browseItems` above). The store handles the Linux cask gate, dedup, and
   * deterministic ordering (descending count, tie-break slug, "General"
   * bucket pinned last). Empty array → render the flat list as before.
   *
   * Degenerate case: a category whose every member is solo collapses to a
   * single "General <Label>" bucket — rendering one lone sub-group header
   * above the full list looks broken, so we treat a single-bucket result as
   * "not worth sub-grouping" and fall through to the flat list.
   */
  let subgroups = $derived.by(() => {
    if (discover.selectedCategories.size !== 1) return [];
    const [slug] = discover.selectedCategories;
    const groups = categories.subgroupsInCategory(slug, ui.locale);
    return groups.length > 1 ? groups : [];
  });

  let showSubgroups = $derived(subgroups.length > 0);
</script>

<!-- Browse-row snippet — shared by the flat chip-filtered list and the
     Feature #6 sub-grouped sections so the 5-column row markup lives in one
     place. -->
{#snippet browseRow(h: { name: string; kind: PackageKind })}
  {@const installed = packages.isInstalled(h.name, h.kind)}
  {@const isSelected = ui.selectedPackage?.name === h.name && ui.selectedPackage?.kind === h.kind}
  <li>
    <button
      class="row row--with-desc"
      class:selected={isSelected}
      aria-current={isSelected ? "true" : undefined}
      onclick={() => openHit(h)}
    >
      <span class="name-cell">
        <PackageRowIcon token={h.name} kind={h.kind} resolveCask />
        <span class="name truncate">
          <span class="name-text">{h.name}</span>
          {#if friendlyOf(h.name)}
            <span class="friendly-subtitle">{friendlyOf(h.name)}</span>
          {/if}
        </span>
      </span>
      <span class="desc truncate text-muted">{descOf(h.name, h.kind) ?? ""}</span>
      <span class="version truncate text-muted">{catalog.versionOf(h.name, h.kind) ?? ""}</span>
      <span class="kind">
        <Pill tone={h.kind === "formula" ? "formula" : "cask"}>
          {h.kind === "formula" ? t("package.kind.formula", ui.locale) : t("package.kind.cask", ui.locale)}
        </Pill>
        {#if deprecationBadgeOf(h.name, h.kind)}
          {@const b = deprecationBadgeOf(h.name, h.kind)!}
          <span title={b.title}><Pill tone={b.tone}>{b.label}</Pill></span>
        {/if}
      </span>
      <span class="installed">
        {#if installed}<Pill tone="success">{t("package.installed", ui.locale)}</Pill>{/if}
      </span>
    </button>
  </li>
{/snippet}

<section class="discover">
  <!-- Pane title moved to the window title bar (+page.svelte).
       Discover has no secondary header actions, so the panel-head
       is dropped entirely. -->

  <!-- Phase 12a: stale-catalog banner. Sits above the search bar so it
       reads as a section-level nudge, not a search affordance. Session-
       dismissable; reappears on next launch if still stale. -->
  {#if catalog.summary && catalog.isStale && !bannerDismissed}
    <div class="stale-banner" role="status">
      <span class="stale-icon"><AlertTriangle size={16} /></span>
      <span class="stale-text">
        {catalogStaleText(catalog.summary.daysOld)}
      </span>
      <button
        type="button"
        class="stale-refresh"
        onclick={refreshFromBanner}
        disabled={catalog.refreshing}
      >
        {#if catalog.refreshing}
          <Loader size={12} class="spin-slow" />
          <span>{t("Refreshing…", ui.locale)}</span>
        {:else}
          <RefreshCw size={12} />
          <span>{t("Refresh from brew.sh →", ui.locale)}</span>
        {/if}
      </button>
      <button
        type="button"
        class="stale-dismiss"
        onclick={() => (bannerDismissed = true)}
        aria-label={t("discover.staleDismissAria", ui.locale)}
        title={t("Dismiss for this session", ui.locale)}
      >
        <XIcon size={14} />
      </button>
    </div>
  {/if}

  <div class="search-bar">
    <Input
      bind:value={search.query}
      variant="search"
      placeholder={t("discover.searchPlaceholder", ui.locale)}
      ariaLabel={t("discover.searchAria", ui.locale)}
      onInput={(v) => search.setQuery(v)}
      onKeydown={handleKey}
    />
    {#if search.recent.length > 0 && !search.results && !search.query && !discover.hasFilter}
      <div class="recent">
        <span class="uppercase-label">{t("Recent", ui.locale)}</span>
        <ul>
          {#each search.recent as r (r)}
            <li><button onclick={() => search.run(r)}>{r}</button></li>
          {/each}
        </ul>
      </div>
    {/if}

    <!-- Phase 13: chip bar hidden when the AI Features toggle is off
         (categories are LLM-generated). Search results below still
         render normally because they don't depend on categories. -->
    {#if categories.visible && discover.hasFilter}
      <div class="chip-bar" aria-label={t("discover.activeFilters", ui.locale)}>
        {#each [...discover.selectedCategories] as slug (slug)}
          {@const Icon = resolveCategoryIcon(
            categories.data?.categories[slug]?.icon ?? "HelpCircle",
          )}
          <button
            class="chip on"
            onclick={() => discover.toggle(slug)}
            aria-label={t("discover.removeFilter", ui.locale, { category: categories.labelOf(slug, ui.locale) })}
          >
            <Icon size={12} />
            <span>{categories.labelOf(slug, ui.locale)}</span>
            <XIcon size={12} />
          </button>
        {/each}
        <button class="chip-clear" onclick={() => discover.clear()}>{t("Clear", ui.locale)}</button>
      </div>
    {/if}
  </div>

  <div class="results">
    {#if search.loading}
      <LoadingState rows={6} label={t("Searching…", ui.locale)} />
    {:else if search.error}
      <EmptyState title={t("discover.searchFailed", ui.locale)} body={search.error}>
        {#snippet icon()}<SearchIcon size={48} />{/snippet}
      </EmptyState>
    {:else if search.results && allHits.length === 0}
      <EmptyState
        title={discover.hasFilter
          ? t("discover.noResultsInCategories", ui.locale, { query: search.results.query })
          : t("discover.noResults", ui.locale, { query: search.results.query })}
        body={discover.hasFilter
          ? t("discover.noResultsInCategories.body", ui.locale)
          : t("discover.noResults.body", ui.locale)}
      >
        {#snippet icon()}<SearchIcon size={48} />{/snippet}
      </EmptyState>
    {:else if search.results}
      <!-- Search-results mode wins over category browsing -->
      <ul class="list" aria-label={t("Search results", ui.locale)}>
        {#each allHits as h (h.name + h.kind)}
          {@const installed = h.installed || packages.isInstalled(h.name, h.kind)}
          {@const isSelected = ui.selectedPackage?.name === h.name && ui.selectedPackage?.kind === h.kind}
          <li>
            <button
              class="row row--with-desc"
              class:selected={isSelected}
              aria-current={isSelected ? "true" : undefined}
              onclick={() => openHit(h)}
            >
              <span class="name-cell">
                <PackageRowIcon token={h.name} kind={h.kind} resolveCask />
                <span class="name truncate">
                  <span class="name-text">{h.name}</span>
                  {#if friendlyOf(h.name)}
                    <span class="friendly-subtitle">{friendlyOf(h.name)}</span>
                  {/if}
                </span>
              </span>
              <span class="desc truncate text-muted">{enrichment.summaryOf(h.name) ?? h.description ?? ""}</span>
              <span class="version truncate text-muted">{catalog.versionOf(h.name, h.kind) ?? ""}</span>
              <span class="kind">
                <Pill tone={h.kind === "formula" ? "formula" : "cask"}>
                  {h.kind === "formula" ? t("package.kind.formula", ui.locale) : t("package.kind.cask", ui.locale)}
                </Pill>
                {#if deprecationBadgeOf(h.name, h.kind)}
                  {@const b = deprecationBadgeOf(h.name, h.kind)!}
                  <span title={b.title}><Pill tone={b.tone}>{b.label}</Pill></span>
                {/if}
              </span>
              <span class="installed">
                {#if installed}<Pill tone="success">{t("package.installed", ui.locale)}</Pill>{/if}
              </span>
            </button>
          </li>
        {/each}
      </ul>
    {:else if categories.visible && discover.hasFilter}
      <!-- Chip-filtered browse mode. Phase 13: hidden when AI toggle off
           (no categories means no chip filter UI). -->
      <div class="cat-header">
        <h2>{browseTitle}</h2>
        <span class="text-muted">{ui.locale === "ru" ? `${fmt(browseItems.length)} ${ruPlural(browseItems.length, "пакет", "пакета", "пакетов")}` : `${fmt(browseItems.length)} packages`}</span>
        {#if showSubgroups}
          <span class="subgroup-note text-muted">{t("discover.subgroupNote", ui.locale)}</span>
          <InfoButton
            title={t("discover.subgroupsTitle", ui.locale)}
            label={t("discover.subgroupsLabel", ui.locale)}
            body={t("discover.subgroupsBody", ui.locale, { category: browseTitle })}
          />
        {/if}
      </div>
      {#if browseItems.length === 0}
        <EmptyState title={t("discover.emptyFilter", ui.locale)} body="">
          {#snippet icon()}<SearchIcon size={48} />{/snippet}
        </EmptyState>
      {:else if showSubgroups}
        <!-- Feature #6: sub-grouped view (single category selected). Section
             header per co-occurring category + a pinned-last "General" bucket.
             Counts match the cask-free browse list on Linux (store-gated). -->
        {#each subgroups as g (g.key)}
          <div class="subgroup-head">
            <h3>{g.label}</h3>
            <span class="text-muted">{fmt(g.items.length)}</span>
          </div>
          <ul class="list" aria-label={t("discover.groupPackagesLabel", ui.locale, { group: g.label })}>
            {#each g.items as h (h.name + h.kind)}
              {@render browseRow(h)}
            {/each}
          </ul>
        {/each}
      {:else}
        <ul class="list" aria-label={t("discover.packagesInCategory", ui.locale, { category: browseTitle })}>
          {#each browseItems as h (h.name + h.kind)}
            {@render browseRow(h)}
          {/each}
        </ul>
      {/if}
    {:else if categories.visible && categories.loading && categories.tiles.length === 0}
      <LoadingState rows={4} label={t("discover.loadingCategories", ui.locale)} />
    {:else if categories.visible && categories.error}
      <EmptyState title={t("Categories unavailable", ui.locale)} body={categories.error}>
        {#snippet icon()}<SearchIcon size={48} />{/snippet}
      </EmptyState>
    {:else if categories.visible}
      <!-- Default: category tile grid. Phase 13: hidden when AI toggle
           off. The empty state below covers the toggled-off case. -->
      <div class="cat-intro">
        <!-- Linux: the bundled categories.json includes cask tokens, but
             casks don't exist there — count formulae only. -->
        <p class="text-muted">
          {#if ui.locale === "ru"}
            Просматривайте {fmt(catalogItemCount)} {ruPlural(catalogItemCount, "пакет", "пакета", "пакетов")} по категориям или используйте поиск выше.
          {:else}
            Browse {fmt(catalogItemCount)} packages by category, or type a query above to search.
          {/if}
        </p>
      </div>
      <div class="tile-grid" role="grid" aria-label={t("Categories", ui.locale)}>
        {#each categories.tiles as tile (tile.slug)}
          {@const Icon = resolveCategoryIcon(tile.icon)}
          <button
            class="tile"
            role="gridcell"
            onclick={() => discover.selectOnly(tile.slug)}
            aria-label={ui.locale === "ru"
              ? `${categories.labelOf(tile.slug, ui.locale)} — ${fmt(tile.count)} ${ruPlural(tile.count, "пакет", "пакета", "пакетов")}`
              : t("discover.categoryTileAria", ui.locale, { category: tile.label, count: fmt(tile.count) })}
          >
            <span class="tile-icon"><Icon size={24} /></span>
            <span class="tile-label">{categories.labelOf(tile.slug, ui.locale)}</span>
            <span class="tile-count">{fmt(tile.count)}</span>
          </button>
        {/each}
      </div>
    {:else}
      <!-- Phase 13: AI features off — invite the user to search since
           the category tile grid is hidden. -->
      <EmptyState
        title={t("discover.searchPromptTitle", ui.locale)}
        body={t("discover.categoryBrowsingHidden", ui.locale)}
      >
        {#snippet icon()}<SearchIcon size={48} />{/snippet}
      </EmptyState>
    {/if}
  </div>
</section>

<style>
  .discover { display: flex; flex-direction: column; min-height: 0; height: 100%; }

  /* ── Phase 12a — stale-catalog banner ─────────────────── */
  .stale-banner {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-4);
    background: var(--color-warning-subtle, rgba(245, 158, 11, 0.1));
    border-bottom: 1px solid var(--color-warning, #f59e0b);
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
  }
  .stale-icon {
    display: inline-flex;
    color: var(--color-warning-strong, #b45309);
    flex-shrink: 0;
  }
  .stale-text {
    flex: 1;
    min-width: 0;
  }
  .stale-refresh {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px var(--space-2);
    height: 24px;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-warning-strong, #b45309);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.12s ease;
  }
  .stale-refresh:hover:not(:disabled) {
    background: var(--color-warning-subtle, rgba(245, 158, 11, 0.18));
    text-decoration: underline;
  }
  .stale-refresh:disabled {
    cursor: default;
    opacity: 0.7;
  }
  .stale-dismiss {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-muted);
    cursor: pointer;
    flex-shrink: 0;
  }
  .stale-dismiss:hover {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }
  .search-bar {
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }
  .search-bar :global(.wrap) { width: 100%; max-width: 480px; }

  .recent { display: flex; gap: var(--space-3); align-items: center; }
  .recent ul { display: flex; gap: var(--space-2); flex-wrap: wrap; }
  .recent button {
    padding: var(--space-1) var(--space-2);
    background: var(--color-surface-sunken);
    border-radius: var(--radius-sm);
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
  }
  .recent button:hover { color: var(--color-text-primary); }

  /* ── chip bar ─────────────────────────────────────────── */
  .chip-bar {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 2px var(--space-2);
    height: 22px;
    border-radius: var(--radius-full);
    border: 1px solid var(--color-border);
    background: var(--color-surface-sunken);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    line-height: 1;
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
  }
  .chip:hover { color: var(--color-text-primary); }
  .chip.on {
    background: var(--color-brand-subtle);
    border-color: var(--color-brand);
    color: var(--color-text-primary);
  }
  .chip-clear {
    padding: 2px var(--space-2);
    height: 22px;
    border-radius: var(--radius-sm);
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
    background: transparent;
  }
  .chip-clear:hover { color: var(--color-text-primary); }

  /* ── results ─────────────────────────────────────────── */
  .results { flex: 1; overflow-y: auto; min-height: 0; }
  .list { display: flex; flex-direction: column; }

  .row {
    align-items: center;
    gap: var(--space-3);
    width: 100%;
    padding: var(--space-2) var(--space-3);
    min-height: 36px;
    text-align: left;
    color: var(--color-text-primary);
    font-size: var(--text-body);
    border-bottom: 1px solid var(--color-border);
    display: grid;
  }
  /* Two row layouts: with-description (search) and no-description (chip-filtered
     browse). Two important details:
       1. Flexible columns use minmax(0, Nfr), not bare Nfr, because each row is
          its own grid container and bare `1fr` = `minmax(auto, 1fr)` lets long
          names expand the name column past its share.
       2. The installed column is a FIXED 90px, not `auto`. With auto, the cell
          collapses when no pill is present, and the leftover space rebalances
          across the fr columns — which shifts the kind cell horizontally between
          installed-vs-not rows. Fixed width keeps every row's kind cell at the
          same x-position. */
  /* Canonical 5-column Discover row: NAME | DESC | VERSION | TYPE | TRAIL.
     Same column order as Library (icon + … + version + type + outdated)
     for cross-pane consistency. Versions tend to be short (e.g. "1.25.0",
     "2026.01.07"), so 100px is comfortable. */
  .row--with-desc { grid-template-columns: minmax(0, 1fr) minmax(0, 2fr) 100px 80px 90px; }
  /* Icon + name stack share the first column; the icon sits left of the
     name/friendly-subtitle stack (matches native's iconNameCell). */
  .name-cell {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
    overflow: hidden;
  }
  .row:hover { background: var(--color-surface-sunken); }
  .row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .row.selected .desc,
  .row.selected .friendly-subtitle { color: var(--color-text-inverse); opacity: 0.85; }
  /* Switch to a vertical flex container so the optional friendly-name
     subtitle (Phase 13) stacks below the raw name. Both children are
     individually truncated; the parent's truncate utility class still
     applies to the wrapping span for legacy callers. */
  .name {
    font-weight: var(--fw-medium);
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    min-width: 0;
    white-space: normal; /* override .truncate's nowrap; children manage their own */
  }
  .name-text {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 100%;
  }
  .friendly-subtitle {
    display: block;
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    font-weight: var(--fw-regular, 400);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 100%;
    line-height: 1.2;
    margin-top: 1px;
  }
  .desc { font-size: var(--text-body-sm); }
  .version {
    font-size: var(--text-body-sm);
    font-variant-numeric: tabular-nums;
    color: var(--color-text-secondary);
  }
  /* Kind cell hosts the type pill plus the optional deprecation/disabled
     badge (Feature #2). Flex-wrap so a second pill drops below the kind
     pill on the narrow 80px track rather than overflowing the cell. */
  .kind {
    display: inline-flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 4px;
    overflow: visible;
  }
  .installed { justify-self: end; min-width: 0; }

  /* ── Phase 9: category tile grid ─────────────────────────── */
  .cat-intro {
    padding: var(--space-4) var(--space-4) 0 var(--space-4);
    font-size: var(--text-body-sm);
  }
  .tile-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: var(--space-3);
    padding: var(--space-4);
  }
  .tile {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-2);
    padding: var(--space-3);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    text-align: left;
    color: var(--color-text-primary);
    transition: background 0.12s ease, border-color 0.12s ease, transform 0.12s ease;
    cursor: pointer;
  }
  .tile:hover {
    background: var(--color-surface);
    border-color: var(--color-accent);
    transform: translateY(-1px);
  }
  .tile:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 2px;
  }
  .tile-icon { color: var(--color-accent); display: inline-flex; }
  .tile-label { font-weight: var(--fw-medium); font-size: var(--text-body); }
  .tile-count { font-size: var(--text-body-sm); color: var(--color-text-secondary); }

  .cat-header {
    display: flex;
    align-items: baseline;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    border-bottom: 1px solid var(--color-border);
  }
  .cat-header h2 {
    font-size: var(--text-h3, 1.05rem);
    font-weight: var(--fw-medium);
    margin: 0;
  }
  /* Feature #6 — the "grouped by overlapping category" caption + (i) sit at
     the end of the cat-header, after the package count. */
  .subgroup-note {
    font-size: var(--text-body-sm);
  }
  .cat-header :global(.trigger) {
    margin-left: -2px;
  }

  /* Feature #6 — sub-group section header. Lighter than the .cat-header so it
     reads as a sub-level divider, not a new pane title. Sticky so the active
     sub-group label stays visible while scrolling its members. */
  .subgroup-head {
    display: flex;
    align-items: baseline;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-4);
    background: var(--color-surface-sunken);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 1;
  }
  .subgroup-head h3 {
    font-size: var(--text-body);
    font-weight: var(--fw-semibold);
    margin: 0;
    color: var(--color-text-secondary);
  }
</style>
