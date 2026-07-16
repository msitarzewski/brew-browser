<script lang="ts">
  /**
   * Bundles section — a master list of curated bundle rows (BundleRow), mirroring
   * Library/Trending. Clicking a row calls `ui.selectBundle(id)`, which opens the
   * right-side `BundleDetailPane` (rendered in +page.svelte). Nothing is selected
   * on entry — the pane stays closed until the user picks a row (matches Library;
   * no auto-select).
   */
  import Package from "@lucide/svelte/icons/package";

  import BundleRow from "./BundleRow.svelte";
  import Button from "./Button.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import { bundles } from "$lib/stores/bundles.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";

  // Load bundles + profile on first mount. Idempotent.
  $effect(() => {
    bundles.load();
  });
</script>

<section class="bundles" aria-label={t("bundles.list", ui.locale)}>
  <div class="list-wrap">
    {#if bundles.loading && bundles.list.length === 0}
      <LoadingState rows={6} label={t("bundles.loading", ui.locale)} />
    {:else if bundles.error}
      <EmptyState title={t("bundles.loadFailed", ui.locale)} body={bundles.error}>
        {#snippet icon()}<Package size={48} />{/snippet}
        {#snippet cta()}
          <Button variant="secondary" onclick={() => bundles.load(true)}>{t("Retry", ui.locale)}</Button>
        {/snippet}
      </EmptyState>
    {:else if bundles.list.length === 0}
      <EmptyState
        title={t("bundles.emptyTitle", ui.locale)}
        body={t("bundles.emptyBody", ui.locale)}
      >
        {#snippet icon()}<Package size={48} />{/snippet}
      </EmptyState>
    {:else}
      <div class="list-header" role="row">
        <span></span>
        <span class="header-label">{t("bundles.header.name", ui.locale)}</span>
        <span class="header-label">{t("bundles.header.tagline", ui.locale)}</span>
        <span class="header-label">{t("bundles.header.packages", ui.locale)}</span>
        <span class="header-label">{t("bundles.header.readiness", ui.locale)}</span>
      </div>
      <div class="list" role="list" aria-label={t("bundles.list", ui.locale)}>
        {#each bundles.list as b (b.id)}
          <BundleRow
            bundle={b}
            selected={ui.selectedBundle === b.id}
            onSelect={(bundle) => ui.selectBundle(bundle.id)}
          />
        {/each}
      </div>
    {/if}
  </div>
</section>

<style>
  .bundles {
    display: flex;
    flex-direction: column;
    min-height: 0;
    height: 100%;
  }

  .list-wrap {
    flex: 1;
    overflow-y: auto;
    min-height: 0;
  }
  .list-header {
    display: grid;
    /* 5 cells matching BundleRow:
       icon / NAME (1fr) / TAGLINE (2fr) / PACKAGES (130px) / READINESS (130px). */
    grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 130px 130px;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 1;
    overflow: hidden;
  }
  .list-header > * { min-width: 0; overflow: hidden; }
  .header-label {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  /* Match BundleRow's responsive column-drops so the header stays aligned
     with the rows when the panel narrows (e.g. detail pane open). */
  @media (max-width: 1100px) {
    .list-header {
      grid-template-columns: 24px minmax(0, 1fr) minmax(0, 2fr) 130px;
    }
    .list-header > :nth-child(4) { display: none; }
  }
  @media (max-width: 820px) {
    .list-header {
      grid-template-columns: 24px minmax(0, 1fr) 130px;
    }
    .list-header > :nth-child(3),
    .list-header > :nth-child(4) { display: none; }
  }

  .list { display: flex; flex-direction: column; }
</style>
