<script lang="ts">
  /**
   * SettingsSectionUpdates.svelte — Phase 15
   *
   * Mounted at the bottom of `SettingsSectionNetwork.svelte` (the
   * Updates flow IS a network feature, so it lives in the same pane
   * the user already opens to manage outbound posture).
   *
   * Three always-visible rows:
   *   1. "Check for updates now" button — disabled with the
   *      "Disabled by Offline Mode" tooltip when Offline Mode is on.
   *   2. "Auto-check daily" toggle — bound to
   *      `settings.updateAutoCheck`. Stays toggleable even in Offline
   *      Mode so the user can configure their preference for the next
   *      time Offline Mode is off (matches every other network toggle).
   *   3. "Update channel: Stable" — read-only display, placeholder
   *      for v0.4+ beta channel support.
   *
   * One conditional card (when `updater.available !== null`):
   *   - **v{version} available** heading
   *   - "Release notes ↗" link (opens via `safeOpenUrl`)
   *   - [Install update] button → `updater.install(version)` → swaps to
   *     a progress indicator while installing, then to a success line
   *     + "Relaunch now" button on completion. On failure: inline
   *     error text + "Try again" button.
   *
   * No "Skip this version" button here — the × on the title-bar
   * indicator owns the skip path so the Settings card stays focused on
   * positive actions.
   */

  import Download from "@lucide/svelte/icons/download";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Loader from "@lucide/svelte/icons/loader-2";
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import CheckCircle from "@lucide/svelte/icons/check-circle-2";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import RotateCw from "@lucide/svelte/icons/rotate-cw";

  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { updater } from "$lib/stores/updater.svelte";
  import { safeOpenUrl } from "$lib/util/url";
  import { t } from "$lib/i18n/messages";

  /** Offline Mode gates both the manual button and the Install action.
      Tracked as a single derived for tidy template gating. */
  let offline = $derived(settings.effective.paranoidMode);

  /** Available-update snapshot for the conditional card. */
  let info = $derived(updater.available);

  function onCheckNow() {
    void updater.checkNow();
  }

  function onToggleAutoCheck(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).checked;
    void settings.save({ updateAutoCheck: v });
  }

  function onInstall() {
    if (!info) return;
    void updater.install(info.version);
  }

  function onRelaunch() {
    void updater.relaunch();
  }

  function onTryAgain() {
    updater.clearError();
    if (info) void updater.install(info.version);
  }

  /** Always-correct release notes URL derived from the version tag.
      The manifest's free-form `notes` field is rendered inline below;
      this link goes to the canonical GH release page so users can
      see the changelog + assets even when the manifest snippet is
      terse. */
  let releaseNotesUrl = $derived(
    info ? `https://github.com/msitarzewski/brew-browser/releases/tag/v${info.version}` : null,
  );

  function onOpenReleaseNotes() {
    if (releaseNotesUrl) void safeOpenUrl(releaseNotesUrl);
  }

  /** Format the last-checked timestamp for the curious user. Locale-
      sensitive; falls back to "—" when never checked. */
  let lastCheckedLabel = $derived.by(() => {
    if (updater.lastChecked === null) return "—";
    return new Date(updater.lastChecked).toLocaleString(ui.locale === "ru" ? "ru-RU" : undefined);
  });
</script>

