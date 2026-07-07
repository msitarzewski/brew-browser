/**
 * UI store — current sidebar section, theme, modal/drawer state.
 * Uses Svelte 5 runes inside a module-scope class instance.
 */

import { discover } from "./discover.svelte";
import type { SettingsSection, SidebarSection, ThemePreference } from "$lib/types";
import {
  DEFAULT_LOCALE_PREFERENCE,
  isLocalePreference,
  resolveLocalePreference,
  type Locale,
  type LocalePreference,
} from "$lib/i18n/messages";

/** Default width of the package detail pane in pixels — the original fixed width. */
export const DETAIL_PANE_DEFAULT_WIDTH = 420;
/** Min allowed width — below this the actions footer crowds up. */
export const DETAIL_PANE_MIN_WIDTH = 320;
/** Storage key for the user's preferred pane width. */
const DETAIL_PANE_WIDTH_KEY = "brew-browser:detail-pane-width";

/** Storage keys for Settings-modal preferences (Phase 12b). */
const DEFAULT_SECTION_KEY = "brew-browser:default-section";
const VIBRANCY_MATERIAL_KEY = "brew-browser:vibrancy-material";
const CONFIRM_DESTRUCTIVE_KEY = "brew-browser:confirm-destructive";
const GREEDY_UPGRADE_KEY = "brew-browser:greedy-upgrade";
const ACTIVITY_MAX_JOBS_KEY = "brew-browser:activity:max-jobs";
const ACTIVITY_MAX_LINES_KEY = "brew-browser:activity:max-lines";
const SIDEBAR_COLLAPSED_KEY = "brew-browser:sidebar-collapsed";
const LOCALE_PREFERENCE_KEY = "brew-browser:locale-preference";

/** Defaults for the Activity-retention settings (Phase 12b). */
export const ACTIVITY_MAX_JOBS_DEFAULT = 50;
export const ACTIVITY_MAX_JOBS_MIN = 1;
export const ACTIVITY_MAX_JOBS_MAX = 1000;
export const ACTIVITY_MAX_LINES_DEFAULT = 500;
export const ACTIVITY_MAX_LINES_MIN = 100;
export const ACTIVITY_MAX_LINES_MAX = 10_000;

/** Known vibrancy materials per the macOS NSVisualEffectMaterial enum exposed
    by the `window-vibrancy` crate. Frozen as a const tuple so the type stays
    in sync with `setVibrancyMaterial` and the localStorage validator. */
export const VIBRANCY_MATERIALS = ["HudWindow", "Sidebar", "FullScreenUI", "Off"] as const;
export type VibrancyMaterial = (typeof VIBRANCY_MATERIALS)[number];

/** SidebarSection values we allow as "default landing" — keeps the validator
    in one place. Mirrors the `SidebarSection` union in `types.ts`. */
const DEFAULT_SECTION_VALUES = [
  "dashboard",
  "library",
  "discover",
  "trending",
  "snapshots",
  "services",
  "activity",
] as const;

