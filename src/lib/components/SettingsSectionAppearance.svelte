<script lang="ts">
  /**
   * SettingsSectionAppearance.svelte — Phase 12b
   *
   * Theme radio (Light/Dark/System), default landing dropdown, vibrancy
   * material dropdown. All settings persist via `ui.svelte.ts`
   * localStorage helpers.
   */

  import Sun from "@lucide/svelte/icons/sun";
  import Moon from "@lucide/svelte/icons/moon";
  import Monitor from "@lucide/svelte/icons/monitor";

  import { ui, VIBRANCY_MATERIALS, type VibrancyMaterial } from "$lib/stores/ui.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { t, type LocalePreference, type MessageKey } from "$lib/i18n/messages";
  import type { SidebarSection, ThemePreference } from "$lib/types";

  /** Sections the user can pick as their default landing page. Mirrors the
      sidebar nav order, plus Dashboard which lives in the brand button. */
  const SECTIONS: { value: SidebarSection; labelKey: MessageKey }[] = [
    { value: "dashboard", labelKey: "nav.dashboard" },
    { value: "library", labelKey: "nav.library" },
    { value: "discover", labelKey: "nav.discover" },
    { value: "trending", labelKey: "nav.trending" },
    { value: "snapshots", labelKey: "nav.snapshots" },
    { value: "services", labelKey: "nav.services" },
    { value: "activity", labelKey: "nav.activity" },
  ];

  const LANGUAGES: { value: LocalePreference; labelKey: MessageKey }[] = [
    { value: "system", labelKey: "language.system" },
    { value: "en", labelKey: "language.english" },
    { value: "ru", labelKey: "language.russian" },
  ];

  function onSectionChange(e: Event) {
    const value = (e.currentTarget as HTMLSelectElement).value as SidebarSection;
    ui.setDefaultSection(value);
  }
  function onVibrancyChange(e: Event) {
    const value = (e.currentTarget as HTMLSelectElement).value as VibrancyMaterial;
    ui.setVibrancyMaterial(value);
  }
  function onLanguageChange(e: Event) {
    const value = (e.currentTarget as HTMLSelectElement).value as LocalePreference;
    ui.setLocalePreference(value);
    window.location.reload();
  }
  function pickTheme(t: ThemePreference) { ui.setTheme(t); }

  // Phase 13 — AI Features master toggle. Saved through the persisted
  // Settings store (settings.json), not localStorage, so it survives
  // reinstalls and matches the rest of the settings.json surface.
  async function onAiFeaturesChange(e: Event) {
    const checked = (e.currentTarget as HTMLInputElement).checked;
    await settings.save({ aiFeaturesEnabled: checked });
  }
</script>

