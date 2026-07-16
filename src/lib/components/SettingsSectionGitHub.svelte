<script lang="ts">
  /**
   * SettingsSectionGitHub.svelte — Phase 12c + 12e
   *
   * Two independent controls:
   *
   * 1. **Show GitHub stats on package pages** — toggle bound to
   *    `settings.githubEnabled`. Off = no probes ever. On = probes
   *    fire under the anonymous 60/hr per-IP limit (or 5,000/hr when
   *    signed in).
   *
   * 2. **Sign in with GitHub** — Device Flow handshake. Stored
   *    token sits in macOS Keychain only; never on the frontend, never
   *    on disk, never logged. Sign-in is optional and only used for
   *    lifting the rate limit + (Phase 12f) star/issue/watch actions.
   *
   * The settings toggle and the sign-in state are decoupled — the user
   * can sign in without enabling stats (useful for Phase 12f), or
   * enable stats without signing in (useful when 60/hr is plenty).
   */

  import { onMount } from "svelte";
  import GitFork from "@lucide/svelte/icons/git-fork";
  import LogIn from "@lucide/svelte/icons/log-in";
  import LogOut from "@lucide/svelte/icons/log-out";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";

  import { settings } from "$lib/stores/settings.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { github } from "$lib/stores/github.svelte";
  import { keyringName } from "$lib/util/platform";
  import { t } from "$lib/i18n/messages";

  onMount(() => {
    void github.loadStatus();
  });

  function toggleGithubEnabled(e: Event) {
    const v = (e.currentTarget as HTMLInputElement).checked;
    void settings.save({ githubEnabled: v });
  }

  function onSignIn() {
    void github.signIn();
  }

  function onSignOut() {
    void github.signOut();
  }

  // Disable the toggle while settings are loading or corrupt. The
  // Network section handles the corrupt-on-disk recovery UI; we just
  // gray out the control here so the user is funnelled there.
  let toggleDisabled = $derived(settings.loading || settings.corruptOnDisk);
</script>

