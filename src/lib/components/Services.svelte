<script lang="ts">
  import { onMount } from "svelte";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Play from "@lucide/svelte/icons/play";
  import Square from "@lucide/svelte/icons/square";
  import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
  import Activity from "@lucide/svelte/icons/activity";

  import Button from "./Button.svelte";
  import Pill from "./Pill.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import SortableHeader from "./SortableHeader.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { t, ruPlural, type Locale } from "$lib/i18n/messages";
  import { normalizeServiceStatus, type Service, type ServiceStatus } from "$lib/types";
  import { reportableToastError } from "$lib/util/reportIssue";

  type SortKey = "name" | "status" | "user";
  let sortKey: SortKey = $state("status");
  let sortDir: "asc" | "desc" = $state("asc");

  onMount(() => {
    services.load();
  });

  function changeSort(key: string) {
    const k = key as SortKey;
    if (sortKey === k) {
      sortDir = sortDir === "asc" ? "desc" : "asc";
    } else {
      sortKey = k;
      sortDir = "asc";
    }
  }

  /** Status sort order: started → scheduled → error → stopped → none → unknown. */
  const STATUS_ORDER: Record<ServiceStatus, number> = {
    started:   0,
    scheduled: 1,
    error:     2,
    stopped:   3,
    none:      4,
    unknown:   5,
  };

  let sorted = $derived.by<Service[]>(() => {
    const arr = [...services.list];
    const mul = sortDir === "asc" ? 1 : -1;
    arr.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case "name":
          cmp = a.name.localeCompare(b.name);
          break;
        case "status":
          cmp = STATUS_ORDER[normalizeServiceStatus(a.status)] -
                STATUS_ORDER[normalizeServiceStatus(b.status)];
          if (cmp === 0) cmp = a.name.localeCompare(b.name);
          break;
        case "user":
          cmp = (a.user ?? "").localeCompare(b.user ?? "");
          if (cmp === 0) cmp = a.name.localeCompare(b.name);
          break;
      }
      return cmp * mul;
    });
    return arr;
  });

  function pillTone(s: ServiceStatus): "success" | "warning" | "danger" | "neutral" {
    switch (s) {
      case "started":   return "success";
      case "scheduled": return "warning";
      case "error":     return "danger";
      default:          return "neutral";
    }
  }

  function statusLabel(s: ServiceStatus, locale: Locale = ui.locale): string {
    if (locale === "ru") {
      switch (s) {
        case "started":   return "запущена";
        case "stopped":   return "остановлена";
        case "none":      return "не загружена";
        case "error":     return "ошибка";
        case "scheduled": return "запланирована";
        case "unknown":   return "неизвестно";
      }
    }
    switch (s) {
      case "started":   return "running";
      case "stopped":   return "stopped";
      case "none":      return "not loaded";
      case "error":     return "error";
      case "scheduled": return "scheduled";
      case "unknown":   return "unknown";
    }
  }

  function servicesCount(): string {
    const running = services.list.filter((s) => normalizeServiceStatus(s.status) === "started").length;
    const total = services.list.length;
    if (ui.locale === "ru") {
      return `${running} ${ruPlural(running, "служба запущена", "службы запущены", "служб запущено")} · всего ${total}`;
    }
    return `${running} running · ${total} total`;
  }

  function actionDone(action: "start" | "stop" | "restart", name: string): string {
    if (ui.locale === "ru") {
      if (action === "start") return `Запущена служба ${name}`;
      if (action === "stop") return `Остановлена служба ${name}`;
      return `Перезапущена служба ${name}`;
    }
    return `${action.charAt(0).toUpperCase() + action.slice(1)}ed ${name}`;
  }

  function actionFailed(action: "start" | "stop" | "restart", name: string): string {
    if (ui.locale === "ru") {
      if (action === "start") return `Не удалось запустить службу ${name}`;
      if (action === "stop") return `Не удалось остановить службу ${name}`;
      return `Не удалось перезапустить службу ${name}`;
    }
    return `Failed to ${action} ${name}`;
  }

  async function act(name: string, action: "start" | "stop" | "restart") {
    try {
      await services.act(name, action);
      toast.success(actionDone(action, name));
    } catch (e) {
      reportableToastError(actionFailed(action, name), e);
    }
  }

  function openPackage(name: string) {
    // Services are formulae by definition.
    if (packages.isInstalled(name, "formula")) {
      ui.selectPackage(name, "formula");
    }
  }
</script>