function clampInt(v: number, lo: number, hi: number, fallback: number): number {
  if (!Number.isFinite(v)) return fallback;
  const n = Math.round(v);
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

/** Clamp `w` to [min, maxFromWindow]; maxFromWindow defaults to 60% of innerWidth. */
export function clampDetailPaneWidth(w: number, windowWidth?: number): number {
  const ww = windowWidth ?? (typeof window === "undefined" ? 1100 : window.innerWidth);
  const max = Math.max(DETAIL_PANE_MIN_WIDTH, Math.floor(ww * 0.6));
  if (!Number.isFinite(w)) return DETAIL_PANE_DEFAULT_WIDTH;
  return Math.min(Math.max(Math.round(w), DETAIL_PANE_MIN_WIDTH), max);
}

/** Human-readable titles shown in the window title bar for each section.
    Kept here (not in Sidebar) so the title bar can read them without
    importing the navigation array. */
const SECTION_TITLES: Record<SidebarSection, string> = {
  dashboard: "Dashboard",
  library:   "Library",
  discover:  "Discover",
  trending:  "Trending",
  snapshots: "Snapshots",
  services:  "Services",
  activity:  "Activity",
};

class UiStore {
  /** First-launch landing. Dashboard is the home screen; clicking the sidebar
      brand returns here. Other sections live below it in the nav. */
  section: SidebarSection = $state("dashboard");

  /** The active section's display name — shown in the window title bar
      (the panel-head `<h1>` was removed in favour of the title bar). */
  pageTitle = $derived(SECTION_TITLES[this.section]);
  drawerOpen: boolean = $state(false);
  drawerMinimized: boolean = $state(false);
  paletteOpen: boolean = $state(false);
  /** Settings modal (Phase 12b). Opened via the top-right gear icon or ⌘,. */
  settingsOpen: boolean = $state(false);
  /** Optional initial section to land on when the modal opens. `null`
      means "use the modal's default (Appearance)". Cleared by closeSettings. */
  settingsInitialSection: SettingsSection | null = $state(null);
  /** About modal — native menu "About brew-browser" + sidebar footer link. */
  aboutOpen: boolean = $state(false);
  theme: ThemePreference = $state("system");
  /** UI language preference. `system` keeps English for non-Russian systems
      and enables Russian for `ru-*` system locales. */
  localePreference: LocalePreference = $state(DEFAULT_LOCALE_PREFERENCE);
  locale: Locale = $derived(resolveLocalePreference(this.localePreference));
  /** the package currently shown in the detail panel; null = panel closed */
  selectedPackage: { name: string; kind: "formula" | "cask" } | null = $state(null);
  /** width of the package detail pane in px; persisted to localStorage */
  detailPaneWidth: number = $state(DETAIL_PANE_DEFAULT_WIDTH);

  /** Which section the app opens on at launch. `dashboard` by default; the
      user can change this from Settings → Appearance. Persists to localStorage
      and is applied by `loadDefaultSectionFromStorage` (called from layout
      onMount) — only when the user hasn't already navigated. */
  defaultSection: SidebarSection = $state("dashboard");

  /** Vibrancy material applied to the macOS window via NSVisualEffectView.
      Restart-required because Tauri 2 applies vibrancy in the setup hook.
      Persisted to localStorage so the next launch reads it. */
  vibrancyMaterial: VibrancyMaterial = $state("HudWindow");

  /** Whether destructive actions (Uninstall, Zap, Delete Brewfile) require
      a confirm dialog. Defaults true; turning it off is a "trust me" mode
      for power users. */
  confirmDestructive: boolean = $state(true);

  /** When true, `brew upgrade` runs with `--greedy` so casks that self-update
      (`auto_updates` / `version :latest`) are upgraded too (issues #47/#31).
      Off by default — greedy can churn apps that manage their own updates.
      Persisted to localStorage; applied by every upgrade path. */
  greedyUpgrade: boolean = $state(false);

  /** Activity persistence caps (Phase 12b). These are the future limits
      for the `activity` store's localStorage mirror. Existing retained
      data is not retroactively trimmed when the user changes these. */
  activityMaxJobs: number = $state(ACTIVITY_MAX_JOBS_DEFAULT);
  activityMaxLines: number = $state(ACTIVITY_MAX_LINES_DEFAULT);

  /** When true, the sidebar collapses to an icon-only rail with native
      tooltips on hover. Persisted to localStorage so the choice survives
      app launches. */
  sidebarCollapsed: boolean = $state(false);

  setSection(s: SidebarSection) {
    const changed = s !== this.section;
    this.section = s;
    // Navigating to ANY section closes the package detail slide-over.
    // Without this, the detail panel persists across sidebar clicks /
    // brand-to-Dashboard / Cmd+0..6, which feels jarring — the user
    // clearly chose a new context; the lingering panel is from the old one.
    this.selectedPackage = null;
    // Category chips are owned by Discover but borrowed by Library for
    // the same kind of filter. The chip context shouldn't follow the
    // user across panes — Discover's "Productivity" filter shouldn't
    // silently filter Library to 0 packages on the next click. Reset
    // on any real section change. Callers that deep-link to a section
    // WITH a chip preselected (Dashboard's category donut, PackageDetail's
    // category pills) must call setSection FIRST, then discover.selectOnly().
    if (changed) discover.clear();
  }

  openDrawer() {
    this.drawerOpen = true;
    this.drawerMinimized = false;
  }

  toggleDrawer() {
    if (this.drawerOpen && !this.drawerMinimized) {
      this.drawerMinimized = true;
    } else if (this.drawerOpen && this.drawerMinimized) {
      this.drawerMinimized = false;
    } else {
      this.drawerOpen = true;
      this.drawerMinimized = false;
    }
  }

  closeDrawer() {
    this.drawerOpen = false;
    this.drawerMinimized = false;
  }

  openPalette() { this.paletteOpen = true; }
  closePalette() { this.paletteOpen = false; }

  openSettings(section: SettingsSection | null = null) {
    this.settingsInitialSection = section;
    this.settingsOpen = true;
  }
  closeSettings() {
    this.settingsOpen = false;
    this.settingsInitialSection = null;
  }

  openAbout() { this.aboutOpen = true; }
  closeAbout() { this.aboutOpen = false; }

  // ---------------- Settings (Phase 12b) ----------------

  /** Persist a new default landing section. Writes to localStorage; the
      runtime application happens at next app launch via
      `loadDefaultSectionFromStorage`. */
  setDefaultSection(s: SidebarSection) {
    this.defaultSection = s;
    try { localStorage.setItem(DEFAULT_SECTION_KEY, s); } catch { /* ignore */ }
  }

  /** On first paint, read the saved default-landing and (if the user
      hasn't already navigated) override `section`. We treat the hardcoded
      Dashboard default as "untouched" — if some early code already routed
      the user elsewhere we leave it alone. Validates against the known
      enum on read per Phase 12 security review § 12b. */
  loadDefaultSectionFromStorage() {
    try {
      const v = localStorage.getItem(DEFAULT_SECTION_KEY);
      if (v !== null && (DEFAULT_SECTION_VALUES as readonly string[]).includes(v)) {
        const validated = v as SidebarSection;
        this.defaultSection = validated;
        // Only override the initial section if it's still the hardcoded
        // dashboard default — anything else means something already routed.
        if (this.section === "dashboard") {
          this.section = validated;
        }
      }
    } catch { /* ignore */ }
  }

  /** Persist a new vibrancy material. The active material does not change
      until the app is restarted (NSVisualEffectView is applied once in
      the Tauri setup hook). */
  setVibrancyMaterial(m: VibrancyMaterial) {
    this.vibrancyMaterial = m;
    try { localStorage.setItem(VIBRANCY_MATERIAL_KEY, m); } catch { /* ignore */ }
  }

  loadVibrancyMaterialFromStorage() {
    try {
      const v = localStorage.getItem(VIBRANCY_MATERIAL_KEY);
      if (v !== null && (VIBRANCY_MATERIALS as readonly string[]).includes(v)) {
        this.vibrancyMaterial = v as VibrancyMaterial;
      }
    } catch { /* ignore */ }
  }

  setConfirmDestructive(v: boolean) {
    this.confirmDestructive = v;
    try { localStorage.setItem(CONFIRM_DESTRUCTIVE_KEY, v ? "1" : "0"); } catch { /* ignore */ }
  }

  loadConfirmDestructiveFromStorage() {
    try {
      const v = localStorage.getItem(CONFIRM_DESTRUCTIVE_KEY);
      if (v === "0") this.confirmDestructive = false;
      else if (v === "1") this.confirmDestructive = true;
    } catch { /* ignore */ }
  }

  setGreedyUpgrade(v: boolean) {
    this.greedyUpgrade = v;
    try { localStorage.setItem(GREEDY_UPGRADE_KEY, v ? "1" : "0"); } catch { /* ignore */ }
  }

  loadGreedyUpgradeFromStorage() {
    try {
      const v = localStorage.getItem(GREEDY_UPGRADE_KEY);
      if (v === "1") this.greedyUpgrade = true;
      else if (v === "0") this.greedyUpgrade = false;
    } catch { /* ignore */ }
  }

  setActivityMaxJobs(n: number) {
    const clamped = clampInt(n, ACTIVITY_MAX_JOBS_MIN, ACTIVITY_MAX_JOBS_MAX, ACTIVITY_MAX_JOBS_DEFAULT);
    this.activityMaxJobs = clamped;
    try { localStorage.setItem(ACTIVITY_MAX_JOBS_KEY, String(clamped)); } catch { /* ignore */ }
  }

  setActivityMaxLines(n: number) {
    const clamped = clampInt(n, ACTIVITY_MAX_LINES_MIN, ACTIVITY_MAX_LINES_MAX, ACTIVITY_MAX_LINES_DEFAULT);
    this.activityMaxLines = clamped;
    try { localStorage.setItem(ACTIVITY_MAX_LINES_KEY, String(clamped)); } catch { /* ignore */ }
  }

  /** Load both Activity-retention caps with clamp-on-read so a corrupted
      or hostile localStorage entry can't ask us to keep "999999999 jobs". */
  loadActivitySettingsFromStorage() {
    try {
      const j = localStorage.getItem(ACTIVITY_MAX_JOBS_KEY);
      if (j !== null) {
        const n = Number(j);
        this.activityMaxJobs = clampInt(n, ACTIVITY_MAX_JOBS_MIN, ACTIVITY_MAX_JOBS_MAX, ACTIVITY_MAX_JOBS_DEFAULT);
      }
      const l = localStorage.getItem(ACTIVITY_MAX_LINES_KEY);
      if (l !== null) {
        const n = Number(l);
        this.activityMaxLines = clampInt(n, ACTIVITY_MAX_LINES_MIN, ACTIVITY_MAX_LINES_MAX, ACTIVITY_MAX_LINES_DEFAULT);
      }
    } catch { /* ignore */ }
  }

  /** Toggle the sidebar between full-width and icon-only mode. Persists
      to localStorage so the choice survives launches. */
  toggleSidebarCollapsed() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
    try {
      localStorage.setItem(SIDEBAR_COLLAPSED_KEY, this.sidebarCollapsed ? "1" : "0");
    } catch { /* ignore */ }
  }

  /** Restore the saved collapsed state on app start. Called once from
      +layout.svelte after the DOM is available. */
  loadSidebarCollapsedFromStorage() {
    try {
      const v = localStorage.getItem(SIDEBAR_COLLAPSED_KEY);
      if (v !== null) this.sidebarCollapsed = v === "1";
    } catch { /* ignore */ }
  }

  setLocalePreference(preference: LocalePreference) {
    this.localePreference = preference;
    try { localStorage.setItem(LOCALE_PREFERENCE_KEY, preference); } catch { /* ignore */ }
  }

  loadLocalePreferenceFromStorage() {
    try {
      const value = localStorage.getItem(LOCALE_PREFERENCE_KEY);
      if (isLocalePreference(value)) this.localePreference = value;
    } catch { /* ignore */ }
  }

  selectPackage(name: string, kind: "formula" | "cask") {
    this.selectedPackage = { name, kind };
  }

  closeDetail() {
    this.selectedPackage = null;
  }

  setTheme(t: ThemePreference) {
    this.theme = t;
    try { localStorage.setItem("brew-browser.theme", t); } catch { /* ignore */ }
    applyTheme(t);
  }

  loadThemeFromStorage() {
    try {
      const v = localStorage.getItem("brew-browser.theme");
      if (v === "light" || v === "dark" || v === "system") {
        this.theme = v;
      }
    } catch { /* ignore */ }
    applyTheme(this.theme);
  }

  /** Load persisted detail-pane width on app mount; clamps in case window shrank since. */
  loadDetailPaneWidthFromStorage() {
    try {
      const raw = localStorage.getItem(DETAIL_PANE_WIDTH_KEY);
      if (raw != null) {
        const n = Number(raw);
        if (Number.isFinite(n)) this.detailPaneWidth = clampDetailPaneWidth(n);
      }
    } catch { /* ignore */ }
  }

  /** Set + persist; clamps to [min, 60% of window width]. */
  setDetailPaneWidth(w: number) {
    this.detailPaneWidth = clampDetailPaneWidth(w);
    try { localStorage.setItem(DETAIL_PANE_WIDTH_KEY, String(this.detailPaneWidth)); } catch { /* ignore */ }
  }

  /** Reset to default width (used by double-clicking the resize handle). */
  resetDetailPaneWidth() {
    this.setDetailPaneWidth(DETAIL_PANE_DEFAULT_WIDTH);
  }
}

function applyTheme(t: ThemePreference) {
  if (typeof document === "undefined") return;
  const html = document.documentElement;
  let resolved: "light" | "dark";
  if (t === "system") {
    resolved = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  } else {
    resolved = t;
  }
  html.dataset.theme = resolved;
}

/** Subscribe matchMedia to flip data-theme when "system" is selected. */
export function watchSystemTheme(getCurrent: () => ThemePreference) {
  if (typeof window === "undefined") return () => {};
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  const handler = () => {
    if (getCurrent() === "system") {
      document.documentElement.dataset.theme = mq.matches ? "dark" : "light";
    }
  };
  mq.addEventListener("change", handler);
  return () => mq.removeEventListener("change", handler);
}

export const ui = new UiStore();
