<script lang="ts">
  import { onMount } from "svelte";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import TrendingUp from "@lucide/svelte/icons/trending-up";
  import Flame from "@lucide/svelte/icons/flame";
  import Snowflake from "@lucide/svelte/icons/snowflake";

  import Button from "./Button.svelte";
  import Pill from "./Pill.svelte";
  import PackageRowIcon from "./PackageRowIcon.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import SortableHeader from "./SortableHeader.svelte";
  import TrendingSparkline from "./TrendingSparkline.svelte";
  import { trending } from "$lib/stores/trending.svelte";
  import { trendingHistory } from "$lib/stores/trendingHistory.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { catalog } from "$lib/stores/catalog.svelte";
  import { t, ruPlural, type MessageKey } from "$lib/i18n/messages";
  import { isLinux } from "$lib/util/platform";
  import type { PackageKind, TrendingEntry, TrendingWindow } from "$lib/types";

  onMount(() => {
    if (!trending.report) trending.load();
    enrichment.ensureLoaded();
    void catalog.ensureSummariesLoaded();
    // v0.4.0 — when enhanced trending is on, fetch the summary blob
    // once. Provides inline sparkline + an authoritative velocity
    // index per row from one HTTP GET.
    void trendingHistory.ensureIndexLoaded();
  });

  function friendlyOf(token: string): string | null {
    return enrichment.friendlyName(token);
  }

  /** True only when the opt-in toggle is on AND Offline Mode is off
      AND we have an index in hand. Gates every inline sparkline + the
      "history-side" velocity override. */
  let enhancedReady = $derived(
    settings.effective.enhancedTrendingEnabled &&
      !settings.effective.paranoidMode &&
      trendingHistory.index !== null,
  );

  /** Resolve the effective velocity for an entry. Prefers the history
      endpoint's number (freshest, server-precomputed nightly) and falls
      back to the backend's per-fetch computation from rolling windows. */
  function velocityOf(name: string, kind: PackageKind, fallback?: number): number | null {
    const fromHistory = enhancedReady ? trendingHistory.velocityFor(name, kind) : null;
    if (fromHistory !== null) return fromHistory;
    return fallback ?? null;
  }

  /** Velocity tier classification for the badge, matching velocity_index's
      documented semantics (1.0 ≈ steady): >=1.5 surging, <=0.7 cooling,
      otherwise neutral. Canonical rule shared with the native build. */
  function velocityTier(v: number | null): "surge" | "cool" | "neutral" | "none" {
    if (v === null) return "none";
    if (v >= 1.5) return "surge";
    if (v <= 0.7) return "cool";
    return "neutral";
  }

  const windows: TrendingWindow[] = ["30d", "90d", "365d"];

  function windowLabel(window: TrendingWindow): string {
    return t(`trending.window.${window}` as MessageKey, ui.locale);
  }

  type SortKey = "rank" | "name" | "kind" | "installs" | "velocity";
  // v0.4.0 — default sort changes from rank to velocity desc. The
  // whole point is to surface what's actually accelerating, not what
  // dep-chains have already lifted to the top.
  let sortKey: SortKey = $state("velocity");
  let sortDir: "asc" | "desc" = $state("desc");

  function changeSort(key: string) {
    const k = key as SortKey;
    if (sortKey === k) {
      sortDir = sortDir === "asc" ? "desc" : "asc";
    } else {
      sortKey = k;
      // Numeric metrics default to descending on first click.
      sortDir = k === "installs" || k === "velocity" ? "desc" : "asc";
    }
  }

  let sortedEntries = $derived.by<TrendingEntry[]>(() => {
    if (!trending.report) return [];
    const arr = [...trending.report.entries];
    const mul = sortDir === "asc" ? 1 : -1;
    arr.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case "rank":     cmp = a.rank - b.rank; break;
        case "name":     cmp = a.name.localeCompare(b.name); break;
        case "kind":     cmp = a.kind.localeCompare(b.kind); break;
        case "installs": cmp = a.installCount - b.installCount; break;
        case "velocity": {
          // Push None-velocity entries to the bottom regardless of
          // direction so "no velocity available" never wins the leaderboard.
          const va = velocityOf(a.name, a.kind, a.velocityIndex);
          const vb = velocityOf(b.name, b.kind, b.velocityIndex);
          if (va === null && vb === null) cmp = 0;
          else if (va === null) cmp = sortDir === "asc" ? 1 : -1; // None last
          else if (vb === null) cmp = sortDir === "asc" ? -1 : 1; // None last
          else cmp = va - vb;
          // Tier-1 sort: never multiplied — keep None at bottom.
          return cmp === 0 ? 0 : cmp * mul;
        }
      }
      return cmp * mul;
    });
    return arr;
  });

  let agoLabel = $derived.by(() => {
    if (!trending.report) return "";
    const secs = trending.report.cacheAgeSeconds;
    if (ui.locale === "ru") {
      if (secs < 60) return `Обновлено ${secs} ${ruPlural(secs, "секунду", "секунды", "секунд")} назад`;
      const mins = Math.floor(secs / 60);
      if (mins < 60) return `Обновлено ${mins} ${ruPlural(mins, "минуту", "минуты", "минут")} назад`;
      const hrs = Math.floor(mins / 60);
      return `Обновлено ${hrs} ${ruPlural(hrs, "час", "часа", "часов")} назад`;
    }
    if (secs < 60) return `Updated ${secs}s ago`;
    const mins = Math.floor(secs / 60);
    if (mins < 60) return `Updated ${mins} min ago`;
    const hrs = Math.floor(mins / 60);
    return `Updated ${hrs}h ago`;
  });

  function openEntry(name: string, kind: "formula" | "cask") {
    ui.selectPackage(name, kind);
  }
