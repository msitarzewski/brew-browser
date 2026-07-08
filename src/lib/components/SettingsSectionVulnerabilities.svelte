<script lang="ts">
  /**
   * SettingsSectionVulnerabilities.svelte — v0.5.0
   *
   * Sibling of SettingsSectionTrendingHistory / SettingsSectionUpdates:
   * embedded near the bottom of SettingsSectionNetwork. The opt-in
   * toggle for the `brew vulns`-backed vulnerability scan path.
   *
   * Why a separate section? The scan path crosses TWO distinct trust
   * boundaries vs the always-on Homebrew analytics:
   *   - OSV.dev (Google) — the underlying advisory feed `brew vulns`
   *     consults.
   *   - api.github.com (when GitHub auth is enabled) — secondary
   *     enrichment for GHSA-id details.
   * The disclosure copy makes both explicit so users opt in knowingly.
   *
   * Five visible states:
   *   1. Off (default) — short paragraph + toggle. No buttons.
   *   2. On, helper not installed (detected via `vulns_not_installed`
   *      error) — install affordance: "Install brew-vulns" button.
   *   3. On, installed, no scan yet — "Scan now" button +
   *      "Last scan: never".
   *   4. On, installed, after scan — status line with vuln counts +
   *      "Scan now" (refresh). Positive state when zero findings.
   *   5. On, lastScanError set — danger callout under the buttons.
   *
   * Detection of "is brew-vulns installed?" is implicit — the store
   * exposes the backend `vulns_not_installed` code as a typed signal;
   * otherwise we assume installed once any scan has completed.
   *
   * Offline Mode (paranoid_mode) hard-locks the feature even when the
   * toggle is on — same gating contract as TrendingHistory.
   */

  import ShieldAlert from "@lucide/svelte/icons/shield-alert";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Loader from "@lucide/svelte/icons/loader-2";
  import Download from "@lucide/svelte/icons/download";
  import CheckCircle from "@lucide/svelte/icons/check-circle-2";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";

  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { reportableToastError } from "$lib/util/reportIssue";
  import { ruPlural, t } from "$lib/i18n/messages";

  /** Offline Mode locks the feature off regardless of toggle state. */
  let offline = $derived(settings.effective.paranoidMode);

  /** Effective toggle state — used for visual + disclosure logic. */
  let on = $derived(settings.effective.vulnerabilityScanningEnabled);

  /** Whether the last scan failed because the `brew vulns` subcommand
      isn't installed. Drives the install-affordance swap. The store
      exposes the backend error code so this state is locale-neutral. */
  let helperMissing = $derived(
    vulnerabilities.lastScanErrorCode === "vulns_not_installed",
  );

  /** True once we've completed at least one scan without a
      `vulns_not_installed` error — implies brew-vulns is present. */
  let helperConfirmedInstalled = $derived(
    vulnerabilities.lastScannedAt !== null && !helperMissing,
  );

  /** Local flag for the install button so we can show a spinner while
      the brew install runs. The store doesn't track helper-install
      progress — that's a UI-local concern. */
  let installing = $state(false);

  let counts = $derived(vulnerabilities.severityCounts);
  let lastScannedAt = $derived(vulnerabilities.lastScannedAt);
  let scanSource = $derived(vulnerabilities.source);

  /** Relative-time formatter for "Last scan: 3 minutes ago". Avoids
      pulling in dayjs/date-fns just for this — Intl handles it. */
  function relativeTime(d: Date | null): string {
    if (!d) return ui.locale === "ru" ? "никогда" : "never";
    const formatter = new Intl.RelativeTimeFormat(ui.locale === "ru" ? "ru" : undefined, { numeric: "auto" });
    const deltaSec = Math.round((d.getTime() - Date.now()) / 1000);
    const abs = Math.abs(deltaSec);
    if (abs < 60) return formatter.format(deltaSec, "second");
    if (abs < 3600) return formatter.format(Math.round(deltaSec / 60), "minute");
    if (abs < 86400) return formatter.format(Math.round(deltaSec / 3600), "hour");
    return formatter.format(Math.round(deltaSec / 86400), "day");
  }

  let lastScanLabel = $derived(relativeTime(lastScannedAt));

  function vulnPackagesNoun(count: number): string {
    if (ui.locale !== "ru") return `package${count === 1 ? "" : "s"} with known vulnerabilities`;
    return `${ruPlural(count, "пакет", "пакета", "пакетов")} с известными уязвимостями`;
  }

  async function onToggle(e: Event) {
    const next = (e.currentTarget as HTMLInputElement).checked;
    await settings.save({ vulnerabilityScanningEnabled: next });
    if (next && !vulnerabilities.lastScannedAt) {
      // First enable → kick off an auto-scan so the UI is populated
      // by the time the user looks at the Dashboard or Library.
      await vulnerabilities.scanAll(false);
    }
    if (!next) {
      vulnerabilities.clear();
    }
  }

  async function onScanNow() {
    await vulnerabilities.scanAll(true);
  }

  async function onInstallHelper() {
    if (installing) return;
    installing = true;
    try {
      await vulnerabilities.installHelper();
      toast.success(
        t("settings.vulnerabilities.helperInstalledTitle", ui.locale),
        t("settings.vulnerabilities.initialScanBody", ui.locale),
      );
      // Helper is now present — kick a forced scan so the empty state
      // flips to real data immediately.
      await vulnerabilities.scanAll(true);
    } catch (e) {
      reportableToastError(t("settings.vulnerabilities.installFailedTitle", ui.locale), e);
    } finally {
      installing = false;
    }
  }
