<script lang="ts">
  import ArrowUp from "@lucide/svelte/icons/arrow-up";
  import ArrowDown from "@lucide/svelte/icons/arrow-down";
  import ArrowUpDown from "@lucide/svelte/icons/arrow-up-down";
  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";

  /**
   * One column header in a list grid that supports sort-by-click. Designed to
   * drop into an existing `.list-header` grid cell without changing layout.
   *
   * The parent owns the sort state (a `{ key, dir }` pair) and tells each
   * header whether it's `active` and in which `dir`. Click the header → parent's
   * `onSort(key)` callback toggles dir or replaces key. Same behavior as macOS
   * Finder column headers.
   */

  interface Props {
    label: string;
    /** A stable key for the column (e.g. "name", "version"). Passed back via onSort. */
    sortKey: string;
    /** True when this column is the currently active sort. */
    active: boolean;
    /** Current direction ("asc" or "desc"). Ignored when `active` is false. */
    dir: "asc" | "desc";
    /** Click handler — parent toggles dir or switches key. */
    onSort: (key: string) => void;
    /** Optional alignment for numeric columns; default left. */
    align?: "left" | "right";
  }

  let { label, sortKey, active, dir, onSort, align = "left" }: Props = $props();

  /**
   * Announce the current sort state to assistive tech via the button's
   * accessible name (the title/aria-label). `aria-sort` would be cleaner but
   * it's a property of `role="columnheader"`, not `role="button"`, and our
   * list grids aren't true tables.
   */
  const ariaTitle = $derived.by(() => {
    if (!active) return t("table.sortBy", ui.locale, { label });
    return t(dir === "asc" ? "table.sortedAsc" : "table.sortedDesc", ui.locale, { label });
  });
</script>

<button
  type="button"
  class="sortable"
  class:align-right={align === "right"}
  class:active
  aria-label={ariaTitle}
  onclick={() => onSort(sortKey)}
  title={ariaTitle}
>
  <span>{label}</span>
  <span class="arrow" aria-hidden="true">
    {#if !active}
      <ArrowUpDown size={11} />
    {:else if dir === "asc"}
      <ArrowUp size={11} />
    {:else}
      <ArrowDown size={11} />
    {/if}
  </span>
</button>

<style>
  .sortable {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    background: transparent;
    color: var(--color-text-muted);
    font-size: var(--text-caption);
    font-weight: var(--fw-semibold);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 0;
    cursor: pointer;
    transition: color 0.12s ease;
    width: 100%;
    text-align: left;
  }
  .sortable:hover { color: var(--color-text-primary); }
  .sortable.active { color: var(--color-text-primary); }
  .sortable.align-right {
    justify-content: flex-end;
    text-align: right;
  }
  .arrow {
    display: inline-flex;
    opacity: 0.6;
  }
  .sortable.active .arrow { opacity: 1; color: var(--color-accent); }
</style>
