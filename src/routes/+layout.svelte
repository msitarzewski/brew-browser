<script lang="ts">
  import "../app.css";
  import { onMount } from "svelte";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import { ui, watchSystemTheme } from "$lib/stores/ui.svelte";
  import { startEnvProbe, startOnboardingGate } from "$lib/stores/env.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { github } from "$lib/stores/github.svelte";
  import { startRuntimeLocalization } from "$lib/i18n/runtime";

  let { children } = $props();

  onMount(() => {
    ui.loadLocalePreferenceFromStorage();
    const stopLocalization = startRuntimeLocalization(ui.locale);
    ui.loadThemeFromStorage();
    // Settings (Phase 12b) — all read with enum/numeric validation so a
    // corrupt or hostile localStorage entry can't poison runtime state.
    ui.loadDefaultSectionFromStorage();
    ui.loadVibrancyMaterialFromStorage();
    ui.loadConfirmDestructiveFromStorage();
    ui.loadGreedyUpgradeFromStorage();
    ui.loadActivitySettingsFromStorage();
    ui.loadSidebarCollapsedFromStorage();
    activity.hydrate();
    // Phase 12d — hydrate the persisted settings.json into the renderer
    // so the Network section, the Catalog stale banner, and the cask
    // icon mode all read from one source of truth.
    //
    // After settings load, hydrate the persisted vulnerability cache so the
    // Dashboard Exposure card + the sidebar count badge reflect the last scan
    // on first paint — instead of looking "never scanned" every launch. This
    // is cache-cheap: scanIfNeeded → scanAll(false) hits the backend's
    // fingerprint-skip and returns the on-disk `vulns_cache.json` report
    // without re-running `brew vulns` when the install set is unchanged. It's
    // gated internally on the opt-in toggle (no-op + no network when off), and
    // it's fire-and-forget so it never blocks launch. See `vulns_cache.json`.
    void settings.load().then(() => {
      void vulnerabilities.scanIfNeeded().catch(() => {});
      // Hydrate GitHub sign-in status so the Dashboard GitHub card + toolbar
      // chip reflect a signed-in user on first paint. Previously this was
      // deliberately NOT done — the worry was that reading the Keychain
      // prompts on every launch. That only holds for unsigned `tauri dev`
      // builds, whose code identity churns each rebuild. For a signed release
      // the Keychain ACL is bound to the Developer-ID designated requirement
      // (stable across app updates), so a signed-in user's read is SILENT, and
      // a never-signed-in user's read finds nothing and shows no prompt.
      // Gated on the GitHub toggle + paranoid/offline so a user who hasn't
      // enabled GitHub never triggers a Keychain read. Fire-and-forget.
      if (settings.effective.githubEnabled && !settings.effective.paranoidMode) {
        void github.loadStatus().catch(() => {});
      }
    });
    // Prime the services list so the sidebar's "Services" badge can show a
    // count from first paint; the Services tab refreshes again on mount.
    void services.load();

    // Native macOS menu bridge — Rust emits `menu:about` / `menu:settings`
    // when the user picks those items from the App menu in the system menu
    // bar; we just open the corresponding modal. The Cmd+, accelerator is
    // also bound on the Settings menu item so both surfaces stay in sync
    // with the in-app shortcut already handled in `+page.svelte`.
    let unlistenAbout: UnlistenFn | undefined;
    let unlistenSettings: UnlistenFn | undefined;
    void listen("menu:about", () => { ui.openAbout(); }).then((u) => { unlistenAbout = u; });
    void listen("menu:settings", () => { ui.openSettings(); }).then((u) => { unlistenSettings = u; });

    const unwatch = watchSystemTheme(() => ui.theme);
    const stopProbe = startEnvProbe();
    // Missing-Homebrew onboarding gate: one system_status probe, then a
    // 2 s brew_redetect poll while brew is missing. `+page.svelte` swaps
    // the shell for OnboardingView via `env.brewMissing`.
    const stopOnboarding = startOnboardingGate();
    return () => {
      unwatch();
      stopProbe();
      stopOnboarding();
      stopLocalization();
      unlistenAbout?.();
      unlistenSettings?.();
    };
  });
</script>

<!--
  Window dragging in Tauri 2 with titleBarStyle: "Overlay" is wired via the
  `data-tauri-drag-region` attribute on regular DOM elements (Sidebar brand
  area + each panel-head). Tauri's WebView handles click-vs-drag detection
  natively, so interactive children inside drag regions still receive their
  clicks. Avoids the fixed-overlay pattern (which intercepts scroll-wheel
  events at the top of the window).
-->

{@render children()}