<section class="services">
  <!-- Pane title ("Services") moved to the window title bar; head keeps
       the running/total count and Refresh. -->
  <header class="panel-head" data-tauri-drag-region>
    <div class="head-right" data-tauri-drag-region="false">
      <span class="text-muted count">
        {#if services.list.length > 0}
          {servicesCount()}
        {/if}
      </span>
      <span class="refresh-wrap">
        <Button size="sm" variant="ghost" onclick={() => services.load(true)} ariaLabel={t("Refresh services", ui.locale)} title={ui.locale === "ru" ? "Обновить (⌘R)" : "Refresh (⌘R)"} disabled={services.loading}>
          {#snippet icon()}<RefreshCw size={14} />{/snippet}
          {t("Refresh", ui.locale)}
        </Button>
      </span>
    </div>
  </header>

  <div class="list-wrap">
    {#if services.loading && services.list.length === 0}
      <LoadingState rows={6} label={t("Loading brew services…", ui.locale)} />
    {:else if services.error}
      <EmptyState title={t("Couldn't load services", ui.locale)} body={services.error}>
        {#snippet icon()}<Activity size={48} />{/snippet}
        {#snippet cta()}
          <Button variant="secondary" onclick={() => services.load(true)}>{t("Retry", ui.locale)}</Button>
        {/snippet}
      </EmptyState>
    {:else if services.list.length === 0}
      <EmptyState
        title={t("No background services.", ui.locale)}
        body={t("Install something like postgresql, redis, or nginx and they'll show up here.", ui.locale)}
      >
        {#snippet icon()}<Activity size={48} />{/snippet}
      </EmptyState>
    {:else}
      <div class="list-header" role="row">
        <SortableHeader label={t("Name", ui.locale)} sortKey="name" active={sortKey === "name"} dir={sortDir} onSort={changeSort} />
        <SortableHeader label={t("Status", ui.locale)} sortKey="status" active={sortKey === "status"} dir={sortDir} onSort={changeSort} />
        <SortableHeader label={t("User", ui.locale)} sortKey="user" active={sortKey === "user"} dir={sortDir} onSort={changeSort} />
        <span class="header-actions">{t("Actions", ui.locale)}</span>
      </div>
      <ul class="list" aria-label={t("Brew services", ui.locale)}>
        {#each sorted as s (s.name)}
          {@const ns = normalizeServiceStatus(s.status)}
          {@const isPending = services.isPending(s.name)}
          {@const isSelected = ui.selectedPackage?.name === s.name && ui.selectedPackage?.kind === "formula"}
          <li>
            <div class="row" class:pending={isPending} class:selected={isSelected}>
              <button
                class="name truncate"
                aria-current={isSelected ? "true" : undefined}
                onclick={() => openPackage(s.name)}
                title={ui.locale === "ru" ? `Открыть карточку ${s.name}` : `Open ${s.name} in detail`}
              >
                {s.name}
              </button>
              <span class="status">
                <Pill tone={pillTone(ns)}>{statusLabel(ns, ui.locale)}</Pill>
              </span>
              <span class="user truncate text-muted">{s.user ?? "—"}</span>
              <div class="actions">
                <button
                  class="act"
                  onclick={() => act(s.name, "start")}
                  disabled={isPending || ns === "started"}
                  title={ns === "started" ? t("Already running", ui.locale) : t("Start service", ui.locale)}
                  aria-label={ui.locale === "ru" ? `Запустить ${s.name}` : `Start ${s.name}`}
                >
                  <Play size={14} />
                </button>
                <button
                  class="act"
                  onclick={() => act(s.name, "stop")}
                  disabled={isPending || ns === "stopped" || ns === "none"}
                  title={ns === "started" ? t("Stop service", ui.locale) : t("Not running", ui.locale)}
                  aria-label={ui.locale === "ru" ? `Остановить ${s.name}` : `Stop ${s.name}`}
                >
                  <Square size={14} />
                </button>
                <button
                  class="act"
                  onclick={() => act(s.name, "restart")}
                  disabled={isPending}
                  title={t("Restart service", ui.locale)}
                  aria-label={ui.locale === "ru" ? `Перезапустить ${s.name}` : `Restart ${s.name}`}
                >
                  <RotateCcw size={14} />
                </button>
              </div>
            </div>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</section>

<style>
  .services { display: flex; flex-direction: column; min-height: 0; height: 100%; }
  .panel-head {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    gap: var(--space-3);
  }
  .head-right { display: flex; align-items: center; gap: var(--space-3); margin-left: auto; }
  .count { font-size: var(--text-body-sm); white-space: nowrap; }

  /* Narrow-window responsive: same pattern as Trending + Library. Drop the
     "N running · M total" count and the Refresh button when the head-right
     cluster crowds the panel. Cmd+R still refreshes the services list. */
  @media (max-width: 1000px) {
    .count { display: none; }
    .refresh-wrap { display: none; }
  }

  .list-wrap { flex: 1; overflow-y: auto; min-height: 0; }
  .list-header {
    display: grid;
    grid-template-columns: minmax(0, 1.5fr) 110px minmax(0, 1fr) 120px;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-4);
    background: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 1;
  }
  .header-actions {
    color: var(--color-text-muted);
    font-size: var(--text-caption);
    font-weight: var(--fw-semibold);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    text-align: right;
  }
  .list { display: flex; flex-direction: column; }
  .row {
    display: grid;
    grid-template-columns: minmax(0, 1.5fr) 110px minmax(0, 1fr) 120px;
    gap: var(--space-3);
    align-items: center;
    padding: var(--space-2) var(--space-4);
    border-bottom: 1px solid var(--color-border);
    transition: opacity 0.12s ease;
  }
  .row.pending { opacity: 0.6; }
  .row:hover { background: var(--color-surface-sunken); }
  .row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .row.selected .name,
  .row.selected .user { color: inherit; }
  .name {
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
    text-align: left;
    background: transparent;
    padding: 0;
    cursor: pointer;
  }
  .name:hover { color: var(--color-text-link); text-decoration: underline; }
  .user { font-size: var(--text-body-sm); }

  .actions {
    display: inline-flex;
    justify-content: flex-end;
    gap: 4px;
  }
  .act {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: var(--color-surface-sunken);
    color: var(--color-text-secondary);
    border: 1px solid var(--color-border);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease;
  }
  .act:not(:disabled):hover {
    background: var(--color-surface);
    color: var(--color-text-primary);
    border-color: var(--color-accent);
  }
  .act:disabled { opacity: 0.35; cursor: default; }
</style>
