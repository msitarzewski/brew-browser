<script lang="ts">
  import { onMount } from "svelte";
  import Sun from "@lucide/svelte/icons/sun";
  import Moon from "@lucide/svelte/icons/moon";
  import Monitor from "@lucide/svelte/icons/monitor";
  import SettingsIcon from "@lucide/svelte/icons/settings";
  import Heart from "@lucide/svelte/icons/heart";
  import Check from "@lucide/svelte/icons/check";
  import GithubMarkIcon from "./GithubMarkIcon.svelte";

  import { ui } from "$lib/stores/ui.svelte";
  import { github } from "$lib/stores/github.svelte";
  import { t } from "$lib/i18n/messages";
  import { safeOpenUrl } from "$lib/util/url";
  import { SPONSOR_URL } from "$lib/util/donate";
  import type { ThemePreference } from "$lib/types";

  /**
   * Title-bar right cluster: theme dropdown + Settings + Donate, grouped
   * as one rounded pill in the top-right of the window title bar. The
   * theme picker is a single button showing the current theme icon; click
   * opens a small popover with Light / Dark / System.
   */

  let themeOpen = $state(false);
  let themeBtn: HTMLButtonElement | undefined = $state();
  let themePopover: HTMLDivElement | undefined = $state();

  function activeIcon(t: ThemePreference) {
    return t === "light" ? Sun : t === "dark" ? Moon : Monitor;
  }
  function activeLabel(theme: ThemePreference) {
    return theme === "light"
      ? t("theme.light", ui.locale)
      : theme === "dark"
        ? t("theme.dark", ui.locale)
        : t("theme.system", ui.locale);
  }

  let ActiveIcon = $derived(activeIcon(ui.theme));

  function pickTheme(t: ThemePreference) {
    ui.setTheme(t);
    themeOpen = false;
  }

  function onDocClick(e: MouseEvent) {
    if (!themeOpen) return;
    const t = e.target as Node | null;
    if (t && !themeBtn?.contains(t) && !themePopover?.contains(t)) {
      themeOpen = false;
    }
  }
  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape" && themeOpen) {
      themeOpen = false;
      themeBtn?.focus();
    }
  }

  function openSponsor() { void safeOpenUrl(SPONSOR_URL); }

  /** GitHub connection status indicator state.
   *
   * Visible only when signed in (signed-out users don't need a chip
   * reminding them they're not connected — the Settings panel is the
   * place to discover the feature). Three colored states:
   *
   * - `ok` (green): signed in, has `public_repo` scope, all authed
   *   actions (star/watch/file-issue) will work
   * - `scope-incomplete` (amber): signed in, but `public_repo` is
   *   missing from the recorded scopes — every authed action will
   *   reject with ScopeRequired. Surfaces the issue-#1-companion bug
   *   we just fixed: GitHub's `/oauth/access_token` returns scopes
   *   comma-separated, the v0.2.1 parser was using split_whitespace
   *   which produced a single-element array that didn't match the
   *   `== "public_repo"` check in the action gate
   * - hidden: not signed in
   */
  type GithubChipState = "ok" | "scope-incomplete" | "hidden";
  const githubChipState = $derived.by<GithubChipState>(() => {
    const s = github.status;
    if (!s || !s.signedIn) return "hidden";
    return s.scopes.includes("public_repo") ? "ok" : "scope-incomplete";
  });

  function openGithubSettings() {
    ui.openSettings("github");
  }

  onMount(() => {
    document.addEventListener("click", onDocClick);
    window.addEventListener("keydown", onKey);

    // Eagerly load GitHub status so the connection-status chip can
    // render its color on first paint. Touches Keychain → triggers
    // the macOS ACL prompt for users who've previously signed in
    // (one-time per binary signature; "Always Allow" remembers).
    //
    // v0.3.0 follow-up: gate this on a localStorage "has-signed-in-
    // before" flag so users who never use GitHub see zero Keychain
    // prompts. For v0.2.2 ship we accept the prompt friction.
    void github.loadStatus();

    return () => {
      document.removeEventListener("click", onDocClick);
      window.removeEventListener("keydown", onKey);
    };
  });
</script>

