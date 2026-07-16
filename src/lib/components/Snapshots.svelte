<script lang="ts">
  import { onMount } from "svelte";
  import Plus from "@lucide/svelte/icons/plus";
  import Archive from "@lucide/svelte/icons/archive";
  import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
  import Trash2 from "@lucide/svelte/icons/trash-2";
  import Upload from "@lucide/svelte/icons/upload";
  import Download from "@lucide/svelte/icons/download";

  import Button from "./Button.svelte";
  import Modal from "./Modal.svelte";
  import DestructiveConfirm from "./DestructiveConfirm.svelte";
  import Input from "./Input.svelte";
  import LoadingState from "./LoadingState.svelte";
  import EmptyState from "./EmptyState.svelte";
  import { brewfiles } from "$lib/stores/brewfiles.svelte";
  import { activity } from "$lib/stores/activity.svelte";
  import { ui } from "$lib/stores/ui.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import { t, ruPlural } from "$lib/i18n/messages";
  import { brewfileDump, brewfileInstall, brewfileDelete, brewfileExport, brewfileImport } from "$lib/api";
  import type { BrewfileSummary } from "$lib/types";
  import { isLinux } from "$lib/util/platform";
  import { reportableToastError } from "$lib/util/reportIssue";

  let newLabel = $state("");
  let creating = $state(false);
  let showNewModal = $state(false);
  let toDelete: BrewfileSummary | null = $state(null);
  let toRestore: BrewfileSummary | null = $state(null);

  onMount(() => { brewfiles.load(); });

  function defaultLabel(): string {
    const now = new Date();
    const y = now.getFullYear();
    const m = String(now.getMonth() + 1).padStart(2, "0");
    const d = String(now.getDate()).padStart(2, "0");
    return `snapshot-${y}-${m}-${d}`;
  }

  function openNew() {
    newLabel = defaultLabel();
    showNewModal = true;
  }

  async function doCreate() {
    if (!newLabel.trim()) return;
    creating = true;
    const tmpId = crypto.randomUUID();
    activity.startJob(ui.locale === "ru" ? `Сохраняем Brewfile: ${newLabel}` : `Dumping Brewfile: ${newLabel}`, tmpId, `brew bundle dump`);
    ui.openDrawer();
    try {
      const summary = await brewfileDump(newLabel.trim(), (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
      const total = summary.counts.formulae + summary.counts.casks;
      toast.success(
        t("Snapshot saved", ui.locale),
        ui.locale === "ru" ? `${total} ${ruPlural(total, "пакет", "пакета", "пакетов")}` : `${total} packages`,
      );
      showNewModal = false;
      newLabel = "";
      brewfiles.load();
    } catch (e) {
      reportableToastError(t("Snapshot failed", ui.locale), e);
    } finally {
      creating = false;
    }
  }

  async function doRestore(b: BrewfileSummary) {
    toRestore = null;
    const tmpId = crypto.randomUUID();
    activity.startJob(ui.locale === "ru" ? `Восстанавливаем ${b.label}` : `Restoring ${b.label}`, tmpId, `brew bundle install`);
    ui.openDrawer();
    try {
      const result = await brewfileInstall(b.id, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
      if (result.success) toast.success(t("Restore complete", ui.locale));
      else toast.error(t("Restore failed", ui.locale));
    } catch (e) {
      reportableToastError(t("Restore failed", ui.locale), e);
    }
  }

  async function doDelete(b: BrewfileSummary) {
    toDelete = null;
    try {
      await brewfileDelete(b.id);
      toast.success(t("Deleted snapshot", ui.locale), b.label);
      brewfiles.load();
    } catch (e) {
      reportableToastError(t("Delete failed", ui.locale), e);
    }
  }

  async function doExport(b: BrewfileSummary) {
    try {
      const { save } = await import("@tauri-apps/plugin-dialog");
      const target = await save({
        defaultPath: `${b.label}.Brewfile`,
        filters: [{ name: "Brewfile", extensions: ["Brewfile", "txt", ""] }],
      });
      if (!target) return;
      await brewfileExport(b.id, target);
      toast.success(t("Exported snapshot", ui.locale), b.label);
    } catch (e) {
      reportableToastError(t("Export failed", ui.locale), e);
    }
  }

  async function doImport() {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const picked = await open({
        multiple: false,
        filters: [{ name: "Brewfile", extensions: ["Brewfile", "txt", ""] }],
      });
      if (!picked || typeof picked !== "string") return;
      const label = picked.split("/").pop() ?? "imported";
      await brewfileImport(picked, label);
      toast.success(t("Imported snapshot", ui.locale), label);
      brewfiles.load();
    } catch (e) {
      reportableToastError(t("Import failed", ui.locale), e);
    }
  }

  function formatDate(s: string): string {
    try { return new Date(s).toLocaleString(ui.locale === "ru" ? "ru-RU" : undefined); } catch { return s; }
  }

  function snapshotMeta(b: BrewfileSummary): string {
    const parts = [
      ui.locale === "ru"
        ? `${b.counts.formulae} ${ruPlural(b.counts.formulae, "формула", "формулы", "формул")}`
        : `${b.counts.formulae} formulae`,
    ];
    if (!isLinux || b.counts.casks > 0) {
      parts.push(ui.locale === "ru"
        ? `${b.counts.casks} ${ruPlural(b.counts.casks, "cask-пакет", "cask-пакета", "cask-пакетов")}`
        : `${b.counts.casks} casks`);
    }
    if (b.counts.masApps > 0) {
      parts.push(ui.locale === "ru"
        ? `${b.counts.masApps} ${ruPlural(b.counts.masApps, "MAS-приложение", "MAS-приложения", "MAS-приложений")}`
        : `${b.counts.masApps} MAS apps`);
    }
    return parts.join(" · ");
  }
</script>

<section class="snapshots">
  <!-- Pane title ("Snapshots") moved to the window title bar; head
       keeps the Import + New Snapshot primary actions. -->
  <header class="panel-head" data-tauri-drag-region>
    <div class="head-right" data-tauri-drag-region="false">
      <Button size="md" variant="secondary" onclick={doImport}>
        {#snippet icon()}<Upload size={14} />{/snippet}
        {t("Import…", ui.locale)}
      </Button>
      <Button size="md" variant="primary" onclick={openNew}>
        {#snippet icon()}<Plus size={14} />{/snippet}
        {t("New Snapshot", ui.locale)}
      </Button>
    </div>
  </header>

  <div class="list-wrap">
    {#if brewfiles.loading}
      <LoadingState rows={4} label={t("Loading snapshots…", ui.locale)} />
    {:else if brewfiles.error}
      <EmptyState title={t("Couldn't load snapshots", ui.locale)} body={brewfiles.error}>
        {#snippet icon()}<Archive size={48} />{/snippet}
        {#snippet cta()}<Button variant="secondary" onclick={() => brewfiles.load()}>{t("Retry", ui.locale)}</Button>{/snippet}
      </EmptyState>
    {:else if brewfiles.list.length === 0}
      <!-- Inline CTAs intentionally omitted: the same actions live in
           the panel-head's top-right (Import… + New Snapshot), so the
           empty state stays purely informational. The storage path mirrors
           the backend's `resolve_brewfiles_dir` (dirs::data_dir() +
           brew-browser/brewfiles/): ~/Library/Application Support on macOS,
           XDG data home (~/.local/share by default) on Linux. -->
      <EmptyState
        title={t("No snapshots yet", ui.locale)}
        body={isLinux
          ? t("Save your current setup so you can restore it on another machine. Snapshots live in ~/.local/share/brew-browser/brewfiles/ — findable outside the app too.", ui.locale)
          : t("Save your current setup so you can restore it on another Mac. Snapshots live in ~/Library/Application Support/brew-browser/brewfiles/ — findable outside the app too.", ui.locale)}
      >
        {#snippet icon()}<Archive size={48} />{/snippet}
      </EmptyState>
    {:else}
      <ul class="cards">
        {#each brewfiles.list as b (b.id)}
          <li class="card">
            <header class="card-head">
              <div>
                <h2>{b.label}</h2>
                <!-- Brewfiles legitimately carry cask lines (a snapshot may
                     come from a Mac) — real cask counts always show. Only
                     the decorative "0 casks" is suppressed on Linux. -->
                <p class="meta">{formatDate(b.createdAt)} · {snapshotMeta(b)}</p>
              </div>
              <div class="actions">
                <Button size="sm" variant="primary" onclick={() => (toRestore = b)}>
                  {#snippet icon()}<RotateCcw size={14} />{/snippet}
                  {t("Restore", ui.locale)}
                </Button>
                <Button size="sm" variant="secondary" onclick={() => doExport(b)}>
                  {#snippet icon()}<Download size={14} />{/snippet}
                  {t("Export…", ui.locale)}
                </Button>
                <Button size="sm" variant="ghost" onclick={() => (toDelete = b)} ariaLabel={ui.locale === "ru" ? `Удалить ${b.label}` : `Delete ${b.label}`} title={t("Delete", ui.locale)}>
                  {#snippet icon()}<Trash2 size={14} />{/snippet}
                  {t("Delete", ui.locale)}
                </Button>
              </div>
            </header>
            <p class="path text-muted truncate" title={b.path}>{b.path}</p>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</section>

<Modal open={showNewModal} title={t("New Snapshot", ui.locale)} defaultFocus="first" onClose={() => (showNewModal = false)}>
  <div class="modal-body">
    <label>
      <span class="lbl">{t("Name", ui.locale)}</span>
      <Input bind:value={newLabel} placeholder="snapshot-name" />
    </label>
    <p class="hint text-muted">{t("Stored in ~/Library/Application Support/brew-browser/brewfiles/", ui.locale)}</p>
  </div>
  {#snippet actions()}
    <Button variant="secondary" onclick={() => (showNewModal = false)}>{t("Cancel", ui.locale)}</Button>
    <Button variant="primary" loading={creating} onclick={doCreate}>{t("Create", ui.locale)}</Button>
  {/snippet}
</Modal>

<DestructiveConfirm
  open={!!toDelete}
  title={toDelete ? (ui.locale === "ru" ? `Удалить снимок «${toDelete.label}»?` : `Delete snapshot "${toDelete.label}"?`) : ""}
  confirmLabel={t("Delete", ui.locale)}
  onCancel={() => (toDelete = null)}
  onConfirm={() => toDelete && doDelete(toDelete)}
>
  <p>{t("The Brewfile will be removed from disk. This cannot be undone.", ui.locale)}</p>
</DestructiveConfirm>

<DestructiveConfirm
  open={!!toRestore}
  title={toRestore ? (ui.locale === "ru" ? `Восстановить из снимка «${toRestore.label}»?` : `Restore from "${toRestore.label}"?`) : ""}
  confirmLabel={t("Restore", ui.locale)}
  confirmVariant="primary"
  onCancel={() => (toRestore = null)}
  onConfirm={() => toRestore && doRestore(toRestore)}
>
  <p>{t("This will install packages from the snapshot. Existing packages are skipped.", ui.locale)}</p>
</DestructiveConfirm>

<style>
  .snapshots { display: flex; flex-direction: column; min-height: 0; height: 100%; }
  .panel-head {
    display: flex; justify-content: flex-end; align-items: center;
    padding: var(--space-4);
    border-bottom: 1px solid var(--color-border);
    gap: var(--space-3);
  }
  .head-right { display: flex; align-items: center; gap: var(--space-2); margin-left: auto; }
  .list-wrap { flex: 1; overflow-y: auto; min-height: 0; padding: var(--space-4); }
  .cards { display: flex; flex-direction: column; gap: var(--space-3); }
  .card {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    padding: var(--space-4);
    box-shadow: var(--shadow-xs);
    transition: box-shadow var(--motion-duration-fast) var(--motion-ease-out);
  }
  .card:hover { box-shadow: var(--shadow-sm); }
  .card-head { display: flex; justify-content: space-between; align-items: flex-start; gap: var(--space-3); }
  .card h2 { font-size: var(--text-h2); margin-bottom: 2px; }
  .meta { font-size: var(--text-body-sm); color: var(--color-text-secondary); }
  .actions { display: flex; gap: var(--space-2); flex-wrap: wrap; }
  .path { font-size: var(--text-caption); margin-top: var(--space-2); font-family: var(--font-mono); }

  .modal-body { display: flex; flex-direction: column; gap: var(--space-3); }
  .modal-body label { display: flex; flex-direction: column; gap: var(--space-1); }
  .lbl { font-size: var(--text-body-sm); color: var(--color-text-secondary); font-weight: var(--fw-medium); }
  .hint { font-size: var(--text-caption); }
</style>
