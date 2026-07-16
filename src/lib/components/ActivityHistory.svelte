<script lang="ts">
  import ActivityIcon from "@lucide/svelte/icons/activity";
  import CheckCircle2 from "@lucide/svelte/icons/check-circle-2";
  import XCircle from "@lucide/svelte/icons/x-circle";
  import Loader from "@lucide/svelte/icons/loader-circle";
  import Trash2 from "@lucide/svelte/icons/trash-2";

  import Button from "./Button.svelte";
  import EmptyState from "./EmptyState.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";

  function open(jobId: string) {
    activity.setActive(jobId);
    ui.openDrawer();
  }

  /** Remove a single job from history. A still-running job is canceled first
   *  so we don't drop tracking of a live brew process. */
  function remove(job: { jobId: string; status: string }) {
    if (job.status === "running") activity.cancel(job.jobId);
    activity.removeJob(job.jobId);
  }

  function fmtDuration(ms?: number): string {
    if (!ms) return "";
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    return ui.locale === "ru" && m === 0 ? `${s} с` : `${m}:${s.toString().padStart(2, "0")}`;
  }
</script>

<section class="hist">
  <!-- Pane title ("Activity") moved to the window title bar. The
       header is only rendered when there's a Clear-completed action
       to surface; otherwise we skip the band entirely. -->
  {#if activity.jobs.length > 0}
    <header class="panel-head" data-tauri-drag-region>
      <span class="action-wrap" data-tauri-drag-region="false">
        <Button size="sm" variant="ghost" onclick={() => activity.clearCompleted()}>
          {#snippet icon()}<Trash2 size={14} />{/snippet}
          {t("Clear completed", ui.locale)}
        </Button>
      </span>
    </header>
  {/if}

  <div class="list-wrap">
    {#if activity.jobs.length === 0}
      <EmptyState
        title={t("Nothing's run yet.", ui.locale)}
        body={t("brew commands kicked off from here will show up in this list.", ui.locale)}
      >
        {#snippet icon()}<ActivityIcon size={48} />{/snippet}
      </EmptyState>
    {:else}
      <ul class="list">
        {#each activity.jobs as j (j.jobId)}
          <li class="row-wrap">
            <button class="row" onclick={() => open(j.jobId)}>
              <span class="status">
                {#if j.status === "running"}<Loader size={14} class="spin" />
                {:else if j.status === "succeeded"}<CheckCircle2 size={14} class="ok" />
                {:else if j.status === "failed"}<XCircle size={14} class="fail" />
                {:else}<XCircle size={14} class="dim" />{/if}
              </span>
              <span class="label truncate">{j.label}</span>
              <span class="cmd mono truncate">{j.command}</span>
              <span class="dur">{fmtDuration(j.durationMs)}</span>
            </button>
            <button
              class="del"
              title={ui.locale === "ru" ? "Убрать из истории" : "Remove from history"}
              aria-label={ui.locale === "ru" ? `Убрать ${j.label} из истории` : `Remove ${j.label} from history`}
              onclick={() => remove(j)}
            >
              <Trash2 size={14} />
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</section>

<style>
  .hist { display: flex; flex-direction: column; min-height: 0; height: 100%; }
  .panel-head {
    display: flex; justify-content: flex-end; align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
  }

  /* Narrow-window responsive: same pattern as Trending + Library + Services.
     Drop the "Clear completed" action at narrow widths. The action stays
     available by clearing individual jobs from the rows themselves. */
  @media (max-width: 1000px) {
    .action-wrap { display: none; }
  }
  .list-wrap { flex: 1; overflow-y: auto; min-height: 0; }
  .list { display: flex; flex-direction: column; }
  .row-wrap {
    display: flex;
    align-items: center;
    border-bottom: 1px solid var(--color-border);
  }
  .row-wrap:hover { background: var(--color-surface-sunken); }
  .row {
    display: grid;
    grid-template-columns: 28px 1fr 2fr 60px;
    align-items: center;
    flex: 1;
    min-width: 0;
    padding: var(--space-2) var(--space-3);
    min-height: 36px;
    text-align: left;
    color: var(--color-text-primary);
    font-size: var(--text-body);
    gap: var(--space-3);
  }
  /* Per-row remove — revealed on hover/focus, like the drawer's prior tab ×.
     List management lives here, not on the (now view-only) drawer tabs. */
  .del {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    align-self: stretch;
    color: var(--color-text-muted);
    opacity: 0;
    transition: opacity 120ms ease, color 120ms ease;
  }
  .row-wrap:hover .del,
  .del:focus-visible { opacity: 1; }
  .del:hover { color: var(--color-danger); }
  .status { display: inline-flex; }
  .status :global(.ok) { color: var(--color-success); }
  .status :global(.fail) { color: var(--color-danger); }
  .status :global(.dim) { color: var(--color-text-muted); }
  .status :global(.spin) { color: var(--color-warning); animation: spin 800ms linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  .label { font-weight: var(--fw-medium); }
  .cmd { font-size: var(--text-mono); color: var(--color-text-secondary); }
  .dur { text-align: right; color: var(--color-text-muted); font-size: var(--text-body-sm); font-variant-numeric: tabular-nums; }
</style>
