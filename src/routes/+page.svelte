<script lang="ts">
  import { onMount } from "svelte";

  import Sidebar from "$lib/components/Sidebar.svelte";
  import Dashboard from "$lib/components/Dashboard.svelte";
  import Library from "$lib/components/Library.svelte";
  import Discover from "$lib/components/Discover.svelte";
  import Trending from "$lib/components/Trending.svelte";
  import Snapshots from "$lib/components/Snapshots.svelte";
  import Services from "$lib/components/Services.svelte";
  import ActivityHistory from "$lib/components/ActivityHistory.svelte";
  import OnboardingView from "$lib/components/OnboardingView.svelte";
  import PackageDetail from "$lib/components/PackageDetail.svelte";
  import ResizeHandle from "$lib/components/ResizeHandle.svelte";
  import ActivityDrawer from "$lib/components/ActivityDrawer.svelte";
  import CommandPalette from "$lib/components/CommandPalette.svelte";
  import Settings from "$lib/components/Settings.svelte";
  import AboutModal from "$lib/components/AboutModal.svelte";
  import DeviceFlowModal from "$lib/components/DeviceFlowModal.svelte";
  import Toast from "$lib/components/Toast.svelte";
  import TitlebarControls from "$lib/components/TitlebarControls.svelte";
  import UpdateIndicator from "$lib/components/UpdateIndicator.svelte";
  import PanelLeftClose from "@lucide/svelte/icons/panel-left-close";
  import PanelLeftOpen from "@lucide/svelte/icons/panel-left-open";

  import { ui } from "$lib/stores/ui.svelte";
  import { DETAIL_PANE_MIN_WIDTH, DETAIL_PANE_DEFAULT_WIDTH, clampDetailPaneWidth } from "$lib/stores/ui.svelte";
  import { env } from "$lib/stores/env.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { brewfiles } from "$lib/stores/brewfiles.svelte";
  import { trending } from "$lib/stores/trending.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { search } from "$lib/stores/search.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { t, type MessageKey } from "$lib/i18n/messages";
  import type { SidebarSection, ThemePreference } from "$lib/types";

  const themeLabel: Record<ThemePreference, MessageKey> = {
    light: "theme.light",
    dark: "theme.dark",
    system: "theme.system",
  };

  function isTextInput(el: EventTarget | null): boolean {
    if (!(el instanceof HTMLElement)) return false;
    return el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable;
  }

  function onKeydown(e: KeyboardEvent) {
    const meta = e.metaKey || e.ctrlKey;

    // Cmd+K: open palette (always)
    if (meta && e.key.toLowerCase() === "k") {
      e.preventDefault();
      ui.openPalette();
      return;
    }

    // Cmd+, : open Settings (macOS preferences convention)
    if (meta && e.key === ",") {
      e.preventDefault();
      ui.openSettings();
      return;
    }

    // Cmd+Shift+L: cycle theme (must precede Cmd+L)
    if (meta && e.shiftKey && e.key.toLowerCase() === "l") {
      e.preventDefault();
      const order = ["light", "dark", "system"] as const;
      const next = order[(order.indexOf(ui.theme) + 1) % order.length];
      ui.setTheme(next);
      toast.info(t("theme.title", ui.locale, { theme: t(themeLabel[next], ui.locale) }));
      return;
    }

    // Cmd+L (no shift): toggle drawer
    if (meta && !e.shiftKey && e.key.toLowerCase() === "l") {
      e.preventDefault();
      ui.toggleDrawer();
      return;
    }

    // Cmd+0..6: section nav (0 = dashboard / home)
    if (meta && ["0","1","2","3","4","5","6"].includes(e.key)) {
      e.preventDefault();
      const map: Record<string, SidebarSection> = {
        "0": "dashboard",
        "1": "library",
        "2": "discover",
        "3": "trending",
        "4": "snapshots",
        "5": "services",
        "6": "activity",
      };
      ui.setSection(map[e.key]);
      return;
    }

    // Cmd+R: refresh current view
    if (meta && e.key.toLowerCase() === "r") {
      e.preventDefault();
      switch (ui.section) {
        case "dashboard": packages.load(true); break;
        case "library":   packages.load(true); break;
        case "trending":  trending.load(true); break;
        case "snapshots": brewfiles.load(); break;
        case "services":  services.load(true); break;
        case "discover":  if (search.query) search.run(search.query); break;
      }
      return;
    }

    // Esc: priority: settings (handles its own Esc) → palette → modal → detail.
    // Settings.svelte handles its own Esc listener with stopPropagation, so
    // we never reach this branch while Settings is open. Belt-and-suspenders
    // gate kept to make the priority intent obvious.
    if (e.key === "Escape") {
      if (ui.settingsOpen) return; // Settings handles its own Esc
      if (ui.paletteOpen) { ui.closePalette(); return; }
      if (ui.selectedPackage) { ui.closeDetail(); return; }
    }

    // "/": focus the in-view filter input (unless typing)
    if (e.key === "/" && !isTextInput(e.target)) {
      const input = document.querySelector<HTMLInputElement>('input[type="text"], input[type="search"], input:not([type])');
      if (input) {
        e.preventDefault();
        input.focus();
      }
    }
  }

  // Recompute the live max (60% of window) on window resize so a previously
  // valid width gets clamped back into range if the user shrinks the window.
  let windowWidth = $state(typeof window === "undefined" ? 1100 : window.innerWidth);
  let detailPaneMax = $derived(Math.max(DETAIL_PANE_MIN_WIDTH, Math.floor(windowWidth * 0.6)));

  onMount(() => {
    window.addEventListener("keydown", onKeydown);
    ui.loadDetailPaneWidthFromStorage();
    const onResize = () => {
      windowWidth = window.innerWidth;
      // Re-clamp current width against the new window dimensions.
      const clamped = clampDetailPaneWidth(ui.detailPaneWidth);
      if (clamped !== ui.detailPaneWidth) ui.setDetailPaneWidth(clamped);
    };
    window.addEventListener("resize", onResize);
    return () => {
      window.removeEventListener("keydown", onKeydown);
      window.removeEventListener("resize", onResize);
    };
  });
