<script lang="ts">
  /**
   * SettingsSectionActivity.svelte — Phase 12b
   *
   * Two clamped number inputs for the localStorage-backed Activity
   * retention caps. Clamping happens in `ui.setActivity*` so a hostile
   * or broken localStorage entry can't ask the activity store to keep
   * "999999999 jobs". Existing retained data is left alone when the
   * limits change — the store applies the new caps as it grows.
   */

  import {
    ui,
    ACTIVITY_MAX_JOBS_MIN,
    ACTIVITY_MAX_JOBS_MAX,
    ACTIVITY_MAX_JOBS_DEFAULT,
    ACTIVITY_MAX_LINES_MIN,
    ACTIVITY_MAX_LINES_MAX,
    ACTIVITY_MAX_LINES_DEFAULT,
  } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";

  function onJobsChange(e: Event) {
    const v = Number((e.currentTarget as HTMLInputElement).value);
    ui.setActivityMaxJobs(v);
  }
  function onLinesChange(e: Event) {
    const v = Number((e.currentTarget as HTMLInputElement).value);
    ui.setActivityMaxLines(v);
  }
</script>

<div class="section">
  <h2>{t("Activity", ui.locale)}</h2>

  <div class="field">
    <label for="max-jobs">{t("Keep last N completed jobs", ui.locale)}</label>
    <input
      id="max-jobs"
      type="number"
      class="num"
      min={ACTIVITY_MAX_JOBS_MIN}
      max={ACTIVITY_MAX_JOBS_MAX}
      step="1"
      value={ui.activityMaxJobs}
      onchange={onJobsChange}
    />
    <p class="hint">
      {t("settings.activity.rangeDefault", ui.locale, {
        min: ACTIVITY_MAX_JOBS_MIN,
        max: ACTIVITY_MAX_JOBS_MAX,
        default: ACTIVITY_MAX_JOBS_DEFAULT,
      })}
    </p>
  </div>

  <div class="field">
    <label for="max-lines">{t("Lines per job", ui.locale)}</label>
    <input
      id="max-lines"
      type="number"
      class="num"
      min={ACTIVITY_MAX_LINES_MIN}
      max={ACTIVITY_MAX_LINES_MAX}
      step="50"
      value={ui.activityMaxLines}
      onchange={onLinesChange}
    />
    <p class="hint">
      {t("settings.activity.rangeDefault", ui.locale, {
        min: ACTIVITY_MAX_LINES_MIN,
        max: ACTIVITY_MAX_LINES_MAX,
        default: ACTIVITY_MAX_LINES_DEFAULT,
      })}
    </p>
  </div>

  <p class="note">
    {t("settings.activity.retentionNote", ui.locale)}
  </p>
</div>

<style>
  .section { display: flex; flex-direction: column; gap: var(--space-5); max-width: 520px; }
  h2 {
    font-size: var(--text-h1);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin-bottom: var(--space-2);
  }
  .field { display: flex; flex-direction: column; gap: var(--space-2); }
  label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
  .num {
    width: 120px;
    padding: 6px var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    font-family: var(--font-mono);
    text-align: right;
  }
  .num:focus-visible {
    outline: none;
    border-color: var(--color-border-focus);
    box-shadow: var(--shadow-focus-ring);
  }
  .hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-snug);
  }
  .note {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-normal);
    padding: var(--space-3);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
  }
</style>