<div class="cluster" data-tauri-drag-region="false" role="group" aria-label={t("app.controls", ui.locale)}>
  {#if githubChipState !== "hidden"}
    <button
      type="button"
      class="ctrl github-chip"
      class:ok={githubChipState === "ok"}
      class:warn={githubChipState === "scope-incomplete"}
      onclick={openGithubSettings}
      title={githubChipState === "ok"
        ? t("github.connectedAs", ui.locale, { username: github.status?.username ?? "user" })
        : t("github.scopeIncomplete", ui.locale)}
      aria-label={t("chrome.github.connectionStatus", ui.locale)}
    >
      <GithubMarkIcon size={14} />
    </button>
  {/if}
  <button
    bind:this={themeBtn}
    type="button"
    class="ctrl"
    class:open={themeOpen}
    onclick={() => (themeOpen = !themeOpen)}
    title={t("theme.title", ui.locale, { theme: activeLabel(ui.theme) })}
    aria-label={t("theme.change", ui.locale)}
    aria-haspopup="menu"
    aria-expanded={themeOpen}
  >
    <ActiveIcon size={14} />
  </button>
  <button
    type="button"
    class="ctrl"
    onclick={() => ui.openSettings()}
    title={t("settings.shortcutTitle", ui.locale)}
    aria-label={t("settings.open", ui.locale)}
  >
    <SettingsIcon size={14} />
  </button>
  <button
    type="button"
    class="ctrl donate"
    onclick={openSponsor}
    title={t("chrome.donate.title", ui.locale)}
    aria-label={t("chrome.donate.aria", ui.locale)}
  >
    <Heart size={14} fill="currentColor" />
  </button>

  {#if themeOpen}
    <div
      bind:this={themePopover}
      class="popover"
      role="menu"
      aria-label={t("theme.change", ui.locale)}
    >
      <button
        type="button"
        class="popover-item"
        class:active={ui.theme === "light"}
        role="menuitemradio"
        aria-checked={ui.theme === "light"}
        onclick={() => pickTheme("light")}
      >
        <Sun size={14} />
        <span>{t("theme.light", ui.locale)}</span>
        {#if ui.theme === "light"}<Check size={12} class="check" />{/if}
      </button>
      <button
        type="button"
        class="popover-item"
        class:active={ui.theme === "dark"}
        role="menuitemradio"
        aria-checked={ui.theme === "dark"}
        onclick={() => pickTheme("dark")}
      >
        <Moon size={14} />
        <span>{t("theme.dark", ui.locale)}</span>
        {#if ui.theme === "dark"}<Check size={12} class="check" />{/if}
      </button>
      <button
        type="button"
        class="popover-item"
        class:active={ui.theme === "system"}
        role="menuitemradio"
        aria-checked={ui.theme === "system"}
        onclick={() => pickTheme("system")}
      >
        <Monitor size={14} />
        <span>{t("theme.system", ui.locale)}</span>
        {#if ui.theme === "system"}<Check size={12} class="check" />{/if}
      </button>
    </div>
  {/if}
</div>

<style>
  /* Pill-shaped group sitting on the sidebar-colored title bar. The
     background uses the panel-body gray (--color-surface) — same as
     the main content — so the cluster reads as a soft well rather
     than a hard black pill. Hair-line dividers between buttons. */
  .cluster {
    position: relative;
    display: inline-flex;
    align-items: center;
    background: var(--color-surface);
    border-radius: var(--radius-md);
    padding: 2px;
    gap: 0;
  }
  .ctrl {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 22px;
    background: transparent;
    border-radius: var(--radius-sm);
    color: var(--color-text-muted);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out),
                color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .ctrl:hover,
  .ctrl.open {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
  }
  /* Hair-line divider between adjacent controls. */
  .ctrl + .ctrl { position: relative; }
  .ctrl + .ctrl::before {
    content: "";
    position: absolute;
    left: -1px;
    top: 4px;
    bottom: 4px;
    width: 1px;
    background: var(--color-border);
    opacity: 0.6;
  }
  /* Pink-filled heart for the Donate button. */
  .ctrl.donate { color: #ec4899; }
  .ctrl.donate:hover { color: #db2777; }

  /* GitHub connection-status chip. Green = OK, amber = scope-incomplete.
     Both shown at a slightly higher saturation than the muted default
     so they pop without being garish. */
  .ctrl.github-chip.ok { color: #16a34a; }       /* green-600 */
  .ctrl.github-chip.ok:hover { color: #15803d; } /* green-700 */
  .ctrl.github-chip.warn { color: #d97706; }      /* amber-600 */
  .ctrl.github-chip.warn:hover { color: #b45309; }/* amber-700 */

  /* Theme dropdown popover. */
  .popover {
    position: absolute;
    top: calc(100% + 4px);
    right: 0;
    min-width: 140px;
    padding: 4px;
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    box-shadow: 0 8px 24px -4px color-mix(in oklch, black 30%, transparent);
    z-index: 40;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .popover-item {
    display: grid;
    grid-template-columns: 16px 1fr 14px;
    gap: var(--space-2);
    align-items: center;
    padding: 6px 8px;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-primary);
    text-align: left;
    font-size: var(--text-body-sm);
    cursor: pointer;
  }
  .popover-item:hover { background: var(--color-surface-sunken); }
  .popover-item :global(.check) { color: var(--color-accent); }
</style>
