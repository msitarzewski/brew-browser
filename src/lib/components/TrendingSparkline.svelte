<script lang="ts">
  /**
   * TrendingSparkline.svelte — v0.4.0
   *
   * SVG line sparkline used in two contexts:
   *   - inline mode (`variant="inline"`): tiny chart inside a trending
   *     list row, ~60×16, from the index.json compact sparkline array.
   *   - detail mode (`variant="detail"`): full-size chart in the package
   *     detail panel, ~360×80, from a full TrendingHistorySeries.
   *
   * Renders nothing gracefully when:
   *   - data is empty or all-zero (nothing meaningful to chart)
   *   - data has only one point (sparkline needs >= 2 to draw a line)
   *
   * The min/max scaling is auto-fit so the line uses the full vertical
   * space of the chart area regardless of absolute magnitudes —
   * trajectory is the message, not the count.
   */

  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";

  type Variant = "inline" | "detail";

  interface Props {
    /** Numeric data points, oldest first. */
    data: number[];
    variant?: Variant;
    /** Optional title for tooltip / a11y. */
    title?: string;
  }

  let { data, variant = "inline", title }: Props = $props();

  /** Dimensions per variant. Pinned here so callers don't have to
      know the magic numbers; both modes use the same SVG geometry. */
  let dims = $derived(
    variant === "detail"
      ? { width: 360, height: 80, strokeWidth: 1.5, padY: 4 }
      : { width: 60, height: 16, strokeWidth: 1, padY: 2 },
  );

  /** Path string for the line. `null` when there's not enough data to
      draw a meaningful chart. */
  let pathD = $derived.by<string | null>(() => {
    if (data.length < 2) return null;
    // All-zero / all-same data → not useful; skip.
    const min = Math.min(...data);
    const max = Math.max(...data);
    if (max === min) return null;

    const { width, height, padY } = dims;
    const chartH = height - 2 * padY;
    const stepX = width / (data.length - 1);
    // Map each point to (x, y) where y is inverted (SVG origin top-left).
    const pts = data.map((v, i) => {
      const x = i * stepX;
      const t = (v - min) / (max - min);
      const y = padY + (1 - t) * chartH;
      return `${x.toFixed(2)},${y.toFixed(2)}`;
    });
    return `M ${pts.join(" L ")}`;
  });

  /** Last point — used to render the "current" dot at the right edge
      of the chart so the user can see where the line ends. Only in
      detail variant; inline is too small for the dot. */
  let lastPoint = $derived.by<{ x: number; y: number } | null>(() => {
    if (variant !== "detail" || data.length < 2) return null;
    const min = Math.min(...data);
    const max = Math.max(...data);
    if (max === min) return null;
    const { width, height, padY } = dims;
    const chartH = height - 2 * padY;
    const x = width;
    const t = (data[data.length - 1] - min) / (max - min);
    const y = padY + (1 - t) * chartH;
    return { x, y };
  });
</script>

{#if pathD}
  <svg
    class="sparkline"
    class:inline={variant === "inline"}
    class:detail={variant === "detail"}
    width={dims.width}
    height={dims.height}
    viewBox={`0 0 ${dims.width} ${dims.height}`}
    role="img"
    aria-label={title ?? t("trending.sparklineAria", ui.locale)}
  >
    {#if title}<title>{title}</title>{/if}
    <path
      d={pathD}
      fill="none"
      stroke="currentColor"
      stroke-width={dims.strokeWidth}
      stroke-linejoin="round"
      stroke-linecap="round"
    />
    {#if lastPoint}
      <circle
        cx={lastPoint.x}
        cy={lastPoint.y}
        r="2.5"
        fill="currentColor"
      />
    {/if}
  </svg>
{:else}
  <!-- Render an inline placeholder so the column still grids — keeps
       row heights consistent across packages that do vs. don't have
       chartable data. -->
  <span class="sparkline-empty" class:inline={variant === "inline"} aria-hidden="true">—</span>
{/if}

<style>
  .sparkline {
    color: var(--color-accent, #b8542a);
    display: inline-block;
    vertical-align: middle;
  }
  .sparkline.inline {
    opacity: 0.85;
  }
  .sparkline.detail {
    color: var(--color-accent, #b8542a);
    width: 100%;
    max-width: 360px;
  }
  .sparkline-empty {
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
    font-variant-numeric: tabular-nums;
  }
  .sparkline-empty.inline {
    font-size: 12px;
    line-height: 16px;
  }
</style>
