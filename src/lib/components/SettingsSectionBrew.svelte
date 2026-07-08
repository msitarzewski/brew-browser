<script lang="ts">
  /**
   * SettingsSectionBrew.svelte — Phase 12b
   *
   * - Analytics toggle: reads the user's Homebrew analytics posture via
   *   `brewGetAnalytics()` on mount, writes it back via `brewSetAnalytics`
   *   on toggle. Shows an in-flight state while the write is shelling out
   *   so the user can see something happened.
   * - Confirm-destructive toggle: writes through `ui.setConfirmDestructive`
   *   to localStorage so the preference survives restart.
   */

  import { onMount } from "svelte";

  import { brewGetAnalytics, brewSetAnalytics, brewAutoremove } from "$lib/api";
  import { ui } from "$lib/stores/ui.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { isBrewError, brewErrorMessage } from "$lib/types";
  import type { BrewStreamEvent } from "$lib/types";
  import { toast } from "$lib/stores/toast.svelte";
  import { t } from "$lib/i18n/messages";
  import Button from "./Button.svelte";
  import DestructiveConfirm from "./DestructiveConfirm.svelte";

  let analyticsEnabled = $state<boolean | null>(null);
  let analyticsLoading = $state(false);
  let analyticsError = $state<string | null>(null);

  async function loadAnalytics() {
    analyticsLoading = true;
    analyticsError = null;
    try {
      analyticsEnabled = await brewGetAnalytics();
    } catch (e) {
      analyticsError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
      // NOTE: we do NOT toast here — the inline `analyticsError` block in
      // the Settings → Brew section already renders the same message. The
      // earlier toast was firing on every Settings open and stacking, since
      // the load runs on mount. The user is already looking at the Brew
      // section to see the error; toast is redundant noise.
    } finally {
      analyticsLoading = false;
    }
  }

  async function toggleAnalytics() {
    if (analyticsLoading || analyticsEnabled === null) return;
    const next = !analyticsEnabled;
    analyticsLoading = true;
    analyticsError = null;
    try {
      await brewSetAnalytics(next);
      analyticsEnabled = next;
      toast.success(t(next ? "Homebrew analytics enabled" : "Homebrew analytics disabled", ui.locale));
    } catch (e) {
      analyticsError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
      toast.error("Couldn't change brew analytics", analyticsError);
      // Re-probe so the UI reflects whatever brew actually settled on.
      await loadAnalytics();
    } finally {
      analyticsLoading = false;
    }
  }

  // ----- Advanced: autoremove (#47) -----

  let autoremoveConfirmOpen = $state(false);
  let autoremoveRunning = $state(false);

  /** Run a streaming brew job into the Activity drawer (mirrors Dashboard's
      `streamJob`): seed a temp job, open the drawer, then reconcile the real
      job id on the first `started` event. */
  async function streamJob(
    label: string,
    command: string,
    run: (onEvent: (evt: BrewStreamEvent) => void) => Promise<{ success: boolean }>,
  ): Promise<boolean> {
    const tmpId = crypto.randomUUID();
    activity.startJob(label, tmpId, command);
    ui.openDrawer();
    const result = await run((evt) => {
      if (evt.kind === "started" && evt.jobId !== tmpId) {
        const j = activity.jobs.find((j) => j.jobId === tmpId);
        if (j) j.jobId = evt.jobId;
      }
      activity.handleEvent(evt);
    });
    return result.success;
  }

  async function runAutoremove() {
    autoremoveConfirmOpen = false;
    if (autoremoveRunning) return;
    autoremoveRunning = true;
    try {
      await streamJob("Removing unused dependencies", "brew autoremove", brewAutoremove);
    } catch (e) {
      toast.error(
        t("settings.brew.autoremove.failedToRun", ui.locale),
        isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e),
      );
    } finally {
      autoremoveRunning = false;
    }
  }

  function onAutoremoveClick() {
    if (ui.confirmDestructive) autoremoveConfirmOpen = true;
    else void runAutoremove();
  }

  onMount(() => {
    void loadAnalytics();
  });
</script>

