<script lang="ts">
  /**
   * SettingsSectionLiveBundles.svelte
   *
   * Sibling of SettingsSectionLiveEnrichment: mounted in
   * SettingsSectionNetwork.svelte. The opt-in toggle for refreshing the curated
   * Bundles recipe set from `brew-browser.zerologic.com/bundles/bundles.json`.
   *
   * Same first-party host as Live enrichment / Enhanced Trending, distinct
   * `/bundles/*` path — its own trust boundary, separate from the always-on
   * Homebrew paths. Unlike enrichment (per-token GETs), this is a SINGLE
   * static-file fetch and sends no package names.
   *
   * - Offline Mode on  → toggle disabled, "Disabled by Offline Mode".
   * - Offline Mode off → ON binds liveBundlesEnabled, flipping the backend's
   *   `require_live_bundles` gate open. The bundled copy is kept on any error.
   */

  import Boxes from "@lucide/svelte/icons/boxes";

  import { settings } from "$lib/stores/settings.svelte";
  import { bundles } from "$lib/stores/bundles.svelte";
  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";

  let offline = $derived(settings.effective.paranoidMode);
  let on = $derived(settings.effective.liveBundlesEnabled);

  async function onToggle(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).checked;
    await settings.save({ liveBundlesEnabled: v });
    // Turning it on: pull the latest set now so the change is immediate.
    if (v) void bundles.refreshLive();
  }
</script>

<div class="section">
  <h2>
    <Boxes size={18} aria-hidden="true" />
    {t("settings.liveBundles.title", ui.locale)}
  </h2>

  <div class="field">
    <label class="toggle" title={offline ? t("Disabled by Offline Mode", ui.locale) : undefined}>
      <input
        type="checkbox"
        checked={on}
        onchange={onToggle}
        disabled={offline || settings.loading || settings.corruptOnDisk}
        aria-describedby="live-bundles-hint"
      />
      <span class="toggle-track" aria-hidden="true"></span>
      <span class="toggle-label">{t("settings.liveBundles.toggle", ui.locale)}</span>
    </label>

    <p class="hint" id="live-bundles-hint">
      {t("settings.liveBundles.hint.beforeHost", ui.locale)}
      <code>brew-browser.zerologic.com/bundles/bundles.json</code>{t("settings.liveBundles.hint.afterHost", ui.locale)}
    </p>

    {#if offline}
      <p class="hint hint-warn">
        {t("settings.liveBundles.offline", ui.locale)}
      </p>
    {/if}
  </div>
</div>

<style>
  .section {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    max-width: 580px;
    margin-top: var(--space-3);
    padding-top: var(--space-5);
    border-top: 1px solid var(--color-border);
  }
  h2 {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
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
    color: var(--color-text-secondary);
    word-break: break-all;
  }
  .hint-warn {
    color: var(--color-warning-strong, #b45309);
  }

  /* ---------- Toggle (matches Network/Updates/LiveEnrichment) ---------- */
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
  .toggle input:disabled + .toggle-track {
    opacity: 0.6;
    cursor: not-allowed;
  }
  .toggle-label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
</style>
