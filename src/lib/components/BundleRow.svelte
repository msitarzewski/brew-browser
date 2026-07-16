<script lang="ts">
  /**
   * BundleRow — a single row in the Bundles master list. Models on
   * `PackageRow.svelte`: a full-width `<button class="row">` with grid cells
   * (icon / name / tagline / packages summary / readiness pill). Clicking the
   * row calls `onSelect(bundle)` — the parent wires that to `ui.selectBundle`,
   * opening the right-side detail pane (same mechanics as Library/Trending).
   */
  import Database from "@lucide/svelte/icons/database";
  import Palette from "@lucide/svelte/icons/palette";
  import Image from "@lucide/svelte/icons/image";
  import Brain from "@lucide/svelte/icons/brain";
  import Clapperboard from "@lucide/svelte/icons/clapperboard";
  import Code from "@lucide/svelte/icons/code";
  import Sparkles from "@lucide/svelte/icons/sparkles";
  import Server from "@lucide/svelte/icons/server";
  import Package from "@lucide/svelte/icons/package";

  import ReadinessPill from "./ReadinessPill.svelte";
  import { bundles } from "$lib/stores/bundles.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { formatBundlePackageSummary } from "$lib/i18n/messages";
  import type { Bundle } from "$lib/types";

  interface Props {
    bundle: Bundle;
    selected?: boolean;
    onSelect?: (bundle: Bundle) => void;
  }

  let { bundle, selected = false, onSelect }: Props = $props();

  // Recipe `icon` names → lucide components. Unknown/missing falls back to a
  // generic package glyph so a new recipe never renders a broken row.
  const ICONS: Record<string, typeof Package> = {
    database: Database,
    palette: Palette,
    image: Image,
    brain: Brain,
    clapperboard: Clapperboard,
    code: Code,
    agentic: Sparkles,
    server: Server,
  };
  const Icon = $derived((bundle.icon && ICONS[bundle.icon]) || Package);

  /** "2 formulae · 1 cask" / "2 формулы · 1 cask-пакет" package summary. */
  const kindSummary = $derived.by<string>(() => {
    const f = bundle.packages.filter((p) => p.kind === "formula").length;
    const c = bundle.packages.filter((p) => p.kind === "cask").length;
    return formatBundlePackageSummary(f, c, ui.locale);
  });

  // Capability readiness against the probed SystemProfile (M1). Derived once
  // per row so the list scroll path stays cheap.
  const readiness = $derived(bundles.readinessFor(bundle));
</script>

<button
  class="row"
  class:selected
  aria-current={selected ? "true" : undefined}
  onclick={() => onSelect?.(bundle)}
>
  <span class="icon" aria-hidden="true"><Icon size={16} /></span>
  <span class="name truncate" title={bundle.name}>{bundle.name}</span>
  <span class="tagline truncate text-muted" title={bundle.tagline}>{bundle.tagline}</span>
  <span class="kinds truncate text-muted">{kindSummary}</span>
  <span class="readiness"><ReadinessPill verdict={readiness.verdict} reason={readiness.reason} /></span>
</button>

<style>
  .row {
    display: grid;
    /* Bundle row columns (5 total):
         icon (24px) / NAME (1fr) / TAGLINE (2fr) / PACKAGES (130px) /
         READINESS (130px).
       Mirrors PackageRow's 1fr/2fr name-to-description balance so the two
       master lists share a visual rhythm; readiness is the key signal so it
       is pinned rightmost and never drops. */
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 130px 130px;
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

  /* Narrow-window responsive — drop columns widest-but-least-essential first,
     mirroring PackageRow. Readiness (5th) always stays.
       <= 1100px : drop Packages summary (4th).
       <=  820px : also drop Tagline (3rd) — icon + name + readiness stay. */
  @media (max-width: 1100px) {
    .row {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 130px;
    }
    .row > :nth-child(4) { display: none; }
  }
  @media (max-width: 820px) {
    .row {
      grid-template-columns: 24px minmax(0, 1fr) 130px;
    }
    .row > :nth-child(3),
    .row > :nth-child(4) { display: none; }
  }

  .row:hover { background: var(--color-surface-sunken); }
  .row.selected {
    background: var(--color-selection-strong);
    color: var(--color-text-inverse);
  }
  .row.selected .tagline,
  .row.selected .kinds { color: inherit; opacity: 0.85; }

  .icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--color-text-secondary);
  }
  .row.selected .icon { color: inherit; }
  .name {
    font-weight: var(--fw-medium);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .tagline {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .kinds {
    font-size: var(--text-body-sm);
    color: var(--color-text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .readiness { display: inline-flex; align-items: center; }
</style>
