<script lang="ts">
  /**
   * DeviceFlowModal.svelte — Phase 12e
   *
   * Renders the user-facing half of the GitHub OAuth Device Flow:
   *
   *   ┌─────────────────────────────────────┐
   *   │  Sign in to GitHub                  │
   *   │                                     │
   *   │  1. Open github.com/login/device    │
   *   │  2. Enter this code:                │
   *   │                                     │
   *   │           [ WDJB-MJHT ]             │
   *   │                                     │
   *   │  ⟳ Waiting for authorization…       │
   *   │  [Cancel]                           │
   *   └─────────────────────────────────────┘
   *
   * The polling loop itself lives in `github.svelte.ts` — this
   * component is pure presentation. It mounts when `signinState.kind`
   * is anything other than "idle" and unmounts when it returns to idle.
   *
   * Cancellation: the [Cancel] button calls `github.cancelSignin()`,
   * which aborts the poll loop and flips state back to idle.
   */

  import { onDestroy } from "svelte";
  import X from "@lucide/svelte/icons/x";
  import ExternalLink from "@lucide/svelte/icons/external-link";
  import Loader from "@lucide/svelte/icons/loader-2";
  import CircleCheck from "@lucide/svelte/icons/circle-check";
  import CircleX from "@lucide/svelte/icons/circle-x";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";

  import { github } from "$lib/stores/github.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";
  import { safeOpenUrl } from "$lib/util/url";
  import { toast } from "$lib/stores/toast.svelte";
  // NOTE: `toast` is still used inside copyCode()'s clipboard handlers
  // (Code copied to clipboard / Couldn't copy code). Those are
  // event-handler-driven imperative toasts — the correct Svelte 5
  // pattern. The signin-result toast is fired from github.svelte.ts's
  // signIn() poll loop at the moment of transition, NOT via $effect.

  /** True when the modal should be visible. Idle state hides it. */
  let isOpen = $derived(github.signinState.kind !== "idle");

  /** Remaining seconds before the device_code expires (waiting state only). */
  let remainingSeconds = $state<number | null>(null);

  /** Tick once a second to refresh the "expires in" countdown.
      Cleared on unmount. */
  let tickHandle: ReturnType<typeof setInterval> | null = null;
  $effect(() => {
    const s = github.signinState;
    if (s.kind === "waiting") {
      tickHandle = setInterval(() => {
        if (github.signinState.kind === "waiting") {
          const ms = github.signinState.expiresAt - Date.now();
          remainingSeconds = Math.max(0, Math.floor(ms / 1000));
        } else {
          remainingSeconds = null;
        }
      }, 1000);
      // Prime immediately.
      const ms = s.expiresAt - Date.now();
      remainingSeconds = Math.max(0, Math.floor(ms / 1000));
    } else {
      if (tickHandle) clearInterval(tickHandle);
      tickHandle = null;
      remainingSeconds = null;
    }
    return () => {
      if (tickHandle) clearInterval(tickHandle);
      tickHandle = null;
    };
  });

  // The signin-result toast + auto-dismiss timer USED to live here as
  // a $effect watching signinState. Per Svelte 5 official guidance
  // ($effect is an "escape hatch" — don't use it for one-shot side
  // effects of state transitions), the toast + setTimeout are now
  // fired imperatively in github.svelte.ts's signIn() poll loop at
  // the moment of the transition. See issue #1 root cause for the
  // effect_update_depth_exceeded chain this $effect pattern produced.

  function onCancel() {
    github.cancelSignin();
  }

  function copyCode() {
    if (github.signinState.kind !== "waiting") return;
    const code = github.signinState.userCode;
    void navigator.clipboard.writeText(code).then(
      () => toast.success(t("Code copied to clipboard", ui.locale)),
      () => toast.error(t("Couldn't copy code", ui.locale)),
    );
  }

  async function openVerification() {
    if (github.signinState.kind !== "waiting") return;
    await safeOpenUrl(github.signinState.verificationUri);
  }

  // Esc to cancel.
  function onKey(e: KeyboardEvent) {
    if (!isOpen) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      onCancel();
    }
  }
  $effect(() => {
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  onDestroy(() => {
    if (tickHandle) clearInterval(tickHandle);
  });

  function formatExpires(seconds: number): string {
    const minutes = Math.floor(seconds / 60);
    const rest = seconds % 60;
    return ui.locale === "ru"
      ? `Код действует ещё ${minutes} мин ${rest} с.`
      : `Code expires in ${minutes}m ${rest}s.`;
  }
</script>

{#if isOpen}
  <div class="scrim" role="presentation" onclick={onCancel}></div>
  <div class="wrap" role="dialog" aria-modal="true" aria-label={t("Sign in to GitHub", ui.locale)}>
    <div class="modal">
      <header>
        <h2>{t("Sign in to GitHub", ui.locale)}</h2>
        <button class="close" aria-label={t("Cancel sign in", ui.locale)} onclick={onCancel}>
          <X size={16} />
        </button>
      </header>

      <div class="body">
        {#if github.signinState.kind === "starting"}
          <div class="status">
            <Loader size={18} class="spin" />
            <span>{t("Contacting GitHub…", ui.locale)}</span>
          </div>
        {:else if github.signinState.kind === "waiting"}
          <ol class="steps">
            <li>
              {#if ui.locale === "ru"}Откройте{:else}Open{/if}
              <button class="link" type="button" onclick={openVerification}>
                {github.signinState.verificationUri}
                <ExternalLink size={12} />
              </button>
              {#if ui.locale === "ru"}в браузере.{:else}in your browser.{/if}
            </li>
            <li>{t("Enter this code:", ui.locale)}</li>
          </ol>
          <button class="code" type="button" onclick={copyCode} title={t("Click to copy", ui.locale)}>
            {github.signinState.userCode}
          </button>
          <p class="hint">{t("Click the code to copy it.", ui.locale)}</p>

          <div class="status">
            <Loader size={16} class="spin" />
            <span>{t("Waiting for authorization…", ui.locale)}</span>
          </div>

          {#if remainingSeconds !== null}
            <p class="expires">{formatExpires(remainingSeconds)}</p>
          {/if}
        {:else if github.signinState.kind === "approved"}
          <div class="status status-ok">
            <CircleCheck size={20} />
            {#if github.status?.username}
              <span>{ui.locale === "ru" ? `Выполнен вход как @${github.status.username}.` : `Signed in as @${github.status.username}.`}</span>
            {:else}
              <span>{t("Signed in as GitHub user.", ui.locale)}</span>
            {/if}
          </div>
        {:else if github.signinState.kind === "denied"}
          <div class="status status-bad">
            <CircleX size={20} />
            <span>{t("Sign-in denied.", ui.locale)}</span>
          </div>
        {:else if github.signinState.kind === "expired"}
          <div class="status status-bad">
            <TriangleAlert size={20} />
            <span>{t("Code expired. Please try again.", ui.locale)}</span>
          </div>
        {:else if github.signinState.kind === "error"}
          <div class="status status-bad">
            <TriangleAlert size={20} />
            <span>{github.signinState.message}</span>
          </div>
        {/if}
      </div>

      <footer>
        <button type="button" class="btn-secondary" onclick={onCancel}>
          {github.signinState.kind === "waiting" || github.signinState.kind === "starting"
            ? t("Cancel", ui.locale)
            : t("Close", ui.locale)}
        </button>
      </footer>
    </div>
  </div>
{/if}

<style>
  .scrim {
    position: fixed;
    inset: 0;
    background: rgb(0 0 0 / 0.4);
    z-index: 95;
    animation: fadeIn var(--motion-duration-base) var(--motion-ease-out);
  }
  .wrap {
    position: fixed;
    inset: 0;
    z-index: 96;
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
    display: flex;
    flex-direction: column;
    overflow: hidden;
    animation: pop var(--motion-duration-base) var(--motion-ease-out);
  }
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
  }
  header h2 {
    font-size: var(--text-h2);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
  }
  .close {
    color: var(--color-text-muted);
    padding: 4px;
    border-radius: var(--radius-sm);
  }
  .close:hover {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }

  .body {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
  }
  .steps {
    margin: 0;
    padding-left: var(--space-5);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    color: var(--color-text-primary);
    font-size: var(--text-body);
    line-height: var(--lh-snug);
  }
  .link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--color-text-link);
    font-size: inherit;
  }
  .link:hover { text-decoration: underline; }

  .code {
    align-self: center;
    font-family: var(--font-mono);
    font-size: 24px;
    letter-spacing: 0.1em;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text-primary);
    cursor: pointer;
    user-select: all;
  }
  .code:hover {
    background: var(--color-surface);
    border-color: var(--color-accent, #b8542a);
  }

  .hint {
    text-align: center;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
  }

  .status {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-text-secondary);
    font-size: var(--text-body);
  }
  .status-ok { color: #58a55c; }
  .status-bad { color: #d24a4a; }

  :global(.spin) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }

  .expires {
    text-align: center;
    color: var(--color-text-muted);
    font-size: var(--text-body-sm);
  }

  footer {
    padding: var(--space-3) var(--space-4);
    border-top: 1px solid var(--color-border);
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
  }
  .btn-secondary {
    padding: 6px 12px;
    border-radius: var(--radius-md);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
  }
  .btn-secondary:hover {
    background: var(--color-surface-sunken);
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
