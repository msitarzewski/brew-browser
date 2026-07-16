<script lang="ts">
  import { onMount } from "svelte";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import PackageIcon from "@lucide/svelte/icons/package";
  import XIcon from "@lucide/svelte/icons/x";

  import Input from "./Input.svelte";
  import Button from "./Button.svelte";
  import PackageRow from "./PackageRow.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import SortableHeader from "./SortableHeader.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { categories } from "$lib/stores/categories.svelte";
  import { discover } from "$lib/stores/discover.svelte";
  import { library, isManual, isDependencyOnly, type LibraryFilter } from "$lib/stores/library.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { t, ruPlural } from "$lib/i18n/messages";
  import { resolveCategoryIcon } from "$lib/util/categoryIcon";
  import { isLinux } from "$lib/util/platform";
  import type { Package } from "$lib/types";

  type SortKey = "name" | "version" | "kind" | "outdated";
  type SortDir = "asc" | "desc";

  let query = $state("");
  let sortKey: SortKey = $state("name");
  let sortDir: SortDir = $state("asc");

  // v0.5.0 — pill set is conditionally extended with "vulnerable" only
  // when the feature is enabled. Adding it unconditionally would show a
  // dead filter pill (always 0) to users who never opted in, which is
  // worse than not surfacing it at all.
  // Feature #3 — "manual"/"dependency" sit after "outdated". They key on
  // per-keg brew flags carried on `Package` and apply to formulae (which
  // exist on Linux), so they are NOT in the isLinux drop list below.
  // Linux: casks don't exist there, so the Casks pill (always 0) is dropped.
  let libraryFilters = $derived.by<LibraryFilter[]>(() => {
    const base: LibraryFilter[] = vulnerabilities.enabled
      ? ["all", "formulae", "casks", "outdated", "pinned", "manual", "dependency", "vulnerable"]
      : ["all", "formulae", "casks", "outdated", "pinned", "manual", "dependency"];
    return base.filter((f) => !(isLinux && f === "casks"));
  });

  // Library shares the Discover store's chip selection so jumping back-and-forth
  // between tabs keeps context. Categories load is idempotent.
  categories.ensureLoaded();

  let filtered = $derived.by<Package[]>(() => {
    let base: Package[];
    switch (library.filter) {
      case "formulae": base = packages.formulae; break;
      case "casks":    base = packages.casks; break;
      case "outdated": base = packages.outdated; break;
      // #90 — pinned packages (held back from brew upgrade); formulae + casks.
      case "pinned":   base = packages.all.filter((p) => p.pinned); break;
      // Feature #3 — Manual = installed_on_request; Dependency = installed
      // as a dependency and NOT on request (so a both-flags-true package
      // counts as Manual only, never Dependency). Predicates are shared
      // with the pill counts below via the library store.
      case "manual":     base = packages.all.filter(isManual); break;
      case "dependency": base = packages.all.filter(isDependencyOnly); break;
      case "vulnerable":
        // v0.5.0 — packages with at least one known CVE. The pill is
        // gated to only render when vuln scanning is enabled, but the
        // filter itself stays defensive: if the user lands here with
        // the feature off (e.g. via a stale dashboard link), base will
        // be empty and the EmptyState kicks in cleanly.
        base = vulnerabilities.enabled
          ? packages.all.filter((p) => {
              const rec = vulnerabilities.byPackage(p.kind, p.name);
              return rec !== undefined && rec.vulns.length > 0;
            })
          : [];
        break;
      default:         base = packages.all;
    }
    const q = query.trim().toLowerCase();
    let result = q
      ? base.filter((p) =>
          p.name.toLowerCase().includes(q) ||
          (p.description?.toLowerCase().includes(q) ?? false),
        )
      : base;

    // Phase 13: only apply the category filter when AI features are on.
    // Toggling AI off silently disregards the chip selection (the chip
    // bar is also hidden) so the user sees their full library again.
    if (categories.visible && discover.hasFilter) {
      result = result.filter((p) => {
        const cats = categories.categoriesOf(p.name, p.kind);
        for (const c of cats) {
          if (discover.selectedCategories.has(c)) return true;
        }
        return false;
      });
    }
    return result;
  });

  let sorted = $derived.by<Package[]>(() => {
    const arr = [...filtered];
    const mul = sortDir === "asc" ? 1 : -1;
    arr.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case "name":
          cmp = a.name.localeCompare(b.name);
          break;
        case "version":
          cmp = (a.installedVersion ?? "").localeCompare(b.installedVersion ?? "");
          break;
        case "kind":
          cmp = a.kind.localeCompare(b.kind);
          break;
        case "outdated":
          // outdated rows surface first when ascending; tiebreak by name.
          cmp = Number(b.outdated) - Number(a.outdated);
          if (cmp === 0) cmp = a.name.localeCompare(b.name);
          break;
      }
      return cmp * mul;
    });
    return arr;
  });

  // Bottom status bar text. Leads with the count of the ACTIVE filter (the
  // rows currently shown, so it reflects the search box too), labelled by the
  // filter; then the standing outdated + pinned stats — skipping whichever the
  // lead already names so we don't print "7 outdated · 7 outdated". #90.
  let countBar = $derived.by(() => {
    const shown = sorted.length;
    const f = library.filter;
    const pinned = packages.all.filter((p) => p.pinned).length;
    const parts = [formatCountBarPart(f, shown)];
    if (f !== "outdated") parts.push(formatCountBarPart("outdated", packages.outdated.length));
    if (f !== "pinned") parts.push(formatCountBarPart("pinned", pinned));
    return parts.join(" · ");
  });

  function formatCountBarPart(filter: LibraryFilter, count: number): string {
    if (ui.locale === "ru") {
      switch (filter) {
        case "all":        return `${count} ${ruPlural(count, "пакет", "пакета", "пакетов")}`;
        case "formulae":   return `${count} ${ruPlural(count, "формула", "формулы", "формул")}`;
        case "casks":      return `${count} ${ruPlural(count, "cask-пакет", "cask-пакета", "cask-пакетов")}`;
        case "outdated":   return `${count} ${ruPlural(count, "с обновлением", "с обновлениями", "с обновлениями")}`;
        case "pinned":     return `${count} ${ruPlural(count, "закреплён", "закреплены", "закреплены")}`;
        case "manual":     return `${count} ${ruPlural(count, "установлен вручную", "установлены вручную", "установлены вручную")}`;
        case "dependency": return `${count} ${ruPlural(count, "зависимость", "зависимости", "зависимостей")}`;
        case "vulnerable": return `${count} ${ruPlural(count, "уязвимый", "уязвимых", "уязвимых")}`;
      }
    }
    switch (filter) {
      case "all":        return `${count} package${count === 1 ? "" : "s"}`;
      case "formulae":   return `${count} ${count === 1 ? "formula" : "formulae"}`;
      case "casks":      return `${count} cask${count === 1 ? "" : "s"}`;
      case "outdated":   return `${count} outdated`;
      case "pinned":     return `${count} pinned`;
      case "manual":     return `${count} manual`;
      case "dependency": return `${count} ${count === 1 ? "dependency" : "dependencies"}`;
      case "vulnerable": return `${count} vulnerable`;
    }
  }

  function changeSort(key: string) {
    const k = key as SortKey;
    if (sortKey === k) {
      sortDir = sortDir === "asc" ? "desc" : "asc";
    } else {
      sortKey = k;
      sortDir = "asc";
    }
  }

  onMount(() => {
    packages.load();
    // Description column reads AI summaries from the enrichment bundle
    // when present. Prime here so direct-to-Library cold opens light
    // them up without a navigation detour.
    enrichment.ensureLoaded();
  });

  function openDetail(p: Package) {
    ui.selectPackage(p.name, p.kind);
  }

  async function refreshLibrary() {
    await packages.load(true);
    vulnerabilities.scanIfNeeded().catch(() => {});
  }

  function filterLabel(filter: LibraryFilter): string {
    if (filter === "all") return t("All", ui.locale);
    if (filter === "formulae") return t("Formulae", ui.locale);
    if (filter === "casks") return t("Casks", ui.locale);
    if (filter === "outdated") return t("Outdated", ui.locale);
    if (filter === "manual") return t("Manual", ui.locale);
    if (filter === "dependency") return t("Dependency", ui.locale);
    if (filter === "vulnerable") return t("Vulnerable", ui.locale);
    return filter;
  }
