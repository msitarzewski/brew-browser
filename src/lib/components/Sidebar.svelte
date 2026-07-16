<script lang="ts">
  import Boxes from "@lucide/svelte/icons/boxes";
  import Compass from "@lucide/svelte/icons/compass";
  import TrendingUp from "@lucide/svelte/icons/trending-up";
  import Archive from "@lucide/svelte/icons/archive";
  import Activity from "@lucide/svelte/icons/activity";
  import Server from "@lucide/svelte/icons/server";
  import PackagePlus from "@lucide/svelte/icons/package-plus";
  import LayoutDashboard from "@lucide/svelte/icons/layout-dashboard";
  import SearchIcon from "@lucide/svelte/icons/search";
  import XIcon from "@lucide/svelte/icons/x";

  import { ui } from "$lib/stores/ui.svelte";
  import { library } from "$lib/stores/library.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { brewfiles } from "$lib/stores/brewfiles.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { env } from "$lib/stores/env.svelte";
  import { search } from "$lib/stores/search.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import {
    formatBrewOperationsRunning,
    formatVulnerablePackageLabel,
    formatVulnerablePackages,
    t,
    type MessageKey,
  } from "$lib/i18n/messages";
  import { normalizeServiceStatus, type PackageKind, type SearchHit } from "$lib/types";
  import Pill from "./Pill.svelte";
  import type { SidebarSection } from "$lib/types";

  interface NavItem {
    id: SidebarSection;
    labelKey: MessageKey;
    shortcut: string;
    icon: typeof Boxes;
  }

  /** Dashboard is now a regular nav item (formerly the brand). Listed first
      so ⌘0 maps to it and it gets the visual primacy without a dedicated
      brand row eating sidebar space. */
  const nav: NavItem[] = [
    { id: "dashboard", labelKey: "nav.dashboard", shortcut: "⌘0", icon: LayoutDashboard },
    { id: "library",   labelKey: "nav.library",   shortcut: "⌘1", icon: Boxes },
    { id: "discover",  labelKey: "nav.discover",  shortcut: "⌘2", icon: Compass },
    { id: "trending",  labelKey: "nav.trending",  shortcut: "⌘3", icon: TrendingUp },
    { id: "snapshots", labelKey: "nav.snapshots", shortcut: "⌘4", icon: Archive },
    { id: "services",  labelKey: "nav.services",  shortcut: "⌘5", icon: Server },
    { id: "activity",  labelKey: "nav.activity",  shortcut: "⌘6", icon: Activity },
    { id: "bundles",   labelKey: "nav.bundles",   shortcut: "⌘7", icon: PackagePlus },
  ];

  // ───────── Sidebar type-ahead search ─────────
  // A persistent quick lookup that hits the same `brew search` index the
  // Discover pane uses, but renders the top hits inline as the user types.
  // Click → open detail panel. Enter → route to Discover with the query.
  // Esc → clear.
  let searchInput: HTMLInputElement | undefined = $state();
  let searchFocused = $state(false);
  let selectedIdx = $state(0);

  /** Flatten formulae + casks, cap to a manageable number for the dropdown.
      Sidebar real estate is tight; >7 results crowd the nav. */
  const topHits = $derived.by<SearchHit[]>(() => {
    const r = search.results;
    if (!r) return [];
    return [...r.formulae, ...r.casks].slice(0, 7);
  });

  /** Show the dropdown when the input has 2+ chars AND is focused (or
      results are loading) AND we're not in collapsed mode (no room). */
  const dropdownOpen = $derived(
    !ui.sidebarCollapsed &&
      searchFocused &&
      search.query.length >= 2 &&
      (search.loading || !!search.results || !!search.error),
  );

  function onSearchInput(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).value;
    selectedIdx = 0;
    search.setQuery(v);
  }

  function clearSearch() {
    search.clear();
    selectedIdx = 0;
    searchInput?.focus();
  }

  function openHit(h: { name: string; kind: PackageKind }) {
    ui.selectPackage(h.name, h.kind);
  }

  function onSearchKey(e: KeyboardEvent) {
    if (e.key === "Escape") {
      if (search.query) {
        e.preventDefault();
        clearSearch();
      } else {
        searchInput?.blur();
      }
      return;
    }
    if (!dropdownOpen) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      selectedIdx = Math.min(topHits.length - 1, selectedIdx + 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      selectedIdx = Math.max(0, selectedIdx - 1);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const hit = topHits[selectedIdx];
      if (hit) {
        openHit(hit);
      } else if (search.query) {
        // No selection — route to Discover with this query so the user
        // gets the full result list.
        ui.setSection("discover");
        search.run(search.query);
      }
    }
  }

  function badge(id: SidebarSection): string | null {
    if (id === "library") {
      // Nag badge counts only *upgradable* updates — pinned packages are
      // intentionally held back (#90), so they don't contribute to the count.
      const o = packages.outdatedUpgradable.length;
      return o > 0 ? String(o) : null;
    }
    if (id === "snapshots") {
      const n = brewfiles.list.length;
      return n > 0 ? String(n) : null;
    }
    if (id === "services") {
      const r = services.list.filter((s) => normalizeServiceStatus(s.status) === "started").length;
      return r > 0 ? String(r) : null;
    }
    if (id === "activity") {
      const r = activity.runningCount;
      return r > 0 ? String(r) : null;
    }
    return null;
  }

  /**
   * Status dot color follows the spec in uxArchitecture.md §2:
   *   green  = ready (brew installed + idle)
   *   amber  = a write op is running
   *   red    = brew missing / unhealthy / probe failed
   *   muted  = first probe still in flight (no report yet)
   */
  const statusKind = $derived.by<"ready" | "running" | "missing" | "unknown">(() => {
    if (env.report === null) return "unknown";
    if (!env.installed) return "missing";
    if (activity.runningCount > 0) return "running";
    return "ready";
  });

  const statusTooltip = $derived.by(() => {
    const base = env.summary;
    if (activity.runningCount > 0) {
      const n = activity.runningCount;
      return `${base}\n${formatBrewOperationsRunning(n, ui.locale)}`;
    }
    return base;
  });

  function refreshEnv() {
    void env.refresh();
  }

  // ───────── Vulnerability badge (v0.5.0) ─────────
  // Surfaces a quiet pulse in the footer when the user has opted into
  // vulnerability scanning AND we've found at least one vulnerable
  // package. Color tone follows max-severity (any critical/high → red,
  // medium → amber, low → blue). Clicking jumps to the Dashboard —
  // Agent A's Exposure card is the "main view" for vuln remediation;
  // we deliberately don't add a dedicated nav item per spec.
  const vulnBadgeVisible = $derived(
    settings.effective.vulnerabilityScanningEnabled === true &&
      vulnerabilities.severityCounts.vulnerablePackages > 0,
  );
  const vulnBadgeTone = $derived.by<"danger" | "warning" | "info">(() => {
    const c = vulnerabilities.severityCounts;
    if (c.critical > 0 || c.high > 0) return "danger";
    if (c.medium > 0) return "warning";
    return "info";
  });
  const vulnBadgeCount = $derived(
    vulnerabilities.severityCounts.vulnerablePackages,
  );
  const vulnBadgeTooltip = $derived.by(() => {
    return formatVulnerablePackages(vulnBadgeCount, ui.locale);
  });

  function openVulnerableInLibrary() {
    // Jump to Library filtered to the vulnerable packages — parity with the
    // native footer (`AppModel.openVulnerableInLibrary`) and the Dashboard
    // Exposure card's "View vulnerable packages" link. setSection FIRST so any
    // chip clears don't stomp the filter pick. The footer only renders when
    // vulnerabilities are enabled, so the gated `vulnerable` pill is available.
    ui.setSection("library");
    library.setFilter("vulnerable");
  }
