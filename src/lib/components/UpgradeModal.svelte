<script lang="ts">
  /**
   * UpgradeModal.svelte
   *
   * Curated multi-select upgrade flow. Triggered from the Dashboard's
   * Updates card ("Upgrade…" button next to "Upgrade all"). Lists every
   * outdated package with a checkbox, name, current → target version,
   * and a pinned badge (pinned packages are checkbox-disabled because
   * brew refuses to upgrade them anyway).
   *
   * On submit, fires a single `brew_upgrade_many(names)` IPC that runs
   * one `brew upgrade <pkg1> <pkg2> ...` invocation streaming into the
   * Activity drawer — much cleaner UX than N sequential IPCs.
   *
   * Selection contract:
   *   - All non-pinned packages start checked (matches "Upgrade all"
   *     default behavior). User unchecks the ones they want to skip.
   *   - Pinned packages start unchecked AND disabled. Tooltip explains
   *     that brew won't upgrade them.
   *   - "Select all" / "Deselect all" toolbar toggles ALL non-pinned
   *     rows; pinned stays excluded regardless.
   *   - Submit button shows the live count of selected packages and is
   *     disabled when zero are selected.
   *
   * Post-upgrade: `packages.load(true)` is called to refresh the
   * installed list (force-bypass the backend cache so the new versions
   * show immediately). Cancellation mid-upgrade is supported via the
   * Activity drawer's existing Cancel button.
   */

  import Modal from "./Modal.svelte";
  import Button from "./Button.svelte";
  import Pill from "./Pill.svelte";
  import ArrowUpCircle from "@lucide/svelte/icons/arrow-up-circle";

  import { activity } from "$lib/stores/activity.svelte";
  import { packages } from "$lib/stores/packages.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { vulnerabilities } from "$lib/stores/vulnerabilities.svelte";
  import { t, ruPlural } from "$lib/i18n/messages";
  import { brewUpgradeMany } from "$lib/api";
  import type { Package } from "$lib/types";
  import { reportableToastError } from "$lib/util/reportIssue";

  interface Props {
    open: boolean;
    onClose: () => void;
  }
  let { open, onClose }: Props = $props();

  /** All outdated packages, formulae first then casks — matches the
      `packages.outdated` derived's ordering. */
  let rows = $derived(packages.outdated);

  /** Map of fullName::kind → checked. Pinned packages are never in
      this map (they're excluded from selection entirely). */
  let selected = $state<Map<string, boolean>>(new Map());

  /** Initialize the selection map whenever the modal opens. Pre-checks
      every non-pinned package; pinned packages aren't tracked here. */
  $effect(() => {
    if (!open) return;
    const next = new Map<string, boolean>();
    for (const p of rows) {
      if (!p.pinned) next.set(rowKey(p), true);
    }
    selected = next;
  });

  function rowKey(p: Package): string {
    return `${p.fullName}::${p.kind}`;
  }

  function isChecked(p: Package): boolean {
    return selected.get(rowKey(p)) === true;
  }

  function toggle(p: Package) {
    if (p.pinned) return;
    const next = new Map(selected);
    next.set(rowKey(p), !next.get(rowKey(p)));
    selected = next;
  }

  let selectedCount = $derived.by(() => {
    let n = 0;
    for (const v of selected.values()) if (v) n += 1;
    return n;
  });

  let upgradablePackages = $derived(rows.filter((p) => !p.pinned));
  let allSelected = $derived(
    upgradablePackages.length > 0 && selectedCount === upgradablePackages.length,
  );

  function selectAll() {
    const next = new Map<string, boolean>();
    for (const p of upgradablePackages) next.set(rowKey(p), true);
    selected = next;
  }

  function deselectAll() {
    const next = new Map<string, boolean>();
    for (const p of upgradablePackages) next.set(rowKey(p), false);
    selected = next;
  }

  let upgrading = $state(false);

  function formatUpgradeAction(count: number): string {
    if (ui.locale === "ru") {
      return count === 0
        ? "Обновить"
        : `Обновить ${count} ${ruPlural(count, "пакет", "пакета", "пакетов")}`;
    }
    return `Upgrade ${count === 0 ? "" : count} ${count === 1 ? "package" : "packages"}`;
  }

  async function runUpgrade() {
    if (upgrading || selectedCount === 0) return;
    const names = rows
      .filter((p) => isChecked(p))
      .map((p) => p.name);
    if (names.length === 0) return;

    upgrading = true;
    const tmpId = crypto.randomUUID();
    const cmdLabel =
      names.length <= 3
        ? `brew upgrade ${names.join(" ")}`
        : `brew upgrade ${names.slice(0, 3).join(" ")} (+${names.length - 3})`;
    activity.startJob(
      names.length === 1
        ? (ui.locale === "ru" ? `Обновляем ${names[0]}` : `Upgrading ${names[0]}`)
        : (ui.locale === "ru"
          ? `Обновляем ${names.length} ${ruPlural(names.length, "пакет", "пакета", "пакетов")}`
          : `Upgrading ${names.length} packages`),
      tmpId,
      cmdLabel,
    );
    ui.openDrawer();
    onClose(); // dismiss the modal so the user sees the drawer

    try {
      const result = await brewUpgradeMany(names, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      }, ui.greedyUpgrade);
      if (result.success) {
        toast.success(
          names.length === 1
            ? (ui.locale === "ru" ? `Обновлён ${names[0]}` : `Upgraded ${names[0]}`)
            : (ui.locale === "ru"
              ? `Обновлено ${names.length} ${ruPlural(names.length, "пакет", "пакета", "пакетов")}`
              : `Upgraded ${names.length} packages`),
        );
        await packages.load(true);
        // v0.5.0 — upgrading many packages = bulk version changes. Easiest
        // is a full re-scan; scanIfNeeded fingerprints to skip when nothing
        // actually changed (e.g. brew_upgrade was a no-op). After the scan
        // completes, surface the once-per-session exposure heads-up so the
        // user sees the post-upgrade security context.
        vulnerabilities
          .scanIfNeeded()
          .then(() => vulnerabilities.maybeNotifyExposure())
          .catch(() => {});
      }
    } catch (e) {
      reportableToastError(t("Upgrade failed", ui.locale), e);
    } finally {
      upgrading = false;
    }
  }