<div class="section">
  <h2>{t("Appearance", ui.locale)}</h2>

  <div class="field">
    <label for="theme-group">{t("Theme", ui.locale)}</label>
    <div id="theme-group" class="radio-row" role="radiogroup" aria-label={t("Theme", ui.locale)}>
      <button
        type="button"
        class="radio-btn"
        class:on={ui.theme === "light"}
        role="radio"
        aria-checked={ui.theme === "light"}
        onclick={() => pickTheme("light")}
      >
        <Sun size={14} /> {t("theme.light", ui.locale)}
      </button>
      <button
        type="button"
        class="radio-btn"
        class:on={ui.theme === "dark"}
        role="radio"
        aria-checked={ui.theme === "dark"}
        onclick={() => pickTheme("dark")}
      >
        <Moon size={14} /> {t("theme.dark", ui.locale)}
      </button>
      <button
        type="button"
        class="radio-btn"
        class:on={ui.theme === "system"}
        role="radio"
        aria-checked={ui.theme === "system"}
        onclick={() => pickTheme("system")}
      >
        <Monitor size={14} /> {t("theme.system", ui.locale)}
      </button>
    </div>
    <p class="hint">{t("Follows the macOS theme when set to System.", ui.locale)}</p>
  </div>

  <div class="field">
    <label for="language">{t("language.label", ui.locale)}</label>
    <select
      id="language"
      class="select"
      value={ui.localePreference}
      onchange={onLanguageChange}
    >
      {#each LANGUAGES as opt (opt.value)}
        <option value={opt.value}>{t(opt.labelKey, ui.locale)}</option>
      {/each}
    </select>
    <p class="hint">{t("language.hint.reload", ui.locale)}</p>
  </div>

  <div class="field">
    <label for="default-section">{t("Default landing", ui.locale)}</label>
    <select
      id="default-section"
      class="select"
      value={ui.defaultSection}
      onchange={onSectionChange}
    >
      {#each SECTIONS as opt (opt.value)}
        <option value={opt.value}>{t(opt.labelKey, ui.locale)}</option>
      {/each}
    </select>
    <p class="hint">{t("Which section opens when you launch brew-browser.", ui.locale)}</p>
  </div>

  <div class="field">
    <label for="vibrancy-material">{t("Window vibrancy", ui.locale)}</label>
    <select
      id="vibrancy-material"
      class="select"
      value={ui.vibrancyMaterial}
      onchange={onVibrancyChange}
    >
      {#each VIBRANCY_MATERIALS as m (m)}
        <option value={m}>{m}</option>
      {/each}
    </select>
    <p class="hint">{t("Requires app restart to take effect. The default (HudWindow) matches the rest of macOS.", ui.locale)}</p>
  </div>

  <div class="field ai-features">
    <div class="ai-row">
      <label for="ai-features-toggle">{t("AI features", ui.locale)}</label>
      <input
        id="ai-features-toggle"
        type="checkbox"
        class="toggle"
        checked={settings.effective.aiFeaturesEnabled}
        onchange={onAiFeaturesChange}
        disabled={settings.loading}
      />
    </div>
    <p class="hint">
      {t("When on, brew-browser shows extra metadata generated at build time by AI: friendly names, expanded descriptions, use cases, similar package suggestions, and category tags.", ui.locale)}
      <strong>{t("Zero LLM calls are made from your machine", ui.locale)}</strong>
      {t("— all enrichment is baked into the app binary.", ui.locale)}
    </p>
    <p class="hint">
      {t("When off, only Homebrew's native metadata appears. Categories (sidebar tile grid, donut chart, chip filters) are also hidden because they're AI-generated.", ui.locale)}
    </p>
  </div>
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
  .hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-snug);
  }
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
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .radio-btn:hover { color: var(--color-text-primary); }
  .radio-btn.on {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    box-shadow: var(--shadow-xs);
  }
  .select {
    width: 100%;
    max-width: 260px;
    padding: 6px var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    font-family: var(--font-sans);
    cursor: pointer;
  }
  .select:focus-visible {
    outline: none;
    border-color: var(--color-border-focus);
    box-shadow: var(--shadow-focus-ring);
  }

  /* Phase 13 — AI features row.
     Single line: label on the left, checkbox-as-switch on the right.
     Two paragraphs of hint text below explain the consequence and
     reassure on the local-only posture. */
  .ai-features { gap: var(--space-2); }
  .ai-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    max-width: 480px;
  }
  .ai-row label { margin: 0; }
  .toggle {
    appearance: none;
    -webkit-appearance: none;
    width: 36px;
    height: 20px;
    border-radius: var(--radius-full);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    position: relative;
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
    flex: none;
  }
  .toggle::before {
    content: "";
    position: absolute;
    top: 1px;
    left: 1px;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-full);
    background: var(--color-text-secondary);
    transition: transform var(--motion-duration-fast) var(--motion-ease-out),
                background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .toggle:checked {
    background: var(--color-brand);
    border-color: var(--color-brand);
  }
  .toggle:checked::before {
    transform: translateX(16px);
    background: var(--color-text-inverse, white);
  }
  .toggle:disabled { opacity: 0.5; cursor: default; }
  .toggle:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 2px;
  }
</style>
