<script lang="ts">
  import ChevronRight from "@lucide/svelte/icons/chevron-right";
  import Pill from "./Pill.svelte";
  import PackageRowIcon from "./PackageRowIcon.svelte";
  import { enrichment } from "$lib/stores/enrichment.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t, ruPlural } from "$lib/i18n/messages";
  import { isLinux } from "$lib/util/platform";
  import type { Package, Severity } from "$lib/types";

  interface Props {
    pkg: Package;
    selected?: boolean;
    onSelect?: (pkg: Package) => void;
  }

  let { pkg, selected = false, onSelect }: Props = $props();

  // ── Vulnerability severity dot (v0.5.0) ──
  //
  // Derived once per row (not per paint) so the Library scroll path
  // stays cheap. We only render the dot when scanning is on AND this
  // package has at least one finding — "scanned-clean" packages
  // intentionally show nothing here per spec (positive framing lives
  // on Dashboard/PackageDetail, not in the row list).
  const vulnRecord = $derived(
    settings.effective.vulnerabilityScanningEnabled
      ? vulnerabilities.byPackage(pkg.kind, pkg.name)
      : undefined,
  );
  const vulnMaxSeverity = $derived.by<Severity | null>(() => {
    if (!vulnRecord || vulnRecord.vulns.length === 0) return null;
    // Rank inline so we don't import the store's private helper.
    let best: Severity = "unknown";
    let bestRank = -1;
    for (const v of vulnRecord.vulns) {
      const r =
        v.severity === "critical" ? 4
        : v.severity === "high"   ? 3
        : v.severity === "medium" ? 2
        : v.severity === "low"    ? 1
        : 0;
      if (r > bestRank) { bestRank = r; best = v.severity; }
    }
    return best;
  });
  /** danger | warning | info | neutral — see brief's severity → tone map. */
  const vulnTone = $derived.by<"danger" | "warning" | "info" | "neutral">(() => {
    switch (vulnMaxSeverity) {
      case "critical":
      case "high":
        return "danger";
      case "medium": return "warning";
      case "low":    return "info";
      default:       return "neutral";
    }
  });
  const vulnTitle = $derived.by(() => {
    if (!vulnRecord || vulnMaxSeverity === null) return "";
    const n = vulnRecord.vulns.length;
    if (ui.locale === "ru") {
      const vulnWord = ruPlural(n, "известная уязвимость", "известные уязвимости", "известных уязвимостей");
      return `${n} ${vulnWord} (максимальная серьёзность: ${severityLabel(vulnMaxSeverity)}). Откройте строку, чтобы посмотреть подробности.`;
    }
    return `${n} known vulnerabilit${n === 1 ? "y" : "ies"} (highest: ${vulnMaxSeverity}). Click row to see details.`;
  });

  function severityLabel(severity: Severity): string {
    if (ui.locale !== "ru") return severity;
    switch (severity) {
      case "critical": return "критическая";
      case "high": return "высокая";
      case "medium": return "средняя";
      case "low": return "низкая";
      default: return "неизвестная";
    }
  }

  // ── Deprecation / disabled badge (Feature #2) ──
  //
  // Library rows are `Package`, so the flags ride along from `brew info`.
  // `disabled` is the stronger state and wins the badge when both are set
  // (the formula is gone / about to be removed → danger tone). A package
  // with neither flag shows nothing — never a placeholder.
	  const deprecationBadge = $derived.by<
	    { label: string; tone: "warning" | "danger"; title: string } | null
	  >(() => {
	    if (pkg.disabled) {
	      return {
	        label: t("disabled", ui.locale),
	        tone: "danger",
	        title: pkg.disableReason
	          ? t("discover.disabledReason", ui.locale, { reason: pkg.disableReason })
	          : t("No longer available via Homebrew.", ui.locale),
	      };
	    }
	    if (pkg.deprecated) {
	      return {
	        label: t("deprecated", ui.locale),
	        tone: "warning",
	        title: pkg.deprecationReason
	          ? t("discover.deprecatedReason", ui.locale, { reason: pkg.deprecationReason })
	          : t("May be removed in a future Homebrew update.", ui.locale),
	      };
	    }
	    return null;
	  });

  /** AI-enriched friendly name for this row's token, or null when the
   *  AI Features toggle is off / no enrichment entry. Called inline in
   *  markup — the underlying enrichment.friendlyName() is a sync Map.get(),
   *  no IPC, sub-microsecond, so we don't need a per-row $derived. */
  function friendlyOf(token: string): string | null {
    return enrichment.friendlyName(token);
  }

  /** Description-column content. Preference order:
   *    1. AI-generated 1-2 sentence summary (when AI Features is on +
   *       token is in the enrichment bundle)
   *    2. Upstream Homebrew `desc` (carried on `pkg.description` for
   *       Library rows — populated by `brew info --installed --json=v2`)
   *    3. null (empty cell)
   *  Sync — both lookups read pre-loaded in-memory state. */
  function descOf(): string | null {
    return enrichment.summaryOf(pkg.name) ?? pkg.description ?? null;
  }