</script>

<section class="trending">
  <!-- Pane title ("Trending") moved to the window title bar; head keeps
       the time-window pills, last-updated label, and Refresh. -->
  <header class="panel-head" data-tauri-drag-region>
    <div class="head-right" data-tauri-drag-region="false">
      <div class="pillgroup" role="tablist" aria-label={ui.locale === "ru" ? "Период" : "Time window"}>
        {#each windows as w (w)}
          <button class:on={trending.window === w} onclick={() => trending.setWindow(w)} role="tab" aria-selected={trending.window === w}>{windowLabel(w)}</button>
        {/each}
      </div>
      <span class="ago text-muted">{agoLabel}</span>
      <span class="refresh-wrap">
        <Button size="sm" variant="ghost" loading={trending.loading} onclick={() => trending.load(true)} title={ui.locale === "ru" ? "Обновить (⌘R)" : "Refresh (⌘R)"} ariaLabel={ui.locale === "ru" ? "Обновить тренды" : "Refresh trending"}>
          {#snippet icon()}<RefreshCw size={14} />{/snippet}
          {t("Refresh", ui.locale)}
        </Button>
      </span>
    </div>
  </header>

  <div class="list-wrap">
    {#if trending.loading && !trending.report}
      <LoadingState rows={10} label={t("Fetching install counts from formulae.brew.sh…", ui.locale)} />
    {:else if trending.error}
      <EmptyState title={ui.locale === "ru" ? "Не удалось подключиться к formulae.brew.sh" : "Couldn't reach formulae.brew.sh"} body={trending.error}>
        {#snippet icon()}<TrendingUp size={48} />{/snippet}
        {#snippet cta()}<Button variant="secondary" onclick={() => trending.load(true)}>{t("Retry", ui.locale)}</Button>{/snippet}
      </EmptyState>
    {:else if trending.report && trending.report.entries.length === 0}
      <EmptyState title={ui.locale === "ru" ? "Пока тихо." : "Quiet for now."} body={t("formulae.brew.sh returned no entries.", ui.locale)}>
        {#snippet icon()}<TrendingUp size={48} />{/snippet}
      </EmptyState>
    {:else if trending.report}
      <!-- Linux: every trending entry is kind=formula (the backend filters
           casks out), so the Type column is pure noise — dropped via the
           `no-kind` grid variant. macOS keeps the full 8-column layout. -->
      <div class="list-header" class:no-kind={isLinux} role="row">
        <SortableHeader label="#" sortKey="rank" active={sortKey === "rank"} dir={sortDir} onSort={changeSort} />
        <SortableHeader label={t("Name", ui.locale)} sortKey="name" active={sortKey === "name"} dir={sortDir} onSort={changeSort} />
        <span class="header-desc">{t("Description", ui.locale)}</span>
        <span class="header-version">{t("Version", ui.locale)}</span>
        {#if !isLinux}
          <SortableHeader label={t("Type", ui.locale)} sortKey="kind" active={sortKey === "kind"} dir={sortDir} onSort={changeSort} />
        {/if}
        <SortableHeader label={t("Velocity", ui.locale)} sortKey="velocity" active={sortKey === "velocity"} dir={sortDir} onSort={changeSort} align="right" />
        <SortableHeader label={t("Installs", ui.locale)} sortKey="installs" active={sortKey === "installs"} dir={sortDir} onSort={changeSort} align="right" />
        <span></span>
      </div>
      <ul class="list" aria-label={ui.locale === "ru" ? "Трендовые пакеты" : "Trending packages"}>
        {#each sortedEntries as e (e.name + e.kind)}
          {@const installed = e.installedLocally || packages.isInstalled(e.name, e.kind)}
          {@const isSelected = ui.selectedPackage?.name === e.name && ui.selectedPackage?.kind === e.kind}
          {@const v = velocityOf(e.name, e.kind, e.velocityIndex)}
          {@const tier = velocityTier(v)}
          {@const spark = enhancedReady ? trendingHistory.sparklineFor(e.name, e.kind) : null}
          <li>
            <button
              class="row"
              class:no-kind={isLinux}
              class:selected={isSelected}
              aria-current={isSelected ? "true" : undefined}
              onclick={() => openEntry(e.name, e.kind)}
            >
              <span class="rank">{e.rank}</span>
              <span class="name-cell">
                <PackageRowIcon token={e.name} kind={e.kind} resolveCask />
                <span class="name truncate">
                  <span class="name-text">{e.name}</span>
                  {#if friendlyOf(e.name)}
                    <span class="friendly-subtitle">{friendlyOf(e.name)}</span>
                  {/if}
                </span>
              </span>
              <span class="desc truncate text-muted">{enrichment.summaryOf(e.name) ?? catalog.descOf(e.name, e.kind) ?? ""}</span>
              <span class="version truncate text-muted">{catalog.versionOf(e.name, e.kind) ?? ""}</span>
              {#if !isLinux}
                <span class="kind"><Pill tone={e.kind === "formula" ? "formula" : "cask"}>{e.kind === "formula" ? t("package.kind.formula", ui.locale) : t("package.kind.cask", ui.locale)}</Pill></span>
              {/if}
              <span class="velocity mono" class:surge={tier === "surge"} class:cool={tier === "cool"}>
                {#if tier === "surge"}
                  <Flame size={12} aria-hidden="true" />
                {:else if tier === "cool"}
                  <Snowflake size={12} aria-hidden="true" />
                {/if}
                {#if v !== null}
                  <span class="vel-num">{v.toFixed(2)}</span>
                {:else}
                  <span class="vel-num text-muted">—</span>
                {/if}
              </span>
              <span class="count-cell mono">
                <span class="count-num">{e.installCountFormatted}</span>
                {#if spark}
                  <span class="count-spark"><TrendingSparkline data={spark} variant="inline" title={ui.locale === "ru" ? `Динамика установок ${e.name}` : `${e.name} install trend`} /></span>
                {/if}
              </span>
              <span class="trail">
                {#if installed}<Pill tone="success">{t("package.installed", ui.locale)}</Pill>{/if}
              </span>
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</section>

<style>
  .trending { display: flex; flex-direction: column; min-height: 0; height: 100%; }
  .panel-head {
    display: flex; justify-content: flex-end; align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    gap: var(--space-3);
  }
  .head-right { display: flex; align-items: center; gap: var(--space-3); margin-left: auto; }
  .ago { font-size: var(--text-body-sm); white-space: nowrap; }

  /* Narrow-window responsive: drop the "Updated Ns ago" text and the
     Refresh button when the head-right cluster starts to crowd the
     panel (typically when the detail panel is open + the window is
     narrow). Refresh stays available via Cmd+R. */
  @media (max-width: 1000px) {
    .ago { display: none; }
    .refresh-wrap { display: none; }
  }

  /* Trending row has 8 cells (# / NAME / DESC / VERSION / TYPE /
     VELOCITY / COUNT / TRAIL). v0.4.0 added VELOCITY between TYPE
     and COUNT. Responsive drops from widest-but-least-essential first:
       <= 1200px: drop Trail (8th, installed pill)
       <= 1000px: also drop Description (3rd)
       <=  800px: also drop Version (4th); leave # / NAME / TYPE / VELOCITY / COUNT
       <=  640px: also drop Type (5th); leave # / NAME / VELOCITY / COUNT */
  @media (max-width: 1200px) {
    .list-header,
    .row {
      grid-template-columns: 48px minmax(0, 1fr) minmax(0, 2fr) 100px 80px 90px 120px;
    }
    .list-header > :nth-child(8),
    .row > :nth-child(8) { display: none; }
  }
  @media (max-width: 1000px) {
    .list-header,
    .row {
      grid-template-columns: 48px minmax(0, 1fr) 100px 80px 90px 120px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(8),
    .row > :nth-child(3),
    .row > :nth-child(8) { display: none; }
  }
  @media (max-width: 800px) {
    .list-header,
    .row {
      grid-template-columns: 48px minmax(0, 1fr) 80px 90px 120px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(4),
    .list-header > :nth-child(8),
    .row > :nth-child(3),
    .row > :nth-child(4),
    .row > :nth-child(8) { display: none; }
  }
  @media (max-width: 640px) {
    .list-header,
    .row {
      grid-template-columns: 48px minmax(0, 1fr) 90px 120px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(4),
    .list-header > :nth-child(5),
    .list-header > :nth-child(8),
    .row > :nth-child(3),
    .row > :nth-child(4),
    .row > :nth-child(5),
    .row > :nth-child(8) { display: none; }
  }

  /* Linux (`no-kind`): the TYPE column isn't rendered, leaving 7 cells
     (# / NAME / DESC / VERSION / VELOCITY / COUNT / TRAIL). Same
     responsive ladder as macOS with every index past the removed column
     shifted left by one (Trail is now 7th). The macOS nth-child rules
     above still hide DESC (3rd) and VERSION (4th) at the right widths. */
  .list-header.no-kind,
  .row.no-kind {
    grid-template-columns: 48px minmax(0, 1fr) minmax(0, 2fr) 100px 90px 120px 100px;
  }
  @media (max-width: 1200px) {
    .list-header.no-kind,
    .row.no-kind {
      grid-template-columns: 48px minmax(0, 1fr) minmax(0, 2fr) 100px 90px 120px;
    }
    .list-header.no-kind > :nth-child(7),
    .row.no-kind > :nth-child(7) { display: none; }
  }
  @media (max-width: 1000px) {
    .list-header.no-kind,
    .row.no-kind {
      grid-template-columns: 48px minmax(0, 1fr) 100px 90px 120px;
    }
  }
  @media (max-width: 800px) {
    .list-header.no-kind,
    .row.no-kind {
      grid-template-columns: 48px minmax(0, 1fr) 90px 120px;
    }
  }
  @media (max-width: 640px) {
    /* The macOS rule hides :nth-child(5) (TYPE); without the TYPE column
       the 5th cell is VELOCITY, which stays visible at this width —
       restore it (header button and row span are both inline-flex). */
    .list-header.no-kind > :nth-child(5),
    .row.no-kind > :nth-child(5) { display: inline-flex; }
  }

  /* Sidebar theme-group pattern: sunken background, no border,
     raised + shadow active state. */
  .pillgroup {
    display: inline-flex;
    background: var(--color-surface-sunken);
    border-radius: var(--radius-md);
    padding: 2px;
    gap: 2px;
  }
  .pillgroup button {
    padding: var(--space-1) var(--space-3);
    border-radius: var(--radius-sm);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
  }
  .pillgroup button.on {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    box-shadow: var(--shadow-xs);
  }

  .list-wrap { flex: 1; overflow-y: auto; min-height: 0; }
  .list-header {
    display: grid;
    /* 8 columns: # / NAME / DESC / VERSION / TYPE / VELOCITY / COUNT+SPARK / TRAIL */
    grid-template-columns: 48px minmax(0, 1fr) minmax(0, 2fr) 100px 80px 90px 120px 100px;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 1;
    /* Prevent column-header text bleeding across cells when the panel is
       narrow (detail panel open + small window). Each cell clips to its
       own column. */
    overflow: hidden;
  }
  .list-header > * { min-width: 0; overflow: hidden; }
  .row > * { min-width: 0; overflow: hidden; }
  .list { display: flex; flex-direction: column; }
  .row {
    display: grid;
    grid-template-columns: 48px minmax(0, 1fr) minmax(0, 2fr) 100px 80px 90px 120px 100px;
    align-items: center;
    gap: var(--space-3);
    width: 100%;
    padding: var(--space-2) var(--space-3);
    min-height: 32px;
    text-align: left;
    color: var(--color-text-primary);
    font-size: var(--text-body);
    border-bottom: 1px solid var(--color-border);
  }
  .row:hover { background: var(--color-surface-sunken); }
  /* Icon + name stack share the name column (matches native's iconNameCell). */
  .name-cell {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
    overflow: hidden;
  }
  .row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .row.selected .rank,
  .row.selected .count-cell { color: inherit; }
  .row.selected .desc,
  .row.selected .version { color: inherit; opacity: 0.85; }
  .row.selected .friendly-subtitle {
    color: var(--color-text-inverse);
    opacity: 0.75;
  }
  .desc {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .version {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    font-variant-numeric: tabular-nums;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .header-desc,
  .header-version {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
  .rank { color: var(--color-text-muted); font-variant-numeric: tabular-nums; }
  /* Vertical flex container so the optional AI-enriched friendly_name
     subtitle (Phase 13) stacks below the raw token. Children manage
     their own truncation. */
  .name {
    font-weight: var(--fw-medium);
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    min-width: 0;
    white-space: normal;
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
  /* v0.4.0 — velocity cell. Badge + numeric, color-coded by tier. */
  .velocity {
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    gap: 4px;
    font-variant-numeric: tabular-nums;
    color: var(--color-text-secondary);
  }
  .velocity.surge { color: #b8542a; }   /* same accent family — warm/orange for surging */
  .velocity.cool  { color: #4a7fa8; }   /* cool blue */
  .vel-num { font-size: var(--text-body-sm); }
  .row.selected .velocity,
  .row.selected .velocity.surge,
  .row.selected .velocity.cool { color: inherit; }

  /* v0.4.0 — count cell becomes vertical-flex with a tiny inline
     sparkline beneath the formatted count. Sparkline only renders
     when enhanced trending is on (`enhancedReady` gate in the markup). */
  .count-cell {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    justify-content: center;
    gap: 1px;
    font-variant-numeric: tabular-nums;
    color: var(--color-text-secondary);
    text-align: right;
  }
  .count-num {
    font-size: var(--text-body);
    line-height: 1.1;
  }
  .count-spark {
    line-height: 0;
    color: var(--color-accent, #b8542a);
  }
  .row.selected .count-spark { color: var(--color-text-inverse); opacity: 0.85; }

  .trail { display: flex; justify-content: flex-end; }
</style>