<div class="section">
  <h2>GitHub</h2>

  <!-- Stats opt-in toggle -->
  <div class="field">
    <label class="toggle">
      <input
        type="checkbox"
        checked={settings.effective.githubEnabled}
        onchange={toggleGithubEnabled}
        disabled={toggleDisabled}
      />
      <span class="toggle-track" aria-hidden="true"></span>
      <span class="toggle-label">{t("Show GitHub stats on package pages", ui.locale)}</span>
	    </label>
	    <p class="hint">
	      {t("settings.github.statsHint.beforeHost", ui.locale)}<code>api.github.com</code>{t("settings.github.statsHint.afterHost", ui.locale)}
	    </p>
	  </div>

  <!-- Sign-in block -->
  <div class="field signin">
    {#if github.status === null}
      <p class="hint">{t("Loading sign-in status…", ui.locale)}</p>
    {:else if github.status.signedIn}
      <div class="signed-in">
        <div class="user">
	          <ShieldCheck size={18} />
	          <div>
	            <div class="username">{t("settings.github.signedInAs", ui.locale)} @{github.status.username ?? t("settings.github.githubUserFallback", ui.locale)}</div>
	            {#if github.status.scopes.length > 0}
	              <div class="scopes">{t("settings.github.scopesLabel", ui.locale)}: {github.status.scopes.join(", ")}</div>
	            {/if}
	          </div>
        </div>
        <button type="button" class="btn-secondary" onclick={onSignOut} disabled={github.statusLoading}>
          <LogOut size={14} /> {t("Sign out", ui.locale)}
        </button>
      </div>
    {:else}
      <button
        type="button"
        class="btn-primary"
        onclick={onSignIn}
        disabled={github.statusLoading || github.signinState.kind !== "idle"}
      >
        <LogIn size={14} /> {t("Sign in with GitHub", ui.locale)}
	      </button>
	      <p class="hint">
	        {t("settings.github.signInHint", ui.locale)}
	      </p>
	    {/if}
	  </div>

  <!-- Privacy note -->
	  <aside class="privacy">
	    <div class="privacy-head">
	      <GitFork size={16} />
	      <strong>{t("settings.github.signInPurpose", ui.locale)}</strong>
	    </div>
	    <p class="privacy-body">
	      {t("settings.github.privacy.beforeStruct", ui.locale, { keyringName })}
	      <code>{`{ signedIn, username, scopes }`}</code>{t("settings.github.privacy.afterStruct", ui.locale)}
	    </p>
	    <p class="privacy-body">
	      {t("settings.github.scopes.beforeReadUser", ui.locale)}
	      <code>read:user</code>{t("settings.github.scopes.afterReadUser", ui.locale)}
	      <code>public_repo</code>{t("settings.github.scopes.afterPublicRepo", ui.locale)}
	      <code>notifications</code>{t("settings.github.scopes.afterNotifications", ui.locale)}
	    </p>
	  </aside>

	  {#if settings.corruptOnDisk}
	    <div class="callout warn" role="alert">
	      <TriangleAlert size={16} />
	      <span>{t("settings.github.corruptSettings", ui.locale)}</span>
	    </div>
	  {/if}
</div>

<style>
  .section { display: flex; flex-direction: column; gap: var(--space-5); max-width: 580px; }
  h2 {
    font-size: var(--text-h1);
    font-weight: var(--fw-semibold);
    color: var(--color-text-primary);
    margin-bottom: var(--space-2);
  }
  .field {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .hint {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    line-height: var(--lh-snug);
  }

  /* ---------- Toggle (same look as Network section) ---------- */
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    cursor: pointer;
    user-select: none;
  }
  .toggle input { position: absolute; opacity: 0; pointer-events: none; }
  .toggle-track {
    width: 36px;
    height: 20px;
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    position: relative;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .toggle-track::after {
    content: "";
    position: absolute;
    top: 1px;
    left: 1px;
    width: 16px;
    height: 16px;
    background: var(--color-surface-raised);
    border-radius: 50%;
    box-shadow: var(--shadow-xs);
    transition: transform var(--motion-duration-fast) var(--motion-ease-out);
  }
  .toggle input:checked + .toggle-track {
    background: var(--color-accent, #b8542a);
    border-color: var(--color-accent, #b8542a);
  }
  .toggle input:checked + .toggle-track::after {
    transform: translateX(16px);
    background: white;
  }
  .toggle-label {
    font-size: var(--text-body);
    font-weight: var(--fw-medium);
    color: var(--color-text-primary);
  }

  /* ---------- Sign-in block ---------- */
  .signin {
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface-sunken);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
  }
  .signed-in {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
  }
  .user {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-text-primary);
  }
  .username { font-weight: var(--fw-semibold); }
  .scopes {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    margin-top: 2px;
  }

  .btn-primary,
  .btn-secondary {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: var(--radius-md);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    width: max-content;
  }
  .btn-primary {
    background: var(--color-accent, #b8542a);
    color: white;
  }
  .btn-primary:hover:not(:disabled) {
    filter: brightness(1.05);
  }
  .btn-primary:disabled { opacity: 0.6; cursor: not-allowed; }
  .btn-secondary {
    background: var(--color-surface-raised);
    color: var(--color-text-primary);
    border: 1px solid var(--color-border);
  }
  .btn-secondary:hover:not(:disabled) {
    background: var(--color-surface);
  }
  .btn-secondary:disabled { opacity: 0.6; cursor: not-allowed; }

  /* ---------- Privacy note ---------- */
  .privacy {
    padding: var(--space-3) var(--space-4);
    background: var(--color-info-subtle, var(--color-surface-sunken));
    border: 1px solid var(--color-info, var(--color-border));
    border-radius: var(--radius-md);
  }
  .privacy-head {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--color-text-primary);
    margin-bottom: var(--space-2);
  }
  .privacy-body {
    color: var(--color-text-secondary);
    font-size: var(--text-body-sm);
    line-height: var(--lh-snug);
    margin-top: var(--space-2);
  }
  .privacy-body code {
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    padding: 1px 4px;
    background: var(--color-surface-raised);
    border-radius: var(--radius-sm);
  }

  .callout.warn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-md);
    background: var(--color-warning-subtle, var(--color-surface-sunken));
    color: var(--color-text-primary);
    font-size: var(--text-body-sm);
    border: 1px solid var(--color-warning, var(--color-border));
  }
</style>
