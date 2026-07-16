<script lang="ts">
  /**
   * BundleDetailPane — the right-side Details pane for the Bundles section,
   * matching Library's PackageDetail mechanics (an `<aside class="detail">`
   * sized by `ui.detailPaneWidth`, gated on `ui.selectedBundle`). Reads the
   * selected bundle back out of the bundles store by id.
   *
   * Content is the former BundleDetail modal: the capability verdict + reason,
   * each package with its live installed state (cross-referenced against the
   * `packages` store), caveats (prominent callout), a Setup checklist, reference
   * links, and an **Install all** action that streams into the Activity drawer
   * via `brewInstallBundle`.
   *
   * A `blocked` readiness verdict gates Install all behind a DestructiveConfirm
   * ("your machine may not run this well") — never a hard block.
   */
  import X from "@lucide/svelte/icons/x";
  import Button from "./Button.svelte";
  import Pill from "./Pill.svelte";
  import ReadinessPill from "./ReadinessPill.svelte";
  import DestructiveConfirm from "./DestructiveConfirm.svelte";
  import DownloadCloud from "@lucide/svelte/icons/download-cloud";
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import Play from "@lucide/svelte/icons/play";
  import FolderOpen from "@lucide/svelte/icons/folder-open";
  import Copy from "@lucide/svelte/icons/copy";
  import ChevronRight from "@lucide/svelte/icons/chevron-right";

  import { activity } from "$lib/stores/activity.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { bundles } from "$lib/stores/bundles.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { services } from "$lib/stores/services.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { brewInfo, brewInstallBundle, openInFinder } from "$lib/api";
  import { normalizeServiceStatus } from "$lib/types";
  import type { Bundle, BundlePackage, PackageKind, SetupStep } from "$lib/types";
  import { safeOpenUrl } from "$lib/util/url";
  import { bareToken } from "$lib/util/token";
  import { stepMode } from "$lib/util/setupStep";
  import { isMac } from "$lib/util/platform";
  import { reportableToastError } from "$lib/util/reportIssue";
  import { formatReadinessReason, t, type MessageKey } from "$lib/i18n/messages";

  // The pane reads the selected bundle out of the store by id (mirrors how
  // PackageDetail reads `ui.selectedPackage`). Undefined while the list is
  // loading or if the id ever goes stale — the pane renders nothing then.
  const bundle = $derived<Bundle | undefined>(
    ui.selectedBundle ? bundles.byId(ui.selectedBundle) : undefined,
  );

  const readiness = $derived(bundle ? bundles.readinessFor(bundle) : null);
  const localizedReason = $derived(readiness ? formatReadinessReason(readiness.reason, ui.locale) : "");
  const pendingCount = $derived(
    bundle ? bundle.packages.filter((p) => stateOf(p) === "not-installed").length : 0,
  );
  const installLabel = $derived(
    !bundle || pendingCount === 0
      ? t("bundles.allInstalled", ui.locale)
      : pendingCount === bundle.packages.length
        ? t("bundles.installAll", ui.locale)
        : t("bundles.installMissing", ui.locale, { count: pendingCount }),
  );

  type InstalledState = "not-installed" | "installed" | "outdated";
  function stateOf(p: BundlePackage): InstalledState {
    const found = packages.findInstalled(p.name, p.kind as PackageKind);
    if (!found) return "not-installed";
    return found.outdated ? "outdated" : "installed";
  }

  const STATE_TONE = { "not-installed": "neutral", installed: "success", outdated: "warning" } as const;
  const STATE_LABEL_KEY: Record<InstalledState, MessageKey> = {
    "not-installed": "bundles.state.notInstalled",
    installed: "bundles.state.installed",
    outdated: "bundles.state.outdated",
  };

  // ---- Per-package inline description accordion ------------------------
  //
  // Each package row can be expanded to reveal its one-line description
  // without leaving the bundle. State is keyed by `name+kind` (the same key
  // the {#each} uses), so multiple rows can be open at once. `$state` object
  // proxies are deeply reactive in Svelte 5, so mutating a key re-renders.

  /** A cached description: `loading` while in flight, `text` null once
   *  resolved with no description available. */
  type DescEntry = { loading: boolean; text: string | null };

  const pkgKey = (p: BundlePackage) => p.name + p.kind;

  let openPkgs = $state<Record<string, boolean>>({});
  let descCache = $state<Record<string, DescEntry>>({});

  function togglePkg(p: BundlePackage) {
    const key = pkgKey(p);
    const nowOpen = !openPkgs[key];
    openPkgs[key] = nowOpen;
    // Lazily resolve the description on first expand; cached thereafter so
    // re-expanding is instant.
    if (nowOpen && descCache[key] === undefined) {
      void loadDesc(p, key);
    }
  }

  async function loadDesc(p: BundlePackage, key: string) {
    // 1) Prefer the localized enrichment summary, matching Library/Discover.
    await enrichment.ensureLoaded();
    const enriched = enrichment.summaryOf(p.name);
    if (enriched) {
      descCache[key] = { loading: false, text: enriched };
      return;
    }

    // 2) Prefer an already-resident description — installed packages carry
    //    one on the `packages` store, so no round-trip is needed.
    const resident = packages.findInstalled(p.name, p.kind as PackageKind);
    if (resident?.description) {
      descCache[key] = { loading: false, text: resident.description };
      return;
    }

    // 3) Fall back to `brew info` — the same call PackageDetail's loadDetail
    //    uses. A tap-qualified name (`user/tap/name`) that isn't tapped
    //    locally makes `brew info` fail; retry the bare token like loadDetail.
    descCache[key] = { loading: true, text: null };
    try {
      const detail = await brewInfo(p.name, p.kind as PackageKind);
      descCache[key] = { loading: false, text: detail.package.description };
      return;
    } catch {
      const bare = bareToken(p.name);
      if (bare !== p.name) {
        try {
          const detail = await brewInfo(bare, p.kind as PackageKind);
          descCache[key] = { loading: false, text: detail.package.description };
          return;
        } catch {
          /* fall through to the graceful empty state */
        }
      }
      descCache[key] = { loading: false, text: null };
    }
  }

  // ---- Per-package single install --------------------------------------
  //
  // A not-installed row's status pill becomes an inline **Install** action
  // that installs ONLY that package. It reuses the same streamed path as
  // "Install all" (`brewInstallBundle` → Activity drawer) but keeps the pane
  // open so the user watches the row flip. Installing state is tracked per
  // package (keyed by `name+kind`, like `openPkgs`), independent of the
  // bundle-wide `installing` flag so multiple single-installs can run at once.
  let installingPkgs = $state<Record<string, boolean>>({});

  async function runInstallOne(p: BundlePackage) {
    const key = pkgKey(p);
    if (installingPkgs[key]) return;
    installingPkgs[key] = true;

    const cmdLabel = `brew install ${p.name}`;
    const tmpId = crypto.randomUUID();
    activity.startJob(t("bundles.activity.installPackage", ui.locale, { name: p.name }), tmpId, cmdLabel);
    ui.openDrawer();
    // Unlike "Install all", do NOT closeDetail — the user stays in the bundle
    // and watches this row flip to "Installed".

    let firstRemapped = false;
    try {
      const result = await brewInstallBundle([p], (evt) => {
        if (evt.kind === "started") {
          if (!firstRemapped) {
            const j = activity.jobs.find((j) => j.jobId === tmpId);
            if (j) j.jobId = evt.jobId;
            firstRemapped = true;
          } else if (!activity.jobs.some((j) => j.jobId === evt.jobId)) {
            activity.startJob(t("bundles.activity.installPackage", ui.locale, { name: p.name }), evt.jobId, evt.command);
          }
        }
        activity.handleEvent(evt);
      });
      if (result.success) {
        toast.success(t("bundles.toast.installedPackage", ui.locale, { name: p.name }));
        // Reload so `stateOf(p)` flips the row to "Installed" (bypass cache).
        await packages.load(true);
      }
    } catch (e) {
      reportableToastError(t("bundles.error.installFailed", ui.locale), e);
    } finally {
      installingPkgs[key] = false;
    }
  }

  let confirmOpen = $state(false);
  let installing = $state(false);

  function onInstallClick() {
    if (installing || !bundle || !readiness) return;
    if (readiness.verdict === "blocked") {
      confirmOpen = true;
    } else {
      void runInstall();
    }
  }

  async function runInstall() {
    if (installing || !bundle) return;
    const b = bundle;
    installing = true;
    confirmOpen = false;

    const names = b.packages.map((p) => p.name);
    const cmdLabel =
      names.length <= 3
        ? `brew install ${names.join(" ")}`
        : `brew install ${names.slice(0, 3).join(" ")} (+${names.length - 3})`;

    // One temp Activity job for instant feedback; the first real `started`
    // event re-keys it. A bundle with both formulae and casks streams as TWO
    // brew steps (see brew_install_bundle) — the second step's `started`
    // arrives with a new jobId, so we register it as its own Activity job.
    const tmpId = crypto.randomUUID();
    activity.startJob(t("bundles.activity.installBundle", ui.locale, { name: b.name }), tmpId, cmdLabel);
    ui.openDrawer();
    ui.closeDetail(); // dismiss the pane so the user sees the drawer

    let firstRemapped = false;
    try {
      const result = await brewInstallBundle(b.packages, (evt) => {
        if (evt.kind === "started") {
          if (!firstRemapped) {
            const j = activity.jobs.find((j) => j.jobId === tmpId);
            if (j) j.jobId = evt.jobId;
            firstRemapped = true;
          } else if (!activity.jobs.some((j) => j.jobId === evt.jobId)) {
            activity.startJob(t("bundles.activity.installBundleCasks", ui.locale, { name: b.name }), evt.jobId, evt.command);
          }
        }
        activity.handleEvent(evt);
      });
      if (result.success) {
        toast.success(t("bundles.toast.installedBundle", ui.locale, { name: b.name }));
        // Reload so per-package installed state flips (force-bypass cache).
        await packages.load(true);
      }
    } catch (e) {
      reportableToastError(t("bundles.error.installFailed", ui.locale), e);
    } finally {
      installing = false;
    }
  }

  // ---- Setup checklist -------------------------------------------------

  // Load services once so `service` steps can reflect running state. Cheap +
  // guarded; only fetches when we don't already have a list.
  $effect(() => {
    if (bundle && bundle.setup.length > 0 && services.list.length === 0) {
      void services.load();
    }
  });

  /** A `service` step's action is only meaningful once its package is
   *  installed (partial install ⇒ nothing to start). Cross-refs the packages
   *  store by name (services are the formula/cask the recipe installs). */
  function serviceInstalled(name: string): boolean {
    return packages.all.some((p) => p.name === name);
  }

  function serviceRunning(name: string): boolean {
    const svc = services.byName(name);
    return svc ? normalizeServiceStatus(svc.status) === "started" : false;
  }

  async function startService(name: string) {
    try {
      await services.start(name);
    } catch (e) {
      reportableToastError(t("bundles.error.startService", ui.locale), e);
    }
  }

  async function reveal(path: string) {
    try {
      await openInFinder(path);
    } catch (e) {
      reportableToastError(t(isMac ? "bundles.error.revealFinder" : "bundles.error.revealFileManager", ui.locale), e);
    }
  }

  async function copyCommand(run: string) {
    try {
      await navigator.clipboard.writeText(run);
      toast.success(t("bundles.toast.copied", ui.locale), run);
    } catch (e) {
      reportableToastError(t("bundles.error.copy", ui.locale), e);
    }
  }

  /** Human label for a step, falling back to a sensible default per kind. */
  function stepLabel(step: SetupStep): string {
    if (step.label) return step.label;
    switch (step.kind) {
      case "service": return step.service ? t("bundles.step.startServiceNamed", ui.locale, { service: step.service }) : t("Start service", ui.locale);
      case "open": return step.url ?? t("bundles.action.open", ui.locale);
      case "reveal": return step.path ?? t("bundles.action.reveal", ui.locale);
      default: return "";
    }
  }

  function close() { ui.closeDetail(); }
