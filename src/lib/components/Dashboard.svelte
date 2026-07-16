<script lang="ts">
  import { onMount } from "svelte";
  import PackageIcon from "@lucide/svelte/icons/package";
  import ArrowUpCircle from "@lucide/svelte/icons/arrow-up-circle";
  import HardDrive from "@lucide/svelte/icons/hard-drive";
  import CheckCircle2 from "@lucide/svelte/icons/check-circle-2";
  import AlertCircle from "@lucide/svelte/icons/alert-circle";
  import ShieldAlert from "@lucide/svelte/icons/shield-alert";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";

  import Button from "./Button.svelte";
  import Pill from "./Pill.svelte";
  import LoadingState from "./LoadingState.svelte";
  import FolderOpen from "@lucide/svelte/icons/folder-open";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Stethoscope from "@lucide/svelte/icons/stethoscope";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Star from "@lucide/svelte/icons/star";
  import GitBranch from "@lucide/svelte/icons/git-branch";
  import Loader from "@lucide/svelte/icons/loader-2";
  import { packages } from "$lib/stores/packages.svelte";
  import { env } from "$lib/stores/env.svelte";
  import { categories } from "$lib/stores/categories.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { catalog } from "$lib/stores/catalog.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { discover } from "$lib/stores/discover.svelte";
  import { library } from "$lib/stores/library.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { github } from "$lib/stores/github.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { brewUpdate, brewUpgrade, diskUsage, diskUsageClearCache, openInFinder, brewDoctorStream, brewCleanup, brewCleanupPreview } from "$lib/api";
  import UpgradeModal from "./UpgradeModal.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { resolveCategoryIcon } from "$lib/util/categoryIcon";
  import { brewErrorMessage, isBrewError, type DiskUsageReport, type CleanupPreview } from "$lib/types";
  import { reportableToastError } from "$lib/util/reportIssue";
  import { isLinux, isMac } from "$lib/util/platform";
  import { fmtBytes } from "$lib/util/format";
  import { t, ruPlural } from "$lib/i18n/messages";

  let disk = $state<DiskUsageReport | null>(null);
  let diskLoading = $state(false);
  let diskError = $state<string | null>(null);

  // Issue #80 — cache maintenance (brew doctor / cleanup), surfaced on the
  // Storage card since that's the disk surface and already shows the cache size.
  let cleanupPreview = $state<CleanupPreview | null>(null);
  let doctorRunning = $state(false);
  let cleanupRunning = $state(false);
  let cleanupConfirmOpen = $state(false);
  let cleanupVerbose = $state(true); // reporter likes seeing every file removed
  let cleanupScrub = $state(false);  // opt-in: also remove latest-version downloads
  let maintBusy = $derived(doctorRunning || cleanupRunning);

  async function loadDisk(force = false) {
    if (diskLoading) return;
    diskLoading = true;
    diskError = null;
    if (force) {
      try { await diskUsageClearCache(); } catch { /* best-effort */ }
    }
    // Refresh the reclaimable estimate INDEPENDENTLY of the (slower, fallible)
    // disk re-measure: a disk-probe error must not leave a stale "frees ~X"
    // hint after a cleanup. `cleanupPreview` re-runs `brew cleanup -n`, which
    // reports ~nothing once the cache has actually been cleared.
    brewCleanupPreview().then((p) => { cleanupPreview = p; }).catch(() => { cleanupPreview = null; });
    try {
      disk = await diskUsage();
    } catch (e) {
      diskError = t("storage.diskProbeFailed", ui.locale, { error: isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e) });
    } finally {
      diskLoading = false;
    }
  }

  /** Stream a no-package brew job into the Activity drawer, mirroring the
   *  brew update / upgrade-all wiring (rebinds the temp job id to the real
   *  one on the `started` event). */
  async function streamJob(
    label: string,
    command: string,
    run: (onEvent: (evt: import("$lib/types").BrewStreamEvent) => void) => Promise<{ success: boolean }>,
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

  async function runDoctor() {
    if (maintBusy) return;
    doctorRunning = true;
    try {
      // A non-zero doctor (advisories) is reported as success by the backend;
      // the advisory text is in the Activity log, which is the whole point.
      await streamJob("Running brew doctor", "brew doctor", brewDoctorStream);
    } catch (e) {
      reportableToastError(t("dashboard.doctor.failedToRun", ui.locale), e);
    } finally {
      doctorRunning = false;
    }
  }

  async function runCleanup() {
    if (maintBusy) return;
    cleanupConfirmOpen = false;
    cleanupRunning = true;
    try {
      await streamJob(
        "Cleaning up Homebrew cache",
        `brew cleanup --prune=all${cleanupScrub ? " --scrub" : ""}${cleanupVerbose ? " --verbose" : ""}`,
        (onEvent) => brewCleanup(cleanupScrub, cleanupVerbose, onEvent),
      );
      // Re-measure the Storage card + refresh the "frees ~X" estimate after the
      // cleanup completes — NOT gated on a clean exit. `brew cleanup` can free
      // space and still exit non-zero (a file it couldn't remove), and even a
      // partial cleanup changes what's reclaimable, so always reconcile.
      await loadDisk(true);
    } catch (e) {
      reportableToastError("Cleanup failed", e);
    } finally {
      cleanupRunning = false;
    }
  }

  async function reveal(path: string) {
    try {
      await openInFinder(path);
    } catch (e) {
      reportableToastError(isMac ? "Couldn't reveal in Finder" : "Couldn't open in file manager", e);
    }
  }

  onMount(() => {
    if (!packages.list) packages.load();
    categories.ensureLoaded();
    catalog.ensureLoaded();
    loadDisk();
  });

  // ────────────────────────────────────────────────────────────────
  // Refresh handler — full three-step sync:
  //
  //   1. `brew update` (git-fetch on every tap in $HOMEBREW_PREFIX/
  //      Library/Taps/) — makes brew itself aware of new upstream
  //      versions. Streams to the Activity drawer so the user can see
  //      what brew is doing (typical output: "Already up-to-date" or
  //      "Updated 2 taps: homebrew/core, homebrew/cask").
  //   2. Catalog refresh — writes a fresh formula.json + cask.json to
  //      ~/Library/Application Support/brew-browser/catalog/ for our
  //      own Discover / Library / Search views. Doesn't touch brew.
  //   3. Installed list reload (force=true) — re-runs brew info
  //      --installed --json=v2 with the now-up-to-date version
  //      knowledge from step 1, so the outdated flag is accurate.
  //
  // All three are needed for "Refresh" to mean what the user expects:
  // "make every count and version on this page reflect reality right
  // now." Without step 1, brew doesn't know about new releases. Without
  // step 2, the Discover index lags. Without step 3, the Updates card
  // shows stale outdated flags.
  //
  // Each step's failure surfaces a typed toast and short-circuits the
  // rest — a failed brew update typically means a flaky network or a
  // tap permissions problem, both worth fixing before continuing.
  let refreshing = $state(false);
  async function refreshCatalog() {
    if (refreshing) return;
    refreshing = true;

    const tmpId = crypto.randomUUID();
    activity.startJob("Updating Homebrew taps", tmpId, "brew update");
    ui.openDrawer();

    try {
      // Step 1: brew update. Stream into Activity so the user sees
      // each tap getting refreshed (or a clean "Already up-to-date").
      const updateResult = await brewUpdate((evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
      if (!updateResult.success) {
        toast.error(t("dashboard.refresh.brewUpdateFailed", ui.locale), t("activity.drawer.show", ui.locale));
        return;
      }

      // Step 2: catalog refresh (our own index from formulae.brew.sh).
      const ok = await catalog.refresh();
      if (!ok) {
        if (catalog.refreshError) {
          toast.error(t("dashboard.refresh.catalogFailed", ui.locale), catalog.refreshError);
        }
        return;
      }

      // Step 3: reload installed list with force=true so brew_list
      // re-runs `brew info --installed` and the outdated flags reflect
      // the fresh upstream knowledge from step 1. Best-effort — the
      // success toast below covers the user-visible outcome.
      await packages.load(true).catch(() => {});

      // v0.5.0 — kick a vuln re-scan now that packages.installed is fresh.
      // Fire-and-forget: scanIfNeeded is internally fingerprint-skipped, so
      // it's cheap when nothing changed, and any error routes through the
      // store's own toast handling. Wrapping in catch() so a thrown promise
      // doesn't propagate out of refreshCatalog.
      vulnerabilities.scanIfNeeded().catch(() => {});

      // Opt-in live enrichment: the served data may carry newer categories /
      // descriptions. Pull newer categories and drop the per-token overlay so
      // the next detail view re-fetches fresh. Both no-op unless the user
      // opted in (toggle + not paranoid + AI on); soft-fail.
      void categories.refreshLiveIfNewer();
      enrichment.resetLive();

      toast.success(t("dashboard.refresh.successTitle", ui.locale), t("dashboard.refresh.successBody", ui.locale));
    } catch (e) {
      reportableToastError(t("dashboard.refresh.failed", ui.locale), e);
    } finally {
      refreshing = false;
    }
  }

  // ────────────────────────────────────────────────────────────────
  // Phase 12f — personal-stats card
  //
  // Only meaningful when (a) the user is signed in to GitHub, (b) the
  // Settings → GitHub toggle is on (the IPC short-circuits otherwise),
  // and (c) paranoid mode is off. The store's `batchIsStarred` does
  // the bounded fan-out via a 50-permit semaphore; we kick it off
  // once the package list is loaded so we have homepages to probe.

  /** Installed packages that resolve to a GitHub repo via any of their
      URL fields. Reads the backend-pre-resolved `githubHomepage` so the
      count includes packages with non-GitHub homepages but GitHub-hosted
      `urls.stable.url` (formula) or `url` (cask). Canonical
      `https://github.com/<o>/<r>` form, ready for `batchIsStarred`. */
  let installedGithubHomepages = $derived.by<string[]>(() => {
    if (!packages.all || packages.all.length === 0) return [];
    return packages.all
      .map((p) => p.githubHomepage)
      .filter((hp): hp is string => hp !== null && hp !== undefined);
  });

  let personalStatsEligible = $derived(
    !!github.status?.signedIn &&
      settings.effective.githubEnabled &&
      !settings.effective.paranoidMode,
  );

  let personalStatsLoading = $derived(github.starredBatchLoading);

  /** Trigger the batch probe once we have homepages + the user is signed
      in. Re-runs whenever the eligible homepage list grows. The store
      caches per homepage so subsequent re-renders don't re-fetch. */
  $effect(() => {
    if (!personalStatsEligible) return;
    if (installedGithubHomepages.length === 0) return;
    void github.batchIsStarred(installedGithubHomepages);
  });

  /** Count of homepages whose cached outcome is exactly `true`. */
  let personalStarredCount = $derived.by(() => {
    let n = 0;
    for (const hp of installedGithubHomepages) {
      if (github.starredCache.get(hp) === true) n += 1;
    }
    return n;
  });

  let personalGithubTotal = $derived(installedGithubHomepages.length);

  // ────────────────────────────────────────────────────────────────
  // v0.5.0 — Exposure card (vulnerability scanning rollup)
  //
  // Renders only when the feature is enabled (no nag when off — the
  // Settings → Network section is the canonical discovery surface).
  // Three sub-states once enabled: never-scanned, scanned-clean,
  // scanned-with-findings. The "Scan now" button mirrors the Storage
  // card's Refresh control for visual consistency.

  /** Hide the entire card unless the user has opted in. We don't even
      render a "scan disabled" stub — the Dashboard is dense and the
      Settings panel handles discovery. */
  let exposureVisible = $derived(
    settings.effective.vulnerabilityScanningEnabled === true,
  );

  let exposureCounts = $derived(vulnerabilities.severityCounts);
  let exposureScannedAt = $derived(vulnerabilities.lastScannedAt);
  let exposureSource = $derived(vulnerabilities.source);
  let exposureLoading = $derived(vulnerabilities.loading);
  /** A confident "all clean" is only honest when the scan ran THIS session. A
      report hydrated from cache on launch (timestamp predating the session) is
      stale — show a caution + re-scan prompt instead of a green all-clear. */
  let exposureFresh = $derived(vulnerabilities.scannedThisSession(exposureScannedAt));

  /** Same RelativeTimeFormat as the Settings card — same UX language. */
  const EXPOSURE_RELATIVE = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  function exposureRelative(d: Date | null): string {
    if (!d) return "never";
    const deltaSec = Math.round((d.getTime() - Date.now()) / 1000);
    const abs = Math.abs(deltaSec);
    if (abs < 60) return EXPOSURE_RELATIVE.format(deltaSec, "second");
    if (abs < 3600) return EXPOSURE_RELATIVE.format(Math.round(deltaSec / 60), "minute");
    if (abs < 86400) return EXPOSURE_RELATIVE.format(Math.round(deltaSec / 3600), "hour");
    return EXPOSURE_RELATIVE.format(Math.round(deltaSec / 86400), "day");
  }
  let exposureLastLabel = $derived(exposureRelative(exposureScannedAt));

  async function scanExposureNow() {
    await vulnerabilities.scanAll(true);
  }

  /** Jump to Library with the "vulnerable" filter pre-selected, so the
      user lands on the list of packages with known CVEs rather than
      "all installed". The pill is gated on `vulnerabilities.enabled`
      in Library — which is guaranteed true here because this function
      is only callable from the Exposure card, which is itself gated
      on the same flag. setSection FIRST so any chip clears don't
      stomp our filter pick. */
  function viewVulnerablePackages() {
    ui.setSection("library");
    library.setFilter("vulnerable");
  }

  function fmt(n: number): string {
    return n.toLocaleString(ui.locale === "ru" ? "ru-RU" : undefined);
  }

  function storageLabel(label: string): string {
    switch (label) {
      case "Formulae (Cellar)": return t("Formulae (Cellar)", ui.locale);
      case "Casks (Caskroom)": return t("Casks (Caskroom)", ui.locale);
      case "Logs (var/log)": return t("Logs (var/log)", ui.locale);
      case "Download cache": return t("Download cache", ui.locale);
      default:
        return label;
    }
  }

  function formulaeLabel(count: number): string {
    return ui.locale === "ru"
      ? ruPlural(count, "формула", "формулы", "формул")
      : "formulae";
  }

  function casksLabel(count: number): string {
    return ui.locale === "ru"
      ? ruPlural(count, "cask-пакет", "cask-пакета", "cask-пакетов")
      : "casks";
  }

  function compositionAria(): string {
    return ui.locale === "ru"
      ? `${fmt(counts.formulae)} ${formulaeLabel(counts.formulae)} и ${fmt(counts.casks)} ${casksLabel(counts.casks)}`
      : `${counts.formulae} formulae and ${counts.casks} casks`;
  }

  function onRequestLabel(count: number): string {
    return ui.locale === "ru"
      ? `${fmt(count)} ${ruPlural(count, "вручную", "вручную", "вручную")}`
      : `${fmt(count)} on request`;
  }

  function dependencyLabel(count: number): string {
    return ui.locale === "ru"
      ? `${fmt(count)} ${ruPlural(count, "как зависимость", "как зависимости", "как зависимостей")}`
      : `${fmt(count)} as dependency`;
  }

  function pinnedLabel(count: number): string {
    return ui.locale === "ru"
      ? `${fmt(count)} ${ruPlural(count, "закреплённый", "закреплённых", "закреплённых")}`
      : `${fmt(count)} pinned`;
  }

  function discoverCategoryTitle(label: string, isOther: boolean): string {
    if (ui.locale === "ru") return isOther ? "Открыть всё в Каталоге" : `Открыть «${label}» в Каталоге`;
    return isOther ? "Browse all in Discover" : `Browse ${label} in Discover`;
  }

  function severityLabel(count: number, severity: "critical" | "high" | "medium" | "low" | "unknown"): string {
    if (ui.locale !== "ru") return severity;
    switch (severity) {
      case "critical": return ruPlural(count, "критическая", "критические", "критических");
      case "high": return ruPlural(count, "высокая", "высокие", "высоких");
      case "medium": return ruPlural(count, "средняя", "средние", "средних");
      case "low": return ruPlural(count, "низкая", "низкие", "низких");
      case "unknown": return ruPlural(count, "неизвестная", "неизвестные", "неизвестных");
    }
  }

  function exposureSummaryText(): string {
    const source = exposureSource ? (ui.locale === "ru" ? ` · источник: ${exposureSource}` : ` · source: ${exposureSource}`) : "";
    if (ui.locale === "ru") {
      const finding = ruPlural(exposureCounts.total, "находка", "находки", "находок");
      const pkg = ruPlural(counts.total, "установленного пакета", "установленных пакетов", "установленных пакетов");
      return `${fmt(exposureCounts.total)} ${finding} в ${fmt(exposureCounts.vulnerablePackages)} из ${fmt(counts.total)} ${pkg}${source}`;
    }
    return `${fmt(exposureCounts.total)} ${exposureCounts.total === 1 ? "finding" : "findings"} across ${fmt(exposureCounts.vulnerablePackages)} of ${fmt(counts.total)} installed packages${source}`;
  }

  function openPackage(name: string, kind: "formula" | "cask") {
    ui.selectPackage(name, kind);
  }

  /** Jump to Library, pre-select the Outdated filter. Used by the Updates card. */
  function goToOutdatedLibrary() {
    library.setFilter("outdated");
    ui.setSection("library");
  }

  /** Counts derived from the loaded package list. All zero until `load` completes. */
  let counts = $derived.by(() => {
    const all = packages.all;
    // "updates available" counts only upgradable packages — pinned ones are
    // held back (#90) and brew upgrade skips them, so they don't nag here.
    const outdated = packages.outdatedUpgradable.length;
    const formulae = packages.formulae.length;
    const casks = packages.casks.length;
    const pinned = all.filter((p) => p.pinned).length;
    const onRequest = all.filter((p) => p.installedOnRequest).length;
    const asDependency = all.filter((p) => p.installedAsDependency && !p.installedOnRequest).length;
    return {
      total: all.length,
      formulae,
      casks,
      outdated,
      pinned,
      onRequest,
      asDependency,
    };
  });

  /** Bar-chart split: percentage of formulae vs casks (display only). */
  let split = $derived.by(() => {
    if (counts.total === 0) return { formulaPct: 0, caskPct: 0 };
    const fp = Math.round((counts.formulae / counts.total) * 100);
    return { formulaPct: fp, caskPct: 100 - fp };
  });

  /** Composition pie segments (formulae vs casks) for the wide side-by-side
   *  layout — mirrors native's CompositionCard pie. Same data as `split`,
   *  shaped for the SVG-arc renderer the donut already uses. */
  let compositionSegments = $derived.by<
    Array<{ label: string; count: number; pct: number; startPct: number; color: string }>
  >(() => {
    const total = counts.formulae + counts.casks;
    if (total === 0) return [];
    const items = [
      { label: "Formulae", count: counts.formulae, color: "var(--color-info, #4a90e2)" },
      { label: "Casks", count: counts.casks, color: "var(--color-brand, #f59e0b)" },
    ];
    let cum = 0;
    return items.map((s) => {
      const pct = (s.count / total) * 100;
      const seg = { ...s, pct, startPct: cum };
      cum += pct;
      return seg;
    });
  });

  // Pie drawn as filled SVG wedges with outer radius 60 — fills the 120 viewBox
  // (= native's 180×180 frame) and exactly matches the donut's outer radius, so
  // the two charts render at an identical diameter.
  const PIE_RADIUS = 60;

  /** SVG path `d` for a pie wedge spanning [startPct, startPct+pct] of the
   *  circle, starting at 12 o'clock and sweeping clockwise. Center (60,60),
   *  r=56 in the shared `0 0 120 120` viewBox. Handles the full-circle case
   *  (one category at 100%, which a single arc can't close). */
  function piePath(startPct: number, pct: number): string {
    const r = PIE_RADIUS;
    const cx = 60;
    const cy = 60;
    if (pct <= 0) return "";
    if (pct >= 100) {
      return `M ${cx} ${cy - r} A ${r} ${r} 0 1 1 ${cx} ${cy + r} A ${r} ${r} 0 1 1 ${cx} ${cy - r} Z`;
    }
    const a0 = (startPct / 100) * 2 * Math.PI - Math.PI / 2;
    const a1 = ((startPct + pct) / 100) * 2 * Math.PI - Math.PI / 2;
    const x0 = (cx + r * Math.cos(a0)).toFixed(3);
    const y0 = (cy + r * Math.sin(a0)).toFixed(3);
    const x1 = (cx + r * Math.cos(a1)).toFixed(3);
    const y1 = (cy + r * Math.sin(a1)).toFixed(3);
    const largeArc = pct > 50 ? 1 : 0;
    return `M ${cx} ${cy} L ${x0} ${y0} A ${r} ${r} 0 ${largeArc} 1 ${x1} ${y1} Z`;
  }

  /**
   * Top-N categories among installed packages, with counts. We weight by single
   * membership (each package contributes 1 to each category it's tagged with;
   * a package in 3 categories adds to all 3). Uncategorized is collapsed into
   * the "Other" remainder so the bar chart focuses on signal.
   */
  let topCategories = $derived.by<
    Array<{ slug: string; label: string; icon: string; count: number }>
  >(() => {
    if (!categories.data || packages.all.length === 0) return [];
    const counts: Record<string, number> = {};
    for (const p of packages.all) {
      const cats = categories.categoriesOf(p.name, p.kind);
      for (const slug of cats) {
        if (slug === "uncategorized") continue;
        counts[slug] = (counts[slug] ?? 0) + 1;
      }
    }
    const arr = Object.entries(counts)
      .map(([slug, count]) => ({
        slug,
        label: categories.labelOf(slug, ui.locale),
        icon: categories.data?.categories[slug]?.icon ?? "HelpCircle",
        count,
      }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 8);
    return arr;
  });

  let topCategoryMax = $derived(topCategories[0]?.count ?? 1);

  /** Donut palette — 9 visually distinct hues that work on both light and dark
      surfaces. Last slot is the muted "Other" color. */
  const DONUT_PALETTE = [
    "#5b8def", // blue
    "#e07a5f", // coral
    "#81b29a", // sage
    "#f2cc8f", // amber
    "#a78bfa", // violet
    "#ec4899", // pink
    "#10b981", // emerald
    "#f97316", // orange
    "#64748b", // slate (used for "Other")
  ];
  // r 48 + half the 24px stroke = outer radius 60 (fills the 120 viewBox, like
  // native's 180×180 frame); inner radius 48 − 12 = 36 = ratio 0.6 of the outer,
  // matching native's donut innerRadius .ratio(0.6).
  const DONUT_RADIUS = 48;
  const DONUT_CIRC = 2 * Math.PI * DONUT_RADIUS;

  /**
   * Donut segments derived from category memberships. Top 8 categories shown
   * individually; everything else collapses into a single "Other" slice. The
   * percentages add to 100% across all category memberships (a single package
   * in multiple categories contributes to each — same model as the legend).
   */
  let categorySegments = $derived.by<
    Array<{
      slug: string;
      label: string;
      icon: string;
      count: number;
      pct: number;
      startPct: number;
      color: string;
    }>
  >(() => {
    if (!categories.data || packages.all.length === 0) return [];
    const tally: Record<string, number> = {};
    for (const p of packages.all) {
      const cats = categories.categoriesOf(p.name, p.kind);
      for (const slug of cats) {
        tally[slug] = (tally[slug] ?? 0) + 1;
      }
    }
    const sortedAll = Object.entries(tally).sort((a, b) => b[1] - a[1]);
    const top = sortedAll.slice(0, 8);
    const otherCount = sortedAll.slice(8).reduce((sum, [, c]) => sum + c, 0);
    const total = sortedAll.reduce((sum, [, c]) => sum + c, 0);
    if (total === 0) return [];

    const base = top.map(([slug, count], idx) => ({
      slug,
      label: categories.labelOf(slug, ui.locale),
      icon: categories.data?.categories[slug]?.icon ?? "HelpCircle",
      count,
      color: DONUT_PALETTE[idx % DONUT_PALETTE.length],
    }));
    if (otherCount > 0) {
      base.push({
        slug: "__other__",
        label: ui.locale === "ru" ? "Другое" : "Other",
        icon: "HelpCircle",
        count: otherCount,
        color: DONUT_PALETTE[8],
      });
    }
    let cum = 0;
    return base.map((s) => {
      const pct = (s.count / total) * 100;
      const seg = { ...s, pct, startPct: cum };
      cum += pct;
      return seg;
    });
  });

  /** Donut hover state. Set by mouseenter on a slice OR a legend row;
   *  cleared on mouseleave. Drives:
   *    - slice highlight (hovered segment fattens, others dim)
   *    - legend row visual indication
   *
   *  Keyboard accessibility: focus-on-slice could also drive this in a
   *  future iteration; today the donut is decorative + the legend rows
   *  carry the click affordance, so keyboard users get the count from
   *  the always-visible legend columns. */
  let hoveredCategory = $state<string | null>(null);

  function jumpToCategory(slug: string) {
    // This card is "Top categories in your library", so keep the user IN the
    // Library, filtered to that category — not the full Discover catalog.
    // Library already filters installed packages by discover.selectedCategories
    // (Library.svelte). See #58.
    if (slug === "__other__") {
      // Uncategorized has no slug to filter on — just show the full library.
      ui.setSection("library");
      discover.clear();
      return;
    }
    // setSection FIRST: it clears chip filters on any real section change,
    // so selectOnly must come after. See ui.setSection().
    ui.setSection("library");
    discover.selectOnly(slug);
  }

  /** First 5 *upgradable* packages, sorted alphabetically for stable display.
   *  Pinned packages are held back (#90) and don't appear in the updates card. */
  let outdatedPreview = $derived.by(() =>
    [...packages.outdatedUpgradable].sort((a, b) => a.name.localeCompare(b.name)).slice(0, 5),
  );

  let upgradeAllRunning = $state(false);
  let upgradeModalOpen = $state(false);

  async function upgradeAll() {
    if (upgradeAllRunning) return;
    upgradeAllRunning = true;
    const tmpId = crypto.randomUUID();
    activity.startJob(`Upgrading all packages`, tmpId, "brew upgrade");
    ui.openDrawer();
    try {
      const result = await brewUpgrade(null, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      }, ui.greedyUpgrade);
      if (result.success) {
        toast.success(t("dashboard.upgradeAll.success", ui.locale, { count: counts.outdated }));
        packages.load(true);
        // v0.5.0 — every upgraded package gets a new version, invalidating
        // its old vuln record. Easiest path: re-scan the whole set. The
        // scanIfNeeded fingerprint catches the install-set change. After
        // the scan completes, surface the once-per-session exposure
        // heads-up so the user sees the security context of their
        // post-upgrade install.
        vulnerabilities
          .scanIfNeeded()
          .then(() => vulnerabilities.maybeNotifyExposure())
          .catch(() => {});
      }
    } catch (e) {
      reportableToastError("Upgrade-all failed", e);
    } finally {
      upgradeAllRunning = false;
    }
  }
</script>

<section class="dashboard">
  <!-- Pane title moved to the window title bar (+page.svelte).
       Dashboard has no secondary header actions, so the panel-head
       is dropped entirely. -->

  <div class="body">
    {#if packages.loading && !packages.list}
      <LoadingState rows={6} label="Loading your packages…" />
    {:else if packages.error}
      <div class="error-card">
        <AlertCircle size={20} />
        <div>
          <strong>{t("Couldn't load packages.", ui.locale)}</strong>
          <p class="text-muted">{packages.error}</p>
        </div>
        <Button variant="secondary" size="sm" onclick={() => packages.load(true)}>Retry</Button>
      </div>
    {:else}
      <!-- Hero stats row -->
      <div class="hero">
        <button class="stat" onclick={() => ui.setSection("library")} title="Open Library">
          <span class="stat-icon"><PackageIcon size={20} /></span>
          <span class="stat-value">{fmt(counts.total)}</span>
          <span class="stat-label">installed</span>
        </button>

        <button
          class="stat stat--accent"
          class:dim={counts.outdated === 0}
          onclick={goToOutdatedLibrary}
          title={counts.outdated > 0 ? "Open Library, filter outdated" : "Everything is up to date"}
          disabled={counts.outdated === 0}
        >
          <span class="stat-icon">
            {#if counts.outdated > 0}
              <ArrowUpCircle size={20} />
            {:else}
              <CheckCircle2 size={20} />
            {/if}
          </span>
          <span class="stat-value">{counts.outdated === 0 ? "All current" : fmt(counts.outdated)}</span>
          <span class="stat-label">{counts.outdated === 0 ? "" : "updates available"}</span>
        </button>

        <div class="stat" title={env.summary}>
          <span class="stat-icon"><HardDrive size={20} /></span>
          <span class="stat-value">{env.report?.version ?? "—"}</span>
          <span class="stat-label">{env.report?.prefix ?? "Homebrew"}</span>
        </div>
      </div>

      <!-- Phase 12a — catalog freshness strip. Inline below the hero so
           the relationship to "version of brew" stays visible. Goes amber
           when the active catalog is older than the user's stale-banner
           threshold (default 14 days). -->
      <div
        class="catalog-line"
        class:catalog-line--stale={catalog.summary && catalog.isStale}
        aria-live="polite"
      >
        <span class="catalog-text">
          Catalog: <strong>{catalog.daysOldLabel}</strong>
          {#if catalog.summary}
            <span class="text-muted catalog-source">({catalog.summary.source})</span>
          {/if}
        </span>
        <button
          type="button"
          class="catalog-refresh"
          onclick={refreshCatalog}
          disabled={refreshing}
          title="Run brew update, refresh the catalog from formulae.brew.sh, and reload your installed list"
        >
          {#if refreshing}
            <Loader size={12} class="spin-slow" />
            <span>Refreshing…</span>
          {:else if catalog.summary && catalog.isStale}
            <RefreshCw size={12} />
            <span>Refresh from brew.sh →</span>
          {:else}
            <RefreshCw size={12} />
            <span>Refresh</span>
          {/if}
        </button>
      </div>

      <!-- Updates panel -->
      {#if counts.outdated > 0}
        <section class="card">
          <div class="card-head">
            <button
              type="button"
              class="card-title-link"
              onclick={goToOutdatedLibrary}
              title="Open Library, filter outdated"
            >
              <h2>Updates available</h2>
              <span class="card-title-chevron" aria-hidden="true">→</span>
            </button>
            <div class="updates-actions">
              <Button
                variant="secondary"
                size="sm"
                onclick={() => (upgradeModalOpen = true)}
                disabled={upgradeAllRunning}
                title="Pick which packages to upgrade"
              >
                Choose…
              </Button>
              <Button variant="primary" size="sm" onclick={upgradeAll} disabled={upgradeAllRunning}>
                {#snippet icon()}<ArrowUpCircle size={14} />{/snippet}
                {upgradeAllRunning ? "Upgrading…" : `Upgrade all (${counts.outdated})`}
              </Button>
            </div>
          </div>
          <ul class="outdated-list">
            {#each outdatedPreview as p (p.fullName + p.kind)}
              {@const isSelected = ui.selectedPackage?.name === p.name && ui.selectedPackage?.kind === p.kind}
              <li>
                <button
                  class="outdated-row"
                  class:selected={isSelected}
                  aria-current={isSelected ? "true" : undefined}
                  onclick={() => openPackage(p.name, p.kind)}
                >
                  <span class="o-name truncate">{p.name}</span>
                  <span class="o-kind"><Pill tone={p.kind === "formula" ? "formula" : "cask"}>{p.kind}</Pill></span>
                  <span class="o-version mono text-muted">
                    {p.installedVersion ?? "?"} → {p.stableVersion ?? "?"}
                  </span>
                </button>
              </li>
            {/each}
          </ul>
          {#if counts.outdated > outdatedPreview.length}
            <div class="card-foot">
              <button class="link" onclick={goToOutdatedLibrary}>
                + {counts.outdated - outdatedPreview.length} more in Library →
              </button>
            </div>
          {/if}
        </section>
      {/if}

      <!-- Composition + Top categories — paired side-by-side on wide panes
           (matches native's >980px breakpoint); stacked full-width below,
           where Composition reverts to a horizontal bar.
           Linux: casks don't exist, so a formulae-vs-casks split is a
           single-kind chart — the whole Composition card is hidden (and
           the pair never pairs; categories takes the full width). -->
      <div class="dash-pair" class:paired={!isLinux && categories.visible && categorySegments.length > 0}>
        {#if !isLinux}
        <section class="card comp-card">
          <div class="card-head">
	            <h2>{t("Composition", ui.locale)}</h2>
            <!-- on-request / as-dependency / pinned chips live in the header
                 upper-right (matches native's CompositionCard title row). -->
            <div class="comp-chips">
              {#if counts.onRequest > 0}
	                <span class="meta-pill">{onRequestLabel(counts.onRequest)}</span>
              {/if}
              {#if counts.asDependency > 0}
	                <span class="meta-pill">{dependencyLabel(counts.asDependency)}</span>
              {/if}
              {#if counts.pinned > 0}
	                <span class="meta-pill">{pinnedLabel(counts.pinned)}</span>
              {/if}
            </div>
          </div>
          <div class="split">
            <!-- Wide + paired: pie + ranked legend (rhymes with the donut). -->
            <div class="comp-pie">
	              <svg viewBox="0 0 120 120" class="pie" role="img" aria-label={compositionAria()}>
                {#each compositionSegments as s (s.label)}
                  <path d={piePath(s.startPct, s.pct)} fill={s.color} />
                {/each}
              </svg>
              <ul class="pie-legend">
                {#each compositionSegments as s (s.label)}
                  <li>
                    <span class="legend-dot" style="background: {s.color}"></span>
                    <span class="legend-label">{s.label}</span>
                    <span class="legend-count">{fmt(s.count)}</span>
                    <span class="legend-pct text-muted">{s.pct.toFixed(1)}%</span>
                  </li>
                {/each}
              </ul>
            </div>
            <!-- Default (narrow / unpaired): stacked horizontal bar. -->
            <div class="comp-bar">
	              <div class="split-bar" role="img" aria-label={compositionAria()}>
                <span class="seg seg--formula" style="width: {split.formulaPct}%"></span>
                <span class="seg seg--cask" style="width: {split.caskPct}%"></span>
              </div>
              <div class="split-legend">
                <span class="legend">
                  <span class="swatch swatch--formula"></span>
	                  <strong>{fmt(counts.formulae)}</strong> {formulaeLabel(counts.formulae)}
                </span>
                <span class="legend">
                  <span class="swatch swatch--cask"></span>
	                  <strong>{fmt(counts.casks)}</strong> {casksLabel(counts.casks)}
                </span>
              </div>
            </div>
          </div>
        </section>
        {/if}

        <!-- Top categories — donut. Phase 13: hidden when the AI Features
             toggle is off (categories are LLM-generated). -->
        {#if categories.visible && categorySegments.length > 0}
        <section class="card">
          <div class="card-head">
	            <h2>{t("Top categories in your library", ui.locale)}</h2>
          </div>
          <div class="donut-wrap">
	            <svg viewBox="0 0 120 120" class="donut" role="img" aria-label={ui.locale === "ru" ? "Разбивка по категориям" : "Category breakdown"}>
              <circle cx="60" cy="60" r={DONUT_RADIUS} class="donut-track" />
              {#each categorySegments as s (s.slug)}
                {@const isHovered = hoveredCategory === s.slug}
                {@const isDimmed = hoveredCategory !== null && !isHovered}
                <!--
                  Slices are decorative+hover-preview only. The canonical
                  click target is the matching legend row below (real
                  <button>, full keyboard support, screen-reader-named).
                  Slice carries a <title> tooltip for mouse users who
                  hover over the chart itself rather than the legend.
                -->
                <circle
                  cx="60"
                  cy="60"
                  r={DONUT_RADIUS}
                  fill="none"
                  stroke={s.color}
                  stroke-width={24}
                  stroke-dasharray="{(s.pct / 100) * DONUT_CIRC} {DONUT_CIRC}"
                  stroke-dashoffset="{-(s.startPct / 100) * DONUT_CIRC}"
                  transform="rotate(-90 60 60)"
                  class="donut-slice"
                  class:donut-slice--dim={isDimmed}
                  role="presentation"
                  onmouseenter={() => (hoveredCategory = s.slug)}
                  onmouseleave={() => (hoveredCategory = null)}
                >
                  <title>{s.label}: {fmt(s.count)} ({s.pct.toFixed(1)}%)</title>
                </circle>
              {/each}
            </svg>
            <ul class="donut-legend">
              {#each categorySegments as s (s.slug)}
                {@const Icon = resolveCategoryIcon(s.icon)}
                {@const isHovered = hoveredCategory === s.slug}
                <li>
                  <button
                    class="legend-row"
                    class:legend-row--hover={isHovered}
                    onclick={() => jumpToCategory(s.slug)}
                    onmouseenter={() => (hoveredCategory = s.slug)}
                    onmouseleave={() => (hoveredCategory = null)}
                    onfocus={() => (hoveredCategory = s.slug)}
                    onblur={() => (hoveredCategory = null)}
	                    title={discoverCategoryTitle(s.label, s.slug === "__other__")}
                  >
                    <span class="legend-dot" style="background: {s.color}"></span>
                    <span class="legend-icon"><Icon size={12} /></span>
                    <span class="legend-label truncate">{s.label}</span>
                    <span class="legend-count">{fmt(s.count)}</span>
                    <span class="legend-pct text-muted">{s.pct.toFixed(1)}%</span>
                  </button>
                </li>
              {/each}
            </ul>
          </div>
        </section>
        {/if}
      </div>

      <!-- Phase 12f — GitHub personal-stats card. Only when signed in,
           toggle enabled, and paranoid mode off. Hidden entirely
           otherwise so signed-out users see nothing about it. -->
      {#if personalStatsEligible}
        <section class="card">
          <div class="card-head">
            <h2><span class="gh-card-icon"><GitBranch size={16} /></span> GitHub</h2>
            {#if github.status?.username}
              <span class="text-muted gh-handle">@{github.status.username}</span>
            {/if}
          </div>
          <div class="gh-card-body">
            {#if personalGithubTotal === 0}
              <p class="text-muted">
	                {ui.locale === "ru" ? "У установленных пакетов нет домашней страницы GitHub." : "None of your installed packages have a GitHub homepage."}
              </p>
            {:else if personalStatsLoading && personalStarredCount === 0}
              <div class="gh-loading">
                <Loader size={14} class="spin-slow" />
	                <span>{ui.locale === "ru" ? `Проверяем, для скольких из ${fmt(personalGithubTotal)} пакетов вы поставили звезду…` : `Checking which of your ${personalGithubTotal} packages you've starred…`}</span>
              </div>
            {:else}
              <p class="gh-line">
                <Star size={14} class="gh-line-icon" fill="currentColor" />
                <span>
	                  {#if ui.locale === "ru"}
	                    Вы поставили звезду для
	                    <strong>{fmt(personalStarredCount)}</strong>
	                    из
	                    <strong>{fmt(personalGithubTotal)}</strong>
	                    установленных пакетов с домашней страницей GitHub.
	                  {:else}
	                    You've starred
	                    <strong>{personalStarredCount}</strong>
	                    of
	                    <strong>{personalGithubTotal}</strong>
	                    installed packages with GitHub homepages.
	                  {/if}
                </span>
              </p>
              {#if personalStatsLoading}
                <p class="gh-line-sub">
                  <Loader size={12} class="spin-slow" />
	                  <span>{t("Refreshing…", ui.locale)}</span>
                </p>
              {/if}
            {/if}
          </div>
        </section>
      {/if}

      <!-- Storage -->
      <section class="card">
        <div class="card-head">
          <h2>Storage</h2>
          <div class="head-right">
            {#if disk}
              <span class="text-muted total">{fmtBytes(disk.totalBytes)} total</span>
            {/if}
            <Button
              size="sm"
              variant="ghost"
              onclick={() => loadDisk(true)}
              ariaLabel={t("storage.refreshDiskUsage", ui.locale)}
              title={t("Refresh", ui.locale)}
              disabled={diskLoading}
            >
              {#snippet icon()}<RefreshCw size={14} />{/snippet}
              {t("Refresh", ui.locale)}
            </Button>
          </div>
        </div>
        {#if diskLoading && !disk}
          <LoadingState rows={4} label={t("storage.measuringDiskUsage", ui.locale, { prefix: env.report?.prefix ?? "Homebrew" })} />
        {:else if diskError && !disk}
          <div class="storage-error">
            <AlertCircle size={16} />
            <span>{diskError}</span>
          </div>
        {:else if disk}
          <ul class="storage-list">
            <!-- Linux: no casks → the Caskroom row (always "not present"
                 there) is dropped. macOS renders every entry as-is. -->
            {#each disk.entries.filter((e) => !isLinux || e.label !== "Casks (Caskroom)") as e (e.path)}
              <li>
                <div class="storage-row">
                  <span class="s-label">{storageLabel(e.label)}</span>
                  <span class="s-path text-muted truncate" title={e.path}>{e.path}</span>
                  <span class="s-bytes mono">
                    {#if e.error}
                      <span class="s-bytes-err" title={e.error}>—</span>
                    {:else if !e.exists}
                      <span class="text-muted">{t("storage.notPresent", ui.locale)}</span>
                    {:else}
                      {fmtBytes(e.bytes)}
                    {/if}
                  </span>
                  <button
                    class="s-open"
                    onclick={() => reveal(e.path)}
                    disabled={!e.exists}
                    title={e.exists ? (isMac ? t("storage.revealInFinder", ui.locale, { path: e.path }) : t("storage.showInFileManager", ui.locale, { path: e.path })) : t("storage.pathMissing", ui.locale)}
                    aria-label={isMac ? t("storage.revealLabelInFinder", ui.locale, { label: storageLabel(e.label) }) : t("storage.showLabelInFileManager", ui.locale, { label: storageLabel(e.label) })}
                  >
                    <FolderOpen size={14} />
                  </button>
                </div>
              </li>
            {/each}
          </ul>
        {/if}

        <!-- Issue #80 — cache maintenance. brew doctor (read-only diagnostics)
             and brew cleanup (reclaim cached downloads), both streamed into the
             Activity drawer. Lives on the Storage card since it already shows
             the Download cache size. -->
        <div class="storage-maint">
          <div class="maint-actions">
            <Button
              size="sm"
              variant="ghost"
              onclick={runDoctor}
              disabled={maintBusy}
              title="Run brew doctor and stream the diagnostics into Activity"
            >
              {#snippet icon()}<Stethoscope size={14} />{/snippet}
              {doctorRunning ? "Running…" : "Run brew doctor"}
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onclick={() => (cleanupConfirmOpen = !cleanupConfirmOpen)}
              disabled={maintBusy}
              title={ui.locale === "ru" ? "Освободить место в кэше загрузок (brew cleanup --prune=all)" : "Reclaim cached downloads (brew cleanup --prune=all)"}
            >
              {#snippet icon()}<Trash2 size={14} />{/snippet}
              {cleanupRunning ? t("Cleaning…", ui.locale) : t("Clean up cache…", ui.locale)}
            </Button>
            {#if cleanupPreview?.reclaimableBytes}
              <span class="maint-hint text-muted">frees ~{fmtBytes(cleanupPreview.reclaimableBytes)}</span>
            {/if}
          </div>

          {#if cleanupConfirmOpen}
              <div class="maint-confirm" role="group" aria-label={ui.locale === "ru" ? "Подтверждение очистки кэша" : "Confirm cache cleanup"}>
                <p>
                {#if ui.locale === "ru"}
                  Удалит устаревшие загрузки из кэша{#if cleanupPreview?.reclaimableBytes}, освободив около
                  <strong>{fmtBytes(cleanupPreview.reclaimableBytes)}</strong>{/if}.{#if cleanupScrub}
                  Также удалит загрузки <strong>текущих</strong> версий (<code>--scrub</code>).{/if}
                  Установленные пакеты не будут затронуты.
                {:else}
                  Removes outdated cached downloads{#if cleanupPreview?.reclaimableBytes}, freeing about
                  <strong>{fmtBytes(cleanupPreview.reclaimableBytes)}</strong>{/if}.{#if cleanupScrub}
                  Also clears the <strong>current</strong> versions' downloads (<code>--scrub</code>).{/if}
                  Your installed packages are not affected.
                {/if}
              </p>
              <label class="maint-verbose">
                <input type="checkbox" bind:checked={cleanupScrub} />
                {t("Scrub — also remove the latest versions' cached downloads (more aggressive)", ui.locale)}
              </label>
              <label class="maint-verbose">
                <input type="checkbox" bind:checked={cleanupVerbose} />
                {t("Verbose — list every file removed", ui.locale)}
              </label>
              <div class="maint-confirm-actions">
                <Button size="sm" variant="ghost" onclick={() => (cleanupConfirmOpen = false)}>{t("Cancel", ui.locale)}</Button>
                <Button size="sm" variant="danger" onclick={runCleanup}>
                  {#snippet icon()}<Trash2 size={14} />{/snippet}
                  {t("Clean up", ui.locale)}
                </Button>
              </div>
            </div>
          {/if}
        </div>
      </section>

      <!-- v0.5.0 — Exposure card. Opt-in only; hidden entirely when
           the Settings → Vulnerability Scanning toggle is off so the
           dashboard doesn't nag users who haven't enabled it. -->
      {#if exposureVisible}
        <section class="card">
          <div class="card-head">
            <h2>
              <span class="exp-card-icon">
                {#if exposureFresh && exposureCounts.vulnerablePackages === 0}
                  <ShieldCheck size={16} />
                {:else}
                  <ShieldAlert size={16} />
                {/if}
              </span>
              {t("Exposure", ui.locale)}
            </h2>
            <div class="head-right">
              {#if exposureScannedAt}
	                <span class="text-muted total">{ui.locale === "ru" ? "Последняя проверка" : "Last scan"}: {exposureLastLabel}</span>
              {/if}
              <Button
                size="sm"
                variant="ghost"
                onclick={scanExposureNow}
	                ariaLabel={t("Scan installed packages for known vulnerabilities", ui.locale)}
	                title={t("settings.vulnerabilities.scanAllTitle", ui.locale)}
                disabled={exposureLoading}
              >
                {#snippet icon()}<RefreshCw size={14} />{/snippet}
	                {exposureLoading ? t("Scanning…", ui.locale) : t("Scan now", ui.locale)}
              </Button>
            </div>
          </div>
          <div class="exp-body">
            {#if !exposureScannedAt}
              <!-- Never scanned: a HAZARD, not a gentle suggestion. We must not
                   imply safety we haven't verified. -->
              <div class="exp-clean exp-warn">
                <AlertCircle size={20} class="exp-warn-icon" />
                <div>
	                  <strong>{t("Not scanned yet.", ui.locale)}</strong>
	                  <p class="text-muted exp-sub">
	                    {ui.locale === "ru"
	                      ? "Мы ещё не проверяли установленные пакеты на известные уязвимости. Запустите проверку, когда сможете. Настраивается в «Настройки → Проверка уязвимостей»."
	                      : "We haven't checked your installed packages for known vulnerabilities. Run a scan when you can. (Configured in Settings → Vulnerability Scanning.)"}
	                  </p>
                </div>
              </div>
            {:else if exposureCounts.vulnerablePackages === 0 && !exposureFresh}
              <!-- Clean LAST scan, but the report is stale (cached / served on
                   launch). Don't claim all-clear — caution + re-scan prompt. -->
              <div class="exp-clean exp-warn">
                <AlertCircle size={20} class="exp-warn-icon" />
                <div>
	                  <strong>{ui.locale === "ru" ? `На момент последней проверки (${exposureLastLabel}) известных уязвимостей нет.` : `No advisories as of the last scan (${exposureLastLabel}).`}</strong>
	                  <p class="text-muted exp-sub">
	                    {ui.locale === "ru" ? "С тех пор набор пакетов мог измениться. Проверьте ещё раз для подтверждения." : "Packages may have changed since. Re-scan to confirm."}
	                  </p>
                </div>
              </div>
            {:else if exposureCounts.vulnerablePackages === 0}
              <!-- Freshly clean. This is a GOOD result — frame it positively. -->
              <div class="exp-clean">
                <CheckCircle2 size={20} />
                <div>
	                  <strong>{t("No known vulnerabilities.", ui.locale)}</strong>
	                  <p class="text-muted exp-sub">
	                    {ui.locale === "ru"
	                      ? "Для установленных пакетов нет уязвимостей, известных brew vulns"
	                      : "All installed packages are clean of advisories known to brew vulns"}{#if exposureSource} · {t("source", ui.locale)}: {exposureSource}{/if}.
	                  </p>
                </div>
              </div>
            {:else}
              <!-- Findings present. Show per-severity counts with tone
                   colors, plus the "X of N" summary line. -->
	              <div class="exp-sev-row" role="group" aria-label={ui.locale === "ru" ? "Количество уязвимостей по серьёзности" : "Vulnerability counts by severity"}>
	                <span class="exp-sev exp-sev--danger">
	                  <strong>{fmt(exposureCounts.critical)}</strong> {severityLabel(exposureCounts.critical, "critical")}
	                </span>
	                <span class="exp-sev exp-sev--danger">
	                  <strong>{fmt(exposureCounts.high)}</strong> {severityLabel(exposureCounts.high, "high")}
	                </span>
	                <span class="exp-sev exp-sev--warning">
	                  <strong>{fmt(exposureCounts.medium)}</strong> {severityLabel(exposureCounts.medium, "medium")}
	                </span>
	                <span class="exp-sev exp-sev--info">
	                  <strong>{fmt(exposureCounts.low)}</strong> {severityLabel(exposureCounts.low, "low")}
	                </span>
	                {#if exposureCounts.unknown > 0}
	                  <span class="exp-sev exp-sev--neutral">
	                    <strong>{fmt(exposureCounts.unknown)}</strong> {severityLabel(exposureCounts.unknown, "unknown")}
	                  </span>
                {/if}
              </div>
              <!-- Findings total + package count: the severity chips count
                   individual advisories, so spell out "N findings across M of T
                   packages" rather than implying the chips sum to the package
                   count. Kept identical to the native Exposure card. -->
              <p class="exp-summary">
	                {exposureSummaryText()}
              </p>
              <div class="exp-actions">
                <button
                  type="button"
                  class="link exp-link"
                  onclick={viewVulnerablePackages}
                >
	                  {t("security.viewVulnerablePackages", ui.locale)}
                </button>
              </div>
            {/if}
          </div>
        </section>
      {/if}

    {/if}
  </div>
</section>

<UpgradeModal
  open={upgradeModalOpen}
  onClose={() => (upgradeModalOpen = false)}
/>

<style>
  .dashboard { display: flex; flex-direction: column; min-height: 0; height: 100%; }

  .body {
    flex: 1;
    overflow-y: auto;
    min-height: 0;
    padding: var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    /* Size container so the Composition/Categories pairing breakpoint tracks
       the content-pane width (sidebar + inspector excluded) — the CSS analog
       of native's onGeometryChange(>980) measurement. */
    container-type: inline-size;
    container-name: dash;
  }
  /* Flex children default to flex-shrink: 1, which causes the cards to be
     squashed to fit the viewport instead of overflowing the scroll container.
     Combined with `.card { overflow: hidden }`, that turned into vertical
     clipping. Pin shrink to 0 so cards keep their natural height and the
     overflow becomes a real scroll. */
  .body > * { flex-shrink: 0; }

  /* ─── Hero stats ──────────────────────────────────────── */
  .hero {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: var(--space-3);
  }
  .stat {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-template-rows: auto auto;
    gap: 4px var(--space-3);
    align-items: center;
    padding: var(--space-4);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    text-align: left;
    color: var(--color-text-primary);
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease, transform 0.12s ease;
  }
  .stat:hover:not(:disabled) {
    background: var(--color-surface);
    border-color: var(--color-accent);
    transform: translateY(-1px);
  }
  .stat:disabled { cursor: default; }
  .stat.dim { opacity: 0.75; }
  .stat-icon {
    grid-row: 1 / span 2;
    color: var(--color-accent);
    display: inline-flex;
  }
  .stat--accent .stat-icon { color: var(--color-brand); }
  .stat-value {
    font-size: 1.4rem;
    font-weight: var(--fw-semibold);
    line-height: 1.1;
  }
  .stat-label {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
  }

  /* ─── Catalog freshness line (Phase 12a) ──────────────── */
  .catalog-line {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    margin-top: calc(-1 * var(--space-2));
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
  }
  .catalog-line--stale {
    color: var(--color-warning-strong);
  }
  .catalog-text strong {
    color: var(--color-text-primary);
    font-weight: var(--fw-medium);
  }
  .catalog-line--stale .catalog-text strong {
    color: var(--color-warning-strong);
  }
  .catalog-source {
    font-size: var(--text-caption);
    margin-left: 4px;
  }
  .catalog-refresh {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px var(--space-2);
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-link);
    font-size: var(--text-body-sm);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease;
  }
  .catalog-refresh:hover:not(:disabled) {
    background: var(--color-surface-sunken);
    text-decoration: underline;
  }
  .catalog-refresh:disabled {
    cursor: default;
    opacity: 0.7;
  }
  .catalog-line--stale .catalog-refresh {
    color: var(--color-warning-strong);
    font-weight: var(--fw-medium);
  }

  /* ─── Card ────────────────────────────────────────────── */
  .card {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    overflow: hidden;
  }
  .card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: var(--space-3) var(--space-4);
    border-bottom: 1px solid var(--color-border);
  }
  .card-head h2 {
    font-size: var(--text-h3, 1rem);
    font-weight: var(--fw-semibold);
    margin: 0;
  }
  /* Right-side cluster for the Updates card's two upgrade actions
     ("Choose…" + "Upgrade all"). Tight gap keeps them paired visually. */
  .updates-actions {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
  }
  .card-title-link {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: transparent;
    color: var(--color-text-primary);
    padding: 0;
    cursor: pointer;
    border-radius: var(--radius-sm);
    transition: color 0.12s ease;
  }
  .card-title-link:hover { color: var(--color-text-link); }
  .card-title-link:hover .card-title-chevron { transform: translateX(2px); }
  .card-title-chevron {
    color: var(--color-text-muted);
    font-size: var(--text-body);
    transition: transform 0.12s ease, color 0.12s ease;
  }
  .card-title-link:hover .card-title-chevron { color: var(--color-text-link); }
  .card-foot {
    padding: var(--space-2) var(--space-4);
    border-top: 1px solid var(--color-border);
  }
  .link {
    background: transparent;
    color: var(--color-text-link);
    font-size: var(--text-body-sm);
    cursor: pointer;
  }
  .link:hover { text-decoration: underline; }

  /* ─── Updates list ────────────────────────────────────── */
  .outdated-list { display: flex; flex-direction: column; }
  .outdated-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 80px 1fr;
    gap: var(--space-3);
    align-items: center;
    width: 100%;
    padding: var(--space-2) var(--space-4);
    text-align: left;
    color: var(--color-text-primary);
    border-bottom: 1px solid var(--color-border);
    cursor: pointer;
    transition: background 0.12s ease;
  }
  .outdated-row:hover { background: var(--color-surface-sunken); }
  .outdated-row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .outdated-row.selected .o-version { color: inherit; }
  .outdated-list li:last-child .outdated-row { border-bottom: none; }
  .o-name { font-weight: var(--fw-medium); }
  /* Keep the "old → new" version pair on one line — never break between a
     version and its arrow. The name column (minmax(0,1fr) + .truncate) absorbs
     any width pressure instead, so long cask versions (e.g. docker-desktop's
     "4.77.0,228796") stay readable as a single row. */
  .o-version { font-size: var(--text-body-sm); white-space: nowrap; }

  /* ─── Split ───────────────────────────────────────────── */
  .split { padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-3); }
  .split-bar {
    display: flex;
    height: 12px;
    border-radius: var(--radius-full);
    overflow: hidden;
    background: var(--color-surface-sunken);
  }
  .seg { display: block; height: 100%; }
  .seg--formula { background: var(--color-info, #4a90e2); }
  .seg--cask { background: var(--color-brand, #f59e0b); }
  .split-legend { display: flex; gap: var(--space-4); flex-wrap: wrap; font-size: var(--text-body-sm); color: var(--color-text-secondary); }
  .legend { display: inline-flex; align-items: center; gap: 6px; }
  .legend strong { color: var(--color-text-primary); }
  .swatch { width: 10px; height: 10px; border-radius: 2px; }
  .swatch--formula { background: var(--color-info, #4a90e2); }
  .swatch--cask { background: var(--color-brand, #f59e0b); }
  .meta-pill {
    display: inline-flex;
    align-items: center;
    padding: 2px var(--space-2);
    height: 20px;
    border-radius: var(--radius-full);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
  }

  /* ─── Composition + Categories pairing ────────────────── */
  /* Stacked full-width by default; two-across once the pane is wide enough
     AND both cards are present (`paired`). When paired+wide, Composition
     swaps its horizontal bar for a pie (rhymes with the categories donut). */
  .dash-pair {
    display: grid;
    grid-template-columns: 1fr;
    gap: var(--space-4);
  }
  .comp-card { min-width: 0; }
  /* on-request / pinned chips, right-aligned in the card header (the
     .card-head is already a space-between flex row, so this pins right). */
  .comp-chips { display: inline-flex; flex-wrap: wrap; gap: var(--space-2); }
  .comp-bar { display: flex; flex-direction: column; gap: var(--space-3); }
  .comp-pie { display: none; }

  @container dash (min-width: 820px) {
    /* stretch (grid default) so both cards share the taller card's height,
       matching native's .frame(maxHeight: .infinity) bottom-alignment. */
    .dash-pair.paired { grid-template-columns: 1fr 1fr; align-items: stretch; }
    .dash-pair.paired .comp-bar { display: none; }
    /* Cards become flex columns so each chart body fills the (equal) card
       height, letting the chart sit vertically centered — like native, where
       both 180×180 charts are center-aligned in equal-height cards. Centering
       both same-size charts in equal bodies is what makes them line up. */
    .dash-pair.paired > .card { display: flex; flex-direction: column; }
    .dash-pair.paired .split { flex: 1; justify-content: center; }
    .dash-pair.paired .donut-wrap { flex: 1; align-items: center; }
    .dash-pair.paired .comp-pie {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      gap: var(--space-4);
      align-items: center;
    }
  }

  /* Same diameter as the categories donut (180px) so the paired charts read
     as a matched set, like native (both .frame(180×180)). */
  .pie { width: 180px; height: 180px; flex-shrink: 0; }
  .pie-legend { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .pie-legend li {
    display: grid;
    grid-template-columns: 10px minmax(0, 1fr) auto 48px;
    gap: var(--space-2);
    align-items: center;
    padding: 4px var(--space-2);
    font-size: var(--text-body-sm);
  }
  .pie-legend .legend-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ─── Donut chart + legend ────────────────────────────── */
  .donut-wrap {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: var(--space-4);
    align-items: center;
    padding: var(--space-4);
  }
  .donut { width: 180px; height: 180px; flex-shrink: 0; }
  .donut-track {
    fill: none;
    stroke: var(--color-surface-sunken);
    stroke-width: 24;
  }
  .donut-legend { display: flex; flex-direction: column; gap: 4px; }
  .legend-row {
    display: grid;
    grid-template-columns: 8px 14px minmax(0, 1fr) 50px 56px;
    gap: var(--space-2);
    align-items: center;
    width: 100%;
    padding: 4px var(--space-2);
    border-radius: var(--radius-sm);
    text-align: left;
    color: var(--color-text-primary);
    cursor: pointer;
    font-size: var(--text-body-sm);
    transition: background 0.12s ease;
  }
  .legend-row:hover,
  .legend-row--hover {
    background: var(--color-surface-sunken);
  }

  /* Donut slices animate width on hover; dimmed siblings fade so the
     hovered slice pops without losing context. Stroke-width transitions
     are SVG-friendly (unlike most CSS animations on SVG attributes). */
  .donut-slice {
    transition: stroke-width 120ms ease-out, opacity 120ms ease-out;
  }
  .donut-slice--dim {
    opacity: 0.35;
  }
  @media (prefers-reduced-motion: reduce) {
    .donut-slice { transition: none; }
  }
  .legend-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }
  .legend-icon { color: var(--color-text-secondary); display: inline-flex; }
  .legend-count {
    font-variant-numeric: tabular-nums;
    text-align: right;
  }
  .legend-pct {
    font-variant-numeric: tabular-nums;
    font-size: var(--text-caption);
    text-align: right;
  }
  @media (max-width: 720px) {
    .donut-wrap { grid-template-columns: 1fr; justify-items: center; }
  }

  /* ─── Storage card ────────────────────────────────────── */
  .head-right { display: flex; align-items: center; gap: var(--space-3); }
  .total { font-size: var(--text-body-sm); }
  .storage-list { display: flex; flex-direction: column; }
  .storage-row {
    display: grid;
    grid-template-columns: 180px minmax(0, 1fr) 100px 32px;
    gap: var(--space-3);
    align-items: center;
    padding: var(--space-2) var(--space-4);
    border-bottom: 1px solid var(--color-border);
  }
  .storage-list li:last-child .storage-row { border-bottom: none; }
  .s-label { font-weight: var(--fw-medium); font-size: var(--text-body-sm); }
  .s-path { font-family: var(--font-mono); font-size: var(--text-caption); }
  .s-bytes { font-size: var(--text-body-sm); text-align: right; }
  .s-bytes-err { color: var(--color-warning-strong); }
  .s-open {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 24px;
    border-radius: var(--radius-sm);
    color: var(--color-text-muted);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease;
  }
  .s-open:not(:disabled):hover {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }
  .s-open:disabled { opacity: 0.35; cursor: default; }
  .storage-error {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-4);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
  }

  /* ─── Cache maintenance (Issue #80) ───────────────────── */
  .storage-maint {
    border-top: 1px solid var(--color-border);
    padding: var(--space-3) var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }
  .maint-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
  }
  .maint-hint {
    font-size: var(--text-body-sm);
    font-variant-numeric: tabular-nums;
  }
  .maint-confirm {
    padding: var(--space-3);
    border: 1px solid color-mix(in oklch, var(--color-danger) 38%, var(--color-border));
    border-radius: var(--radius-lg);
    background: color-mix(in oklch, var(--color-danger-subtle) 50%, var(--color-surface-raised));
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .maint-confirm p {
    margin: 0;
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-body);
  }
  .maint-confirm code {
    font-family: var(--font-mono);
    font-size: var(--text-caption);
  }
  .maint-verbose {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-body-sm);
    color: var(--color-text-primary);
  }
  .maint-confirm-actions {
    display: flex;
    gap: var(--space-2);
    justify-content: flex-end;
  }

  /* ─── GitHub personal-stats card (Phase 12f) ──────────── */
  .gh-card-icon {
    display: inline-flex;
    align-items: center;
    vertical-align: middle;
    margin-right: 4px;
    color: var(--color-text-secondary);
  }
  .gh-handle {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
  }
  .gh-card-body {
    padding: var(--space-3) var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .gh-line {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--color-text-primary);
    font-size: var(--text-body);
  }
  .gh-line strong {
    font-variant-numeric: tabular-nums;
    color: var(--color-brand);
  }
  .gh-line :global(.gh-line-icon) {
    color: var(--color-brand);
    flex: none;
  }
  .gh-line-sub {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
  }
  .gh-loading {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--color-text-muted);
    font-size: var(--text-body);
  }

  /* ─── Exposure card (v0.5.0 vulnerability scanning) ──── */
  .exp-card-icon {
    display: inline-flex;
    align-items: center;
    vertical-align: middle;
    margin-right: 4px;
    color: var(--color-text-secondary);
  }
  .exp-body {
    padding: var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }
  .exp-clean {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: var(--space-3);
    align-items: start;
    padding: var(--space-3);
    background: var(--color-success-subtle);
    border-radius: var(--radius-md);
    color: var(--color-success-on-subtle);
  }
  /* Never-scanned + stale-clean states reuse the .exp-clean layout but warn
     (amber), since a security tool must not imply safety it hasn't verified. */
  .exp-warn {
    background: var(--color-warning-subtle);
    color: var(--color-warning-on-subtle);
  }
  .exp-warn :global(.exp-warn-icon) { color: var(--color-warning-on-subtle); }
  .exp-clean strong {
    display: block;
    color: var(--color-success-on-subtle);
    font-size: var(--text-body);
    font-weight: var(--fw-semibold);
  }
  .exp-sub {
    margin-top: 2px;
    font-size: var(--text-body-sm);
    line-height: var(--lh-snug);
  }
  .exp-sev-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }
  .exp-sev {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    padding: 6px var(--space-3);
    border-radius: var(--radius-sm);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    font-variant-numeric: tabular-nums;
  }
  .exp-sev strong {
    font-size: var(--text-body);
    font-weight: var(--fw-semibold);
  }
  .exp-sev--danger  { background: var(--color-danger-subtle);  color: var(--color-danger-on-subtle); }
  .exp-sev--warning { background: var(--color-warning-subtle); color: var(--color-warning-on-subtle); }
  .exp-sev--info    { background: var(--color-info-subtle);    color: var(--color-info-on-subtle); }
  .exp-sev--neutral { background: var(--color-surface-sunken); color: var(--color-text-secondary); }
  .exp-summary {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
    margin: 0;
  }
  .exp-actions {
    display: inline-flex;
    align-items: center;
    gap: var(--space-3);
  }
  .exp-link {
    font-size: var(--text-body-sm);
  }

  /* ─── Error card ──────────────────────────────────────── */
  .error-card {
    display: grid;
    grid-template-columns: auto 1fr auto;
    gap: var(--space-3);
    align-items: center;
    padding: var(--space-3) var(--space-4);
    background: var(--color-danger-subtle, rgba(239, 68, 68, 0.08));
    border: 1px solid var(--color-danger, #ef4444);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
  }
</style>