<div class="section">
  <h2>{t("Updates", ui.locale)}</h2>

  <!-- Row 1: Check for updates now -->
  <div class="field">
    <span class="field-label">{t("Check for updates now", ui.locale)}</span>
    <div class="row">
      <button
        type="button"
        class="btn-secondary"
        onclick={onCheckNow}
        disabled={offline || updater.checking}
        title={offline ? t("Disabled by Offline Mode", ui.locale) : (ui.locale === "ru" ? "Проверить канал обновлений на новую версию" : "Check the manifest for a newer release")}
      >
        {#if updater.checking}
          <span class="spin"><Loader size={14} /></span>
          {ui.locale === "ru" ? "Проверяем…" : "Checking…"}
        {:else}
          <RefreshCw size={14} />
          {t("Check now", ui.locale)}
        {/if}
      </button>
      <span class="meta">{ui.locale === "ru" ? "Последняя проверка" : "Last checked"}: {lastCheckedLabel}</span>
    </div>
    {#if offline}
      <p class="hint">
        {#if ui.locale === "ru"}
          Офлайн-режим включён — ручная проверка обновлений заблокирована.
          Отключите его выше, чтобы проверить канал обновлений.
        {:else}
          Offline Mode is on — manual update checks are blocked. Turn it off above
          to check the manifest.
        {/if}
      </p>
    {:else}
      <p class="hint">
        {#if ui.locale === "ru"}
          Загружает <code>brew-browser.zerologic.com/updater.json</code> и
          сравнивает опубликованную версию с установленной. Номер вашей
          версии не отправляется.
        {:else}
          Fetches <code>brew-browser.zerologic.com/updater.json</code> and
          compares the published version to the one you're running. No
          version number is sent.
        {/if}
      </p>
    {/if}
  </div>

  <!-- Row 2: Auto-check daily -->
  <div class="field">
    <label class="toggle">
      <input
        type="checkbox"
        checked={settings.effective.updateAutoCheck}
        onchange={onToggleAutoCheck}
        disabled={settings.loading || settings.corruptOnDisk}
      />
      <span class="toggle-track" aria-hidden="true"></span>
      <span class="toggle-label">{t("Auto-check daily", ui.locale)}</span>
    </label>
    <p class="hint">
      {#if ui.locale === "ru"}
        Если включено, brew-browser проверяет канал обновлений раз в 24 часа
        и показывает индикатор в заголовке окна, когда доступна новая версия.
        Автоматически приостанавливается в офлайн-режиме.
      {:else}
        When on, brew-browser checks the manifest once every 24 hours and
        surfaces a notice in the title bar if a newer version is available.
        Suspended automatically while Offline Mode is on.
      {/if}
    </p>
  </div>

  <!-- Row 3: Update channel -->
  <div class="field">
    <span class="field-label">{t("Update channel", ui.locale)}</span>
    <div class="channel-row">
      <span class="channel-name">{t("Stable", ui.locale)}</span>
      <span class="meta">{t("No beta channel in this release.", ui.locale)}</span>
    </div>
  </div>

  <!-- Conditional: notice card when an update is available -->
  {#if info}
    <div class="notice" role="region" aria-label={`${t("Update available", ui.locale)}: brew-browser ${info.version}`}>
      <div class="notice-head">
        <strong>{ui.locale === "ru" ? `Доступна версия v${info.version}` : `v${info.version} available`}</strong>
        <button
          type="button"
          class="link"
          onclick={onOpenReleaseNotes}
          aria-label={ui.locale === "ru" ? "Открыть примечания к релизу в браузере" : "Open release notes in your browser"}
        >
          {ui.locale === "ru" ? "Примечания к релизу" : "Release notes"} <ExternalLink size={12} />
        </button>
      </div>

      {#if updater.installComplete}
        <div class="result success">
          <CheckCircle size={16} />
          <span>{t("Install complete. Relaunch to use the new version.", ui.locale)}</span>
        </div>
        <button
          type="button"
          class="btn-primary"
          onclick={onRelaunch}
          title={ui.locale === "ru" ? "Перезапустить только что установленный brew-browser" : "Relaunch into the freshly-installed brew-browser"}
        >
          <RotateCw size={14} /> {ui.locale === "ru" ? "Перезапустить сейчас" : "Relaunch now"}
        </button>
      {:else if updater.installing}
        <div class="progress" role="status" aria-live="polite">
          <span class="spin"><Loader size={16} /></span>
          <span>{ui.locale === "ru" ? `Загружаем и проверяем brew-browser v${info.version}…` : `Downloading and verifying brew-browser v${info.version}…`}</span>
        </div>
      {:else if updater.error}
        <div class="result error">
          <TriangleAlert size={16} />
          <span>{updater.error}</span>
        </div>
        <button
          type="button"
          class="btn-secondary"
          onclick={onTryAgain}
          disabled={offline}
          title={offline ? t("Disabled by Offline Mode", ui.locale) : (ui.locale === "ru" ? "Повторить установку" : "Retry the install")}
        >
          <RotateCw size={14} /> {t("Try again", ui.locale)}
        </button>
      {:else}
        <button
          type="button"
          class="btn-primary"
          onclick={onInstall}
          disabled={offline}
          title={offline ? t("Disabled by Offline Mode", ui.locale) : (ui.locale === "ru" ? `Загрузить и установить brew-browser v${info.version}` : `Download and install brew-browser v${info.version}`)}
        >
          <Download size={14} /> {ui.locale === "ru" ? "Установить обновление" : "Install update"}
        </button>
      {/if}

      {#if info.notes}
        <p class="notes-body">{info.notes}</p>
      {/if}
    </div>
  {/if}
</div>

<style>
  .section {
    display: flex;
    flex-direction: column;
    gap: var(--space-5);
    max-width: 580px;
    /* Mounted at the bottom of the Network section — a top divider
       reads as the section break instead of having a duplicate H2
       hug the previous content. */
    margin-top: var(--space-3);
    padding-top: var(--space-5);
    border-top: 1px solid var(--color-border);
  }
  h2 {
    font-size: var(--text-h2);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin: 0 0 var(--space-2) 0;
  }
  .field {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .field-label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
  .hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-snug);
  }
  .hint code {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    padding: 1px 4px;
    background: var(--color-surface-sunken);
    border-radius: var(--radius-sm);
  }
  .row {
    display: inline-flex;
    align-items: center;
    gap: var(--space-3);
  }
  .meta {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
  }

  /* ---------- Toggle (matches Network/GitHub) ---------- */
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

  /* ---------- Channel row ---------- */
  .channel-row {
    display: inline-flex;
    align-items: baseline;
    gap: var(--space-3);
  }
  .channel-name {
    font-size: var(--text-body);
    color: var(--color-text-primary);
    font-weight: var(--fw-medium);
    padding: 2px 10px;
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
  }

  /* ---------- Buttons (match GitHub section pattern) ---------- */
  .btn-primary,
  .btn-secondary {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: var(--radius-md);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    width: max-content;
  }
  .btn-primary {
    background: var(--color-accent, #b8542a);
    color: white;
  }
  .btn-primary:hover:not(:disabled) { filter: brightness(1.05); }
  .btn-primary:disabled { opacity: 0.6; cursor: not-allowed; }
  .btn-secondary {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    border: 1px solid var(--color-border);
  }
  .btn-secondary:hover:not(:disabled) { background: var(--color-surface); }
  .btn-secondary:disabled { opacity: 0.6; cursor: not-allowed; }

  /* ---------- Notice card (when update is available) ---------- */
  .notice {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
    background: var(--color-warning-subtle, var(--color-surface-sunken));
    border: 1px solid var(--color-warning, var(--color-border));
    border-radius: var(--radius-md);
  }
  .notice-head {
    display: inline-flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-3);
    color: var(--color-warning-on-subtle, var(--color-text-primary));
    font-size: var(--text-body);
  }
  .link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    background: transparent;
    border: none;
    color: var(--color-accent, #b8542a);
    cursor: pointer;
    font-size: var(--text-body-sm);
    padding: 0;
    text-decoration: underline;
    text-underline-offset: 2px;
  }
  .link:hover { filter: brightness(1.1); }
  .link:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
    border-radius: var(--radius-sm);
  }

  /* In-progress / result rows live inside the notice card. */
  .progress,
  .result {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-body-sm);
    color: var(--color-text-primary);
  }
  .result.success { color: #2e7d32; }
  .result.error { color: var(--color-warning-strong, #b45309); }

  /* Release notes body — the manifest's free-form `notes` text. */
  .notes-body {
    margin: 0;
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-snug);
    white-space: pre-wrap;
  }

  /* Spinner used inline in buttons and progress rows. */
  .spin {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }
  @media (prefers-reduced-motion: reduce) {
    .spin { animation: none; }
  }
</style>