</script>

<section class="library">
  <!-- Pane title ("Library") moved to the window title bar; the head
       keeps the install count + filter input + Refresh button. -->
  <header class="panel-head" data-tauri-drag-region>
    <div class="head-left">
      <!-- Install count relocated to the bottom status bar (`count-bar`),
           alongside the outdated + pinned tallies (#90). -->
    </div>
    <div class="head-right" data-tauri-drag-region="false">
      <Input bind:value={query} placeholder={ui.locale === "ru" ? "Фильтр…" : "Filter…"} variant="search" size="sm" ariaLabel={ui.locale === "ru" ? "Фильтр установленных пакетов" : "Filter installed packages"} />
      <span class="refresh-wrap">
        <Button size="sm" variant="ghost" onclick={refreshLibrary} ariaLabel={t("Refresh", ui.locale)} title={ui.locale === "ru" ? "Обновить (⌘R)" : "Refresh (⌘R)"}>
          {#snippet icon()}<RefreshCw size={14} />{/snippet}
          {t("Refresh", ui.locale)}
        </Button>
      </span>
    </div>
  </header>

  <div class="filter-bar">
    <div class="pillgroup" role="tablist" aria-label={ui.locale === "ru" ? "Фильтр по типу" : "Type filter"}>
      {#each libraryFilters as f (f)}
        <!-- Counts moved to the bottom status bar (`count-bar`) — the tabs
             stay clean labels. -->
        <button
          role="tab"
          aria-selected={library.filter === f}
          class:on={library.filter === f}
          onclick={() => library.setFilter(f)}
        >
          {filterLabel(f)}
        </button>
      {/each}
    </div>

    <!-- Phase 13: chip bar hidden when the AI Features toggle is off
         (categories are LLM-generated). -->
    {#if categories.visible && discover.hasFilter}
      <div class="chip-bar" aria-label={ui.locale === "ru" ? "Активные фильтры категорий" : "Active category filters"}>
        {#each [...discover.selectedCategories] as slug (slug)}
          {@const Icon = resolveCategoryIcon(
            categories.data?.categories[slug]?.icon ?? "HelpCircle",
          )}
          <button
            class="chip on"
            onclick={() => discover.toggle(slug)}
            aria-label={ui.locale === "ru" ? `Убрать фильтр «${categories.labelOf(slug, ui.locale)}»` : `Remove ${categories.labelOf(slug, ui.locale)} filter`}
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

  <div class="list-wrap">
    {#if packages.loading && !packages.list}
      <LoadingState rows={8} label={ui.locale === "ru" ? "Загружаем установленные пакеты…" : "Loading installed packages…"} />
    {:else if packages.error}
      <EmptyState
        title={t("Couldn't load packages", ui.locale)}
        body={packages.error}
      >
        {#snippet icon()}<PackageIcon size={48} />{/snippet}
        {#snippet cta()}
          <Button variant="secondary" onclick={() => packages.load(true)}>{t("Retry", ui.locale)}</Button>
        {/snippet}
      </EmptyState>
    {:else if sorted.length === 0}
      <!-- Phase 13: chip-filter messaging only matters when the AI toggle
           is on (otherwise the chip bar isn't visible and the filter
           isn't applied). Treat AI-off as "no chip filter active". -->
      {@const chipFilterActive = categories.visible && discover.hasFilter}
      <EmptyState
        title={query
          ? (ui.locale === "ru" ? `По запросу «${query}» ничего не найдено` : `Nothing matches "${query}"`)
          : chipFilterActive
            ? (ui.locale === "ru" ? "В выбранных категориях нет установленных пакетов." : "No installed packages in the selected categories.")
            : (ui.locale === "ru" ? "Пакеты не установлены." : "No packages installed.")}
        body={query
          ? (ui.locale === "ru" ? "Попробуйте более короткий или другой запрос." : "Try a shorter or different term.")
          : chipFilterActive
            ? (ui.locale === "ru" ? "Уберите категорию или откройте Каталог, чтобы найти другие пакеты." : "Remove a chip or open Discover to find more.")
            : (ui.locale === "ru" ? "`brew install wget` — хороший старт. Или откройте Каталог и посмотрите варианты." : "`brew install wget` would be a fine start. Or open Discover to look around.")}
      >
        {#snippet icon()}<PackageIcon size={48} />{/snippet}
        {#snippet cta()}
          {#if query}
            <Button variant="secondary" onclick={() => (query = "")}>{t("Clear filter", ui.locale)}</Button>
          {:else if chipFilterActive}
            <Button variant="secondary" onclick={() => discover.clear()}>{t("Clear categories", ui.locale)}</Button>
          {:else}
            <Button variant="primary" onclick={() => ui.setSection("discover")}>{t("Open Discover", ui.locale)}</Button>
          {/if}
        {/snippet}
      </EmptyState>
    {:else}
      <!-- Linux: every installed package is a formula, so the Type column
           is pure noise — the sortable header gives way to an empty
           placeholder cell (the rows keep a slim 5th cell for the vuln
           severity dot, see PackageRow's `no-kind` variant). -->
      <div class="list-header" class:no-kind={isLinux} role="row">
        <span></span>
        <SortableHeader label={t("Name", ui.locale)} sortKey="name" active={sortKey === "name"} dir={sortDir} onSort={changeSort} />
        <span class="header-desc">{t("Description", ui.locale)}</span>
        <SortableHeader label={t("Version", ui.locale)} sortKey="version" active={sortKey === "version"} dir={sortDir} onSort={changeSort} />
        {#if !isLinux}
          <SortableHeader label={t("Type", ui.locale)} sortKey="kind" active={sortKey === "kind"} dir={sortDir} onSort={changeSort} />
        {:else}
          <span></span>
        {/if}
        <SortableHeader label={t("Outdated", ui.locale)} sortKey="outdated" active={sortKey === "outdated"} dir={sortDir} onSort={changeSort} />
      </div>
      <div class="list" role="list" aria-label={ui.locale === "ru" ? "Установленные пакеты" : "Installed packages"}>
        {#each sorted as p (p.fullName + p.kind)}
          <PackageRow
            pkg={p}
            selected={ui.selectedPackage?.name === p.name && ui.selectedPackage?.kind === p.kind}
            onSelect={openDetail}
          />
        {/each}
      </div>
    {/if}
  </div>

  <!-- Bottom status tally — mirrors the Services header style, at the foot of
       the Library. Replaces the per-tab counts + the old header "N installed".
       Leads with the active filter's count (see `countBar`). #90. -->
  <footer class="count-bar text-muted">{countBar}</footer>
</section>

<style>
  .library {
    display: flex; flex-direction: column;
    min-height: 0;
    height: 100%;
  }
  .panel-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    gap: var(--space-3);
  }
  .head-left { display: flex; align-items: baseline; gap: var(--space-3); }
  .head-right { display: flex; align-items: center; gap: var(--space-2); }

  /* Narrow-window responsive: drop the Refresh button when the head-right
     cluster starts to crowd the panel (typically when the detail panel is
     open + the window is narrow). The Filter input is the primary control
     here so it stays; Refresh remains available via Cmd+R. */
  @media (max-width: 1000px) {
    .refresh-wrap { display: none; }
  }
  .count-bar {
    flex-shrink: 0;
    padding: var(--space-2) var(--space-4);
    border-top: 1px solid var(--color-border);
    font-size: var(--text-body-sm);
  }

  .filter-bar {
    padding: var(--space-2) var(--space-4);
    border-bottom: 1px solid var(--color-border);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  /* Sidebar theme-group pattern: sunken background, no border,
     raised + shadow active state. */
  .pillgroup {
    display: inline-flex;
    background: var(--color-surface-sunken);
    border-radius: var(--radius-md);
    padding: 2px;
    gap: 2px;
    width: max-content;
  }
  .pillgroup button {
    padding: var(--space-1) var(--space-3);
    border-radius: var(--radius-sm);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
  }
  .pillgroup button.on {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    box-shadow: var(--shadow-xs);
  }
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

  .list-wrap {
    flex: 1;
    overflow-y: auto;
    min-height: 0;
  }
  .list-header {
    display: grid;
    /* 6 cells matching PackageRow:
       icon / NAME (1fr) / DESCRIPTION (2fr) / VERSION (120px) /
       TYPE (80px) / OUTDATED (120px). */
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 80px 120px;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 1;
    overflow: hidden;
  }
  .list-header > * { min-width: 0; overflow: hidden; }
  .header-desc {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  /* Match PackageRow's responsive column-drops so the header stays
     aligned with the rows when the panel narrows. */
  @media (max-width: 1100px) {
    .list-header {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 80px;
    }
    .list-header > :nth-child(6) { display: none; }
  }
  @media (max-width: 900px) {
    .list-header {
      grid-template-columns: 24px minmax(0, 1fr) 120px 80px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(6) { display: none; }
  }
  @media (max-width: 720px) {
    .list-header {
      grid-template-columns: 24px minmax(0, 1fr) 80px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(4),
    .list-header > :nth-child(6) { display: none; }
  }

  /* Linux (`no-kind`): mirrors PackageRow's `no-kind` templates — the
     TYPE track shrinks from 80px to the 12px vuln-dot slot. The header
     keeps an empty placeholder in the 5th cell, so the macOS nth-child
     hide rules above apply unchanged at every breakpoint. */
  .list-header.no-kind {
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 12px 120px;
  }
  @media (max-width: 1100px) {
    .list-header.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 12px;
    }
  }
  @media (max-width: 900px) {
    .list-header.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) 120px 12px;
    }
  }
  @media (max-width: 720px) {
    .list-header.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) 12px;
    }
  }
  .list { display: flex; flex-direction: column; }
</style>
