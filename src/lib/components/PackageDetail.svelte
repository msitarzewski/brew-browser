<script lang="ts">
  import { onMount, untrack } from "svelte";
  import X from "@lucide/svelte/icons/x";
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import ChevronDown from "@lucide/svelte/icons/chevron-down";
  import ChevronRight from "@lucide/svelte/icons/chevron-right";
  import Download from "@lucide/svelte/icons/download";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import RefreshCcw from "@lucide/svelte/icons/refresh-ccw";
  import ArrowUpCircle from "@lucide/svelte/icons/arrow-up-circle";

  import Pill from "./Pill.svelte";
  import Button from "./Button.svelte";
  import PackageRowIcon from "./PackageRowIcon.svelte";
  import DestructiveConfirm from "./DestructiveConfirm.svelte";
  import InfoButton from "./InfoButton.svelte";
  import LoadingState from "./LoadingState.svelte";
  import Play from "@lucide/svelte/icons/play";
  import Square from "@lucide/svelte/icons/square";
  import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
  import Star from "@lucide/svelte/icons/star";
  import GitFork from "@lucide/svelte/icons/git-fork";
  import Tag from "@lucide/svelte/icons/tag";
  import Archive from "@lucide/svelte/icons/archive";
  import Loader from "@lucide/svelte/icons/loader-2";
  import AlertCircle from "@lucide/svelte/icons/alert-circle";

  import MessageSquarePlus from "@lucide/svelte/icons/message-square-plus";
  import EyeIcon from "@lucide/svelte/icons/eye";
  import EyeOff from "@lucide/svelte/icons/eye-off";

  import { ui } from "$lib/stores/ui.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { t, ruPlural, type Locale } from "$lib/i18n/messages";
  import { categories } from "$lib/stores/categories.svelte";
  import { discover } from "$lib/stores/discover.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { env } from "$lib/stores/env.svelte";
  import { github, type RepoStatsOutcome, type StarredOutcome } from "$lib/stores/github.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import ShieldAlert from "@lucide/svelte/icons/shield-alert";
  import Shield from "@lucide/svelte/icons/shield";
  import { brewInfo, brewInstall, brewUninstall, brewUpgrade, appVersion, catalogReverseDependents } from "$lib/api";
  import { isLinux } from "$lib/util/platform";
  import { safeOpenUrl } from "$lib/util/url";
  import { bareToken } from "$lib/util/token";
  import { fmtBytes } from "$lib/util/format";
  import { reportableToastError } from "$lib/util/reportIssue";
  import { resolveCategoryIcon } from "$lib/util/categoryIcon";
  import IssueModal from "./IssueModal.svelte";
  import TrendingSparkline from "./TrendingSparkline.svelte";
  import { trendingHistory } from "$lib/stores/trendingHistory.svelte";
  import { brewErrorMessage, isBrewError, normalizeServiceStatus, type EnrichmentEntry, type IconSource, type PackageDetail, type RawVuln, type ReverseDependent, type Severity } from "$lib/types";

  // Categories file is small; ensure it's loaded so the pills can render. Idempotent.
  categories.ensureLoaded();
  // Phase 13: enrichment bundle is also small (< 5 MiB) and only parses
  // once; lazy-load on detail open so it's ready by the time the user
  // scrolls. Idempotent — the store guards duplicate fetches.
  enrichment.ensureLoaded();

  // Small transparency label for the meta row — keeps "where did this come from?"
  // visible without painting a whole section. Skips into a tooltip for the
  // homepage URL so the line itself stays one token wide.
  function iconSourceLabel(src: IconSource): string {
    switch (src.kind) {
      case "installedApp": return t("icon.source.installedApp", ui.locale);
      case "homepage":     return t("icon.source.homepage", ui.locale);
      case "none":         return t("icon.source.none", ui.locale);
    }
  }
  function iconSourceTitle(src: IconSource): string | undefined {
    return src.kind === "homepage"
      ? t("icon.source.faviconFrom", ui.locale, { homepage: src.homepage })
      : undefined;
  }

  let detail = $state<PackageDetail | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);

  let depsOpen = $state(false);
  let dependentsOpen = $state(false);
  // Feature #1 — reverse dependencies ("Required by"). Catalog-graph
  // inversion fetched alongside the detail; collapsible like Dependencies.
  let reqByOpen = $state(false);
  let dependents = $state<ReverseDependent[]>([]);
  let confirmUninstall = $state(false);
  let confirmExternalInstall = $state(false);

  // Focus management for the slide-over (A11Y-2 / WCAG 2.4.3).
  // When the panel opens (null → truthy), capture the previously-focused element
  // and move focus to the panel heading. When it closes (truthy → null), restore.
  let headingEl: HTMLHeadingElement | undefined = $state();
  let openerEl: HTMLElement | null = null;
  let lastOpen = false;

  // Reload when selected package changes (also handles focus open/close transitions)
  $effect(() => {
    const sel = ui.selectedPackage;
    const isOpen = !!sel;

    if (isOpen && !lastOpen) {
      // null → truthy: opening
      const active = document.activeElement;
      openerEl = active instanceof HTMLElement ? active : null;
      queueMicrotask(() => headingEl?.focus());
    } else if (!isOpen && lastOpen) {
      // truthy → null: closing — restore focus to the opener
      const toFocus = openerEl;
      openerEl = null;
      queueMicrotask(() => toFocus?.focus?.());
    }
    lastOpen = isOpen;

    if (!sel) {
      untrack(() => {
        detail = null;
        error = null;
      });
      return;
    }
    untrack(() => loadDetail(sel.name, sel.kind));
  });

  async function loadDetail(name: string, kind: "formula" | "cask") {
    loading = true;
    error = null;
    detail = null;
    // Reset reverse-deps for the new package; refilled below.
    dependents = [];
    reqByOpen = false;
    try {
      detail = await brewInfo(name, kind);
    } catch (e) {
      // A tap-qualified name (`user/tap/name`) that isn't tapped locally makes
      // `brew info` fail. Retry the bare name — the core formula the list's
      // catalog/enrichment data already resolved to.
      const bare = bareToken(name);
      if (bare !== name) {
        try {
          detail = await brewInfo(bare, kind);
        } catch {
          error = isBrewError(e) ? brewErrorMessage(e, ui.locale) : t("trending.error.backend", ui.locale, { error: String(e) });
        }
      } else {
        error = isBrewError(e) ? brewErrorMessage(e, ui.locale) : t("trending.error.backend", ui.locale, { error: String(e) });
      }
    } finally {
      loading = false;
    }
    // v0.4.0 — fire-and-forget enhanced-trending series fetch. The
    // store's internal `enabled` getter no-ops when the toggle is off
    // or Offline Mode is on, so this is safe to call unconditionally.
    // Soft-fails — sparkline simply doesn't appear if fetch fails.
    void trendingHistory.ensureSeriesLoaded(name, kind);
    // Feature #1 — reverse dependencies. Pure catalog-graph inversion
    // (no subprocess, no network). Key on the bare token: the catalog
    // graph stores bare formula tokens, while `name` may be tap-qualified
    // (`user/tap/foo`). Soft-fails to an empty set — the section simply
    // doesn't appear if the lookup errors. Guarded against a stale
    // response overwriting a newer selection via the token check.
    {
      const reqToken = bareToken(name);
      void catalogReverseDependents(reqToken)
        .then((res) => {
          // Only apply if the user is still looking at this package.
          if (ui.selectedPackage && bareToken(ui.selectedPackage.name) === reqToken) {
            dependents = res.dependents;
          }
        })
        .catch(() => {
          /* leaf / unknown / catalog-corrupt → no section */
        });
    }
    // Opt-in live enrichment: fetch fresher friendly-name/summary/etc. for the
    // package being viewed and overlay it. No-ops unless the user opted in
    // (toggle + not paranoid + AI on); soft-fails to the bundled entry.
    void enrichment.ensureLive(name);
  }

  async function doInstall(force = false) {
    if (!ui.selectedPackage) return;
    const { name, kind } = ui.selectedPackage;
    const tmpId = crypto.randomUUID();
    activity.startJob(ui.locale === "ru" ? `Устанавливаем ${name}` : `Installing ${name}`, tmpId, `brew install ${name}${force ? " --force" : ""}`);
    ui.openDrawer();
    try {
      const result = await brewInstall(name, kind, force, (evt) => {
        // first event will carry the real jobId; rewrite if needed
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
      if (result.success) {
        toast.success(ui.locale === "ru" ? `Установлено: ${name}` : `Installed ${name}`);
        packages.load(true);
        if (ui.selectedPackage) loadDetail(ui.selectedPackage.name, ui.selectedPackage.kind);
        // v0.5.0 — newly installed package has no scan record. Kick a
        // single-package scan so the Security card populates without
        // waiting for the next full Refresh. After the scan completes,
        // surface a one-time-per-session heads-up if the user has
        // known vulnerabilities ELSEWHERE in their install — the
        // "install a thing → notice you have N existing CVEs" moment.
        if (settings.effective.vulnerabilityScanningEnabled) {
          vulnerabilities
            .scanOne(kind, name)
            .then(() => vulnerabilities.maybeNotifyExposure())
            .catch(() => {});
        }
      }
    } catch (e) {
      reportableToastError(ui.locale === "ru" ? "Не удалось установить" : "Install failed", e);
    }
  }

  function handleInstallClick() {
    if (pkg && pkg.kind === "cask" && !pkg.installedVersion && detail?.existsInApplications) {
      confirmExternalInstall = true;
    } else {
      doInstall(false);
    }
  }

  async function doUninstall() {
    if (!ui.selectedPackage) return;
    confirmUninstall = false;
    const { name, kind } = ui.selectedPackage;
    const tmpId = crypto.randomUUID();
    activity.startJob(ui.locale === "ru" ? `Удаляем ${name}` : `Uninstalling ${name}`, tmpId, `brew uninstall ${name}`);
    ui.openDrawer();
    try {
      const result = await brewUninstall(name, kind, false, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
      if (result.success) {
        toast.success(ui.locale === "ru" ? `Удалено: ${name}` : `Uninstalled ${name}`);
        // v0.5.0 — drop the vuln cache entry for the version we just removed.
        // Safe even when feature is off (no-op). Capture installedVersion
        // BEFORE closeDetail/packages.load wipes our `pkg` derived.
        const removedVersion = pkg?.installedVersion ?? null;
        packages.load(true);
        if (removedVersion) {
          vulnerabilities.invalidate(kind, name, removedVersion).catch(() => {});
        }
        ui.closeDetail();
      }
    } catch (e) {
      reportableToastError(ui.locale === "ru" ? "Не удалось удалить" : "Uninstall failed", e);
    }
  }

  async function doUpgrade() {
    if (!ui.selectedPackage) return;
    const { name, kind } = ui.selectedPackage;
    const tmpId = crypto.randomUUID();
    activity.startJob(ui.locale === "ru" ? `Обновляем ${name}` : `Upgrading ${name}`, tmpId, `brew upgrade ${name}`);
    ui.openDrawer();
    try {
      const result = await brewUpgrade(name, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      }, ui.greedyUpgrade);
      if (result.success) {
        toast.success(ui.locale === "ru" ? `Обновлено: ${name}` : `Upgraded ${name}`);
        // v0.5.0 — old version gone, new version installed. Drop the old
        // vuln entry and re-scan so the Security card reflects the patched
        // state immediately. Capture oldVersion BEFORE packages.load
        // refreshes `pkg` with the new installedVersion.
        const oldVersion = pkg?.installedVersion ?? null;
        packages.load(true);
        if (ui.selectedPackage) loadDetail(ui.selectedPackage.name, ui.selectedPackage.kind);
        if (oldVersion) {
          await vulnerabilities.invalidate(kind, name, oldVersion).catch(() => {});
        }
        if (settings.effective.vulnerabilityScanningEnabled) {
          vulnerabilities
            .scanOne(kind, name)
            .then(() => vulnerabilities.maybeNotifyExposure())
            .catch(() => {});
        }
      }
    } catch (e) {
      reportableToastError(t("Upgrade failed", ui.locale), e);
    }
  }

  async function openHomepage(url: string) {
    // Scheme allowlist (http/https only) lives in safeOpenUrl — cask `homepage`
    // is attacker-influenced metadata; never hand a raw URL to the opener.
    // Security audit §H1 (memory-bank/security.md).
    await safeOpenUrl(url);
  }

  function close() { ui.closeDetail(); }

  // Helpful derived — explicit type to avoid `never` narrowing from union state.
  let pkg = $derived<PackageDetail["package"] | undefined>(detail?.package);
  let isInstalled = $derived(!!pkg?.installedVersion);
  let isOutdated = $derived(!!pkg?.outdated);
  // Casks are macOS-only; the backend already keeps them out of Discover and
  // search on Linux, but detail can still surface one (snapshots, deep links)
  // — never offer an Install that can only fail with "macOS is required".
  let caskOnLinux = $derived(isLinux && ui.selectedPackage?.kind === "cask");

  // ────────────────────────────────────────────────────────────────
  // Feature #2 — deprecation / disabled notice.
  //
  // `pkg` comes from `brew info`, so it carries the richest data: flags,
  // reason, date, AND the replacement token (the catalog has no
  // replacement). `disabled` is the stronger state — when both are true
  // the notice shows the disabled (danger) variant. A package with
  // neither flag renders no notice (never a placeholder).
  //
  // The replacement is a clickable token routing via `ui.selectPackage`,
  // which re-fetches `brew info` for it. We infer the replacement's kind
  // the same way `openSimilar` does (loaded packages first, else formula
  // — the catalog doesn't carry kind for an arbitrary token). On Linux a
  // cask replacement still routes to detail, where the existing
  // `caskOnLinux` gate suppresses the install action — same already-gated
  // path, so no extra branch is needed here.
  let deprecationNotice = $derived.by<
    { kind: "deprecated" | "disabled"; reason: string | null; date: string | null; replacement: string | null } | null
  >(() => {
    if (!pkg) return null;
    if (pkg.disabled) {
      return {
        kind: "disabled",
        reason: pkg.disableReason,
        date: pkg.disableDate,
        replacement: pkg.disableReplacement,
      };
    }
    if (pkg.deprecated) {
      return {
        kind: "deprecated",
        reason: pkg.deprecationReason,
        date: pkg.deprecationDate,
        replacement: pkg.deprecationReplacement,
      };
    }
    return null;
  });

  /** Jump to a deprecation replacement's detail. Same kind-inference as
   *  {@link openSimilar} — the catalog doesn't carry the replacement's
   *  kind, so prefer a loaded package, else default to formula. */
  function openReplacement(token: string) {
    const installed = packages.all.find((p) => p.name === token);
    const kind = installed?.kind ?? "formula";
    ui.selectPackage(token, kind);
  }

  /** Categories assigned to this package (from `categories.json`). */
  let pkgCategories = $derived.by<string[]>(() => {
    if (!pkg) return [];
    return categories.categoriesOf(pkg.name, pkg.kind);
  });

  // ────────────────────────────────────────────────────────────────
  // Phase 13 — LLM-enriched metadata.
  //
  // `enriched` is null when EITHER the AI Features toggle is off OR
  // the bundled enrichment.json.gz is the placeholder (no real
  // enrichment baked in yet) OR this token has no entry. Components
  // gate on `enriched && enriched.<field>` (or `enriched.<field>?.length > 0`
  // for arrays) before painting any AI-derived UI.
  let enriched = $derived<EnrichmentEntry | null>(
    pkg ? enrichment.lookup(pkg.name) : null,
  );

  /** Open the "Wrong?" issue against msitarzewski/brew-browser for an
   *  enriched field. Title + body are tailored per field so the user
   *  doesn't have to retype context. Signed-in users get the in-app
   *  modal; everyone else gets a deeplink with URL-encoded params. */
  async function openWrongEnrichedIssue(field: "summary" | "friendly_name" | "use_cases" | "similar" | "tags") {
    if (!pkg) return;
    const ver = await ensureAppVersion();
    const fieldLabels: Record<typeof field, string> = {
      summary: "Summary",
      friendly_name: "Friendly name",
      use_cases: "Use cases",
      similar: "Similar packages",
      tags: "Tags",
    };
    const label = fieldLabels[field];
    const current = (() => {
      if (!enriched) return "(none)";
      switch (field) {
        case "summary":       return enriched.summary || "(none)";
        case "friendly_name": return enriched.friendlyName || "(none)";
        case "use_cases":     return enriched.useCases.join(" · ") || "(none)";
        case "similar":       return enriched.similar.join(", ") || "(none)";
        case "tags":          return enriched.tags.join(", ") || "(none)";
      }
    })();
    const title = `Wrong ${label.toLowerCase()} for ${pkg.name}`;
    const body = [
      `**Package:** ${pkg.name} (${pkg.kind})`,
      `**Field:** ${label}`,
      `**Currently:** ${current}`,
      `**Suggestion:** _your suggested ${label.toLowerCase()}_`,
      "",
      "---",
      `*Reported via brew-browser v${ver} on macOS (Homebrew ${env.report?.version ?? "unknown"})*`,
    ].join("\n");

    if (githubSignedIn) {
      issueTargetHomepage = "https://github.com/msitarzewski/brew-browser";
      issueTargetRepo = { owner: "msitarzewski", repo: "brew-browser" };
      issueInitialTitle = title;
      issueInitialBody = body;
      issueInitialLabels = ["enrichment-suggestion"];
      issueOpen = true;
    } else {
      const params = new URLSearchParams();
      params.set("title", title);
      params.set("body", body);
      params.set("labels", "enrichment-suggestion");
      const url = `https://github.com/msitarzewski/brew-browser/issues/new?${params.toString()}`;
      await safeOpenUrl(url);
    }
  }

  /** Jump to PackageDetail for a sibling token (used by "Similar packages"
   *  pills). Currently the catalog doesn't carry kind for an arbitrary
   *  token, so we infer from packages.isInstalled() when available, else
   *  default to formula (the common case). The PackageDetail panel will
   *  re-fetch `brew info` and pick up the actual kind from there. */
  function openSimilar(token: string) {
    // Try to pull the real kind from the loaded packages list first.
    const installed = packages.all.find((p) => p.name === token);
    const kind = installed?.kind ?? "formula";
    ui.selectPackage(token, kind);
  }

  /** Feature #1 — reverse dependents, filtered for the host platform.
   *  Cask dependents can only install on macOS, so on Linux we drop
   *  cask-kind rows entirely (a deep-linked formula must never offer a
   *  cask that can only fail). Formula→formula edges show everywhere —
   *  byte-identical to the macOS formula-graph result. */
  let visibleDependents = $derived<ReverseDependent[]>(
    isLinux ? dependents.filter((d) => d.kind !== "cask") : dependents,
  );

  /** Jump to a reverse-dependent's detail. The dependent's `kind` is
   *  authoritative (it came straight from the catalog), so we pass it
   *  directly rather than re-inferring like {@link openSimilar}. */
  function openDependent(dep: ReverseDependent) {
    ui.selectPackage(dep.name, dep.kind);
  }

  /** Short label for an edge type, shown after the name. "required" is
   *  the default and stays unlabelled to keep the list quiet; the rest
   *  are flagged so build-only / opt-in edges read honestly. */
  function edgeLabel(dep: ReverseDependent): string | null {
    if (dep.kind === "cask") return ui.locale === "ru" ? "cask-пакет" : "cask";
    switch (dep.edge) {
      case "build":       return ui.locale === "ru" ? "для сборки" : "build";
      case "recommended": return ui.locale === "ru" ? "рекомендуемая" : "recommended";
      case "optional":    return ui.locale === "ru" ? "опциональная" : "optional";
      case "required":    return null;
    }
  }

  /**
   * Jump to Discover with a category chip pre-selected. Closes the detail panel
   * so the user lands on the filtered view, not an obscured one.
   */
  function jumpToCategory(slug: string) {
    // Order matters: setSection clears chip filters on any real section
    // change, so we must call it BEFORE selectOnly. See ui.setSection().
    ui.closeDetail();
    ui.setSection("discover");
    discover.selectOnly(slug);
  }

  /** Brew service entry for this package, if it has one. Formulae only. */
  let svc = $derived.by(() =>
    pkg && pkg.kind === "formula" ? services.byName(pkg.name) : undefined,
  );
  let svcStatus = $derived(svc ? normalizeServiceStatus(svc.status) : null);
  let svcPending = $derived(pkg ? services.isPending(pkg.name) : false);

  function serviceStatusLabel(status: ReturnType<typeof normalizeServiceStatus> | null, locale: Locale = ui.locale): string {
    if (!status) return locale === "ru" ? "неизвестно" : "unknown";
    if (locale === "ru") {
      switch (status) {
        case "started":   return "запущена";
        case "stopped":   return "остановлена";
        case "none":      return "не загружена";
        case "error":     return "ошибка";
        case "scheduled": return "запланирована";
        case "unknown":   return "неизвестно";
      }
    }
    return status === "started" ? "running" : status === "none" ? "not loaded" : status;
  }

  // ────────────────────────────────────────────────────────────────
  // Phase 12c — GitHub stats card.
  //
  // We gate three things before triggering a fetch:
  //   1. `settings.effective.githubEnabled` — user opt-in toggle.
  //   2. `!settings.effective.paranoidMode` — master kill switch.
  //   3. `pkg.githubHomepage !== null` — the backend pre-resolved a
  //      canonical github.com/<o>/<r> URL by walking homepage →
  //      urls.stable.url → urls.head.url (formula) or homepage → url
  //      (cask). Lights up the card for packages whose homepage alone
  //      wouldn't have qualified.
  //
  // The backend re-validates the URL strictly via `parse_github_url`,
  // so this resolved field is already canonical; no extra regex needed.

  /** Canonical GitHub homepage for action routing (star/watch/issue/stats).
      Backend-pre-resolved; null when the package has no GitHub-resolvable
      URL field. Use this (not `pkg.homepage`) for any github.com call. */
  let githubHp = $derived<string | null>(pkg?.githubHomepage ?? null);

  let githubStatsEligible = $derived(
    githubHp !== null &&
      settings.effective.githubEnabled &&
      !settings.effective.paranoidMode,
  );

  /** The outcome from the GitHub store for the current homepage. */
  let githubOutcome = $derived<RepoStatsOutcome | null>(
    githubStatsEligible && githubHp
      ? (github.repoStatsCache.get(githubHp) ?? { kind: "loading" })
      : null,
  );

  // Trigger the fetch on first paint for a given homepage. The store
  // memoises in its cache so repeat opens of the same package don't
  // re-invoke.
  $effect(() => {
    if (githubStatsEligible && githubHp) {
      void github.getRepoStats(githubHp);
    }
  });

  /** Format a star/fork count in compact form (1.2k, 12.3k, 1.2M). */
  function fmtCount(n: number): string {
    if (n < 1000) return `${n}`;
    if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0).replace(/\.0$/, "")}k`;
    return `${(n / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
  }

  /** "3 weeks ago" style for ISO timestamps. */
  function fmtRelative(iso: string | null): string {
    if (!iso) return "—";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return "—";
    const diffMs = Date.now() - t;
    const days = Math.max(0, Math.floor(diffMs / (24 * 60 * 60 * 1000)));
    if (ui.locale === "ru") {
      if (days === 0) return "сегодня";
      if (days === 1) return "вчера";
      if (days < 7) return `${days} ${ruPlural(days, "день", "дня", "дней")} назад`;
      if (days < 30) {
        const weeks = Math.floor(days / 7);
        return `${weeks} ${ruPlural(weeks, "неделю", "недели", "недель")} назад`;
      }
      if (days < 365) {
        const months = Math.floor(days / 30);
        return `${months} ${ruPlural(months, "месяц", "месяца", "месяцев")} назад`;
      }
      const years = Math.floor(days / 365);
      return `${years} ${ruPlural(years, "год", "года", "лет")} назад`;
    }
    if (days === 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 7) return `${days} days ago`;
    if (days < 30) return `${Math.floor(days / 7)} weeks ago`;
    if (days < 365) return `${Math.floor(days / 30)} months ago`;
    const years = Math.floor(days / 365);
    return years === 1 ? "1 year ago" : `${years} years ago`;
  }

  /** Format the rate-limit reset time for the inline error variant. */
  function fmtResetTime(resetAt: number): string {
    if (!resetAt) return ui.locale === "ru" ? "скоро" : "soon";
    return new Date(resetAt * 1000).toLocaleTimeString(ui.locale === "ru" ? "ru-RU" : undefined, { hour: "2-digit", minute: "2-digit" });
  }

  // ────────────────────────────────────────────────────────────────
  // Phase 12f — authed actions (star, watch, file issue) + "Wrong?"
  //
  // Visible only when the user is signed in to GitHub via Settings →
  // GitHub. Backend gates: paranoid-mode → URL allowlist → auth →
  // scope (`public_repo`) → action. Errors surface as typed BrewErrors
  // and toast with a friendly message.

  /** True when the current package's homepage is a GitHub URL AND
      the user is signed in. Anonymous users see a hint instead of the
      action row. */
  let githubSignedIn = $derived(!!github.status?.signedIn);
  let githubActionsEligible = $derived(githubStatsEligible && githubSignedIn);

  /** Per-row starred outcome from the shared cache. */
  let starredState = $state<StarredOutcome>("unknown");

  $effect(() => {
    // Reset and refetch whenever the resolved github homepage changes.
    const hp = githubHp;
    if (!hp || !githubActionsEligible) {
      starredState = "unknown";
      return;
    }
    // CRITICAL: refetch only when the cache has NO entry for this
    // homepage (true cache miss). Earlier this test was `starredState
    // === "unknown"` which couldn't distinguish "haven't fetched yet"
    // from "fetched and failed" — failed fetches wrote "unknown" to
    // the cache, which retriggered this effect, which refetched, which
    // failed, which wrote "unknown" again. Infinite IPC storm + Svelte
    // scheduler thrash that surfaced as a duplicate-toast cascade in
    // the sign-in flow (issue #1). The `isStarred` catch now writes
    // "error" (distinct from "unknown"), and this gate now checks
    // `cached === undefined` so failed attempts don't keep retrying.
    const cached = github.starredCache.get(hp);
    starredState = cached ?? "unknown";
    if (cached === undefined) {
      void github.isStarred(hp).then((result) => {
        // Only update if we're still on the same package.
        if (githubHp === hp) {
          starredState = result;
        }
      });
    }
  });

  function githubActionRu(actionLabel: string): string {
    switch (actionLabel) {
      case "star this package": return "поставить звезду этому пакету";
      case "watch this package": return "отслеживать этот пакет";
      case "file an issue": return "сообщить о проблеме";
      case "file an issue on this repo": return "сообщить о проблеме в этом репозитории";
      case "update star": return "обновить звезду";
      case "update watch": return "обновить отслеживание";
      default: return actionLabel;
    }
  }

  /** Intercept any authed GitHub action while signed out: deep-link to
      Settings → GitHub and toast a hint. Returns false when the caller
      should stop. Keeps the action buttons usable without painting a
      static "sign in to …" hint in every package detail.

      Lazy-probes the Keychain on demand: if `github.status` hasn't been
      hydrated yet (the app no longer probes on launch — that would
      train users to dismiss the macOS Keychain prompt), this awaits
      the probe before deciding. The prompt only fires when the user
      is actively trying to do a GitHub action — contextual, not
      surprising. */
  async function requireGithubSignIn(actionLabel: string): Promise<boolean> {
    if (github.status === null && !github.statusLoading) {
      await github.loadStatus();
    }
    if (github.status?.signedIn) return true;
    ui.openSettings("github");
    toast.info(
      ui.locale === "ru"
        ? `Войдите в GitHub, чтобы ${githubActionRu(actionLabel)}`
        : `Sign in to GitHub to ${actionLabel}`,
      t("Use the Sign in with GitHub button in Settings.", ui.locale),
    );
    return false;
  }

  /** True while a toggle-star IPC is in flight (per current package).
      The button disables itself during the call so a double-click can't
      fire two opposite IPCs. */
  let starToggling = $state(false);

  /** Handle a failed authed-action IPC with friendly UX.
   *
   *  - `ScopeRequired { scope }` → actionable toast: "Watch needs the
   *    'notifications' permission. [Re-authorize]". Clicking
   *    Re-authorize calls `github.signIn()` which re-runs Device Flow
   *    requesting the FULL scope set; GitHub's consent screen shows
   *    only the missing scopes (existing grants persist), the user
   *    clicks Authorize once, the new token overwrites the old one
   *    in Keychain transparently. NO sign-out needed.
   *  - Any other BrewError → regular error toast via `brewErrorMessage`.
   *  - Unknown error → toast the stringified value.
   */
  function showActionFailureToast(
    actionLabel: string,
    e: unknown,
  ): void {
    if (isBrewError(e) && e.code === "scope_required") {
      const scope = e.scope;
      toast.error(
        ui.locale === "ru" ? `Не удалось ${githubActionRu(actionLabel)}` : `Couldn't ${actionLabel}`,
        ui.locale === "ru"
          ? `Не хватает разрешения GitHub "${scope}". Нажмите, чтобы выдать его без выхода из аккаунта.`
          : `Needs the "${scope}" GitHub permission. Click to grant it without signing out.`,
        {
          label: t("Re-authorize", ui.locale),
          onClick: () => {
            void github.signIn();
          },
        },
      );
      return;
    }
    toast.error(
      ui.locale === "ru" ? `Не удалось ${githubActionRu(actionLabel)}` : `Couldn't ${actionLabel}`,
      isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e),
    );
  }

  async function onToggleStar() {
    if (!githubHp || starToggling) return;
    if (!(await requireGithubSignIn("star this package"))) return;
    starToggling = true;
    const hp = githubHp;
    try {
      const target = await github.toggleStar(hp);
      if (target === true) toast.success(ui.locale === "ru" ? `${t("Starred package", ui.locale)}: ${pkg!.name}` : `Starred ${pkg!.name}`);
      else if (target === false) toast.success(ui.locale === "ru" ? `${t("Unstarred package", ui.locale)}: ${pkg!.name}` : `Unstarred ${pkg!.name}`);
      starredState = github.starredCache.get(hp) ?? "unknown";
    } catch (e) {
      showActionFailureToast("update star", e);
    } finally {
      starToggling = false;
    }
  }

  let watchPending = $state(false);
  /** Watch state isn't tracked persistently (the API to read it is
      cheap but not yet wired). For v1 we just expose the on-demand
      toggle and rely on optimistic feedback. */
  let watching = $state<boolean | null>(null);

  async function onToggleWatch() {
    if (!githubHp || watchPending) return;
    if (!(await requireGithubSignIn("watch this package"))) return;
    watchPending = true;
    const want = !watching;
    try {
      if (want) await github.watch(githubHp);
      else await github.unwatch(githubHp);
      watching = want;
      toast.success(want
        ? (ui.locale === "ru" ? `${t("Watching package", ui.locale)}: ${pkg!.name}` : `Watching ${pkg!.name}`)
        : (ui.locale === "ru" ? `${t("Stopped watching package", ui.locale)}: ${pkg!.name}` : `Stopped watching ${pkg!.name}`));
    } catch (e) {
      showActionFailureToast("update watch", e);
    } finally {
      watchPending = false;
    }
  }

  // ── Issue modal state ──
  //
  // We use a single IssueModal instance with swappable props because
  // both the "File issue" button and the "Wrong?" link share the
  // form. The `issueTarget` determines which repo to file against
  // and what to prefill.

  let issueOpen = $state(false);
  let issueTargetHomepage = $state("");
  let issueTargetRepo = $state<{ owner: string; repo: string }>({ owner: "", repo: "" });
  let issueInitialTitle = $state("");
  let issueInitialBody = $state("");
  let issueInitialLabels = $state<string[]>([]);

  /** Cached app version for the issue body footer. Loaded lazily on
      first issue open so we don't pay for it on every package open. */
  let cachedAppVersion = $state<string | null>(null);
  async function ensureAppVersion(): Promise<string> {
    if (cachedAppVersion !== null) return cachedAppVersion;
    try {
      cachedAppVersion = await appVersion();
    } catch {
      cachedAppVersion = "unknown";
    }
    return cachedAppVersion!;
  }

  async function openPackageIssue() {
    if (!githubHp || !pkg) return;
    if (!(await requireGithubSignIn("file an issue on this repo"))) return;
    const repoInfo = githubRepoFromHomepage(githubHp);
    if (!repoInfo) return;
    const ver = await ensureAppVersion();
    issueTargetHomepage = githubHp;
    issueTargetRepo = repoInfo;
    issueInitialTitle = `[brew-browser] ${pkg.name}: `;
    issueInitialBody = [
      `**Package:** ${pkg.name} (${pkg.kind})`,
      `**brew-browser version:** ${ver}`,
      `**Homebrew version:** ${env.report?.version ?? "unknown"}`,
      "",
      "---",
      "",
      "Describe the issue here.",
    ].join("\n");
    issueInitialLabels = [];
    issueOpen = true;
  }

  /** Open the "Wrong?" issue against msitarzewski/brew-browser. */
  async function openWrongCategoryIssue() {
    if (!pkg) return;
    const ver = await ensureAppVersion();
    const currentCats = pkgCategories
      .map((slug) => categories.labelOf(slug, ui.locale))
      .join(", ") || "(none)";
    const body = [
      `**Package:** ${pkg.name} (${pkg.kind})`,
      `**Currently tagged:** ${currentCats}`,
      `**Suggestion:** _your suggested categories_`,
      "",
      "---",
      `*Reported via brew-browser v${ver} on macOS (Homebrew ${env.report?.version ?? "unknown"})*`,
    ].join("\n");
    const title = `Wrong categories for ${pkg.name}`;

    if (githubSignedIn) {
      // In-app modal targeting the brew-browser repo.
      issueTargetHomepage = "https://github.com/msitarzewski/brew-browser";
      issueTargetRepo = { owner: "msitarzewski", repo: "brew-browser" };
      issueInitialTitle = title;
      issueInitialBody = body;
      issueInitialLabels = ["category-suggestion"];
      issueOpen = true;
    } else {
      // Deeplink fallback. URL-encode every user-influenced segment via
      // encodeURIComponent (NOT manual string interpolation) per the
      // §12f review.
      const params = new URLSearchParams();
      params.set("title", title);
      params.set("body", body);
      params.set("labels", "category-suggestion");
      const url = `https://github.com/msitarzewski/brew-browser/issues/new?${params.toString()}`;
      await safeOpenUrl(url);
    }
  }

  /** Extract (owner, repo) from a GitHub homepage string for the
      issue modal's header. Returns null when the URL isn't strictly
      a github.com/<owner>/<repo>. The backend's parser is
      authoritative; this is just for display. */
  function githubRepoFromHomepage(url: string): { owner: string; repo: string } | null {
    const m = /^https?:\/\/github\.com\/([^/?#]+)\/([^/?#]+)/i.exec(url.trim());
    if (!m) return null;
    return { owner: m[1], repo: m[2].replace(/\.git$/i, "") };
  }

  // ────────────────────────────────────────────────────────────────
  // v0.5.0 — Security card
  //
  // Three rendering states (all gated by the feature toggle):
  //   1. No record  → CTA "Check now" (calls vulnerabilities.scanOne)
  //   2. Record + no vulns → positive "✓ No known vulnerabilities"
  //   3. Record + vulns    → list of findings + optional "Upgrade to fix"
  //
  // Deliberately surfaced AFTER the homepage / before trending and
  // service cards so it's prominent without elbowing the GitHub stats
  // (which a far larger fraction of packages have).

  /** Show the card at all? Settings gate only — the inner states branch
      on whether we have a record. */
  let securityCardVisible = $derived(
    settings.effective.vulnerabilityScanningEnabled === true,
  );

  /** The current package's scan record, or undefined when never scanned. */
  let securityRecord = $derived(
    pkg ? vulnerabilities.byPackage(pkg.kind, pkg.name) : undefined,
  );

  /** A green "no known vulnerabilities" all-clear is only honest when this
      package was scanned THIS session — a record hydrated from cache on launch
      is stale, so we caution + prompt a re-scan instead. */
  let securityFresh = $derived(
    securityRecord ? vulnerabilities.scannedThisSession(securityRecord.scannedAt) : false,
  );

  /** True while a scan IPC is in flight (any scan, since the store is
      single-flight). Used to disable buttons and show a spinner. */
  let securityLoading = $derived(vulnerabilities.loading);

  /** Severity → tone for the per-vuln pill colour. Mirrors the row dot's
      mapping (critical+high → danger, medium → warning, low → info,
      unknown → neutral) so the visual language stays consistent across
      surfaces. */
  function severityTone(sev: Severity): "danger" | "warning" | "info" | "neutral" {
    switch (sev) {
      case "critical":
      case "high":   return "danger";
      case "medium": return "warning";
      case "low":    return "info";
      default:       return "neutral";
    }
  }

  function severityLabel(sev: Severity): string {
    if (ui.locale !== "ru") return sev;
    switch (sev) {
      case "critical": return "критическая";
      case "high": return "высокая";
      case "medium": return "средняя";
      case "low": return "низкая";
      default: return "неизвестная";
    }
  }

  /** First HTTPS reference for a vuln — used as the click-target for
      the CVE/GHSA id. When `references` is empty (brew-vulns currently
      omits the field for OSV-sourced entries; only GHSA enrichment
      populates it), fall back to the canonical detail page derived
      from the ID prefix. */
  function vulnPrimaryLink(v: RawVuln): string | null {
    for (const ref of v.references) {
      if (ref.startsWith("https://")) return ref;
    }
    return canonicalVulnUrl(v.id);
  }

  /** Map a vulnerability ID to its canonical detail page so the user
      always has somewhere to click when the advisory's `references`
      field is empty (the common case for OSV-sourced entries from
      `brew vulns` without GHSA enrichment).
      Returns null for unrecognized ID shapes. */
  function canonicalVulnUrl(id: string): string | null {
    if (!id) return null;
    if (id.startsWith("CVE-")) return `https://nvd.nist.gov/vuln/detail/${id}`;
    if (id.startsWith("OSV-")) return `https://osv.dev/vulnerability/${id}`;
    if (id.startsWith("GHSA-")) return `https://github.com/advisories/${id}`;
    return null;
  }

  /** Compare two semver-ish version strings. Returns true when `a` is
      strictly OLDER than `b`. Used to decide whether to show "Upgrade
      to fix" — if the user is already on the patched version (or newer)
      we shouldn't nag. Naïve dot-segment compare with numeric coercion
      — good enough for brew's mostly-semver tags; doesn't handle every
      pre-release suffix edge case but degrades to "show the button"
      (false-positive bias). */
  function versionLessThan(a: string, b: string): boolean {
    if (!a || !b) return false;
    const norm = (v: string) => v.replace(/^v/i, "").split(/[.-]/);
    const aa = norm(a);
    const bb = norm(b);
    const len = Math.max(aa.length, bb.length);
    for (let i = 0; i < len; i++) {
      const an = parseInt(aa[i] ?? "0", 10);
      const bn = parseInt(bb[i] ?? "0", 10);
      if (Number.isNaN(an) || Number.isNaN(bn)) {
        // String compare for non-numeric segments.
        const as = aa[i] ?? "";
        const bs = bb[i] ?? "";
        if (as < bs) return true;
        if (as > bs) return false;
      } else {
        if (an < bn) return true;
        if (an > bn) return false;
      }
    }
    return false;
  }

  /** True when ANY vuln on the record has a `fixedIn` value AND the
      installed version is older than that fix. Drives the "Upgrade to
      fix" button. */
  let securityUpgradeAvailable = $derived.by(() => {
    if (!securityRecord || securityRecord.vulns.length === 0) return false;
    if (!pkg?.installedVersion) return false;
    const installed = pkg.installedVersion;
    for (const v of securityRecord.vulns) {
      if (v.fixedIn && versionLessThan(installed, v.fixedIn)) return true;
    }
    return false;
  });

  /** Relative time helper for the scan timestamp. "scanned 2h ago" /
      "just now" / "scanned 3 days ago". */
  function relativeScanTime(d: Date | string): string {
    const t = typeof d === "string" ? Date.parse(d) : d.getTime();
    if (Number.isNaN(t)) return "";
    const diffMs = Date.now() - t;
    const sec = Math.floor(diffMs / 1000);
    if (ui.locale === "ru") {
      if (sec < 60) return "только что";
      const min = Math.floor(sec / 60);
      if (min < 60) return `${min} ${ruPlural(min, "минуту", "минуты", "минут")} назад`;
      const hr = Math.floor(min / 60);
      if (hr < 24) return `${hr} ${ruPlural(hr, "час", "часа", "часов")} назад`;
      const day = Math.floor(hr / 24);
      if (day < 30) return `${day} ${ruPlural(day, "день", "дня", "дней")} назад`;
      const mo = Math.floor(day / 30);
      return `${mo} ${ruPlural(mo, "месяц", "месяца", "месяцев")} назад`;
    }
    if (sec < 60) return "just now";
    const min = Math.floor(sec / 60);
    if (min < 60) return `${min}m ago`;
    const hr = Math.floor(min / 60);
    if (hr < 24) return `${hr}h ago`;
    const day = Math.floor(hr / 24);
    if (day < 30) return `${day} day${day === 1 ? "" : "s"} ago`;
    const mo = Math.floor(day / 30);
    return `${mo} month${mo === 1 ? "" : "s"} ago`;
  }

  /** Invoke the store's scanOne — used by "Check now" and "Re-check". */
  async function checkSecurity() {
    if (!pkg) return;
    await vulnerabilities.scanOne(pkg.kind, pkg.name);
  }

  /** Run the actual upgrade — same pipeline the footer Upgrade button
      uses. Wired up here directly so the user can fix from inside the
      Security card without scrolling to the footer. */
  function upgradeForSecurity() {
    void doUpgrade();
  }

  /** Open a vuln advisory link via the URL allowlist. */
  async function openVulnRef(url: string) {
    await safeOpenUrl(url);
  }

  async function svcAct(action: "start" | "stop" | "restart") {
    if (!pkg) return;
    try {
      await services.act(pkg.name, action);
      toast.success(ui.locale === "ru"
        ? (action === "start"
          ? `Запущена служба ${pkg.name}`
          : action === "stop"
            ? `Остановлена служба ${pkg.name}`
            : `Перезапущена служба ${pkg.name}`)
        : `${action.charAt(0).toUpperCase() + action.slice(1)}ed ${pkg.name}`);
    } catch (e) {
      reportableToastError(ui.locale === "ru"
        ? (action === "start"
          ? `Не удалось запустить службу ${pkg.name}`
          : action === "stop"
            ? `Не удалось остановить службу ${pkg.name}`
            : `Не удалось перезапустить службу ${pkg.name}`)
        : `Failed to ${action} ${pkg.name}`, e);
    }
  }
</script>

{#if ui.selectedPackage}
  <aside
    class="detail"
    aria-label={t("Package detail", ui.locale)}
    style="--detail-pane-width: {ui.detailPaneWidth}px"
  >
    <header class="panel-head">
      <!--
        Header title rules (Phase 13.b rework):
        - AI features ON + enrichment has friendlyName: friendlyName is the
          h1; the raw token moves DOWN into the meta list as a `Token` row.
        - AI features OFF or no enrichment entry: raw `ui.selectedPackage.name`
          is the h1 (legacy behavior).
        Type pill is right-aligned via `margin-left: auto` so it always pins
        to the right edge regardless of title length.
      -->
      <!-- AI-enriched badge intentionally NOT shown next to the title.
           The friendly name is the title (when AI is on); the raw token
           still appears in the meta `Token` row below, so users always
           see both. Per-field provenance is surfaced via (i) info
           popovers next to each enriched section (Categories, Tags,
           Summary, Why install this?, Similar packages). -->
      <h1 bind:this={headingEl} tabindex="-1" class="detail-title">
        {enriched?.friendlyName ?? ui.selectedPackage.name}
      </h1>
      <Pill tone={ui.selectedPackage.kind === "formula" ? "formula" : "cask"}>{ui.selectedPackage.kind}</Pill>
      <button class="close" aria-label={t("Close detail panel", ui.locale)} onclick={close} title={t("close Esc", ui.locale)}>
        <X size={16} />
      </button>
    </header>

    <div class="body">
      {#if loading}
        <LoadingState rows={5} label={t("Loading package detail…", ui.locale)} />
      {:else if error}
        <div class="error">
          <p>{t("Couldn't load detail", ui.locale)}: {error}</p>
          <Button variant="secondary" onclick={() => ui.selectedPackage && loadDetail(ui.selectedPackage.name, ui.selectedPackage.kind)}>{t("Retry", ui.locale)}</Button>
        </div>
      {:else if detail && pkg}
        <!-- Centered app-icon identity anchor (matches native's DetailIcon):
             the resolved cask icon at 64px, or a kind glyph for formulae /
             unresolved casks. Provenance still lives in the "Icon source"
             meta row below. -->
        <div class="detail-icon">
          <PackageRowIcon
            token={pkg.name}
            kind={pkg.kind}
            iconSource={pkg.iconSource}
            homepage={pkg.homepage}
            size={64}
          />
        </div>
        <dl class="meta">
          {#if enriched?.friendlyName}
            <!-- AI is on AND enrichment has a friendlyName, so the h1
                 above shows the friendly version. Surface the canonical
                 token here so it doesn't disappear from the UI. When AI
                 is off, enriched is null so this row doesn't render and
                 the h1 falls back to the raw token (legacy behaviour). -->
            <div>
              <dt>{t("Token", ui.locale)}</dt>
              <dd class="mono">{ui.selectedPackage.name}</dd>
            </div>
          {/if}
          <div>
            <dt>{t("Installed", ui.locale)}</dt>
            <dd>
              {#if pkg.installedVersion}
                {pkg.installedVersion}
              {:else if detail.existsInApplications}
                {t("Installed by User", ui.locale)}
              {:else}
                {t("Not installed", ui.locale)}
              {/if}
            </dd>
          </div>
          <!-- Feature #3 — install provenance. Only meaningful for an
               actually-installed package, and only when a per-keg brew
               flag is set (legacy/neither-flag kegs render no row rather
               than a fabricated default). "Dependency" wins a Pill badge
               (mirrors the Feature #2 deprecation badge intent); explicit
               on-request installs read plainly as "On request". The
               Dependency case keys on installedAsDependency && NOT
               on-request, matching the Library "Dependency" filter so a
               both-flags-true package reads as Manual ("On request"). -->
          {#if pkg.installedVersion && (pkg.installedOnRequest || pkg.installedAsDependency)}
            <div>
              <dt>{t("Install", ui.locale)}</dt>
              <dd>
                {#if pkg.installedOnRequest}
                  {t("On request", ui.locale)}
                {:else}
                  <span title={t("Installed as a dependency, not requested directly", ui.locale)}>
                    <Pill tone="info">{t("dependency", ui.locale)}</Pill>
                  </span>
                {/if}
              </dd>
            </div>
          {/if}
          <!-- Feature #4 — on-disk keg size. Travels on the PackageDetail
               DTO (computed lazily by `brew_info` via `du -sk`); null when
               the package isn't installed, the keg dir is absent (e.g. a
               cask on Linux), or `du` couldn't measure it. Null → no row
               (no fabricated "0 B" / estimate). Kind-agnostic and
               self-gating on the null value, so no isLinux gate is needed.
               Shares `fmtBytes` with the Dashboard Storage card. -->
          {#if detail.installedSizeBytes != null}
            <div>
              <dt>{t("Size", ui.locale)}</dt>
              <dd title={t("Total on-disk size of the installed keg (all versions).", ui.locale)}>
                {fmtBytes(detail.installedSizeBytes)}
              </dd>
            </div>
          {/if}
          <div>
            <dt>{t("Latest", ui.locale)}</dt>
            <dd>
              {pkg.stableVersion ?? "—"}
              {#if isOutdated}
                <span class="warn">{t("Upgrade available", ui.locale)}</span>
              {/if}
            </dd>
          </div>
          {#if pkg.license}
            <div><dt>{t("License", ui.locale)}</dt><dd>{pkg.license}</dd></div>
          {/if}
          {#if pkg.tap}
            <div><dt>Tap</dt><dd>{pkg.tap}</dd></div>
          {/if}
          <div>
            <dt>{t("Icon source", ui.locale)}</dt>
            <dd class="icon-source" title={iconSourceTitle(pkg.iconSource)}>{iconSourceLabel(pkg.iconSource)}</dd>
          </div>
          {#if categories.visible && pkgCategories.length > 0}
            <div>
              <dt>{t("Categories", ui.locale)}</dt>
              <dd class="cat-pills">
                {#each pkgCategories as slug (slug)}
                  {@const Icon = resolveCategoryIcon(
                    categories.data?.categories[slug]?.icon ?? "HelpCircle",
                  )}
                  <button
                    type="button"
                    class="cat-pill"
                    onclick={() => jumpToCategory(slug)}
                    title={t("detail.category.openTitle", ui.locale, { category: categories.labelOf(slug, ui.locale) })}
                  >
                    <Icon size={12} />
                    <span>{categories.labelOf(slug, ui.locale)}</span>
                  </button>
                {/each}
                <InfoButton
                  title={t("About categories", ui.locale)}
                  body={t("detail.aboutCategories.body", ui.locale)}
                  label={t("About this package's categories", ui.locale)}
                  onReport={openWrongCategoryIssue}
                />
              </dd>
            </div>
          {/if}

          <!-- Phase 13: enriched tags. Distinct from category pills above —
               categories are coarse (19 slugs), tags are fine-grained
               tech-stack labels (database, video-editing, kubernetes…). -->
          {#if enriched && enriched.tags.length > 0}
            <div>
              <dt>{t("Tags", ui.locale)}</dt>
              <dd class="tag-pills">
                {#each enriched.tags as t (t)}
                  <span class="tag-pill">
                    <Tag size={10} aria-hidden="true" />
                    <span>{t}</span>
                  </span>
                {/each}
                <InfoButton
                  title={t("About tags", ui.locale)}
                  body={t("detail.aboutTags.body", ui.locale)}
                  label={t("About these tags", ui.locale)}
                  onReport={() => openWrongEnrichedIssue("tags")}
                />
              </dd>
            </div>
          {/if}
        </dl>

        <!-- Phase 13: enriched summary, between the meta and the brew
             native description. Both render when present; the brew
             native description never disappears. -->
        {#if enriched?.summary}
          <blockquote class="enriched-summary">
            <p>{enriched.summary}&nbsp;<InfoButton
              title={t("About this summary", ui.locale)}
              body={t("detail.aboutSummary.body", ui.locale)}
              label={t("About this summary", ui.locale)}
              onReport={() => openWrongEnrichedIssue("summary")}
            /></p>
          </blockquote>
        {/if}

        {#if pkg.description}
          <p class="desc">{pkg.description}</p>
        {/if}

        {#if pkg.homepage}
          <button class="homepage" onclick={() => openHomepage(pkg!.homepage!)} title={pkg.homepage}>
            <span class="truncate">{pkg.homepage}</span>
            <ExternalLink size={12} />
          </button>
        {/if}

        <!-- Feature #2: deprecation / disabled notice. Renders before the
             Security card (mirrors the gh-archived notice pattern). Shows
             the reason + date verbatim and, when brew info supplied a
             replacement token, a clickable "use X instead" link that
             re-fetches detail for the successor. `disabled` is the
             stronger (danger) state; neither flag → no notice. -->
        {#if deprecationNotice}
          <div
            class="deprecation-notice"
            class:disabled={deprecationNotice.kind === "disabled"}
            role="status"
          >
            <Archive size={14} aria-hidden="true" />
            <div class="deprecation-body">
              <p class="deprecation-line">
                <strong>
                  {deprecationNotice.kind === "disabled" ? t("Disabled", ui.locale) : t("Deprecated", ui.locale)}
                </strong>{#if deprecationNotice.date}<span class="deprecation-date"> &middot; {deprecationNotice.date}</span>{/if}{#if deprecationNotice.reason}<span class="deprecation-reason"> — {deprecationNotice.reason}</span>{/if}
              </p>
              {#if deprecationNotice.kind === "disabled"}
                <p class="deprecation-sub">{t("No longer available via Homebrew.", ui.locale)}</p>
              {:else}
                <p class="deprecation-sub">{t("May be removed in a future Homebrew update.", ui.locale)}</p>
              {/if}
              {#if deprecationNotice.replacement}
                <p class="deprecation-replacement">
                  {t("Use", ui.locale)}
                  <button
                    type="button"
                    class="deprecation-replacement-link"
                    onclick={() => openReplacement(deprecationNotice!.replacement!)}
                    title={t("package.openToken", ui.locale, { token: deprecationNotice.replacement })}
                  >
                    {deprecationNotice.replacement}
                  </button>
                  {t("instead.", ui.locale)}
                </p>
              {/if}
            </div>
          </div>
        {/if}

        <!-- v0.5.0: Security card. Three states branch off whether we
             have a scan record for this (kind, name) pair. Settings-
             gated; the entire section disappears when the user hasn't
             opted into vulnerability scanning. -->
        {#if securityCardVisible}
          <section class="sec-card" aria-label={t("Security", ui.locale)}>
            {#if securityRecord === undefined}
              <!-- State 1: never scanned this package -->
              <div class="sec-head">
                <Shield size={16} class="sec-icon" />
                <h3>{t("Security", ui.locale)}</h3>
              </div>
              <p class="sec-cta">{t("Check this package for known vulnerabilities.", ui.locale)}</p>
              <div class="sec-actions">
                <button
                  type="button"
                  class="sec-btn sec-btn-primary"
                  disabled={securityLoading}
                  onclick={checkSecurity}
                  title={t("Runs brew vulns across your whole install — it can't scan a single package", ui.locale)}
                >
                  {#if securityLoading}
                    <Loader size={14} class="spin-slow" />
                    <span>{t("Scanning all…", ui.locale)}</span>
                  {:else}
                    <Shield size={14} />
                    <span>{t("Scan all packages", ui.locale)}</span>
                  {/if}
                </button>
              </div>
            {:else if securityRecord.vulns.length === 0 && !securityFresh}
              <!-- State 2a: clean LAST scan, but stale (cached / from a prior
                   session). Don't claim all-clear — caution + re-scan prompt. -->
              <div class="sec-head">
                <ShieldAlert size={16} class="sec-icon-warn" />
                <h3>{t("Security", ui.locale)}</h3>
              </div>
              <p class="sec-clean">
                {ui.locale === "ru"
                  ? `На момент последней проверки (${relativeScanTime(securityRecord.scannedAt)}) записей об уязвимостях нет. Пакеты могли измениться — проверьте ещё раз.`
                  : `No advisories as of the last scan (${relativeScanTime(securityRecord.scannedAt)}). Packages may have changed since — re-scan to confirm.`}
              </p>
              <div class="sec-foot">
                <button
                  type="button"
                  class="sec-link"
                  disabled={securityLoading}
                  onclick={checkSecurity}
                  title={t("Runs brew vulns across your whole install — it can't scan a single package", ui.locale)}
                >
                  {securityLoading ? t("Scanning all…", ui.locale) : t("Re-scan all", ui.locale)}
                </button>
              </div>
            {:else if securityRecord.vulns.length === 0}
              <!-- State 2b: scanned clean THIS session -->
              <div class="sec-head sec-head-clean">
                <ShieldCheck size={16} class="sec-icon-clean" />
                <h3>{t("Security", ui.locale)}</h3>
              </div>
              <p class="sec-clean">
                {securityRecord.version
                  ? (ui.locale === "ru" ? `Известных уязвимостей в версии ${securityRecord.version} нет.` : `No known vulnerabilities at version ${securityRecord.version}.`)
                  : t("No known vulnerabilities.", ui.locale)}
              </p>
              <div class="sec-foot">
                <span class="sec-stamp text-muted">
                  {ui.locale === "ru" ? "проверено" : "scanned"} {relativeScanTime(securityRecord.scannedAt)}
                </span>
                <button
                  type="button"
                  class="sec-link"
                  disabled={securityLoading}
                  onclick={checkSecurity}
                  title={t("Runs brew vulns across your whole install — it can't scan a single package", ui.locale)}
                >
                  {securityLoading ? t("Scanning all…", ui.locale) : t("Re-scan all", ui.locale)}
                </button>
              </div>
            {:else}
              <!-- State 3: scanned, has findings -->
              {@const vulns = securityRecord.vulns}
              <div class="sec-head sec-head-vuln">
                <ShieldAlert size={16} class="sec-icon-vuln" />
                <h3>
                  {t("Security", ui.locale)} &middot;
                  {ui.locale === "ru"
                    ? `${vulns.length} ${ruPlural(vulns.length, "известная уязвимость", "известные уязвимости", "известных уязвимостей")}`
                    : `${vulns.length} known vulnerabilit${vulns.length === 1 ? "y" : "ies"}`}
                </h3>
              </div>

              {#if securityUpgradeAvailable}
                <div class="sec-actions">
                  <button
                    type="button"
                    class="sec-btn sec-btn-primary"
                    onclick={upgradeForSecurity}
                    title={t("Run brew upgrade for this package", ui.locale)}
                  >
                    <ArrowUpCircle size={14} />
                    <span>{t("Upgrade to fix", ui.locale)}</span>
                  </button>
                </div>
              {/if}

              <ul class="sec-list">
                {#each vulns as v (v.id || v.summary)}
                  {@const tone = severityTone(v.severity)}
                  {@const link = vulnPrimaryLink(v)}
                  <li class="sec-item">
                    <div class="sec-item-head">
                      <span class="sec-sev sec-sev-{tone}">{severityLabel(v.severity)}</span>
                      {#if v.id}
                        {#if link}
                          <button
                            type="button"
                            class="sec-id"
                            onclick={() => openVulnRef(link)}
                            title={`${t("Open advisory", ui.locale)}: ${link}`}
                          >
                            {v.id}
                            <ExternalLink size={10} />
                          </button>
                        {:else}
                          <span class="sec-id sec-id-plain">{v.id}</span>
                        {/if}
                      {/if}
                      {#if v.fixedIn}
                        <span class="sec-fixed" title={t("Patched version", ui.locale)}>
                          {t("Patched in", ui.locale)} {v.fixedIn}
                        </span>
                      {/if}
                    </div>
                    {#if v.summary}
                      <p class="sec-summary">{v.summary}</p>
                    {:else if link}
                      <!-- brew-vulns sends `summary: null` for advisories
                           OSV hasn't summarized (a real case, e.g. some
                           CVE entries). Keep the row balanced with a
                           "View details →" affordance pointed at the
                           canonical detail page, so the user always has
                           somewhere to click instead of an orphaned ID. -->
                      <p class="sec-summary sec-summary-empty">
                        <button
                          type="button"
                          class="sec-details-link"
                          onclick={() => openVulnRef(link)}
                        >
                          {t("No summary available — view details", ui.locale)}
                          <ExternalLink size={10} />
                        </button>
                      </p>
                    {/if}
                  </li>
                {/each}
              </ul>

              <div class="sec-foot">
                <span class="sec-stamp text-muted">
                  {ui.locale === "ru" ? "проверено" : "scanned"} {relativeScanTime(securityRecord.scannedAt)}
                </span>
                <button
                  type="button"
                  class="sec-link"
                  disabled={securityLoading}
                  onclick={checkSecurity}
                  title={t("Runs brew vulns across your whole install — it can't scan a single package", ui.locale)}
                >
                  {securityLoading ? t("Scanning all…", ui.locale) : t("Re-scan all", ui.locale)}
                </button>
              </div>
            {/if}
          </section>
        {/if}

        <!-- v0.4.0: install-trend sparkline. Strictly passive (D4): only
             renders when enhanced trending is on AND we actually have a
             series with chartable data for this package. No placeholder
             when off — the section simply doesn't exist. -->
        {#if trendingHistory.enabled}
          {@const series = trendingHistory.seriesFor(pkg.name, pkg.kind)}
          {#if series && series.points.length >= 2}
            <section class="trend-card" aria-label={ui.locale === "ru" ? `Динамика установок ${pkg.name}` : `Install trend for ${pkg.name}`}>
              <header class="trend-head">
                <h3>{t("Install trend", ui.locale)}</h3>
                <span class="trend-meta text-muted">
                  {#if series.points.some((p) => p.source === "seed")}
                    {t("detail.trend.bootstrap", ui.locale)}
                  {:else}
                    {t("detail.trend.daily", ui.locale)}
                  {/if}
                </span>
              </header>
              <TrendingSparkline
                data={series.points.map((p) => p.estimatedDailyInstalls ?? p.count30d ?? 0)}
                variant="detail"
                title={t("package.installTrendFor", ui.locale, { name: pkg.name })}
              />
            </section>
          {/if}
        {/if}

        <!-- Phase 13: "Why install this?" use-case bullets. -->
        {#if enriched && enriched.useCases.length > 0}
          <section class="enriched-section" aria-label={t("Use cases", ui.locale)}>
            <h3>
              {t("Why install this?", ui.locale)}
              <InfoButton
                title={t("About use cases", ui.locale)}
                body={t("detail.aboutUseCases.body", ui.locale)}
                label={t("About these use cases", ui.locale)}
                onReport={() => openWrongEnrichedIssue("use_cases")}
              />
            </h3>
            <ul class="use-cases">
              {#each enriched.useCases as uc (uc)}
                <li>{uc}</li>
              {/each}
            </ul>
          </section>
        {/if}

        <!-- Phase 13: Similar packages, clickable pills that re-open
             PackageDetail for that token. -->
        {#if enriched && enriched.similar.length > 0}
          <section class="enriched-section" aria-label={t("Similar packages", ui.locale)}>
            <h3>
              {t("Similar packages", ui.locale)}
              <InfoButton
                title={t("About similar packages", ui.locale)}
                body={t("detail.aboutSimilar.body", ui.locale)}
                label={t("About these similar packages", ui.locale)}
                onReport={() => openWrongEnrichedIssue("similar")}
              />
            </h3>
            <div class="similar-pills">
              {#each enriched.similar as token (token)}
                <button
                  type="button"
                  class="similar-pill"
                  onclick={() => openSimilar(token)}
                  title={ui.locale === "ru" ? `Открыть ${token}` : `Open ${token}`}
                >
                  {token}
                </button>
              {/each}
            </div>
          </section>
        {/if}

        {#if githubOutcome}
          <section class="gh-card" aria-label={t("GitHub repository statistics", ui.locale)}>
            {#if githubOutcome.kind === "loading"}
              <div class="gh-loading">
                <Loader size={14} class="spin-slow" />
                <span>{t("Loading GitHub stats…", ui.locale)}</span>
              </div>
            {:else if githubOutcome.kind === "loaded"}
              {@const s = githubOutcome.stats}
              <div class="gh-stats">
                <span class="gh-stat" title={t("github.stargazers", ui.locale)}>
                  <Star size={14} /> {fmtCount(s.stars)}
                </span>
                <span class="gh-sep">·</span>
                <span class="gh-stat" title={t("github.forks", ui.locale)}>
                  <GitFork size={14} /> {fmtCount(s.forks)}
                </span>
                {#if s.lastReleaseTag}
                  <span class="gh-sep">·</span>
                  <span class="gh-stat" title={s.lastReleaseDate ?? ""}>
                    <Tag size={14} /> {s.lastReleaseTag}
                    {#if s.lastReleaseDate}
                      <span class="gh-muted">({fmtRelative(s.lastReleaseDate)})</span>
                    {/if}
                  </span>
                {/if}
              </div>
              {#if s.archived}
                <div class="gh-archived" role="status">
                  <Archive size={14} />
                  <span>
                    {s.archivedAt
                      ? (ui.locale === "ru" ? `Архивирован ${fmtRelative(s.archivedAt)} — вероятно, больше не поддерживается.` : `Archived ${fmtRelative(s.archivedAt)} — likely unmaintained.`)
                      : (ui.locale === "ru" ? "Архивирован — вероятно, больше не поддерживается." : "Archived — likely unmaintained.")}
                  </span>
                </div>
              {/if}
              {#if s.licenseSpdx && pkg.license && s.licenseSpdx !== pkg.license}
                <div
                  class="gh-license-mismatch"
                  title={t("github.licenseMismatchTitle", ui.locale, { brew: pkg.license, github: s.licenseSpdx })}
                >
                  <AlertCircle size={12} aria-hidden="true" />
                  <span>{t("License mismatch", ui.locale)} — brew: <code>{pkg.license}</code>, GitHub: <code>{s.licenseSpdx}</code></span>
                </div>
              {/if}
            {:else if githubOutcome.kind === "rateLimited"}
              <div class="gh-error">
                <AlertCircle size={14} />
                <span>
                  {ui.locale === "ru"
                    ? `Статистика GitHub временно недоступна (лимит запросов сбросится в ${fmtResetTime(githubOutcome.resetAt)}). Войдите через «Настройки → GitHub», чтобы снять ограничение.`
                    : `GitHub stats temporarily unavailable (rate limit resets at ${fmtResetTime(githubOutcome.resetAt)}). Sign in via Settings → GitHub to remove the limit.`}
                </span>
              </div>
            {:else if githubOutcome.kind === "blocked"}
              <div class="gh-error">
                <AlertCircle size={14} />
                <span>{t("Blocked by Offline Mode. Disable in Settings → Network.", ui.locale)}</span>
              </div>
            {:else if githubOutcome.kind === "error"}
              <div class="gh-error">
                <AlertCircle size={14} />
                <span>{t("Couldn't load GitHub stats", ui.locale)}: {githubOutcome.message}</span>
              </div>
            {/if}
            <!-- kind === "miss" renders nothing -->

            <!-- Phase 12f — actions row. Painted whenever the stats card
                 itself rendered (so non-GitHub homepages and paranoid-
                 blocked rows stay quiet). Clicking any action while
                 signed-out intercepts via `requireGithubSignIn()` —
                 deep-links to Settings → GitHub with a toast hint. No
                 static "Sign in to …" line; the prompt only appears when
                 the user actually wants to act. -->
            {#if githubStatsEligible && pkg?.homepage}
              <div class="gh-actions">
                <button
                  type="button"
                  class="gh-action"
                  class:active={githubSignedIn && starredState === true}
                  onclick={onToggleStar}
                  disabled={starToggling || (githubSignedIn && starredState === "unknown")}
                  title={!githubSignedIn
                    ? t("Sign in to GitHub to star this repository", ui.locale)
                    : starredState === true
                      ? t("Unstar this repository", ui.locale)
                      : starredState === false
                        ? t("Star this repository", ui.locale)
                        : (ui.locale === "ru" ? "Загружаем состояние звезды…" : "Loading starred state…")}
                >
                  <Star
                    size={14}
                    fill={githubSignedIn && starredState === true ? "currentColor" : "none"}
                  />
                  <span>{githubSignedIn && starredState === true ? t("Starred", ui.locale) : t("Star", ui.locale)}</span>
                </button>

                <button
                  type="button"
                  class="gh-action"
                  class:active={githubSignedIn && watching === true}
                  onclick={onToggleWatch}
                  disabled={watchPending}
                  title={!githubSignedIn
                    ? t("Sign in to GitHub to watch this repository", ui.locale)
                    : watching === true
                      ? t("Stop watching", ui.locale)
                      : t("Watch for activity", ui.locale)}
                >
                  {#if githubSignedIn && watching === true}
                    <EyeIcon size={14} />
                    <span>{t("Watching", ui.locale)}</span>
                  {:else}
                    <EyeOff size={14} />
                    <span>{t("Watch", ui.locale)}</span>
                  {/if}
                </button>

                <button
                  type="button"
                  class="gh-action"
                  onclick={openPackageIssue}
                  title={!githubSignedIn
                    ? (ui.locale === "ru" ? "Войдите в GitHub, чтобы сообщить о проблеме" : "Sign in to GitHub to file an issue")
                    : (ui.locale === "ru"
                      ? `Сообщить о проблеме в ${githubHp ? githubRepoFromHomepage(githubHp)?.owner ?? "" : ""}/${githubHp ? githubRepoFromHomepage(githubHp)?.repo ?? "" : ""}`
                      : `File an issue against ${githubHp ? githubRepoFromHomepage(githubHp)?.owner ?? "" : ""}/${githubHp ? githubRepoFromHomepage(githubHp)?.repo ?? "" : ""}`)}
                >
                  <MessageSquarePlus size={14} />
                  <span>{t("File issue", ui.locale)}</span>
                </button>
              </div>
            {/if}
          </section>
        {/if}

        {#if svc}
          <section class="service-card" class:pending={svcPending}>
            <div class="svc-head">
              <h3>{t("Service", ui.locale)}</h3>
              <Pill tone={svcStatus === "started" ? "success" : svcStatus === "error" ? "danger" : svcStatus === "scheduled" ? "warning" : "neutral"}>
                {serviceStatusLabel(svcStatus, ui.locale)}
              </Pill>
            </div>
            {#if svc.user}
              <div class="svc-meta text-muted">{ui.locale === "ru" ? "пользователь" : "user"}: {svc.user}</div>
            {/if}
            <div class="svc-actions">
              <button
                class="svc-btn"
                onclick={() => svcAct("start")}
                disabled={svcPending || svcStatus === "started"}
                title={svcStatus === "started" ? t("Already running", ui.locale) : t("Start service", ui.locale)}
              >
                <Play size={14} /> {t("Start", ui.locale)}
              </button>
              <button
                class="svc-btn"
                onclick={() => svcAct("stop")}
                disabled={svcPending || svcStatus === "stopped" || svcStatus === "none"}
                title={svcStatus === "started" ? t("Stop service", ui.locale) : t("Not running", ui.locale)}
              >
                <Square size={14} /> {t("Stop", ui.locale)}
              </button>
              <button
                class="svc-btn"
                onclick={() => svcAct("restart")}
                disabled={svcPending}
                title={t("Restart service", ui.locale)}
              >
                <RotateCcw size={14} /> {t("Restart", ui.locale)}
              </button>
            </div>
          </section>
        {/if}

        {#if detail.caveats}
          <section class="caveats">
            <h3>{t("Caveats", ui.locale)}</h3>
            <pre>{detail.caveats}</pre>
          </section>
        {/if}

        {#if detail.dependencies.length > 0}
          <section class="collapse">
            <button class="collapse-head" aria-expanded={depsOpen} onclick={() => (depsOpen = !depsOpen)}>
              {#if depsOpen}<ChevronDown size={14} />{:else}<ChevronRight size={14} />{/if}
              <span>{t("Dependencies", ui.locale)} ({detail.dependencies.length})</span>
            </button>
            {#if depsOpen}
              <ul class="deps">
                {#each detail.dependencies as d (d)}
                  <li>{d}</li>
                {/each}
              </ul>
            {/if}
          </section>
        {/if}

        <!-- Feature #1 — Reverse dependencies ("Required by"). Pure
             catalog-graph inversion: every catalog entry that declares
             this package as a dependency. Each row is a button that
             navigates to that dependent's detail (same pattern as the
             Similar-packages pills). Cask dependents are gated off Linux
             via `visibleDependents`. Empty set → no section (honest
             leaf-node state). Note: forward Dependencies above come from
             `brew info` (the installed formula's actual deps) while this
             list inverts the bundled catalog snapshot, so the two aren't
             guaranteed to be perfectly symmetric. -->
        {#if visibleDependents.length > 0}
          <section class="collapse">
            <button class="collapse-head" aria-expanded={reqByOpen} onclick={() => (reqByOpen = !reqByOpen)}>
              {#if reqByOpen}<ChevronDown size={14} />{:else}<ChevronRight size={14} />{/if}
              <span>{t("Required by", ui.locale)} ({visibleDependents.length})</span>
              <InfoButton
                title={t("About reverse dependencies", ui.locale)}
                body={t("detail.aboutReverseDependencies.body", ui.locale)}
                label={t("About reverse dependencies", ui.locale)}
              />
            </button>
            {#if reqByOpen}
              <ul class="deps">
                {#each visibleDependents as dep (dep.kind + ":" + dep.name)}
                  {@const label = edgeLabel(dep)}
                  <li>
                    <button
                      type="button"
                      class="dependent-link"
                      onclick={() => openDependent(dep)}
                      title={ui.locale === "ru" ? `Открыть ${dep.name}` : `Open ${dep.name}`}
                    >
                      {dep.name}
                    </button>
                    {#if label}<span class="dependent-edge text-muted">{label}</span>{/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </section>
        {/if}

        {#if detail.conflictsWith.length > 0}
          <section class="collapse">
            <button class="collapse-head" aria-expanded={dependentsOpen} onclick={() => (dependentsOpen = !dependentsOpen)}>
              {#if dependentsOpen}<ChevronDown size={14} />{:else}<ChevronRight size={14} />{/if}
              <span>{t("Conflicts with", ui.locale)} ({detail.conflictsWith.length})</span>
            </button>
            {#if dependentsOpen}
              <ul class="deps">
                {#each detail.conflictsWith as c (c)}<li>{c}</li>{/each}
              </ul>
            {/if}
          </section>
        {/if}
      {/if}
    </div>

    <footer class="actions">
      {#if isInstalled && isOutdated}
        <Button variant="primary" onclick={doUpgrade}>
          {#snippet icon()}<ArrowUpCircle size={16} />{/snippet}
          {t("Upgrade", ui.locale)}
        </Button>
        <Button variant="danger" onclick={() => (confirmUninstall = true)}>
          {#snippet icon()}<Trash2 size={16} />{/snippet}
          {t("Uninstall", ui.locale)}
        </Button>
      {:else if isInstalled}
        <Button variant="secondary" onclick={() => doInstall(false)}>
          {#snippet icon()}<RefreshCcw size={16} />{/snippet}
          {t("detail.action.reinstall", ui.locale)}
        </Button>
        <Button variant="danger" onclick={() => (confirmUninstall = true)}>
          {#snippet icon()}<Trash2 size={16} />{/snippet}
          {t("Uninstall", ui.locale)}
        </Button>
      {:else if pkg && caskOnLinux}
        <p class="cask-unavailable">{t("detail.caskUnavailableLinux", ui.locale)}</p>
      {:else if pkg}
        <Button variant="primary" onclick={handleInstallClick}>
          {#snippet icon()}<Download size={16} />{/snippet}
          {t("Install", ui.locale)}
        </Button>
      {/if}
    </footer>
  </aside>

  <DestructiveConfirm
    open={confirmUninstall}
    title={ui.locale === "ru" ? `Удалить ${ui.selectedPackage.name}?` : `Uninstall ${ui.selectedPackage.name}?`}
    confirmLabel={t("Uninstall", ui.locale)}
    onCancel={() => (confirmUninstall = false)}
    onConfirm={doUninstall}
  >
    {#if ui.locale === "ru"}
      <p>Пакет <strong>{ui.selectedPackage.name}</strong> будет удалён из системы.</p>
    {:else}
      <p>This will remove <strong>{ui.selectedPackage.name}</strong> from your system.</p>
    {/if}
  </DestructiveConfirm>

  <DestructiveConfirm
    open={confirmExternalInstall}
    title={detail?.isMas ? t("App Store Version Detected", ui.locale) : t("Overwrite manual installation?", ui.locale)}
    confirmLabel={detail?.isMas ? t("Installation Blocked", ui.locale) : t("Install & Override", ui.locale)}
    confirmVariant="danger"
    confirmDisabled={detail?.isMas}
    onCancel={() => (confirmExternalInstall = false)}
    onConfirm={() => {
      confirmExternalInstall = false;
      doInstall(true);
    }}
  >
    {#if detail?.isMas}
      <div class="mas-warning-box">
        <p>{t("An existing App Store version was found in your Applications folder.", ui.locale)} <strong>{ui.selectedPackage?.name}</strong></p>
        <p>{t("App Store bundles are system-protected and cannot be overwritten by Homebrew.", ui.locale)}</p>
        <div class="mas-instruction">
          <strong>{ui.locale === "ru" ? "Решение:" : "Resolution:"}</strong>
          {ui.locale === "ru"
            ? " удалите из /Applications версию, установленную через App Store, затем установите приложение через Homebrew."
            : ` ${t("Resolution: delete the App Store version from /Applications, then install it again via Homebrew.", ui.locale).replace(/^Resolution: /u, "")}`}
        </div>
      </div>
    {:else}
      <p>{t("An existing version was found in your Applications folder. If you proceed, Homebrew will force-install and overwrite the existing bundle.", ui.locale)} <strong>{ui.selectedPackage?.name}</strong></p>
    {/if}
  </DestructiveConfirm>

  <IssueModal
    open={issueOpen}
    title={issueInitialTitle}
    body={issueInitialBody}
    labels={issueInitialLabels}
    repo={issueTargetRepo}
    homepage={issueTargetHomepage}
    onClose={() => (issueOpen = false)}
  />
{/if}

<style>
  .detail {
    /* Width is driven by ui.detailPaneWidth via the inline style binding below.
       Default falls back to the original 420px so the panel keeps working if
       the var is somehow unset (e.g. SSR or pre-mount). */
    width: var(--detail-pane-width, 420px);
    flex: none;
    background: var(--color-surface-raised);
    border-left: 1px solid var(--color-border);
    display: flex;
    flex-direction: column;
    min-height: 0;
    min-width: 0;
    animation: slideIn var(--motion-duration-base) var(--motion-ease-out);
  }
  @keyframes slideIn {
    from { transform: translateX(8px); opacity: 0; }
    to   { transform: translateX(0); opacity: 1; }
  }
  @media (prefers-reduced-motion: reduce) {
    .detail { animation: none; }
  }

  /* Local rules for the detail header. The shared `.panel-head` baseline
     (in app.css) pins height, padding, border-bottom, and h1 typography
     so the detail header separator lines up with every main panel head
     to the pixel. We only customise: the title's truncation, the type
     pill's right-alignment, and the close button. */
  .detail-title {
    /* Truncate long friendly names so they don't push the type pill off */
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    display: inline-flex;
    align-items: baseline;
    gap: 8px;
  }
  /* h1 receives programmatic focus when the slide-over opens (a11y).
     Suppress its focus ring — the slide-in animation + panel context are the visual cue;
     the ring on a non-interactive heading would be misleading. */
  .detail-title:focus { outline: none; box-shadow: none; }

  /* Type pill (formula/cask) pushed to the right of the title via
     auto margin. Sits flush against the close button. */
  .panel-head :global(.pill) {
    margin-left: auto;
  }

  .close { color: var(--color-text-muted); padding: 4px; border-radius: var(--radius-sm); }
  .close:hover { background: var(--color-surface-sunken); color: var(--color-text-primary); }

  /* Centered app-icon anchor at the top of the detail body. */
  .detail-icon {
    display: flex;
    justify-content: center;
    padding: var(--space-2) 0 var(--space-4);
  }

  .body {
    padding: var(--space-4);
    flex: 1;
    overflow-y: auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .meta {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .meta > div { display: grid; grid-template-columns: 80px 1fr; gap: var(--space-2); font-size: var(--text-body-sm); }
  .meta dt { color: var(--color-text-muted); }
  .meta dd { color: var(--color-text-primary); }
  .warn { color: var(--color-warning-strong); margin-left: var(--space-2); font-weight: var(--fw-medium); } /* AA text contrast */
  .icon-source { color: var(--color-text-secondary); }

  /* Category pills sit in the dd column; let them wrap if there are many. */
  .cat-pills {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .cat-pill {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px var(--space-2);
    height: 20px;
    border-radius: var(--radius-full);
    border: 1px solid var(--color-border);
    background: var(--color-surface-sunken);
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
    line-height: 1;
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
  }
  .cat-pill:hover {
    background: var(--color-brand-subtle);
    border-color: var(--color-brand);
    color: var(--color-text-primary);
  }
  .cat-pill:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 2px;
  }

  .desc {
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
    overflow-wrap: anywhere;
    word-break: break-word;
  }

  .homepage {
    display: inline-flex; align-items: center; gap: var(--space-1);
    color: var(--color-text-link);
    font-size: var(--text-body-sm);
    max-width: 100%;
    /* long URLs that exceed the pane wrap rather than clipping at the edge */
    overflow-wrap: anywhere;
    word-break: break-word;
    text-align: left;
  }
  .homepage:hover { text-decoration: underline; }
  /* Allow the URL to use the full available width and wrap; the ellipsis-truncate
     of the old design clipped paths mid-segment at narrow widths. */
  .homepage .truncate {
    max-width: 100%;
    overflow-wrap: anywhere;
    word-break: break-word;
    white-space: normal;
  }

  /* ── Service card (per-package brew services controls) ── */
  .service-card {
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
    padding: var(--space-3);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    transition: opacity 0.12s ease;
  }
  .service-card.pending { opacity: 0.6; }
  .svc-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }
  .svc-head h3 {
    font-size: var(--text-h3);
    font-weight: var(--fw-semibold);
    margin: 0;
  }
  .svc-meta { font-size: var(--text-body-sm); }
  .svc-actions {
    display: flex;
    gap: var(--space-2);
  }
  .svc-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px var(--space-2);
    height: 28px;
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
  }
  .svc-btn:not(:disabled):hover {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    border-color: var(--color-accent);
  }
  .svc-btn:disabled { opacity: 0.4; cursor: default; }

  .caveats {
    background: var(--color-warning-subtle);
    color: var(--color-text-primary);
    border-left: 3px solid var(--color-warning);
    padding: var(--space-3) var(--space-4);
    border-radius: var(--radius-md);
    /* Caveats commonly contain long $HOMEBREW_PREFIX paths — wrap aggressively
       on any character so they don't clip at the pane edge. */
    overflow-wrap: anywhere;
    word-break: break-word;
    min-width: 0;
  }
  .caveats h3 { font-size: var(--text-h3); margin-bottom: var(--space-2); color: var(--color-warning-strong); } /* AA text contrast on warning-subtle */
  .caveats pre {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    white-space: pre-wrap;     /* preserve brew's newlines AND allow wrapping */
    word-break: break-word;
    overflow-wrap: anywhere;
    /* Fallback: if a single unbreakable token (long hash, no whitespace) still
       overflows, give the <pre> its own horizontal scroll instead of clipping
       at the pane edge. */
    overflow-x: auto;
    max-width: 100%;
  }

  .collapse-head {
    display: inline-flex; align-items: center; gap: var(--space-1);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    padding: var(--space-1) 0;
  }
  .collapse-head:hover { color: var(--color-text-primary); }
  .deps {
    padding-left: var(--space-4);
    margin-top: var(--space-1);
    display: flex; flex-direction: column; gap: 2px;
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    /* Dependency names with slashes (e.g. "homebrew/cask/foo") can be long;
       wrap them rather than letting the pane scroll horizontally. */
    overflow-wrap: anywhere;
    word-break: break-word;
    min-width: 0;
  }
  .deps li { min-width: 0; }
  .deps li::before { content: "·"; margin-right: var(--space-2); color: var(--color-text-muted); }

  /* Feature #1 — reverse-dependent rows are clickable links that
     navigate to the dependent's detail. Inline text-button styling so
     they sit naturally inside the `.deps` list next to the bullet. */
  .dependent-link {
    color: var(--color-text-secondary);
    font-size: inherit;
    text-align: left;
    cursor: pointer;
    overflow-wrap: anywhere;
    word-break: break-word;
    transition: color 0.12s ease;
  }
  .dependent-link:hover { color: var(--color-text-primary); text-decoration: underline; }
  .dependent-link:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 2px;
    border-radius: var(--radius-sm, 3px);
  }
  .dependent-edge {
    margin-left: var(--space-2);
    font-size: var(--text-caption);
  }

  .actions {
    display: flex;
    gap: var(--space-3);
    padding: var(--space-4);
    border-top: 1px solid var(--color-border);
    justify-content: flex-end;
  }

  .cask-unavailable {
    margin: 0;
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    align-self: center;
  }

  .error { padding: var(--space-4); display: flex; flex-direction: column; gap: var(--space-3); }

  /* ── GitHub stats card (Phase 12c) ── */
  .gh-card {
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
    padding: var(--space-2) var(--space-3);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    font-size: var(--text-body-sm);
  }
  .gh-loading {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--color-text-muted);
  }
  .gh-stats {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    color: var(--color-text-primary);
  }
  .gh-stat {
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }
  .gh-sep { color: var(--color-text-muted); }
  .gh-muted { color: var(--color-text-muted); }
  .gh-archived {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 8px;
    background: var(--color-warning-subtle);
    border-radius: var(--radius-sm);
    color: var(--color-warning-strong);
  }

  /* ── Feature #2: deprecation / disabled notice ──
     Mirrors the .gh-archived warning card. Deprecated = warning (amber),
     disabled = danger (red, the stronger state). Reason/date strings are
     rendered verbatim; the replacement is a clickable link styled like an
     inline button. */
  .deprecation-notice {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: var(--space-2) var(--space-3);
    background: var(--color-warning-subtle);
    border: 1px solid var(--color-warning, #f59e0b);
    border-radius: var(--radius-md);
    color: var(--color-warning-strong);
    font-size: var(--text-body-sm);
  }
  .deprecation-notice :global(svg) { flex: none; margin-top: 2px; }
  .deprecation-notice.disabled {
    background: var(--color-danger-subtle);
    border-color: var(--color-danger);
    color: var(--color-danger-on-subtle, var(--color-danger));
  }
  .deprecation-body { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .deprecation-line { margin: 0; line-height: var(--lh-normal); }
  .deprecation-line strong { font-weight: var(--fw-semibold); }
  .deprecation-date { font-variant-numeric: tabular-nums; opacity: 0.85; }
  .deprecation-reason { opacity: 0.95; }
  .deprecation-sub {
    margin: 0;
    font-size: var(--text-caption);
    opacity: 0.85;
  }
  .deprecation-replacement {
    margin: 2px 0 0 0;
    color: var(--color-text-primary);
  }
  .deprecation-replacement-link {
    display: inline;
    padding: 0;
    background: none;
    border: none;
    color: inherit;
    font: inherit;
    font-weight: var(--fw-semibold);
    text-decoration: underline;
    cursor: pointer;
  }
  .deprecation-replacement-link:hover { text-decoration: none; }
  /* Render as a single flowing line: the icon is a flex child that
     doesn't shrink, and the whole sentence (including the inline <code>
     elements for license names) lives inside one span so it wraps as
     prose instead of breaking between the prose and the code blocks. */
  .gh-license-mismatch {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    color: var(--color-text-muted);
    font-size: var(--text-caption);
    line-height: 1.45;
  }
  .gh-license-mismatch :global(svg) {
    flex: none;
    margin-top: 3px;
  }
  .gh-license-mismatch > span {
    min-width: 0;
  }
  .gh-license-mismatch code {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
  }
  .gh-error {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
  }

  /* ── Phase 12f authed-actions row ── */
  .gh-actions {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
    margin-top: 6px;
    padding-top: var(--space-2);
    border-top: 1px dashed var(--color-border);
  }
  .gh-action {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px var(--space-2);
    height: 26px;
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
  }
  .gh-action:not(:disabled):hover {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    border-color: var(--color-accent);
  }
  .gh-action.active {
    color: var(--color-brand);
    border-color: var(--color-brand);
  }
  .gh-action.active:not(:disabled):hover {
    background: var(--color-brand-subtle, rgba(245, 158, 11, 0.08));
  }
  .gh-action:disabled { opacity: 0.5; cursor: default; }

  /* ── Phase 13 — enriched metadata visuals ── */

  /* Enriched summary blockquote — between meta dl and brew desc. */
  .enriched-summary {
    margin: 0;
    padding: var(--space-3);
    border-left: 3px solid var(--color-brand, var(--color-accent));
    background: var(--color-surface-sunken);
    border-radius: 0 var(--radius-md) var(--radius-md) 0;
    color: var(--color-text-primary);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .enriched-summary p {
    margin: 0;
    line-height: var(--lh-normal);
    overflow-wrap: anywhere;
  }

  /* Use cases + similar sections share a heading style. */
  .enriched-section {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .enriched-section h3 {
    font-size: var(--text-h3);
    font-weight: var(--fw-semibold);
    margin: 0;
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-2);
  }

  /* v0.4.0 — install-trend chart card in PackageDetail. Same gap/H3
     rhythm as enriched-section so it blends with the surrounding AI
     blocks. */
  .trend-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-top: var(--space-3);
  }
  .trend-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-3);
    flex-wrap: wrap;
  }
  .trend-head h3 {
    font-size: var(--text-h3);
    font-weight: var(--fw-semibold);
    margin: 0;
  }
  .trend-meta {
    font-size: var(--text-body-sm);
  }

  .use-cases {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding-left: var(--space-4);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    list-style: disc;
  }
  .use-cases li { line-height: var(--lh-normal); }

  .similar-pills {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .similar-pill {
    display: inline-flex;
    align-items: center;
    padding: 2px var(--space-2);
    height: 20px;
    border-radius: var(--radius-full);
    border: 1px solid var(--color-border);
    background: var(--color-surface-sunken);
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
    line-height: 1;
    cursor: pointer;
    font-family: var(--font-mono, inherit);
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
  }
  .similar-pill:hover {
    background: var(--color-brand-subtle, rgba(245, 158, 11, 0.08));
    border-color: var(--color-brand, var(--color-accent));
    color: var(--color-text-primary);
  }
  .similar-pill:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 2px;
  }

  /* Tags — small ghost-style pills, distinct from category pills. */
  .tag-pills {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    align-items: center;
  }
  .tag-pill {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 1px 6px;
    height: 18px;
    border-radius: var(--radius-sm);
    background: transparent;
    border: 1px solid var(--color-border);
    color: var(--color-text-muted);
    font-size: 10px;
    font-weight: var(--fw-medium);
    line-height: 1;
  }

  /* ── Security card (v0.5.0) ──
     Three visual states share a card frame. Tone-coloured headers
     signal posture (neutral/clean/vuln) at a glance; the body width is
     constrained by the parent .body padding. List items use a clean
     left-aligned layout with a severity pill, the advisory id, and an
     optional "Patched in X" badge. */
  .sec-card {
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
    padding: var(--space-3);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    font-size: var(--text-body-sm);
  }
  .sec-head {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-text-primary);
  }
  .sec-head h3 {
    font-size: var(--text-h3);
    font-weight: var(--fw-semibold);
    margin: 0;
  }
  .sec-card :global(.sec-icon) { color: var(--color-text-secondary); }
  .sec-card :global(.sec-icon-clean) { color: var(--color-success-on-subtle, var(--color-success)); }
  .sec-card :global(.sec-icon-warn)  { color: var(--color-warning-on-subtle, var(--color-warning)); }
  .sec-card :global(.sec-icon-vuln)  { color: var(--color-danger-on-subtle, var(--color-danger)); }

  .sec-cta {
    margin: 0;
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
  }
  .sec-clean {
    margin: 0;
    color: var(--color-success-on-subtle, var(--color-success));
    font-weight: var(--fw-medium);
  }

  .sec-actions {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
  }
  .sec-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px var(--space-2);
    height: 28px;
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
  }
  .sec-btn:not(:disabled):hover {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    border-color: var(--color-accent);
  }
  .sec-btn:disabled { opacity: 0.5; cursor: default; }
  .sec-btn-primary {
    background: var(--color-brand-subtle, var(--color-surface));
    border-color: var(--color-brand, var(--color-accent));
    color: var(--color-text-primary);
  }
  .sec-btn-primary:not(:disabled):hover {
    background: var(--color-brand, var(--color-accent));
    color: var(--color-text-inverse);
    border-color: var(--color-brand, var(--color-accent));
  }

  .sec-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin: 0;
    padding: 0;
    list-style: none;
  }
  .sec-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: var(--space-2);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
  }
  .sec-item-head {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-2);
  }
  .sec-summary {
    margin: 0;
    color: var(--color-text-secondary);
    line-height: var(--lh-normal);
    overflow-wrap: anywhere;
  }
  .sec-summary-empty { font-style: italic; }
  .sec-details-link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    background: none;
    border: 0;
    padding: 0;
    color: var(--color-text-link, var(--color-brand));
    font: inherit;
    font-style: italic;
    cursor: pointer;
  }
  .sec-details-link:hover { text-decoration: underline; }

  /* Severity pill — mirrors Pill.svelte's tones but inlined here so the
     pill keeps Pill.svelte's class isolation untouched. Lowercase text
     to match the rest of the design system. */
  .sec-sev {
    display: inline-flex;
    align-items: center;
    height: 18px;
    padding: 0 var(--space-2);
    border-radius: var(--radius-sm);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
    text-transform: lowercase;
    letter-spacing: 0.02em;
    line-height: 1;
    white-space: nowrap;
  }
  .sec-sev-danger  { background: var(--color-danger-subtle);  color: var(--color-danger-on-subtle); }
  .sec-sev-warning { background: var(--color-warning-subtle); color: var(--color-warning-on-subtle); }
  .sec-sev-info    { background: var(--color-info-subtle);    color: var(--color-info-on-subtle); }
  .sec-sev-neutral { background: var(--color-surface-sunken); color: var(--color-text-secondary); border: 1px solid var(--color-border); }

  .sec-id {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 1px 6px;
    height: 18px;
    border-radius: var(--radius-sm);
    background: transparent;
    border: 1px dashed var(--color-border);
    color: var(--color-text-link, var(--color-brand));
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    line-height: 1;
    cursor: pointer;
  }
  .sec-id:hover { background: var(--color-surface-sunken); text-decoration: underline; }
  .sec-id-plain {
    cursor: default;
    color: var(--color-text-muted);
  }
  .sec-id-plain:hover { background: transparent; text-decoration: none; }

  .sec-fixed {
    display: inline-flex;
    align-items: center;
    height: 18px;
    padding: 0 6px;
    border-radius: var(--radius-sm);
    background: var(--color-success-subtle);
    color: var(--color-success-on-subtle);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
    line-height: 1;
  }

  .sec-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
    padding-top: var(--space-2);
    border-top: 1px dashed var(--color-border);
  }
  .sec-stamp { font-size: var(--text-caption); }
  .sec-link {
    background: transparent;
    color: var(--color-text-link, var(--color-brand));
    font-size: var(--text-caption);
    padding: 2px var(--space-1);
    border-radius: var(--radius-sm);
    cursor: pointer;
  }
  .sec-link:not(:disabled):hover { background: var(--color-surface); text-decoration: underline; }
  .sec-link:disabled { opacity: 0.5; cursor: default; }

  :global(.spin-slow) {
    animation: spin 1.5s linear infinite;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }
  @media (prefers-reduced-motion: reduce) {
    :global(.spin-slow) { animation: none; }
  }

  .mas-warning-box {
    background: var(--color-warning-subtle);
    border-left: 3px solid var(--color-warning);
    padding: var(--space-3) var(--space-4);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
    margin-bottom: var(--space-4);
    text-align: left;
    font-size: var(--text-body);
    line-height: var(--lh-body);
  }
  .mas-warning-box p {
    margin: 0 0 var(--space-2) 0;
  }
  .mas-warning-box p:last-child {
    margin: 0;
  }
  .mas-warning-box strong {
    color: var(--color-warning-strong);
    font-weight: var(--fw-semibold);
  }
  .mas-instruction {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-sm);
    margin-top: var(--space-3);
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
  }
</style>
