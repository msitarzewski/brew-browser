<script lang="ts">
  /**
   * UpdateIndicator.svelte — Phase 15
   *
   * Title-bar pill that surfaces a "newer brew-browser version is
   * available" notice in chrome (the Mac convention — Mail's unread
   * count, Notes's sync dot) rather than in a modal.
   *
   * Render gate (both must be true):
   *   - `updater.available !== null` — the backend confirmed a newer
   *     release exists and the user hasn't skipped it.
   *   - `settings.effective.paranoidMode === false` — Offline Mode
   *     suppresses every outbound network feature, so showing an
   *     "update available" pill while the user can't install would
   *     be inconsistent. The notice re-appears the moment Offline
   *     Mode flips off (the cached `available` value is still in the
   *     store).
   *
   * Click flow:
   *   - Pill → `ui.openSettings("network")`. The Updates subsection
   *     lives at the bottom of the Network pane; the user lands one
   *     scroll away from the Install button.
   *   - × → `updater.skip(version)` + `event.stopPropagation()`. The
   *     stopPropagation is critical — without it, the click would
   *     bubble up to the pill's onclick and open Settings on top of
   *     the dismissal.
   *
   * Inline install state: while `updater.installing === true`, the ×
   * is replaced with a small spinner so the user sees activity even
   * if they navigated away from Settings. The pill remains clickable
   * to open Settings (where the progress bar + result UI lives).
   *
   * ARIA: the pill is `role="button"` (behaviorally a button, but a
   * notification by intent — we lean on role-button so screen readers
   * announce the interaction). The × is a real `<button>` nested
   * inside so each gets a distinct accessible name.
   */

  import X from "@lucide/svelte/icons/x";
  import Loader from "@lucide/svelte/icons/loader-2";
  import ArrowUp from "@lucide/svelte/icons/arrow-up";

  import { updater } from "$lib/stores/updater.svelte";
  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { t } from "$lib/i18n/messages";

  /** Local snapshot to keep handlers tidy. Reactive — re-evaluates when
      the store's `available` changes. */
  let info = $derived(updater.available);

  /** Both gates resolved into a single boolean for the `{#if}`. */
  let visible = $derived(info !== null && settings.effective.paranoidMode === false);

  function onPillClick() {
    ui.openSettings("network");
  }

  function onPillKeydown(e: KeyboardEvent) {
    // role="button" needs explicit Space/Enter handling — the browser
    // doesn't synthesize click for non-<button> elements.
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      onPillClick();
    }
  }

  function onSkipClick(e: MouseEvent) {
    // CRITICAL: prevent the click from bubbling to the pill (which
    // would also fire onPillClick and open Settings). The × is purely
    // a dismiss; the pill is the "read more / install" path.
    e.stopPropagation();
    if (info) {
      void updater.skip(info.version);
    }
  }
</script>

{#if visible && info}
  <div
    class="pill"
    role="button"
    tabindex="0"
    onclick={onPillClick}
    onkeydown={onPillKeydown}
    aria-label={t("updates.availableLabel", ui.locale, { version: info.version })}
    title={t("updates.versionAvailable", ui.locale, { version: info.version })}
  >
    <span class="text" aria-hidden="true">
      <ArrowUp size={12} />
      <span>{t("updates.available", ui.locale)}</span>
    </span>
    {#if updater.installing}
      <span class="spinner" aria-label={t("updates.installing", ui.locale)} title={t("Installing…", ui.locale)}>
        <Loader size={12} />
      </span>
    {:else}
      <button
        type="button"
        class="dismiss"
        onclick={onSkipClick}
        aria-label={t("updates.dismissVersion", ui.locale, { version: info.version })}
        title={t("updates.skipVersion", ui.locale)}
      >
        <X size={12} />
      </button>
    {/if}
  </div>
{/if}

<style>
  /* Pill matches the TitlebarControls cluster's chrome: same
     --color-surface background, same --radius-md, same vertical
     metrics so the two read as siblings rather than competing
     elements. The pill is a row of [icon + text + dismiss], with
     a hair-line divider between text and dismiss matching the
     cluster's inter-button divider style. */
  .pill {
    display: inline-flex;
    align-items: center;
    height: 26px; /* matches cluster body height */
    padding: 0 2px 0 8px;
    background: var(--color-surface);
    border-radius: var(--radius-md);
    color: var(--color-warning-strong);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    user-select: none;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .pill:hover {
    background: var(--color-surface-raised);
  }
  .pill:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
  }
  .text {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding-right: 6px;
  }
  /* Dismiss button — small, neutral, hover bumps it to the warning
     tone so the user sees what they're about to click. Hair-line
     divider on its leading edge matches the cluster's pattern. */
  .dismiss {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 22px;
    margin-left: 2px;
    background: transparent;
    border: none;
    border-radius: var(--radius-sm);
    color: var(--color-text-muted);
    cursor: pointer;
    position: relative;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out),
                color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .dismiss::before {
    content: "";
    position: absolute;
    left: -1px;
    top: 4px;
    bottom: 4px;
    width: 1px;
    background: var(--color-border);
    opacity: 0.6;
  }
  .dismiss:hover {
    background: var(--color-surface-sunken);
    color: var(--color-text-primary);
  }
  .dismiss:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
  }
  /* Spinner sits in the same slot as the × so the pill width
     doesn't shift when installation starts. */
  .spinner {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 22px;
    margin-left: 2px;
    color: var(--color-warning-strong);
    position: relative;
    animation: spin 1s linear infinite;
  }
  .spinner::before {
    content: "";
    position: absolute;
    left: -1px;
    top: 4px;
    bottom: 4px;
    width: 1px;
    background: var(--color-border);
    opacity: 0.6;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }
  @media (prefers-reduced-motion: reduce) {
    .spinner { animation: none; }
  }
</style>
