<script lang="ts">
  /**
   * SettingsSectionNetwork.svelte — Phase 12d
   *
   * Real Network controls. Backed by `settings.svelte.ts` which mirrors
   * the on-disk `settings.json`. Every control change calls
   * `settings.save({...})` with an optimistic UI update; the backend
   * round-trip applies clamps so the displayed value reverts cleanly if
   * the user types something out-of-range.
   *
   * Failure modes handled:
   * - `settings.loading && !settings.data` → "Loading…" placeholder.
   * - `settings.corruptOnDisk` → "Settings file is unreadable" panel
   *   with a [Reset to defaults] button that calls `settings.reset()`.
   *   This is the fail-closed recovery path required by the §12d
   *   security review.
   *
   * The disclosure list at the bottom reflects the current setting
   * values (checkmark vs cross) so the user can see at a glance which
   * outbound paths are live.
   */

  import AlertTriangle from "@lucide/svelte/icons/triangle-alert";
  import CheckCircle from "@lucide/svelte/icons/check-circle-2";
  import XCircle from "@lucide/svelte/icons/x-circle";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";

  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { isLinux } from "$lib/util/platform";
  import SettingsSectionUpdates from "$lib/components/SettingsSectionUpdates.svelte";
  import SettingsSectionTrendingHistory from "$lib/components/SettingsSectionTrendingHistory.svelte";
  import SettingsSectionLiveEnrichment from "$lib/components/SettingsSectionLiveEnrichment.svelte";
  import SettingsSectionLiveBundles from "$lib/components/SettingsSectionLiveBundles.svelte";
  import SettingsSectionVulnerabilities from "$lib/components/SettingsSectionVulnerabilities.svelte";
  import type {
    CaskIconMode,
    CatalogAutoRefresh,
  } from "$lib/types";
  import { t } from "$lib/i18n/messages";

  /** Tooltip + accessible-description copy for the Offline Mode toggle
      (Phase 15 plan §11 item 13). Centralised in one constant so the
      `title` attribute and the on-screen hint stay in sync. Linux: casks
      (and therefore cask icon probes) don't exist — the phrase is dropped. */
  const OFFLINE_MODE_DESCRIPTION =
    "Blocks every outbound network call: catalog refresh, Trending fetch, " +
    `GitHub stats, GitHub sign-in, ${isLinux ? "" : "cask icon homepage probes, "}update checks. ` +
    "All UI that depends on the network shows a 'disabled by Offline Mode' " +
    "notice. brew itself still runs normally — its network access is the " +
    "user's call at the terminal.";

  let offlineModeDescription = $derived(ui.locale === "ru"
    ? "Блокирует все исходящие сетевые обращения: обновление каталога, загрузку трендов, статистику GitHub, вход через GitHub, " +
      `${isLinux ? "" : "проверку homepage для иконок cask-пакетов, "}проверку обновлений. ` +
      "Весь UI, зависящий от сети, показывает, что действие отключено офлайн-режимом. Сам brew продолжает работать как обычно: его сетевой доступ остаётся вашим явным действием."
    : OFFLINE_MODE_DESCRIPTION);

  /** Inclusive bounds — kept in sync with `Settings::CATALOG_STALE_DAYS_*`
      in src-tauri/src/commands/settings.rs. */
  const CATALOG_STALE_MIN = 1;
  const CATALOG_STALE_MAX = 365;
  /** Inclusive bounds — kept in sync with `Settings::TRENDING_TTL_*`. */
  const TRENDING_TTL_MIN = 5;
  const TRENDING_TTL_MAX = 1440;

  /** Clamp a free-typed number for snappy UX. Backend re-clamps on save. */
  function clampInt(v: number, lo: number, hi: number, fallback: number): number {
    if (!Number.isFinite(v)) return fallback;
    const n = Math.round(v);
    if (n < lo) return lo;
    if (n > hi) return hi;
    return n;
  }

  function toggleParanoid(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).checked;
    void settings.save({ paranoidMode: v });
  }

  function pickAutoRefresh(v: CatalogAutoRefresh) {
    void settings.save({ catalogAutoRefresh: v });
  }

  function pickIconMode(v: CaskIconMode) {
    void settings.save({ caskIconMode: v });
  }

  function autoRefreshLabel(v: CatalogAutoRefresh, sentence = false): string {
    if (ui.locale === "ru") {
      if (v === "off") return sentence ? "вручную" : "Выкл.";
      if (v === "weekly") return sentence ? "еженедельно" : "Еженедельно";
      return sentence ? "ежедневно" : "Ежедневно";
    }
    if (v === "off") return sentence ? "manual" : "Off";
    if (v === "weekly") return sentence ? "weekly" : "Weekly";
    return sentence ? "daily" : "Daily";
  }

  function onStaleDaysChange(e: Event) {
    const raw = Number((e.currentTarget as HTMLInputElement).value);
    const clamped = clampInt(raw, CATALOG_STALE_MIN, CATALOG_STALE_MAX, 14);
    void settings.save({ catalogStaleBannerDays: clamped });
  }

  function onTtlChange(e: Event) {
    const raw = Number((e.currentTarget as HTMLInputElement).value);
    const clamped = clampInt(raw, TRENDING_TTL_MIN, TRENDING_TTL_MAX, 60);
    void settings.save({ trendingTtlMinutes: clamped });
  }

  function handleReset() {
    void settings.reset();
  }

  /** Derive a human path-status pair for the disclosure list. Updates
      live as `settings.data` changes. Each entry shows allowed/blocked
      based on the active config; the master paranoid switch overrides
      every entry's "allowed" badge with "blocked". */
  type PathStatus = {
    label: string;
    desc: string;
    allowed: boolean;
  };
  let pathStatuses = $derived.by<PathStatus[]>(() => {
    const s = settings.effective;
    const paranoid = s.paranoidMode;
    return [
      {
        label: "formulae.brew.sh/api/analytics",
        desc: ui.locale === "ru"
          ? "Вкладка «Тренды» — загружает опубликованные Homebrew счётчики установок."
          : "Trending tab — fetches Homebrew's published install counts.",
        allowed: !paranoid,
      },
      {
        // Linux: the backend only fetches formula.json (no casks there).
        label: isLinux
          ? "formulae.brew.sh/api/formula.json"
          : "formulae.brew.sh/api/{formula,cask}.json",
        desc: ui.locale === "ru"
          ? `Обновление каталога — ${s.catalogAutoRefresh === "off"
              ? "только вручную"
              : `по расписанию (${autoRefreshLabel(s.catalogAutoRefresh, true)})`}.`
          : `Catalog refresh — ${s.catalogAutoRefresh === "off"
              ? "manual only"
              : `scheduled (${autoRefreshLabel(s.catalogAutoRefresh, true)})`}.`,
        allowed: !paranoid,
      },
      // Linux: no casks → no cask icon cascade; the entry would describe
      // a path that can never be exercised, so it's omitted entirely.
      ...(isLinux
        ? []
        : [{
            label: ui.locale === "ru" ? "Проверка homepage cask-пакетов" : "Cask homepage probes",
            desc: ui.locale === "ru"
              ? `Цепочка поиска иконок для неустановленных cask-пакетов — ${
                  s.caskIconMode === "off" ? "отключена" :
                  s.caskIconMode === "installed-only" ? "только установленные приложения" :
                  "все cask-пакеты с homepage"
                }.`
              : `Uninstalled-cask icon cascade — ${
                  s.caskIconMode === "off" ? "disabled" :
                  s.caskIconMode === "installed-only" ? "installed apps only" :
                  "all casks with a homepage"
                }.`,
            allowed: !paranoid && s.caskIconMode !== "off",
          }]),
      {
        label: "brew-browser.zerologic.com/trending-history",
        desc: ui.locale === "ru"
          ? (s.enhancedTrendingEnabled
              ? "Расширенная история трендов — исторические установки по пакетам для мини-графиков и графиков."
              : "Расширенная история трендов — опционально, сейчас отключена.")
          : (s.enhancedTrendingEnabled
              ? "Enhanced trending history — per-package historical install trends for sparklines + charts."
              : "Enhanced trending history — opt-in, currently disabled."),
        allowed: !paranoid && s.enhancedTrendingEnabled,
      },
      {
        label: "brew",
        desc: ui.locale === "ru"
          ? "brew install, brew uninstall и brew upgrade — brew сам загружает bottles. Офлайн-режим это не блокирует, потому что команду запускаете вы."
          : "Install/uninstall/upgrade — brew itself fetches bottles. Not gated by Offline Mode (you initiated the action).",
        allowed: true,
      },
      {
        label: ui.locale === "ru" ? "Браузер по умолчанию" : "Default browser",
        // tauri-plugin-opener delegates to the `open` crate: open(1) on
        // macOS, xdg-open (first in its fallback chain) on Linux.
        desc: ui.locale === "ru"
          ? `Открытие внешних ссылок передаётся в ${isLinux ? "xdg-open" : "macOS open(1)"}. Это не сетевой запрос от brew-browser.`
          : `Opening external links hands off to ${isLinux ? "xdg-open" : "macOS open(1)"}. Not a network call from us.`,
        allowed: true,
      },
    ];
  });