</script>

<div class="app" class:sidebar-collapsed={ui.sidebarCollapsed}>
  <!--
    Window title bar. Spans the full width above the main split so it
    reads as one unified chrome (the Mac unified-toolbar pattern).
    Layout:
      • macOS-rendered traffic lights overlay the far left (~80 px)
      • Sidebar toggle sits just inside the sidebar's right edge when
        expanded; when collapsed, it slides over next to the traffic
        lights (the sidebar can't fit a button at 56 px wide).
      • Page title sits just past where the sidebar divider lands so it
        aligns with the main content column.
    Both the toggle and the title slide via CSS custom properties driven
    by the `.sidebar-collapsed` class on `.app`, so transitions are smooth.
  -->
  <header class="titlebar" data-tauri-drag-region>
    <button
      type="button"
      class="titlebar-btn"
      data-tauri-drag-region="false"
      title={ui.sidebarCollapsed ? t("nav.showSidebar", ui.locale) : t("nav.hideSidebar", ui.locale)}
      aria-label={ui.sidebarCollapsed ? t("nav.showSidebar", ui.locale) : t("nav.hideSidebar", ui.locale)}
      aria-pressed={ui.sidebarCollapsed}
      onclick={() => ui.toggleSidebarCollapsed()}
    >
      {#if ui.sidebarCollapsed}
        <PanelLeftOpen size={16} />
      {:else}
        <PanelLeftClose size={16} />
      {/if}
    </button>
    <h1 class="titlebar-title">{ui.pageTitle}</h1>
    <div class="titlebar-right">
      <UpdateIndicator />
      <TitlebarControls />
    </div>
  </header>
  <div class="main">
    {#if env.brewMissing}
      <!-- Onboarding gate: brew is confirmed missing — replace the whole
           shell (sidebar + sections + detail pane) with the setup view.
           The env store polls brew_redetect every 2 s and flips this off
           (plus loads the library) the moment the install lands. -->
      <OnboardingView />
    {:else}
      <Sidebar />
      <main class="content">
        {#key ui.section}
          <div class="section-pane">
            {#if ui.section === "dashboard"}
              <Dashboard />
            {:else if ui.section === "library"}
              <Library />
            {:else if ui.section === "discover"}
              <Discover />
            {:else if ui.section === "trending"}
              <Trending />
            {:else if ui.section === "snapshots"}
              <Snapshots />
            {:else if ui.section === "services"}
              <Services />
            {:else if ui.section === "activity"}
              <ActivityHistory />
            {/if}
          </div>
        {/key}
      </main>
      {#if ui.selectedPackage}
        <ResizeHandle
          width={ui.detailPaneWidth}
          min={DETAIL_PANE_MIN_WIDTH}
          max={detailPaneMax}
          defaultWidth={DETAIL_PANE_DEFAULT_WIDTH}
          direction="left"
          label={t("Resize package detail panel", ui.locale)}
          onChange={(w) => (ui.detailPaneWidth = w)}
          onCommit={(w) => ui.setDetailPaneWidth(w)}
        />
        <PackageDetail />
      {/if}
    {/if}
  </div>
  <ActivityDrawer />
  <CommandPalette />
  <Settings />
  <AboutModal />
  <DeviceFlowModal />
  <Toast />
</div>

<style>
  .app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--color-surface);
    /* Title bar layout knobs — driven by sidebar state. */
    --titlebar-toggle-left: 168px;  /* inside sidebar's right edge (200 − 32) */
    --titlebar-title-left: 220px;   /* just past the sidebar divider */
  }
  .app.sidebar-collapsed {
    --titlebar-toggle-left: 84px;   /* just past the traffic lights */
    --titlebar-title-left: 124px;   /* just past the toggle */
  }
  /* Window-level title bar. Same chrome color as the sidebar so the
     two read as one continuous L-shaped frame around the main content.
     Height tuned with `trafficLightPosition` (tauri.conf.json) so the
     macOS-rendered traffic lights end up vertically centered on the
     same horizontal axis as the toggle and the page title. */
  .titlebar {
    flex: none;
    height: 36px;
    position: relative;
    background: var(--color-surface-raised);
    border-bottom: 1px solid var(--color-border);
  }
  /* Toggle slides between two positions via CSS variables. */
  .titlebar-btn {
    position: absolute;
    top: 50%;
    left: var(--titlebar-toggle-left);
    transform: translateY(-50%);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    background: transparent;
    border-radius: var(--radius-md);
    color: var(--color-text-muted);
    cursor: pointer;
    transition: left var(--motion-duration-base, 180ms) var(--motion-ease-out, ease),
                background-color var(--motion-duration-fast) var(--motion-ease-out),
                color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .titlebar-btn:hover {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }
  .titlebar-btn:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand));
    outline-offset: 2px;
  }
  /* Page title also slides so it stays aligned with the start of the
     main content column (just past the sidebar divider). */
  .titlebar-title {
    position: absolute;
    top: 50%;
    left: var(--titlebar-title-left);
    transform: translateY(-50%);
    margin: 0;
    font-size: var(--text-h3);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    white-space: nowrap;
    transition: left var(--motion-duration-base, 180ms) var(--motion-ease-out, ease);
    /* Don't intercept the draggable region: clicks on the title still
       let the user drag the window. */
    pointer-events: none;
  }
  @media (prefers-reduced-motion: reduce) {
    .titlebar-btn, .titlebar-title { transition: none; }
  }
  /* Right-side button cluster — theme dropdown + Settings + Donate.
     Now that the title bar's right half is otherwise empty, this is
     the natural Mac spot for app controls (Mail's right-side toolbar
     uses the same alignment). Nudged 1 px below center to align
     optically with the macOS traffic lights on the left. */
  .titlebar-right {
    position: absolute;
    top: 50%;
    /* Align the cluster's right edge with the main panel's content
       right edge. Panel-head and body both use var(--space-4) of
       horizontal padding, so matching it here lines everything up. */
    right: var(--space-4);
    transform: translateY(calc(-50% + 1px));
    display: flex;
    align-items: center;
    /* 8 px between the optional UpdateIndicator pill and the
       TitlebarControls cluster (Phase 15). The indicator hides
       entirely when there's no update available, so the gap is
       absorbed by the layout — no empty space when nothing to show. */
    gap: 8px;
  }
  .main {
    flex: 1;
    display: flex;
    min-height: 0;
    overflow: hidden;
  }
  .content {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
    overflow: hidden;
  }
  /* Quiet crossfade when switching sidebar sections.
     Tabs are peers, so we fade content rather than slide (designSystem §6). */
  .section-pane {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-height: 0;
    animation: section-in var(--motion-duration-base) var(--motion-ease-out);
  }
  @keyframes section-in {
    from { opacity: 0; }
    to   { opacity: 1; }
  }
  @media (prefers-reduced-motion: reduce) {
    .section-pane { animation: none; }
  }
</style>
