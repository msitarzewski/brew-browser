<script lang="ts">
  import type { Snippet } from "svelte";
  import { onMount } from "svelte";
  import X from "@lucide/svelte/icons/x";
  import { t } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";

  interface Props {
    open: boolean;
    title: string;
    dismissible?: boolean;
    /**
     * Where focus lands when the modal opens.
     *  - "cancel" (default): a footer element tagged `data-modal-action="cancel"`,
     *    falling back to the first focusable inside the footer, then body, then header.
     *    Use this for destructive confirms so Enter without thinking is the safe path.
     *  - "confirm": footer element tagged `data-modal-action="confirm"`.
     *  - "first": first focusable inside the body, then footer, then header. Use this
     *    for input-collection modals (e.g. "New Snapshot") so the field is focused first.
     */
    defaultFocus?: "cancel" | "confirm" | "first";
    onClose?: () => void;
    children: Snippet;
    actions?: Snippet;
  }

  let {
    open,
    title,
    dismissible = true,
    defaultFocus = "cancel",
    onClose,
    children,
    actions,
  }: Props = $props();

  let dialogEl: HTMLDivElement | undefined = $state();

  const FOCUSABLE =
    "button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])";

  function pickInitialFocus(root: HTMLElement): HTMLElement | null {
    const footer = root.querySelector<HTMLElement>("footer");
    const body = root.querySelector<HTMLElement>(".body");
    const header = root.querySelector<HTMLElement>("header");

    // 1. Explicit tag wins if present anywhere in the dialog.
    if (defaultFocus === "cancel") {
      const tagged = root.querySelector<HTMLElement>('[data-modal-action="cancel"]');
      if (tagged) return tagged;
    } else if (defaultFocus === "confirm") {
      const tagged = root.querySelector<HTMLElement>('[data-modal-action="confirm"]');
      if (tagged) return tagged;
    }

    // 2. Region order depends on intent:
    //    - "first" (input-first modals): body → footer → header
    //    - otherwise (safe-default modals): footer → body → header
    //    Header (close-X) is always the last resort so Enter-without-thinking
    //    never lands on the dismiss button by accident.
    const inFooter = footer?.querySelector<HTMLElement>(FOCUSABLE) ?? null;
    const inBody = body?.querySelector<HTMLElement>(FOCUSABLE) ?? null;
    const inHeader = header?.querySelector<HTMLElement>(FOCUSABLE) ?? null;

    if (defaultFocus === "first") {
      return inBody ?? inFooter ?? inHeader;
    }
    return inFooter ?? inBody ?? inHeader;
  }

  $effect(() => {
    if (open && dialogEl) {
      const target = pickInitialFocus(dialogEl);
      target?.focus();
    }
  });

  function backdropClick() {
    if (dismissible) onClose?.();
  }

  function keydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === "Escape" && dismissible) {
      e.stopPropagation();
      onClose?.();
    }
    // primitive focus trap
    if (e.key === "Tab" && dialogEl) {
      const focusables = dialogEl.querySelectorAll<HTMLElement>(
        "button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])"
      );
      if (focusables.length === 0) return;
      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      const active = document.activeElement as HTMLElement | null;
      if (e.shiftKey && active === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus(); }
    }
  }

  onMount(() => {
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  });
</script>

{#if open}
  <div class="scrim" role="presentation" onclick={backdropClick}></div>
  <div class="modal-wrap" role="dialog" aria-modal="true" aria-labelledby="modal-title">
    <div class="modal" bind:this={dialogEl}>
      <header>
        <h1 id="modal-title">{title}</h1>
        {#if dismissible}
          <button class="close" aria-label={t("Close", ui.locale)} onclick={() => onClose?.()}>
            <X size={16} />
          </button>
        {/if}
      </header>
      <div class="body">
        {@render children()}
      </div>
      {#if actions}
        <footer>{@render actions()}</footer>
      {/if}
    </div>
  </div>
{/if}

<style>
  .scrim {
    position: fixed; inset: 0;
    background: rgb(0 0 0 / 0.4);
    z-index: 50;
    animation: fadeIn var(--motion-duration-base) var(--motion-ease-out);
  }
  .modal-wrap {
    position: fixed; inset: 0;
    z-index: 51;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    pointer-events: none;
  }
  .modal {
    pointer-events: auto;
    width: 100%;
    max-width: 440px;
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-modal);
    padding: var(--space-6);
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    animation: pop var(--motion-duration-base) var(--motion-ease-out);
  }
  header {
    display: flex; align-items: center; justify-content: space-between;
    gap: var(--space-3);
  }
  header h1 {
    font-size: var(--text-h1);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
  }
  .close {
    color: var(--color-text-muted);
    padding: 4px;
    border-radius: var(--radius-sm);
  }
  .close:hover { color: var(--color-text-primary); background: var(--color-surface-sunken); }

  .body { color: var(--color-text-secondary); font-size: var(--text-body); }

  footer {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-3);
    margin-top: var(--space-2);
  }

  @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
  @keyframes pop {
    from { opacity: 0; transform: scale(0.96); }
    to   { opacity: 1; transform: scale(1); }
  }
  @media (prefers-reduced-motion: reduce) {
    .scrim, .modal { animation: none; }
  }
</style>