</script>

{#if bundle && readiness}
  <aside
    class="detail"
    aria-label={t("bundles.detail", ui.locale)}
    style="--detail-pane-width: {ui.detailPaneWidth}px"
  >
    <header class="panel-head">
      <h1 class="detail-title">{bundle.name}</h1>
      <ReadinessPill verdict={readiness.verdict} reason={readiness.reason} />
      <button class="close" aria-label={t("bundles.closeDetail", ui.locale)} onclick={close} title={t("bundles.closeTitle", ui.locale)}>
        <X size={16} />
      </button>
    </header>

    <div class="body">
      <p class="tagline">{bundle.tagline}</p>

      {#if bundle.description}
        <p class="description">{bundle.description}</p>
      {/if}

      {#if readiness.verdict !== "ready"}
        <div
          class="verdict-callout"
          class:warning={readiness.verdict === "marginal"}
          class:danger={readiness.verdict === "blocked"}
          role="note"
        >
          <span class="verdict-icon" aria-hidden="true"><TriangleAlert size={16} /></span>
          <p>{localizedReason}</p>
        </div>
      {/if}

      <section class="block">
        <h3>{t("bundles.header.packages", ui.locale)}</h3>
        <ul class="pkgs" role="list">
          {#each bundle.packages as p (p.name + p.kind)}
            {@const st = stateOf(p)}
            {@const key = pkgKey(p)}
            {@const open = openPkgs[key] ?? false}
            <li class="pkg" class:open>
              <div class="pkg-row">
                <button
                  type="button"
                  class="pkg-toggle"
                  aria-expanded={open}
                  onclick={() => togglePkg(p)}
                  title={open ? t("bundles.hideDescription", ui.locale) : t("bundles.showDescription", ui.locale)}
                >
                  <span class="pkg-chevron" aria-hidden="true"><ChevronRight size={14} /></span>
                  <span class="pkg-name truncate">{p.name}</span>
                </button>
                <Pill tone={p.kind === "formula" ? "formula" : "cask"}>
                  {t(p.kind === "formula" ? "package.kind.formula" : "package.kind.cask", ui.locale)}
                </Pill>
                {#if st === "not-installed"}
                  {@const inst = installingPkgs[key] ?? false}
                  <span class="pkg-state">
                    <Button
                      size="sm"
                      variant="secondary"
                      onclick={(e) => {
                        e.stopPropagation();
                        void runInstallOne(p);
                      }}
                      disabled={inst}
                      loading={inst}
                      title={inst ? t("Installing…", ui.locale) : t("bundles.action.installPackage", ui.locale, { name: p.name })}
                    >
                      {#snippet icon()}<DownloadCloud size={13} />{/snippet}
                      {inst ? t("Installing…", ui.locale) : t("Install", ui.locale)}
                    </Button>
                  </span>
                {:else}
                  <span class="pkg-state"><Pill tone={STATE_TONE[st]}>{t(STATE_LABEL_KEY[st], ui.locale)}</Pill></span>
                {/if}
              </div>
              {#if open}
                <div class="pkg-desc">
                  {#if descCache[key]?.loading}
                    <span class="pkg-desc-loading">{t("bundles.loadingDescription", ui.locale)}</span>
                  {:else if descCache[key]?.text}
                    <span class="pkg-desc-text">{descCache[key]?.text}</span>
                  {:else}
                    <span class="pkg-desc-empty">{t("bundles.noDescription", ui.locale)}</span>
                  {/if}
                </div>
              {/if}
            </li>
          {/each}
        </ul>
      </section>

      {#if bundle.caveats}
        <div class="caveats" role="note">
          <span class="caveats-icon" aria-hidden="true"><TriangleAlert size={16} /></span>
          <p>{bundle.caveats}</p>
        </div>
      {/if}

      {#if bundle.setup.length > 0}
        <section class="block">
          <h3>{t("bundles.setup", ui.locale)}</h3>
          <p class="setup-hint">
            {t("bundles.setupHint.before", ui.locale)}{" "}
            <em>{t("bundles.setupHint.youRunThis", ui.locale)}</em>{" "}
            {t("bundles.setupHint.after", ui.locale)}
          </p>
          <ol class="setup" role="list">
            {#each bundle.setup as step, i (i)}
              {@const mode = stepMode(step.kind)}
              <li class="step">
                <span class="step-num" aria-hidden="true">{i + 1}</span>

                {#if step.kind === "service"}
                  {@const installed = serviceInstalled(step.service ?? "")}
                  {@const running = serviceRunning(step.service ?? "")}
                  <span class="step-body">
                    <span class="step-label">{stepLabel(step)}</span>
                    {#if running}<span class="step-tag ok">{t("bundles.step.running", ui.locale)}</span>{/if}
                  </span>
                  <Button
                    size="sm"
                    variant="secondary"
                    onclick={() => startService(step.service ?? "")}
                    disabled={!installed || running || services.isPending(step.service ?? "")}
                    title={!installed
                      ? step.service
                        ? t("bundles.step.installFirst", ui.locale, { service: step.service })
                        : t("bundles.step.installFirstGeneric", ui.locale)
                      : running
                        ? t("bundles.step.alreadyRunning", ui.locale)
                        : t("bundles.step.startService", ui.locale)}
                  >
                    {#snippet icon()}<Play size={13} />{/snippet}
                    {t("Start", ui.locale)}
                  </Button>

                {:else if step.kind === "open"}
                  <span class="step-body"><span class="step-label">{stepLabel(step)}</span></span>
                  <Button size="sm" variant="secondary" onclick={() => safeOpenUrl(step.url ?? "")} disabled={!step.url}>
                    {#snippet icon()}<ExternalLink size={13} />{/snippet}
                    {t("bundles.action.open", ui.locale)}
                  </Button>

                {:else if step.kind === "reveal"}
                  <span class="step-body"><span class="step-label">{stepLabel(step)}</span></span>
                  <Button size="sm" variant="secondary" onclick={() => reveal(step.path ?? "")} disabled={!step.path}>
                    {#snippet icon()}<FolderOpen size={13} />{/snippet}
                    {t("bundles.action.reveal", ui.locale)}
                  </Button>

                {:else if step.kind === "command"}
                  <span class="step-body step-body--cmd">
                    {#if step.label}<span class="step-label">{step.label}</span>{/if}
                    <span class="step-run-row">
                      <code class="step-run">{step.run}</code>
                      <span class="step-yourun" title={t("bundles.step.youRunThisTitle", ui.locale)}>{t("bundles.setupHint.youRunThis", ui.locale)}</span>
                    </span>
                  </span>
                  <Button size="sm" variant="secondary" onclick={() => copyCommand(step.run ?? "")} disabled={!step.run}>
                    {#snippet icon()}<Copy size={13} />{/snippet}
                    {t("bundles.action.copy", ui.locale)}
                  </Button>

                {:else if mode === "note"}
                  <!-- note (and any unknown kind, via stepMode → "note"): inert text.
                       No markdown sanitizer exists in this app (PackageDetail renders
                       caveats as plain text too), so render as plain text — no @html. -->
                  <span class="step-body step-body--note">
                    <span class="step-note">{step.text ?? ""}</span>
                  </span>
                {/if}
              </li>
            {/each}
          </ol>
        </section>
      {/if}

      {#if bundle.links.length > 0}
        <section class="block">
          <h3>{t("bundles.links", ui.locale)}</h3>
          <ul class="links" role="list">
            {#each bundle.links as l (l.url)}
              <li>
                <button type="button" class="link" onclick={() => safeOpenUrl(l.url)}>
                  <ExternalLink size={13} />
                  {l.label}
                </button>
              </li>
            {/each}
          </ul>
        </section>
      {/if}
    </div>

    <footer class="detail-foot">
      <Button variant="primary" onclick={onInstallClick} disabled={installing || pendingCount === 0} loading={installing}>
        {#snippet icon()}<DownloadCloud size={14} />{/snippet}
        {installLabel}
      </Button>
    </footer>
  </aside>

  <DestructiveConfirm
    open={confirmOpen}
    title={t("bundles.installAnywayTitle", ui.locale)}
    confirmLabel={t("bundles.installAnywayConfirm", ui.locale)}
    cancelLabel={t("Cancel", ui.locale)}
    confirmVariant="danger"
    onConfirm={runInstall}
    onCancel={() => (confirmOpen = false)}
  >
    <p>{localizedReason}</p>
    <p>{t("bundles.installAnywayBody", ui.locale, { name: bundle.name })}</p>
  </DestructiveConfirm>
{/if}

<style>
  /* Mirrors PackageDetail's pane shell: width driven by ui.detailPaneWidth,
     left border, column flex with a scrolling body. */
  .detail {
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

  /* The shared `.panel-head` baseline (app.css) pins height/padding/border and
     h1 typography so the detail header lines up with every main panel head. */
  .detail-title {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    margin-right: auto;
  }
  .close { color: var(--color-text-muted); padding: 4px; border-radius: var(--radius-sm); }
  .close:hover { background: var(--color-surface-sunken); color: var(--color-text-primary); }

  .body {
    padding: var(--space-4);
    flex: 1;
    overflow-y: auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .detail-foot {
    flex: none;
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-4);
    border-top: 1px solid var(--color-border);
  }

  .tagline {
    font-size: var(--text-body);
    color: var(--color-text-primary);
    margin: 0;
  }

  /* Intent paragraph ("what is this / why") — body copy under the tagline.
     Muted-but-readable with a comfortable reading measure. */
  .description {
    font-size: var(--text-body);
    color: var(--color-text-secondary);
    line-height: 1.6;
    margin: 0;
  }

  /* Actionable readiness reason — rendered in the body ONLY for a
     `marginal`/`blocked` verdict (the header pill is the sole verdict badge).
     Color-coded to the verdict: amber for marginal, red for blocked. */
  .verdict-callout {
    display: flex;
    gap: var(--space-2);
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
  }
  .verdict-callout.warning {
    background: var(--color-warning-subtle);
    border-color: var(--color-warning);
  }
  .verdict-callout.danger {
    background: var(--color-danger-subtle);
    border-color: var(--color-danger);
  }
  .verdict-icon { flex: none; margin-top: 1px; }
  .verdict-callout.warning .verdict-icon { color: var(--color-warning-on-subtle); }
  .verdict-callout.danger .verdict-icon { color: var(--color-danger-on-subtle); }
  .verdict-callout p {
    margin: 0;
    font-size: var(--text-body-sm);
    line-height: 1.4;
  }
  .verdict-callout.warning p { color: var(--color-warning-on-subtle); }
  .verdict-callout.danger p { color: var(--color-danger-on-subtle); }

  .block h3 {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-semibold);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-muted);
    margin: 0 0 var(--space-2) 0;
  }

  .pkgs {
    list-style: none;
    margin: 0;
    padding: 0;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
  }
  .pkg {
    display: flex;
    flex-direction: column;
    border-bottom: 1px solid var(--color-border);
  }
  .pkg:last-child { border-bottom: none; }
  .pkg-row {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
  }
  /* The name + chevron form the disclosure button; it stretches to fill the
     row so the whole left region is a comfortable click/tap target. */
  .pkg-toggle {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: 0;
    background: transparent;
    border: none;
    text-align: left;
    cursor: pointer;
    color: inherit;
    border-radius: var(--radius-sm);
  }
  .pkg-toggle:focus-visible {
    outline: 2px solid var(--color-accent, #b8542a);
    outline-offset: 2px;
  }
  .pkg-chevron {
    flex: none;
    display: inline-flex;
    color: var(--color-text-muted);
    transition: transform var(--motion-duration-base) var(--motion-ease-out);
  }
  .pkg.open .pkg-chevron { transform: rotate(90deg); }
  .pkg-toggle:hover .pkg-chevron { color: var(--color-text-primary); }
  @media (prefers-reduced-motion: reduce) {
    .pkg-chevron { transition: none; }
  }
  .pkg-name {
    min-width: 0;
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
  .pkg-state { flex: none; }

  /* Inline description revealed under the row. Indented to align with the
     package name (past the chevron) and muted like the intent paragraph. */
  .pkg-desc {
    padding: 0 var(--space-3) var(--space-2)
      calc(var(--space-3) + 14px + var(--space-2));
  }
  .pkg-desc-text,
  .pkg-desc-loading,
  .pkg-desc-empty {
    font-size: var(--text-body-sm);
    line-height: 1.4;
    color: var(--color-text-secondary);
  }
  .pkg-desc-loading,
  .pkg-desc-empty { color: var(--color-text-muted); }

  .caveats {
    display: flex;
    gap: var(--space-2);
    padding: var(--space-3);
    background: var(--color-warning-subtle, var(--color-surface-raised));
    border: 1px solid var(--color-warning, var(--color-border));
    border-radius: var(--radius-md);
  }
  .caveats-icon { color: var(--color-warning-strong, #b45309); flex: none; margin-top: 1px; }
  .caveats p {
    margin: 0;
    font-size: var(--text-body-sm);
    color: var(--color-text-primary);
    line-height: 1.4;
  }

  .links {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-3);
  }
  .link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    background: transparent;
    border: none;
    color: var(--color-accent, #b8542a);
    cursor: pointer;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    padding: 0;
    text-decoration: underline;
    text-underline-offset: 2px;
  }
  .link:hover { filter: brightness(1.1); }

  /* Setup checklist */
  .setup-hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    margin: 0 0 var(--space-2) 0;
    line-height: 1.4;
  }
  .setup-hint em {
    font-style: normal;
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }
  .setup {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    counter-reset: step;
  }
  .step {
    display: flex;
    align-items: flex-start;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
  }
  .step-num {
    flex: none;
    width: 20px;
    height: 20px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-semibold);
    color: var(--color-text-muted);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 50%;
    margin-top: 1px;
  }
  .step-body {
    flex: 1;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
  }
  .step-body--cmd,
  .step-body--note {
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
  }
  .step-label {
    font-size: var(--text-body);
    color: var(--color-text-primary);
  }
  .step-tag.ok {
    font-size: var(--text-body-sm);
    color: var(--color-success-strong, #15803d);
  }
  .step-run-row {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
    width: 100%;
  }
  .step-run {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: var(--text-body-sm);
    color: var(--color-text-primary);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    padding: 2px 6px;
    overflow-x: auto;
    white-space: pre;
  }
  .step-yourun {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    color: var(--color-warning-strong, #b45309);
    white-space: nowrap;
  }
  .step-note {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: 1.4;
    white-space: pre-wrap;
  }
</style>