<div class="section">
  <h2>Brew</h2>

  <section class="group">
    <h3>{t("Analytics", ui.locale)}</h3>
    <p class="desc">
      {t("settings.brew.analyticsDesc.beforeCommand", ui.locale)}
      <code>brew analytics on</code> / <code>off</code>
      {t("settings.brew.analyticsDesc.afterCommand", ui.locale)}
    </p>

    <div class="row">
      <label class="toggle">
        <input
          type="checkbox"
          checked={analyticsEnabled === true}
          disabled={analyticsLoading || analyticsEnabled === null}
          onchange={toggleAnalytics}
        />
        <span>{t("settings.brew.analyticsToggle", ui.locale)}</span>
      </label>
      {#if analyticsLoading}
        <span class="status">{t("working…", ui.locale)}</span>
      {:else if analyticsEnabled === null && analyticsError}
        <span class="status status--err">{t("unavailable", ui.locale)}</span>
      {/if}
    </div>

    {#if analyticsError && analyticsEnabled === null}
      <p class="err">{analyticsError}</p>
    {/if}
  </section>

  <section class="group">
    <h3>{t("Confirmations", ui.locale)}</h3>
    <p class="desc">
      {t("settings.brew.confirmationsDesc", ui.locale)}
    </p>
    <div class="row">
      <label class="toggle">
        <input
          type="checkbox"
          checked={ui.confirmDestructive}
          onchange={(e) => ui.setConfirmDestructive((e.currentTarget as HTMLInputElement).checked)}
        />
        <span>{t("Confirm before uninstall / zap", ui.locale)}</span>
      </label>
    </div>
  </section>

  <section class="group">
    <h3>{t("Advanced", ui.locale)}</h3>
    <p class="desc">{t("settings.brew.advancedDesc.beforeCommand", ui.locale)}<code>brew</code>{t("settings.brew.advancedDesc.afterCommand", ui.locale)}</p>

    <div class="row">
      <label class="toggle">
        <input
          type="checkbox"
          checked={ui.greedyUpgrade}
          onchange={(e) => ui.setGreedyUpgrade((e.currentTarget as HTMLInputElement).checked)}
        />
        <span>{t("Greedy upgrades (include self-updating casks)", ui.locale)}</span>
      </label>
    </div>
    <p class="desc subtle">
      {t("settings.brew.greedyDesc.beforeFlag", ui.locale)}
      <code>--greedy</code>
      {t("settings.brew.greedyDesc.between", ui.locale)}
      <code>brew upgrade</code>
      {t("settings.brew.greedyDesc.afterCommand", ui.locale)}
    </p>

    <div class="row">
      <Button variant="secondary" disabled={autoremoveRunning} onclick={onAutoremoveClick}>
        {autoremoveRunning ? t("Removing…", ui.locale) : t("Autoremove unused dependencies", ui.locale)}
      </Button>
    </div>
    <p class="desc subtle">
      {t("settings.brew.autoremoveDesc.beforeCommand", ui.locale)}
      <code>brew autoremove</code>
      {t("settings.brew.autoremoveDesc.afterCommand", ui.locale)}
    </p>
  </section>
</div>

<DestructiveConfirm
  open={autoremoveConfirmOpen}
  title={t("Remove unused dependencies?", ui.locale)}
  confirmLabel={t("Autoremove", ui.locale)}
  onConfirm={runAutoremove}
  onCancel={() => (autoremoveConfirmOpen = false)}
>
  <p>
    {t("settings.brew.autoremoveConfirm.beforeCommand", ui.locale)}
    <code>brew autoremove</code>
    {t("settings.brew.autoremoveConfirm.afterCommand", ui.locale)}
  </p>
</DestructiveConfirm>

<style>
  .section { display: flex; flex-direction: column; gap: var(--space-5); max-width: 560px; }
  h2 {
    font-size: var(--text-h1);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin-bottom: var(--space-2);
  }
  .group { display: flex; flex-direction: column; gap: var(--space-2); }
  h3 {
    font-size: var(--text-h2);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
  }
  .desc {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
  }
  .desc code {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    background: var(--color-surface-sunken);
    padding: 1px 4px;
    border-radius: var(--radius-sm);
  }
  .desc.subtle {
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    margin-top: calc(-1 * var(--space-1));
  }
  .row {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-2) 0;
  }
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    cursor: pointer;
    font-size: var(--text-body);
    color: var(--color-text-primary);
  }
  .toggle input[type="checkbox"] {
    width: 16px;
    height: 16px;
    accent-color: var(--color-brand);
    cursor: pointer;
  }
  .toggle input[type="checkbox"]:disabled { cursor: wait; }
  .status {
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    font-style: italic;
  }
  .status--err { color: var(--color-danger); font-style: normal; }
  .err {
    font-size: var(--text-body-sm);
    color: var(--color-danger);
    background: var(--color-danger-subtle);
    border: 1px solid var(--color-danger);
    border-radius: var(--radius-sm);
    padding: var(--space-2) var(--space-3);
  }
</style>