</script>

<div class="section">
  <h2>
    <ShieldAlert size={18} aria-hidden="true" />
    {t("Vulnerability Scanning", ui.locale)}
  </h2>

  <div class="field">
    <label
      class="toggle"
      title={offline ? t("Disabled by Offline Mode", ui.locale) : undefined}
    >
      <input
        type="checkbox"
        checked={on}
        onchange={onToggle}
        disabled={offline || settings.loading || settings.corruptOnDisk}
        aria-describedby="vuln-scan-hint"
      />
      <span class="toggle-track" aria-hidden="true"></span>
      <span class="toggle-label">{t("Scan installed packages for known vulnerabilities", ui.locale)}</span>
    </label>

    <p class="hint" id="vuln-scan-hint">
      {t("settings.vulnerabilities.privacyHint", ui.locale)}
    </p>

    {#if offline}
      <p class="hint hint-warn">
        {t("settings.vulnerabilities.offlineHint", ui.locale)}
      </p>
    {/if}
  </div>

  <!-- Action area, only relevant when the feature is on and Offline
       Mode isn't blocking. Renders one of three sub-states: install
       affordance, ready-to-scan, or post-scan status. -->
  {#if on && !offline}
    {#if helperMissing}
      <!-- State 2: helper not installed. -->
      <div class="callout install" role="region" aria-label={t("Install brew-vulns", ui.locale)}>
        <div class="callout-head">
          <TriangleAlert size={16} />
          <strong>{t("The brew-vulns subcommand isn't installed.", ui.locale)}</strong>
        </div>
        <p class="callout-body">
          {t("settings.vulnerabilities.installPrompt", ui.locale)}
        </p>
        <div class="row">
          <button
            type="button"
            class="btn-primary"
            onclick={onInstallHelper}
            disabled={installing}
          >
            {#if installing}
              <span class="spin"><Loader size={14} /></span>
              {t("Installing…", ui.locale)}
            {:else}
              <Download size={14} />
              {t("Install brew-vulns", ui.locale)}
            {/if}
          </button>
        </div>
      </div>
    {:else}
      <!-- States 3 + 4: idle (never scanned) or post-scan status. -->
      <div class="field">
        <div class="row">
          <button
            type="button"
            class="btn-secondary"
            onclick={onScanNow}
            disabled={vulnerabilities.loading}
            title={t("settings.vulnerabilities.scanAllTitle", ui.locale)}
          >
            {#if vulnerabilities.loading}
              <span class="spin"><Loader size={14} /></span>
              {t("Scanning…", ui.locale)}
            {:else}
              <RefreshCw size={14} />
              {t("Scan now", ui.locale)}
            {/if}
          </button>
          <span class="meta">{t("settings.vulnerabilities.lastScan", ui.locale)}: {lastScanLabel}</span>
        </div>

        {#if helperConfirmedInstalled}
          {#if counts.vulnerablePackages === 0 && counts.total === 0}
            <!-- Clean result: positive framing, this is the GOOD case. -->
            <div class="callout clean" role="status">
              <CheckCircle size={16} />
              <span>
                {t("settings.vulnerabilities.cleanResult", ui.locale)}
                {#if scanSource}
                  <span class="meta-inline">({t("source", ui.locale)}: {scanSource})</span>
                {/if}
              </span>
            </div>
          {:else}
            <!-- Found some. Break out by severity tier. -->
            <p class="status-line">
              <strong>{counts.vulnerablePackages}</strong>
              {vulnPackagesNoun(counts.vulnerablePackages)} ·
              <span class="sev sev-danger">{counts.critical} {ui.locale === "ru" ? ruPlural(counts.critical, "критическая", "критические", "критических") : "critical"}</span> ·
              <span class="sev sev-danger">{counts.high} {ui.locale === "ru" ? ruPlural(counts.high, "высокая", "высокие", "высоких") : "high"}</span> ·
              <span class="sev sev-warning">{counts.medium} {ui.locale === "ru" ? ruPlural(counts.medium, "средняя", "средние", "средних") : "medium"}</span> ·
              <span class="sev sev-info">{counts.low} {ui.locale === "ru" ? ruPlural(counts.low, "низкая", "низкие", "низких") : "low"}</span>
              {#if counts.unknown > 0}
                · <span class="sev sev-neutral">{counts.unknown} {ui.locale === "ru" ? ruPlural(counts.unknown, "неизвестная", "неизвестные", "неизвестных") : "unknown"}</span>
              {/if}
              {#if scanSource}
                <span class="meta-inline">· {t("source", ui.locale)}: {scanSource}</span>
              {/if}
            </p>
          {/if}
        {/if}
      </div>
    {/if}

    <!-- Surface the last error (other than `vulns_not_installed`,
         which has its own affordance above). -->
    {#if vulnerabilities.lastScanError && !helperMissing}
      <div class="callout error" role="alert">
        <TriangleAlert size={16} />
        <span>{vulnerabilities.lastScanError}</span>
      </div>
    {/if}
  {/if}
</div>

<style>
  /* Mirrors SettingsSectionTrendingHistory: nested subsection with a
     divider on top, no second-tier H1. */
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
  .hint-warn {
    color: var(--color-warning-strong, #b45309);
  }
  .row {
    display: inline-flex;
    align-items: center;
    gap: var(--space-3);
    flex-wrap: wrap;
  }
  .meta {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
  }
  .meta-inline {
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
    margin-left: 4px;
  }
  .status-line {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
  }
  .status-line strong {
    color: var(--color-text-primary);
    font-weight: var(--fw-semibold);
  }
  .sev {
    display: inline-block;
    padding: 1px 6px;
    border-radius: var(--radius-sm);
    font-weight: var(--fw-medium);
    font-variant-numeric: tabular-nums;
  }
  .sev-danger  { background: var(--color-danger-subtle);  color: var(--color-danger-on-subtle); }
  .sev-warning { background: var(--color-warning-subtle); color: var(--color-warning-on-subtle); }
  .sev-info    { background: var(--color-info-subtle);    color: var(--color-info-on-subtle); }
  .sev-neutral { background: var(--color-surface-sunken); color: var(--color-text-secondary); }

  /* ---------- Toggle (matches Network/TrendingHistory) ---------- */
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

  /* ---------- Buttons (match Updates section pattern) ---------- */
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

  /* ---------- Callouts (install / clean / error) ---------- */
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
  .install {
    background: var(--color-warning-subtle);
    border-color: var(--color-warning-subtle);
  }
  .install .callout-head { color: var(--color-warning-on-subtle); }
  .clean {
    flex-direction: row;
    align-items: center;
    background: var(--color-success-subtle);
    border-color: var(--color-success-subtle);
    color: var(--color-success-on-subtle);
    font-size: var(--text-body-sm);
  }
  .error {
    flex-direction: row;
    align-items: center;
    background: var(--color-danger-subtle);
    border-color: var(--color-danger-subtle);
    color: var(--color-danger-on-subtle);
    font-size: var(--text-body-sm);
  }

  /* Spinner used inline in buttons. */
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