</script>

<button
  class="row"
  class:no-kind={isLinux}
  class:selected
  aria-current={selected ? "true" : undefined}
  onclick={() => onSelect?.(pkg)}
>
  <PackageRowIcon token={pkg.name} kind={pkg.kind} iconSource={pkg.iconSource} homepage={pkg.homepage} />
  <span class="name truncate" title={pkg.name}>
    <span class="name-text">{pkg.name}</span>
    {#if friendlyOf(pkg.name)}
      <span class="friendly-subtitle">{friendlyOf(pkg.name)}</span>
    {/if}
  </span>
  <span class="desc truncate text-muted" title={descOf() ?? ""}>{descOf() ?? ""}</span>
  <span class="version truncate">{pkg.installedVersion ?? pkg.stableVersion ?? "—"}</span>
  <!-- Linux: every installed package is a formula, so the type pill is
       pure noise and isn't rendered (`no-kind` collapses the column).
       The cell itself stays — it also hosts the vulnerability severity
       dot, which is fully meaningful on Linux. -->
  <span class="kind">
    {#if !isLinux}
      <Pill tone={pkg.kind === "formula" ? "formula" : "cask"}>
        {pkg.kind === "formula" ? t("package.kind.formula", ui.locale) : t("package.kind.cask", ui.locale)}
      </Pill>
    {/if}
    {#if deprecationBadge}
      <!-- Deprecation / disabled badge (Feature #2). Lives next to the
           kind pill; formula deprecation renders identically on Linux. -->
      <span title={deprecationBadge.title}>
        <Pill tone={deprecationBadge.tone}>{deprecationBadge.label}</Pill>
      </span>
    {/if}
    {#if vulnMaxSeverity !== null}
      <!-- Severity dot — colour wins by max severity. Hover tooltip
           exposes the count and highest band; click bubbles up to the
           row's onSelect so the user lands on PackageDetail's Security
           card. -->
      <span class="vuln-dot vuln-tone-{vulnTone}" title={vulnTitle} aria-label={vulnTitle}></span>
    {/if}
    {#if pkg.pinned}
      <!-- Pinned badge (#90) — package is held back from brew upgrade. -->
      <span title="Pinned — held back from brew upgrade">
        <Pill tone="neutral">Pinned</Pill>
      </span>
    {/if}
  </span>
  <span class="outdated">
    {#if pkg.outdated}
      <span class="upgrade" title={t("Upgrade available", ui.locale)}>
        <ChevronRight size={14} />
        {pkg.stableVersion ?? ""}
      </span>
    {/if}
  </span>
</button>

<style>
  .row {
    display: grid;
    /* Library row columns (6 total):
         icon (24px) / NAME (1fr) / DESCRIPTION (2fr) / VERSION (120px) /
         TYPE (80px) / OUTDATED (120px).
       The 1fr/2fr balance gives the description ~2× the name column's
       share so AI-generated summaries breathe on wide windows. Both use
       minmax(0, …) so the rest of the grid stays stable when the desc
       text would otherwise blow past its share. */
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 80px 120px;
    align-items: center;
    width: 100%;
    min-height: 36px;
    padding: 0 var(--space-3);
    gap: var(--space-3);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    border-bottom: 1px solid var(--color-border);
    text-align: left;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .row > * { min-width: 0; overflow: hidden; }

  /* Narrow-window responsive — drop columns in priority order from
     widest-but-least-essential first:
       <= 1100px : drop Outdated (6th) — outdated state still encoded by
                  the upgrade-chevron rendered inside the name cell's
                  trailing slot in a future tweak; for now just hidden.
       <=  900px : also drop Description (3rd) — name + version + type
                  + outdated indicator stay visible.
       <=  720px : also drop Version (4th). Tightest layout. */
  @media (max-width: 1100px) {
    .row {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 80px;
    }
    .row > :nth-child(6) { display: none; }
  }
  @media (max-width: 900px) {
    .row {
      grid-template-columns: 24px minmax(0, 1fr) 120px 80px;
    }
    .row > :nth-child(3),
    .row > :nth-child(6) { display: none; }
  }
  @media (max-width: 720px) {
    .row {
      grid-template-columns: 24px minmax(0, 1fr) 80px;
    }
    .row > :nth-child(3),
    .row > :nth-child(4),
    .row > :nth-child(6) { display: none; }
  }

  /* Linux (`no-kind`): the type pill isn't rendered, so the TYPE track
     shrinks from 80px to a fixed 12px slot that fits just the 9px vuln
     severity dot (fixed, not auto, so columns stay aligned across rows
     with and without findings). The cell count is unchanged — the macOS
     nth-child hide rules above apply as-is at every breakpoint. */
  .row.no-kind {
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 12px 120px;
  }
  @media (max-width: 1100px) {
    .row.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 120px 12px;
    }
  }
  @media (max-width: 900px) {
    .row.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) 120px 12px;
    }
  }
  @media (max-width: 720px) {
    .row.no-kind {
      grid-template-columns: 24px minmax(0, 1fr) 12px;
    }
  }
  .row:hover { background: var(--color-surface-sunken); }
  .row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .row.selected .version,
  .row.selected .upgrade { color: inherit; }

  /* Vertical flex container so the optional AI-enriched friendly_name
     subtitle (Phase 13) stacks below the raw token. Children manage
     their own truncation; the parent's .truncate class is overridden
     to allow the column. */
  .name {
    font-weight: var(--fw-medium);
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    min-width: 0;
    white-space: normal;
  }
  .name-text {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 100%;
  }
  .friendly-subtitle {
    display: block;
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    font-weight: var(--fw-regular, 400);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 100%;
    line-height: 1.2;
    margin-top: 1px;
  }
  /* Selected-row variant: keep the subtitle legible against the strong
     selection background by tinting toward the inverse text color. */
  .row.selected .friendly-subtitle {
    color: var(--color-text-inverse);
    opacity: 0.75;
  }
  .desc {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row.selected .desc { color: inherit; opacity: 0.85; }
  .version { font-size: var(--text-body-sm); color: var(--color-text-secondary); }
  .upgrade {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    font-size: var(--text-caption);
    color: var(--color-warning-strong); /* darker amber for AA on light surface (was --color-warning at 2.9:1) */
  }

  /* ── Vulnerability severity dot (v0.5.0) ──
     Sits inline to the right of the kind pill. Filled circle, tone-
     coloured by max severity. No own click handler — clicking the row
     opens PackageDetail and the Security card scrolls into view.
     The .kind cell becomes a flex row so the dot lines up vertically
     with the pill's baseline. */
  .kind {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .vuln-dot {
    width: 9px;
    height: 9px;
    border-radius: var(--radius-full, 50%);
    flex: none;
    background: var(--color-text-muted);
    box-shadow: 0 0 0 1px color-mix(in oklch, currentColor 18%, transparent);
  }
  .vuln-tone-danger  { background: var(--color-danger); }
  .vuln-tone-warning { background: var(--color-warning); }
  .vuln-tone-info    { background: var(--color-info, var(--color-text-secondary)); }
  .vuln-tone-neutral { background: var(--color-text-muted); }
</style>