</script>

<div class="section">
  <h2>{t("Network", ui.locale)}</h2>

  {#if settings.loading && !settings.data}
    <p class="lead">{t("Loading settings…", ui.locale)}</p>
  {:else if settings.corruptOnDisk}
    <div class="callout corrupt" role="alert">
      <div class="callout-head">
        <AlertTriangle size={18} />
        <strong>{ui.locale === "ru" ? "Файл настроек не читается." : "Settings file is unreadable."}</strong>
      </div>
      <p class="callout-body">
        {ui.locale === "ru"
          ? "Не удалось разобрать "
          : "Your "}
        <code>settings.json</code>
        {ui.locale === "ru"
          ? ". Пока файл не исправлен, все исходящие сетевые запросы заблокированы для безопасности. Сброс перезапишет файл значениями по умолчанию."
          : " couldn't be parsed. Until it's repaired, all outbound network calls are blocked as a safety measure. Resetting will overwrite the file with defaults."}
      </p>
      {#if settings.error}
        <p class="callout-error">{settings.error}</p>
      {/if}
      <button
        type="button"
        class="btn-danger"
        onclick={handleReset}
        disabled={settings.loading}
      >
        <RefreshCw size={14} /> {t("Reset to defaults", ui.locale)}
      </button>
    </div>
  {:else if settings.data}
    <!-- Master switch — Phase 15 renames user-visible "Paranoid Mode"
         to "Offline Mode". The internal field name (`paranoidMode` on
         the Settings DTO, `paranoid_mode` in settings.json) stays
         unchanged to avoid migration churn — only the UX moves. -->
    <div class="field">
      <label class="toggle" title={offlineModeDescription}>
        <input
          type="checkbox"
          checked={settings.data.paranoidMode}
          onchange={toggleParanoid}
          disabled={settings.loading}
          aria-describedby="offline-mode-hint"
        />
        <span class="toggle-track" aria-hidden="true"></span>
        <span class="toggle-label">{t("Offline Mode", ui.locale)}</span>
      </label>
      <p class="hint" id="offline-mode-hint">{offlineModeDescription}</p>
      {#if settings.data.paranoidMode}
        <div class="callout warn" role="status">
          <AlertTriangle size={16} />
          {#if isLinux}
            <span>{ui.locale === "ru" ? "Офлайн-режим включён — тренды и обновление каталога заблокированы." : "Offline Mode is on — Trending and Catalog refresh are blocked."}</span>
          {:else}
            <span>{ui.locale === "ru" ? "Офлайн-режим включён — тренды, обновление каталога и проверки иконок cask-пакетов заблокированы." : "Offline Mode is on — Trending, Catalog refresh, and Cask icon probes are blocked."}</span>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Catalog auto-refresh -->
    <div class="field">
      <span class="field-label">{ui.locale === "ru" ? "Автообновление каталога" : "Catalog auto-refresh"}</span>
      <div class="radio-row" role="radiogroup" aria-label={ui.locale === "ru" ? "Автообновление каталога" : "Catalog auto-refresh"}>
        {#each (["off", "weekly", "daily"] as const) as opt (opt)}
          <button
            type="button"
            class="radio-btn"
            class:on={settings.data.catalogAutoRefresh === opt}
            role="radio"
            aria-checked={settings.data.catalogAutoRefresh === opt}
            disabled={settings.loading}
            onclick={() => pickAutoRefresh(opt)}
          >
            {autoRefreshLabel(opt)}
          </button>
        {/each}
      </div>
      <p class="hint">{ui.locale === "ru" ? "Выкл. сохраняет текущее поведение: ручное обновление из Сводки." : "Off keeps the current Phase 12a behaviour (manual refresh from the Dashboard)."}</p>
    </div>

    <!-- Stale banner threshold -->
    <div class="field">
      <label for="stale-days">{ui.locale === "ru" ? "Порог предупреждения об устаревшем каталоге" : "Catalog stale-banner threshold"}</label>
      <div class="number-row">
        <input
          id="stale-days"
          type="number"
          class="number"
          min={CATALOG_STALE_MIN}
          max={CATALOG_STALE_MAX}
          step="1"
          value={settings.data.catalogStaleBannerDays}
          onchange={onStaleDaysChange}
          disabled={settings.loading}
        />
        <span class="unit">{ui.locale === "ru" ? "дн." : "days"}</span>
      </div>
      <p class="hint">{ui.locale === "ru"
        ? `Показывать предупреждение «Каталог устарел на N дней», когда активный каталог отстаёт минимум на столько дней. Диапазон ${CATALOG_STALE_MIN}–${CATALOG_STALE_MAX}.`
        : `Show a "Catalog is N days old" banner when the active catalog is at least this many days behind. Range ${CATALOG_STALE_MIN}–${CATALOG_STALE_MAX}.`}</p>
    </div>

    <!-- Cask icon mode. Linux: casks don't exist there, so the whole
         control (and the icon cascade it configures) is hidden. -->
    {#if !isLinux}
    <div class="field">
      <span class="field-label">{ui.locale === "ru" ? "Загрузка иконок cask-пакетов" : "Cask icon fetching"}</span>
      <div class="radio-row" role="radiogroup" aria-label={ui.locale === "ru" ? "Загрузка иконок cask-пакетов" : "Cask icon fetching"}>
        {#each (["off", "installed-only", "all"] as const) as opt (opt)}
          <button
            type="button"
            class="radio-btn"
            class:on={settings.data.caskIconMode === opt}
            role="radio"
            aria-checked={settings.data.caskIconMode === opt}
            disabled={settings.loading}
            onclick={() => pickIconMode(opt)}
          >
            {ui.locale === "ru" ? (opt === "off" ? "Выкл." : opt === "installed-only" ? "Только установленные" : "Все") : opt === "off" ? "Off" : opt === "installed-only" ? "Installed only" : "All"}
          </button>
        {/each}
      </div>
      <p class="hint">{ui.locale === "ru" ? "«Все» соответствует текущему поведению. «Только установленные» пропускает homepage-поиск для неустановленных cask-пакетов. «Выкл.» полностью отключает извлечение иконок." : "All matches the current Phase 8 behaviour. Installed-only skips the homepage cascade for uninstalled casks. Off disables icon extraction entirely."}</p>
    </div>
    {/if}

    <!-- Trending TTL -->
    <div class="field">
      <label for="trending-ttl">{ui.locale === "ru" ? "Время жизни кэша трендов" : "Trending cache TTL"}</label>
      <div class="number-row">
        <input
          id="trending-ttl"
          type="number"
          class="number"
          min={TRENDING_TTL_MIN}
          max={TRENDING_TTL_MAX}
          step="5"
          value={settings.data.trendingTtlMinutes}
          onchange={onTtlChange}
          disabled={settings.loading}
        />
        <span class="unit">{ui.locale === "ru" ? "мин" : "minutes"}</span>
      </div>
      <p class="hint">{ui.locale === "ru"
        ? `Как долго хранить загруженный отчёт трендов перед повторным обращением к formulae.brew.sh. Диапазон ${TRENDING_TTL_MIN}–${TRENDING_TTL_MAX}.`
        : `How long to keep a fetched Trending report before re-hitting formulae.brew.sh. Range ${TRENDING_TTL_MIN}–${TRENDING_TTL_MAX}.`}</p>
    </div>

    <!-- Disclosure list -->
    <div class="field disclosure">
      <span class="field-label">{ui.locale === "ru" ? "Исходящие обращения (только чтение)" : "Outbound paths (read-only)"}</span>
      <ol class="paths">
        {#each pathStatuses as p, i (p.label)}
          <li>
            <span class="num">{i + 1}.</span>
            <span class="status" aria-label={p.allowed ? (ui.locale === "ru" ? "разрешено" : "allowed") : (ui.locale === "ru" ? "заблокировано" : "blocked")}>
              {#if p.allowed}
                <CheckCircle size={14} class="ok" />
              {:else}
                <XCircle size={14} class="bad" />
              {/if}
            </span>
            <div>
              <code class="path-label">{p.label}</code>
              <p class="path-desc">{p.desc}</p>
            </div>
          </li>
        {/each}
      </ol>
      <p class="hint">{ui.locale === "ru"
        ? "Повторяет раздел README «Open by default» и отражает текущие настройки."
        : "Mirrors the README \"Open by default\" disclosure. Reflects your current settings."}</p>
    </div>

    {#if settings.error}
      <p class="callout-error">{settings.error}</p>
    {/if}

    <!-- v0.4.0: Enhanced trending history — opt-in, distinct trust
         boundary (project infra, not Homebrew first-party). Lives in
         Network because it's a network opt-in. -->
    <SettingsSectionTrendingHistory />

    <!-- Live category + description updates — opt-in, same first-party host
         as Enhanced Trending (distinct /enrichment/* path). Network opt-in. -->
    <SettingsSectionLiveEnrichment />

    <!-- v0.7.0: Bundles live-refresh — opt-in, same first-party host as Live
         enrichment (distinct /bundles/* path). Single static-file fetch. -->
    <SettingsSectionLiveBundles />

    <!-- v0.5.0: Vulnerability scanning — opt-in, OSV.dev + GitHub
         Advisories trust boundary. Lives in Network because it's a
         network opt-in. -->
    <SettingsSectionVulnerabilities />

    <!-- Phase 15: Updates subsection lives at the bottom of Network. -->
    <SettingsSectionUpdates />
  {/if}
</div>

<style>
  .section { display: flex; flex-direction: column; gap: var(--space-5); max-width: 580px; }
  h2 {
    font-size: var(--text-h1);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin-bottom: var(--space-2);
  }
  .lead {
    font-size: var(--text-body);
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
  }
  .field { display: flex; flex-direction: column; gap: var(--space-2); }
  .field-label,
  .field > label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
  .hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-snug);
  }

  /* ---------- Toggle ---------- */
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    cursor: pointer;
    user-select: none;
  }
  .toggle input { position: absolute; opacity: 0; pointer-events: none; }
  .toggle-track {
    width: 36px;
    height: 20px;
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    position: relative;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .toggle-track::after {
    content: "";
    position: absolute;
    top: 1px;
    left: 1px;
    width: 16px;
    height: 16px;
    background: var(--color-surface-raised);
    border-radius: 50%;
    box-shadow: var(--shadow-xs);
    transition: transform var(--motion-duration-fast) var(--motion-ease-out);
  }
  .toggle input:checked + .toggle-track {
    background: var(--color-accent, #b8542a);
    border-color: var(--color-accent, #b8542a);
  }
  .toggle input:checked + .toggle-track::after {
    transform: translateX(16px);
    background: white;
  }
  .toggle-label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }

  /* ---------- Radio row ---------- */
  .radio-row {
    display: inline-flex;
    gap: 2px;
    padding: 2px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
    width: max-content;
  }
  .radio-btn {
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .radio-btn:hover { color: var(--color-text-primary); }
  .radio-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .radio-btn.on {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    box-shadow: var(--shadow-xs);
  }

  /* ---------- Number input ---------- */
  .number-row {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
  }
  .number {
    width: 90px;
    padding: 6px var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    font-family: var(--font-sans);
  }
  .number:focus-visible {
    outline: none;
    border-color: var(--color-border-focus);
    box-shadow: var(--shadow-focus-ring);
  }
  .unit {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
  }

  /* ---------- Callouts ---------- */
  .callout {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-3);
    border-radius: var(--radius-md);
    border: 1px solid var(--color-border);
  }
  .callout-head {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-text-primary);
    font-size: var(--text-body);
  }
  .callout-body {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-snug);
  }
  .callout-error {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    color: var(--color-text-muted);
    word-break: break-word;
    margin-top: var(--space-1);
  }
  .corrupt {
    background: color-mix(in srgb, var(--color-accent, #b8542a) 8%, var(--color-surface-sunken));
    border-color: color-mix(in srgb, var(--color-accent, #b8542a) 35%, var(--color-border));
  }
  .warn {
    flex-direction: row;
    align-items: center;
    background: var(--color-surface-sunken);
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
  }

  /* ---------- Reset button ---------- */
  .btn-danger {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: var(--radius-md);
    background: var(--color-accent, #b8542a);
    color: white;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    width: max-content;
  }
  .btn-danger:disabled { opacity: 0.6; cursor: not-allowed; }
  .btn-danger:hover:not(:disabled) {
    filter: brightness(1.05);
  }

  /* ---------- Disclosure list ---------- */
  .disclosure { gap: var(--space-3); }
  .paths {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    margin: 0;
  }
  .paths li {
    display: grid;
    grid-template-columns: 22px 18px 1fr;
    gap: var(--space-2);
    align-items: start;
  }
  .num {
    font-variant-numeric: tabular-nums;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
    padding-top: 2px;
  }
  .status {
    display: inline-flex;
    align-items: center;
    padding-top: 2px;
  }
  .status :global(.ok)  { color: #58a55c; }
  .status :global(.bad) { color: #d24a4a; }
  .path-label {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    color: var(--color-text-primary);
    background: var(--color-surface-raised);
    padding: 1px 6px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--color-border);
  }
  .path-desc {
    margin-top: 4px;
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-snug);
  }
</style>
