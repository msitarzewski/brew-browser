<script lang="ts">
  /**
   * IssueModal.svelte — Phase 12f
   *
   * Modal form for filing a GitHub issue against an arbitrary repo
   * (the package's own repo, or `msitarzewski/brew-browser` for the
   * "Wrong?" categorization affordance). The modal owns its own form
   * state; the parent passes initial title/body/labels and gets
   * notified via `onClose()` when the user submits, cancels, or hits
   * Esc.
   *
   * Form rules (mirroring the backend caps):
   *   - title: ≤ 256 chars (counter goes red beyond).
   *   - body:  ≤ 64 KiB UTF-8 (counter in characters; bytes capped
   *            on the backend so an emoji-heavy body still works).
   *   - labels: read-only chips supplied by the caller. The backend
   *            also re-validates the slugs.
   *
   * On submit:
   *   1. Calls `github.createIssue(...)`. The store opens the result
   *      URL via `safeOpenUrl` after success.
   *   2. Toasts success + closes the modal.
   *   3. On error, surfaces the message inline and keeps the modal
   *      open so the user can edit + retry.
   */

  import { onMount } from "svelte";
  import X from "@lucide/svelte/icons/x";
  import Send from "@lucide/svelte/icons/send";
  import AlertCircle from "@lucide/svelte/icons/alert-circle";
  import Loader from "@lucide/svelte/icons/loader-2";

  import { github } from "$lib/stores/github.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";
  import { brewErrorMessage, isBrewError } from "$lib/types";

  interface Props {
    open: boolean;
    /** Initial title; user can edit. */
    title: string;
    /** Initial body (markdown); user can edit. */
    body: string;
    /** Fixed labels — displayed as chips, not editable in the form.
        The backend re-validates the slugs against the §12f allowlist. */
    labels: string[];
    /** Repo to target. Currently only used for the "Filing against
        owner/repo" header label. The actual URL goes via `homepage`. */
    repo: { owner: string; repo: string };
    /** Homepage of the repo (e.g. `https://github.com/owner/repo`).
        Passed to the store's createIssue command. */
    homepage: string;
    onClose: () => void;
  }

  let {
    open,
    title: initialTitle,
    body: initialBody,
    labels,
    repo,
    homepage,
    onClose,
  }: Props = $props();

  /** Local form state; seeded from props each time the modal opens
      so re-opening with different prefilled content resets cleanly. */
  let formTitle = $state("");
  let formBody = $state("");
  let submitting = $state(false);
  let inlineError = $state<string | null>(null);

  // Caps mirror the backend (`actions::ISSUE_TITLE_MAX_CHARS` /
  // `ISSUE_BODY_MAX_BYTES`). Kept in sync by hand because the backend
  // doesn't expose them via IPC — if either changes, update both ends
  // and add a test.
  const TITLE_CAP = 256;
  const BODY_CAP = 64 * 1024;

  // Seed form state every time the modal transitions from closed → open.
  let lastOpen = false;
  $effect(() => {
    if (open && !lastOpen) {
      formTitle = initialTitle;
      formBody = initialBody;
      inlineError = null;
      submitting = false;
    }
    lastOpen = open;
  });

  let titleEl: HTMLInputElement | undefined = $state();
  let bodyEl: HTMLTextAreaElement | undefined = $state();

  // Focus the title field when the modal opens.
  $effect(() => {
    if (open) {
      queueMicrotask(() => titleEl?.focus());
    }
  });

  // Esc to close.
  function onKey(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      handleClose();
    }
  }
  onMount(() => {
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  /** Reactive char/byte counts for the counters. */
  let titleCount = $derived(formTitle.length);
  let bodyCount = $derived(formBody.length);
  // Approximate byte count via TextEncoder for the body cap (matches
  // the backend's `.len()` on the cleaned String).
  let bodyByteCount = $derived(new TextEncoder().encode(formBody).length);

  let titleInvalid = $derived(titleCount === 0 || titleCount > TITLE_CAP);
  let bodyInvalid = $derived(bodyByteCount > BODY_CAP);
  let canSubmit = $derived(
    !submitting && !titleInvalid && !bodyInvalid && formTitle.trim().length > 0,
  );

  function handleClose() {
    if (submitting) return; // Don't close mid-submit.
    onClose();
  }

  async function handleSubmit(e: Event) {
    e.preventDefault();
    if (!canSubmit) return;
    submitting = true;
    inlineError = null;
    try {
      await github.createIssue(homepage, formTitle.trim(), formBody, labels);
      // Success — toast + close. The store has already opened the
      // result URL via safeOpenUrl.
      toast.success(ui.locale === "ru" ? "Проблема отправлена" : "Issue filed");
      onClose();
    } catch (e) {
      // Keep the modal open so the user can retry. Surface the typed
      // error message; fall back to String(e) for unexpected shapes.
      inlineError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
    } finally {
      submitting = false;
    }
  }

  /** Pretty-print a byte count for the body counter ("12.3 KB"). */
  function fmtBytes(n: number): string {
    if (n < 1024) return `${n} B`;
    return `${(n / 1024).toFixed(1)} KB`;
  }
</script>

{#if open}
  <div class="scrim" role="presentation" onclick={handleClose}></div>
  <div class="wrap" role="dialog" aria-modal="true" aria-labelledby="issue-modal-title">
    <form class="modal" onsubmit={handleSubmit}>
      <header>
        <div class="hd-left">
          <h2 id="issue-modal-title">{t("File an issue", ui.locale)}</h2>
          <p class="repo">{ui.locale === "ru" ? "в" : "on"} <code>{repo.owner}/{repo.repo}</code></p>
        </div>
        <button
          type="button"
          class="close"
          aria-label={t("Close", ui.locale)}
          onclick={handleClose}
          disabled={submitting}
        >
          <X size={16} />
        </button>
      </header>

      <div class="body">
        <label class="field">
          <span class="field-head">
            <span class="field-label">{t("Title", ui.locale)}</span>
            <span class="counter" class:over={titleCount > TITLE_CAP}>
              {titleCount} / {TITLE_CAP}
            </span>
          </span>
          <input
            bind:this={titleEl}
            type="text"
            class="title-input"
            class:invalid={titleInvalid && formTitle.length > 0}
            bind:value={formTitle}
            maxlength={TITLE_CAP + 64}
            disabled={submitting}
            required
          />
        </label>

        <label class="field">
          <span class="field-head">
            <span class="field-label">{t("Body (Markdown)", ui.locale)}</span>
            <span class="counter" class:over={bodyInvalid}>
              {fmtBytes(bodyByteCount)} / {fmtBytes(BODY_CAP)}
            </span>
          </span>
          <textarea
            bind:this={bodyEl}
            class="body-input"
            class:invalid={bodyInvalid}
            bind:value={formBody}
            rows="8"
            disabled={submitting}
          ></textarea>
        </label>

        {#if labels.length > 0}
          <div class="labels-row">
            <span class="field-label">{t("Labels", ui.locale)}</span>
            <div class="chips">
              {#each labels as label (label)}
                <span class="chip">{label}</span>
              {/each}
            </div>
          </div>
        {/if}

        {#if inlineError}
          <div class="error" role="alert">
            <AlertCircle size={14} />
            <span>{inlineError}</span>
          </div>
        {/if}
      </div>

      <footer>
        <button
          type="button"
          class="btn-secondary"
          onclick={handleClose}
          disabled={submitting}
        >
          {t("Cancel", ui.locale)}
        </button>
        <button type="submit" class="btn-primary" disabled={!canSubmit}>
          {#if submitting}
            <Loader size={14} class="spin" />
            {ui.locale === "ru" ? "Отправляем…" : "Filing…"}
          {:else}
            <Send size={14} />
            {t("File issue", ui.locale)}
          {/if}
        </button>
      </footer>
    </form>
  </div>
{/if}

<style>
  .scrim {
    position: fixed;
    inset: 0;
    background: rgb(0 0 0 / 0.4);
    z-index: 90;
    animation: fadeIn var(--motion-duration-base) var(--motion-ease-out);
  }
  .wrap {
    position: fixed;
    inset: 0;
    z-index: 91;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    pointer-events: none;
  }
  .modal {
    pointer-events: auto;
    width: 100%;
    max-width: 560px;
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-modal);
    display: flex;
    flex-direction: column;
    max-height: calc(100vh - 2 * var(--space-4));
    overflow: hidden;
    animation: pop var(--motion-duration-base) var(--motion-ease-out);
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    gap: var(--space-3);
  }
  .hd-left { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  header h2 {
    font-size: var(--text-h2);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin: 0;
  }
  .repo {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    margin: 0;
  }
  .repo code {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
  }
  .close {
    color: var(--color-text-muted);
    padding: 4px;
    border-radius: var(--radius-sm);
    flex: none;
  }
  .close:hover:not(:disabled) {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }
  .close:disabled { opacity: 0.4; cursor: default; }

  .body {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
    overflow-y: auto;
    flex: 1;
    min-height: 0;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .field-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-2);
  }
  .field-label {
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    color: var(--color-text-secondary);
  }
  .counter {
    font-size: var(--text-caption);
    color: var(--color-text-muted);
    font-variant-numeric: tabular-nums;
  }
  .counter.over { color: var(--color-danger, #ef4444); }

  .title-input,
  .body-input {
    width: 100%;
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    font-family: inherit;
  }
  .title-input:focus,
  .body-input:focus {
    border-color: var(--color-border-focus);
    box-shadow: var(--shadow-focus-ring);
    outline: none;
  }
  .body-input {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    line-height: var(--lh-snug);
    resize: vertical;
    min-height: 120px;
  }
  .invalid {
    border-color: var(--color-danger, #ef4444) !important;
  }

  .labels-row {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    padding: 2px var(--space-2);
    height: 20px;
    border-radius: var(--radius-full);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    font-weight: var(--fw-medium);
  }

  .error {
    display: inline-flex;
    align-items: flex-start;
    gap: 6px;
    padding: var(--space-2) var(--space-3);
    background: var(--color-danger-subtle, rgba(239, 68, 68, 0.08));
    border: 1px solid var(--color-danger, #ef4444);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
  }
  .error :global(svg) { flex: none; margin-top: 2px; }

  footer {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-4);
    border-top: 1px solid var(--color-border);
  }
  .btn-secondary,
  .btn-primary {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: var(--radius-md);
    border: 1px solid var(--color-border);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
  }
  .btn-secondary {
    background: var(--color-surface);
    color: var(--color-text-primary);
  }
  .btn-secondary:hover:not(:disabled) {
    background: var(--color-surface-sunken);
  }
  .btn-primary {
    background: var(--color-brand);
    color: white;
    border-color: var(--color-brand);
  }
  .btn-primary:hover:not(:disabled) {
    background: var(--color-brand-strong, var(--color-brand));
    border-color: var(--color-brand-strong, var(--color-brand));
  }
  .btn-primary:disabled,
  .btn-secondary:disabled { opacity: 0.5; cursor: default; }

  :global(.spin) { animation: spin 1s linear infinite; }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }
  @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
  @keyframes pop {
    from { opacity: 0; transform: scale(0.96); }
    to   { opacity: 1; transform: scale(1); }
  }
  @media (prefers-reduced-motion: reduce) {
    .scrim, .modal { animation: none; }
    :global(.spin) { animation: none; }
  }
</style>
