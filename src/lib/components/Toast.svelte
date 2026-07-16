<script lang="ts">
  import CheckCircle2 from "@lucide/svelte/icons/check-circle-2";
  import Info from "@lucide/svelte/icons/info";
  import AlertTriangle from "@lucide/svelte/icons/alert-triangle";
  import XCircle from "@lucide/svelte/icons/x-circle";
  import X from "@lucide/svelte/icons/x";

  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";
  import { toast } from "$lib/stores/toast.svelte";
</script>

<div class="toast-stack" aria-live="polite" aria-relevant="additions">
  {#each toast.items as item (item.id)}
    <div class="toast tone-{item.kind}" role={item.kind === "error" || item.kind === "warning" ? "alert" : "status"}>
      <span class="icon" aria-hidden="true">
        {#if item.kind === "success"}
          <CheckCircle2 size={16} />
        {:else if item.kind === "info"}
          <Info size={16} />
        {:else if item.kind === "warning"}
          <AlertTriangle size={16} />
        {:else}
          <XCircle size={16} />
        {/if}
      </span>
      <div class="body">
        <div class="title">{item.title}</div>
        {#if item.body}<div class="sub">{item.body}</div>{/if}
        {#if item.action}
          <button
            type="button"
            class="action"
            onclick={() => toast.invokeAction(item.id)}
          >
            {item.action.label}
          </button>
        {/if}
      </div>
      <button class="close" aria-label={t("Dismiss", ui.locale)} onclick={() => toast.dismiss(item.id)}>
        <X size={14} />
      </button>
    </div>
  {/each}
</div>

<style>
  .toast-stack {
    position: fixed;
    right: var(--space-4);
    bottom: var(--space-4);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    z-index: 100;
    pointer-events: none;
  }
  .toast {
    pointer-events: auto;
    width: 320px;
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: start;
    gap: var(--space-3);
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-left-width: 3px;
    border-radius: var(--radius-md);
    padding: var(--space-3) var(--space-4);
    box-shadow: var(--shadow-md);
    animation: slideIn var(--motion-duration-base) var(--motion-ease-spring);
  }
  .tone-success { border-left-color: var(--color-success); }
  .tone-info    { border-left-color: var(--color-info); }
  .tone-warning { border-left-color: var(--color-warning); }
  .tone-error   { border-left-color: var(--color-danger); }

  .tone-success .icon { color: var(--color-success); }
  .tone-info    .icon { color: var(--color-info); }
  .tone-warning .icon { color: var(--color-warning); }
  .tone-error   .icon { color: var(--color-danger); }

  .title { font-weight: var(--fw-medium); font-size: var(--text-body); color: var(--color-text-primary); }
  .sub { font-size: var(--text-body-sm); color: var(--color-text-secondary); margin-top: 2px; }

  .close {
    color: var(--color-text-muted);
    padding: 2px;
    border-radius: var(--radius-sm);
  }
  .close:hover { color: var(--color-text-primary); background: var(--color-surface-sunken); }

  /* Inline action button on a toast (e.g., "Re-authorize" on a
     ScopeRequired error). Sits below the body text, tone-colored to
     match the toast's left border so the affordance reads as paired
     with the alert. */
  .action {
    margin-top: var(--space-2);
    align-self: start;
    padding: 4px 10px;
    background: transparent;
    border: 1px solid currentColor;
    border-radius: var(--radius-sm);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .tone-success .action { color: var(--color-success); }
  .tone-info    .action { color: var(--color-info); }
  .tone-warning .action { color: var(--color-warning); }
  .tone-error   .action { color: var(--color-danger); }
  .action:hover { background: color-mix(in oklch, currentColor 12%, transparent); }

  @keyframes slideIn {
    from { transform: translateY(8px); opacity: 0; }
    to   { transform: translateY(0); opacity: 1; }
  }

  @media (prefers-reduced-motion: reduce) {
    .toast { animation: none; }
  }
</style>
