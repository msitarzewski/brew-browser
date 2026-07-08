<script lang="ts">
  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";

  /**
   * ResizeHandle — vertical drag handle for resizing a sibling pane horizontally.
   *
   * Renders a 6px-wide invisible hit zone with a 1px hairline in the middle so
   * the cursor target is generous but the visual is calm. Drag horizontally to
   * change `width`; pointer events are captured so dragging continues even when
   * the cursor briefly leaves the handle.
   *
   * Keyboard (when focused, role=separator):
   *   - Left / Right arrows: ±8 px
   *   - Shift + Left / Right: ±32 px
   *   - Home: jump to `min`
   *   - End:  jump to `max` (computed from window for the live max)
   *
   * Double-click resets to `defaultWidth` (small polish; per spec).
   *
   * Width is "owned" by the parent — we just emit changes via `onChange(next)`
   * (live, while dragging) and `onCommit(next)` (mouseup/keyup) so the parent
   * can persist on commit and avoid thrashing localStorage during the drag.
   *
   * `direction` controls which way a positive delta grows the pane.  For a
   * left-edge handle on a right-anchored pane, dragging LEFT grows the pane,
   * so direction = "left". The default fits brew-browser's right-side detail pane.
   */

  type Props = {
    width: number;
    min: number;
    defaultWidth: number;
    /** Optional cap. If omitted, parent should clamp inside onChange/onCommit. */
    max?: number;
    /** Direction the pane grows when the user drags the handle LEFT. */
    direction?: "left" | "right";
    /** Live updates during drag / arrow key — parent applies but should NOT persist. */
    onChange: (next: number) => void;
    /** Fires on drag end or keyup — parent should persist here. */
    onCommit: (next: number) => void;
    /** ARIA label for screen readers. */
    label?: string;
  };

  let {
    width,
    min,
    defaultWidth,
    max,
    direction = "left",
    onChange,
    onCommit,
    label = "",
  }: Props = $props();

  const resolvedLabel = $derived(label || t("resize.panel", ui.locale));

  // Drag state — `dragging` is reactive (`class:dragging` styles the hairline);
  // the rest are imperative-only (set in pointerdown, read in pointermove).
  let dragging = $state(false);
  let startX = 0;
  let startWidth = 0;
  let pendingWidth = 0;
  let pointerId: number | null = null;

  // Sign multiplier: dragging right grows a "right" pane, shrinks a "left" pane.
  // Derived so a parent that flips `direction` at runtime would be honored.
  let dirSign = $derived(direction === "left" ? -1 : 1);

  function onPointerDown(e: PointerEvent) {
    // Only primary button
    if (e.button !== 0) return;
    dragging = true;
    startX = e.clientX;
    startWidth = width;
    pendingWidth = width;
    pointerId = e.pointerId;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    e.preventDefault();
  }

  function onPointerMove(e: PointerEvent) {
    if (!dragging) return;
    const dx = (e.clientX - startX) * dirSign;
    pendingWidth = clamp(startWidth + dx);
    onChange(pendingWidth);
  }

  function endDrag(e: PointerEvent) {
    if (!dragging) return;
    dragging = false;
    if (pointerId != null) {
      try { (e.currentTarget as HTMLElement).releasePointerCapture(pointerId); } catch { /* ignore */ }
      pointerId = null;
    }
    onCommit(pendingWidth);
  }

  function clamp(w: number): number {
    const lo = min;
    const hi = max ?? Number.POSITIVE_INFINITY;
    return Math.min(Math.max(Math.round(w), lo), hi);
  }

  function onKeyDown(e: KeyboardEvent) {
    let next: number | null = null;
    const step = e.shiftKey ? 32 : 8;
    // Arrow direction matches the visual: pressing Left grows a "left"-direction
    // pane (right-anchored) and shrinks a "right"-direction pane.
    if (e.key === "ArrowLeft")  next = clamp(width - step * dirSign);
    else if (e.key === "ArrowRight") next = clamp(width + step * dirSign);
    else if (e.key === "Home")  next = clamp(min);
    else if (e.key === "End")   next = clamp(max ?? Number.POSITIVE_INFINITY);
    if (next != null) {
      e.preventDefault();
      onChange(next);
      onCommit(next);
    }
  }

  function onDblClick() {
    const w = clamp(defaultWidth);
    onChange(w);
    onCommit(w);
  }
</script>

<!-- A keyboard-operable splitter is the standard ARIA pattern here; svelte-check's
     "noninteractive role" heuristic doesn't recognize role=separator with a valuenow
     as interactive, so we silence those two specific lints on this element. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
  class="handle"
  class:dragging
  role="separator"
  aria-orientation="vertical"
  aria-label={resolvedLabel}
  aria-valuemin={min}
  aria-valuemax={max ?? undefined}
  aria-valuenow={Math.round(width)}
  tabindex="0"
  onpointerdown={onPointerDown}
  onpointermove={onPointerMove}
  onpointerup={endDrag}
  onpointercancel={endDrag}
  onkeydown={onKeyDown}
  ondblclick={onDblClick}
  title={t("resize.dragHint", ui.locale)}
></div>

<style>
  .handle {
    /* 6px hit zone, hairline centered.  The flex `none` keeps it from being
       squeezed when the parent shrinks. */
    flex: none;
    width: 6px;
    cursor: col-resize;
    position: relative;
    background: transparent;
    /* keep the layout box predictable across browsers */
    box-sizing: border-box;
    align-self: stretch;
    /* Prevent native gestures (mobile/trackpad) from hijacking the drag. */
    touch-action: none;
    user-select: none;
  }

  /* 1px hairline using the design-system border token. */
  .handle::before {
    content: "";
    position: absolute;
    inset: 0;
    left: 50%;
    width: 1px;
    transform: translateX(-50%);
    background: var(--color-border);
    transition: background var(--motion-duration-fast) var(--motion-ease-out);
  }

  .handle:hover::before,
  .handle:focus-visible::before,
  .handle.dragging::before {
    background: var(--color-border-strong);
  }

  /* Replace the default global focus ring (which would draw a 2px box around
     the entire 6px hit zone) with a slightly thicker hairline — it reads
     correctly as a focused separator without dominating the chrome. */
  .handle:focus-visible {
    outline: none;
  }
  .handle:focus-visible::before {
    width: 2px;
    background: var(--color-border-focus);
  }

  @media (prefers-reduced-motion: reduce) {
    .handle::before { transition: none; }
  }
</style>