</script>

<Modal {open} title={t("Choose packages to upgrade", ui.locale)} {onClose}>
  {#if rows.length === 0}
    <p class="empty">{t("No outdated packages.", ui.locale)}</p>
  {:else}
    <div class="toolbar">
      <span class="count">{ui.locale === "ru" ? `Выбрано ${selectedCount} из ${upgradablePackages.length}` : `${selectedCount} of ${upgradablePackages.length} selected`}</span>
      <div class="toolbar-actions">
        {#if allSelected}
          <button type="button" class="link" onclick={deselectAll}>{t("Deselect all", ui.locale)}</button>
        {:else}
          <button type="button" class="link" onclick={selectAll}>{t("Select all", ui.locale)}</button>
        {/if}
      </div>
    </div>
    <ul class="rows" role="list">
      {#each rows as p (rowKey(p))}
        <li class="row" class:row--pinned={p.pinned}>
          <label class="row-label">
            <input
              type="checkbox"
              checked={isChecked(p)}
              disabled={p.pinned}
              onchange={() => toggle(p)}
              aria-label={ui.locale === "ru" ? `Включить ${p.name}` : `Include ${p.name}`}
            />
            <span class="row-main">
              <span class="row-name truncate">{p.name}</span>
              <span class="row-kind">
                <Pill tone={p.kind === "formula" ? "formula" : "cask"}>{p.kind === "formula" ? t("package.kind.formula", ui.locale) : t("package.kind.cask", ui.locale)}</Pill>
              </span>
              <span class="row-version mono">
                {p.installedVersion ?? "?"} <span class="row-arrow">→</span> {p.stableVersion ?? "?"}
              </span>
              {#if p.pinned}
                <span class="row-pinned" title={t("Pinned packages are not upgraded by brew. Unpin from the package detail page.", ui.locale)}>{t("pinned", ui.locale)}</span>
              {/if}
            </span>
          </label>
        </li>
      {/each}
    </ul>
  {/if}

  {#snippet actions()}
    <Button variant="secondary" onclick={onClose}>{t("Cancel", ui.locale)}</Button>
    <Button
      variant="primary"
      onclick={runUpgrade}
      disabled={selectedCount === 0 || upgrading}
      loading={upgrading}
    >
      {#snippet icon()}<ArrowUpCircle size={14} />{/snippet}
      {formatUpgradeAction(selectedCount)}
    </Button>
  {/snippet}
</Modal>

<style>
  .empty {
    color: var(--color-text-muted);
    font-size: var(--text-body);
    padding: var(--space-3) 0;
  }

  /* Toolbar with selection count + select-all/deselect-all toggle. */
  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 0 var(--space-2) 0;
    border-bottom: 1px solid var(--color-border);
    margin-bottom: var(--space-2);
  }
  .count {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
  }
  .toolbar-actions {
    display: inline-flex;
    gap: var(--space-3);
  }
  .link {
    background: transparent;
    border: none;
    color: var(--color-accent, #b8542a);
    cursor: pointer;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    padding: 0;
    text-decoration: underline;
    text-underline-offset: 2px;
  }
  .link:hover { filter: brightness(1.1); }

  /* Selection list. Sized so 6–8 rows fit without scrolling on a
     standard window; longer lists scroll inside the modal body. */
  .rows {
    list-style: none;
    margin: 0;
    padding: 0;
    max-height: 360px;
    overflow-y: auto;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-surface-sunken);
  }
  .row {
    border-bottom: 1px solid var(--color-border);
  }
  .row:last-child { border-bottom: none; }
  .row--pinned { opacity: 0.6; }

  .row-label {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    cursor: pointer;
  }
  .row--pinned .row-label { cursor: not-allowed; }
  .row-label:hover { background: var(--color-surface); }
  .row--pinned .row-label:hover { background: transparent; }

  .row-label input[type="checkbox"] {
    flex: none;
    margin: 0;
    cursor: inherit;
  }
  .row-main {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr auto auto auto;
    align-items: center;
    gap: var(--space-3);
    min-width: 0;
  }
  .row-name {
    font-size: var(--text-body);
    color: var(--color-text-primary);
    font-weight: var(--fw-medium);
  }
  .row-kind { flex: none; }
  .row-version {
    font-size: var(--text-body-sm);
    color: var(--color-text-muted);
    white-space: nowrap;
  }
  .row-arrow { color: var(--color-text-muted); margin: 0 2px; }
  .row-pinned {
    font-size: var(--text-body-sm);
    color: var(--color-warning-strong, #b45309);
    padding: 1px 8px;
    background: var(--color-warning-subtle, var(--color-surface-raised));
    border: 1px solid var(--color-warning, var(--color-border));
    border-radius: var(--radius-sm);
    text-transform: lowercase;
  }
</style>