</script>

<aside class="sidebar" class:collapsed={ui.sidebarCollapsed} aria-label={t("nav.primary", ui.locale)}>
  <!--
    Persistent type-ahead search above the nav. NO divider below the
    search wrap — it visually flows straight into the nav list per
    the user's "no separator" direction. Hidden when the sidebar is
    collapsed (no room for an input in the icon-only rail).
  -->
  {#if !ui.sidebarCollapsed}
    <div class="search-wrap">
      <span class="search-icon" aria-hidden="true"><SearchIcon size={14} /></span>
      <input
        bind:this={searchInput}
        type="search"
        role="combobox"
        class="search-input"
        placeholder={t("search.packagesPlaceholder", ui.locale)}
        value={search.query}
        oninput={onSearchInput}
        onfocus={() => (searchFocused = true)}
        onblur={() => setTimeout(() => (searchFocused = false), 150)}
        onkeydown={onSearchKey}
        aria-label={t("search.packages", ui.locale)}
        aria-autocomplete="list"
        aria-expanded={dropdownOpen}
        aria-controls="sidebar-search-results"
        spellcheck="false"
        autocomplete="off"
      />
      {#if search.query}
        <button
          type="button"
          class="search-clear"
          onclick={clearSearch}
          aria-label={t("search.clearSearch", ui.locale)}
          title={t("search.clear", ui.locale)}
        >
          <XIcon size={12} />
        </button>
      {/if}

      {#if dropdownOpen}
        <div
          id="sidebar-search-results"
          class="search-dropdown"
          role="listbox"
          aria-label={t("search.results", ui.locale)}
        >
          {#if search.loading && topHits.length === 0}
            <div class="search-empty">{t("search.searching", ui.locale)}</div>
          {:else if search.error}
            <div class="search-empty search-error">{search.error}</div>
          {:else if topHits.length === 0}
            <div class="search-empty">{t("search.noMatches", ui.locale, { query: search.query })}</div>
          {:else}
            {#each topHits as hit, i (hit.kind + hit.name)}
              <button
                type="button"
                class="search-hit"
                class:selected={i === selectedIdx}
                role="option"
                aria-selected={i === selectedIdx}
                onmousedown={(e) => { e.preventDefault(); openHit(hit); }}
                onmouseenter={() => (selectedIdx = i)}
              >
                <span class="hit-name truncate">{hit.name}</span>
                <Pill tone={hit.kind === "formula" ? "formula" : "cask"}>{hit.kind}</Pill>
                {#if hit.installed}
                  <Pill tone="success">{t("installed", ui.locale)}</Pill>
                {/if}
              </button>
            {/each}
            <button
              type="button"
              class="search-all"
              onmousedown={(e) => {
                e.preventDefault();
                ui.setSection("discover");
                search.run(search.query);
              }}
            >
              {t("search.allResultsInDiscover", ui.locale)}
            </button>
          {/if}
        </div>
      {/if}
    </div>
  {/if}

  <nav>
    <ul>
      {#each nav as item (item.id)}
        {@const isActive = ui.section === item.id}
        {@const label = t(item.labelKey, ui.locale)}
        {@const b = badge(item.id)}
        <li>
          <button
            class="nav-item"
            class:active={isActive}
            aria-current={isActive ? "page" : undefined}
            onclick={() => ui.setSection(item.id)}
            title={`${label} (${item.shortcut})`}
          >
            <span class="ico" aria-hidden="true"><item.icon size={16} /></span>
            <span class="label">{label}</span>
            {#if b}<span class="badge">{b}</span>{/if}
          </button>
        </li>
      {/each}
    </ul>
  </nav>

  <footer class="foot">
    {#if vulnBadgeVisible}
      <button
        type="button"
        class="vuln-badge tone-{vulnBadgeTone}"
        title={vulnBadgeTooltip}
        aria-label={vulnBadgeTooltip}
        onclick={openVulnerableInLibrary}
      >
        <span class="vuln-dot" aria-hidden="true"></span>
        <span class="vuln-count">{vulnBadgeCount}</span>
        <span class="vuln-label">{formatVulnerablePackageLabel(vulnBadgeCount, ui.locale)}</span>
      </button>
    {/if}
    <button
      type="button"
      class="status"
      class:status-ready={statusKind === "ready"}
      class:status-running={statusKind === "running"}
      class:status-missing={statusKind === "missing"}
      class:status-unknown={statusKind === "unknown"}
      title={statusTooltip}
      aria-label={statusTooltip}
      onclick={refreshEnv}
    >
      <span class="dot" aria-hidden="true"></span>
      <span class="status-label">{env.shortLabel}</span>
    </button>
  </footer>
</aside>

<style>
  .sidebar {
    width: 200px;
    flex: none;
    background: var(--color-surface-raised);
    border-right: 1px solid var(--color-border);
    display: flex;
    flex-direction: column;
    min-height: 0;
    transition: width var(--motion-duration-base, 180ms) var(--motion-ease-out, ease);
  }
  /* Honor prefers-reduced-motion: don't animate the width change. */
  @media (prefers-reduced-motion: reduce) {
    .sidebar { transition: none; }
  }
  /* ── Type-ahead search ── No border-bottom: the search flows
     straight into the nav list per the user's "no separator" spec. */
  .search-wrap {
    position: relative;
    padding: var(--space-2);
  }
  .search-icon {
    position: absolute;
    left: calc(var(--space-2) + 8px);
    top: 50%;
    transform: translateY(-50%);
    color: var(--color-text-muted);
    pointer-events: none;
    display: inline-flex;
  }
  /* Background uses the panel-body gray (--color-surface) — sitting on
     the sidebar's raised chrome, this reads as a subtle input field
     without competing visually with the SELECTED nav item, which uses
     the darker --color-surface-sunken. Border crisps up on focus. */
  .search-input {
    width: 100%;
    padding: 6px 26px 6px 30px;
    background: var(--color-surface);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
    line-height: 1.2;
    border: 1px solid var(--color-border);
    transition: border-color var(--motion-duration-fast) var(--motion-ease-out),
                background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .search-input::placeholder { color: var(--color-text-muted); }
  .search-input:focus {
    outline: none;
    background: var(--color-surface);
    border-color: var(--color-focus, var(--color-brand));
  }
  /* Strip the WebKit search-input UA chrome (rounded silver pill + X). */
  .search-input::-webkit-search-cancel-button,
  .search-input::-webkit-search-decoration { -webkit-appearance: none; appearance: none; }

  .search-clear {
    position: absolute;
    right: calc(var(--space-2) + 6px);
    top: 50%;
    transform: translateY(-50%);
    width: 18px;
    height: 18px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    color: var(--color-text-muted);
    border-radius: var(--radius-full);
    cursor: pointer;
  }
  .search-clear:hover { color: var(--color-text-primary); background: var(--color-surface-raised); }

  /* Results dropdown — anchored under the input. Widens past the
     sidebar's 200 px so longer package names don't ellipsize. */
  .search-dropdown {
    position: absolute;
    top: calc(100% - 2px);
    left: var(--space-2);
    right: var(--space-2);
    min-width: 260px;
    max-height: 280px;
    overflow-y: auto;
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    box-shadow: 0 8px 24px -4px color-mix(in oklch, black 30%, transparent);
    z-index: 30;
    padding: 4px;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .search-hit {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
    text-align: left;
    cursor: pointer;
  }
  .search-hit:hover,
  .search-hit.selected {
    background: var(--color-surface-sunken);
  }
  .hit-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: var(--fw-medium);
  }
  .search-empty {
    padding: 12px;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
    text-align: center;
  }
  .search-error { color: var(--color-danger); }
  .search-all {
    margin-top: 2px;
    padding: 6px 8px;
    background: transparent;
    color: var(--color-text-link, var(--color-brand));
    font-size: var(--text-caption);
    border-radius: var(--radius-sm);
    text-align: left;
    cursor: pointer;
  }
  .search-all:hover { background: var(--color-surface-sunken); }

  nav { flex: 1; padding: var(--space-2); overflow-y: auto; }
  ul { display: flex; flex-direction: column; gap: 1px; }

  .nav-item {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    width: 100%;
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-md);
    color: var(--color-text-secondary);
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    line-height: 1;
    text-align: left;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .nav-item:hover { background: var(--color-surface-sunken); color: var(--color-text-primary); }
  .nav-item.active {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
    font-weight: var(--fw-semibold);
  }
  .nav-item .label { flex: 1; }
  .ico { display: inline-flex; }
  .badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 16px;
    min-width: 16px;
    padding: 0 var(--space-1);
    border-radius: var(--radius-full);
    background: var(--color-brand);
    color: var(--color-text-inverse);
    font-size: var(--text-caption);
    font-weight: var(--fw-semibold);
  }

  .foot {
    border-top: 1px solid var(--color-border);
    padding: var(--space-3);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .status {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    padding: 2px var(--space-1);
    margin: -2px calc(-1 * var(--space-1));
    border-radius: var(--radius-sm);
    background: transparent;
    cursor: pointer;
    text-align: left;
    white-space: nowrap;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .status:hover { background: var(--color-surface-sunken); }
  .dot {
    width: 8px; height: 8px; border-radius: var(--radius-full);
    background: var(--color-text-muted);
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .status-ready .dot   { background: var(--color-success); }
  .status-running .dot { background: var(--color-warning); }
  .status-missing .dot { background: var(--color-danger); }
  .status-unknown .dot { background: var(--color-text-muted); }

  /* ── Vulnerability badge (v0.5.0) ──
     Lives in the footer above the status row when scanning is on and
     we've found something. Tone-coloured pill: max severity wins.
     Same .foot gap as the status row — reads as a stack of two
     small status indicators. */
  .vuln-badge {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: 2px var(--space-2);
    margin: -2px calc(-1 * var(--space-1));
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
    line-height: 1;
    cursor: pointer;
    text-align: left;
    white-space: nowrap;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .vuln-badge:hover { background: var(--color-surface-sunken); }
  .vuln-dot {
    width: 8px; height: 8px; border-radius: var(--radius-full);
    background: var(--color-text-muted);
    flex: none;
  }
  .vuln-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 16px;
    min-width: 16px;
    padding: 0 var(--space-1);
    border-radius: var(--radius-full);
    font-size: var(--text-caption);
    font-weight: var(--fw-semibold);
    line-height: 1;
  }
  .vuln-label { color: var(--color-text-muted); }

  .vuln-badge.tone-danger  .vuln-dot   { background: var(--color-danger); }
  .vuln-badge.tone-danger  .vuln-count { background: var(--color-danger-subtle); color: var(--color-danger-on-subtle); }
  .vuln-badge.tone-warning .vuln-dot   { background: var(--color-warning); }
  .vuln-badge.tone-warning .vuln-count { background: var(--color-warning-subtle); color: var(--color-warning-on-subtle); }
  .vuln-badge.tone-info    .vuln-dot   { background: var(--color-info, var(--color-text-secondary)); }
  .vuln-badge.tone-info    .vuln-count { background: var(--color-info-subtle); color: var(--color-info-on-subtle); }

  /* ── Collapsed sidebar (icon-rail mode) ──
     Width drops from 200 → 56 px. Everything that depends on width
     collapses to icon-only and centres in the rail. Native `title`
     tooltips on every interactive element keep the labels reachable
     on hover — pragmatic for a sidebar with many items (the same
     pattern Finder uses for its collapsed sidebar). */
  .sidebar.collapsed { width: 56px; }

  /* Nav items: icon centred; label hidden. Badges shrink to a small
     overlay dot so the user still sees "there's something" without a
     stretched-out tooltip-only rail. */
  .sidebar.collapsed .nav-item {
    justify-content: center;
    padding-left: 0;
    padding-right: 0;
    position: relative;
  }
  .sidebar.collapsed .nav-item .label { display: none; }
  .sidebar.collapsed .nav-item .badge {
    position: absolute;
    top: 2px;
    right: 4px;
    min-width: 14px;
    height: 14px;
    padding: 0 4px;
    font-size: 9px;
    line-height: 1;
  }
  nav > ul { gap: 1px; }

  /* Footer in collapsed mode: centre the lone status row. */
  .sidebar.collapsed .foot {
    align-items: center;
    padding-left: var(--space-2);
    padding-right: var(--space-2);
  }

  /* Status row: keep the dot, drop the text. */
  .sidebar.collapsed .status {
    justify-content: center;
    margin: 0;
    padding: 4px;
  }
  .sidebar.collapsed .status-label { display: none; }

  /* Vuln badge in collapsed rail: keep the count pill (small numeric
     signal stays useful even in icon-only mode), drop the "vulnerable"
     word. The dot is redundant with the count pill's own color tone, so
     hide it too to keep the rail uncluttered. */
  .sidebar.collapsed .vuln-badge {
    justify-content: center;
    margin: 0;
    padding: 4px;
    gap: 0;
  }
  .sidebar.collapsed .vuln-dot,
  .sidebar.collapsed .vuln-label { display: none; }
</style>
