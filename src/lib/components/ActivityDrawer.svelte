<script lang="ts">
  import { tick } from "svelte";
  import X from "@lucide/svelte/icons/x";
  import ChevronUp from "@lucide/svelte/icons/chevron-up";
  import ChevronDown from "@lucide/svelte/icons/chevron-down";
  import Copy from "@lucide/svelte/icons/copy";
  import Square from "@lucide/svelte/icons/square";
  import CheckCircle2 from "@lucide/svelte/icons/check-circle-2";
  import XCircle from "@lucide/svelte/icons/x-circle";
  import AlertTriangle from "@lucide/svelte/icons/alert-triangle";

  import { activity } from "$lib/stores/activity.svelte";
  import ResizeHandle from "$lib/components/ResizeHandle.svelte";
  import {
    ACTIVITY_DRAWER_DEFAULT_HEIGHT,
    ACTIVITY_DRAWER_MIN_HEIGHT,
    ui,
  } from "$lib/stores/ui.svelte";
  import { toast } from "$lib/stores/toast.svelte";
  import type { ActivityLine } from "$lib/types";
  import { openReportIssueFromJob } from "$lib/util/reportIssue";
  import {
    classifyRecovery,
    runRecovery,
    recoveryJobLabel,
    type RecoveryOption,
    type RecoveryKind,
  } from "$lib/util/recovery";
  import { classifyPartialUpgrade } from "$lib/util/partialUpgrade";
  import { openTerminalUpgrade } from "$lib/api";
  import { packages } from "$lib/stores/packages.svelte";

  type Props = {
    maxHeight: number;
  };

  let { maxHeight }: Props = $props();

  let consoleEl: HTMLDivElement | undefined = $state();
  let autoScroll = $state(true);

  let activeJob = $derived(activity.jobs.find((j) => j.jobId === activity.activeJobId) ?? activity.jobs[0]);

  // In-app recovery (#13/#102/#100): when a failed job is a known-recoverable
  // brew error (install hit "already an App", uninstall hit "required by…"),
  // offer one-click retry buttons instead of sending the user to Terminal.
  let recovery = $derived(activeJob ? classifyRecovery(activeJob) : null);
  let recoveryBusy = $state(false);

  async function runRecoveryChoice(opt: RecoveryOption, choice: RecoveryKind) {
    if (recoveryBusy) return;
    recoveryBusy = true;
    const tmpId = crypto.randomUUID();
    const flagged =
      choice === "forceRemove"
        ? `brew uninstall ${opt.kind === "cask" ? "--cask " : ""}${opt.name} --ignore-dependencies`
        : `brew install ${opt.kind === "cask" ? "--cask " : ""}${opt.name}${choice === "adopt" ? " --adopt" : " --force"}`;
    activity.startJob(recoveryJobLabel(opt, choice), tmpId, flagged);
    try {
      await runRecovery(opt, choice, (evt) => {
        if (evt.kind === "started" && evt.jobId !== tmpId) {
          const j = activity.jobs.find((j) => j.jobId === tmpId);
          if (j) j.jobId = evt.jobId;
        }
        activity.handleEvent(evt);
      });
    } catch (e) {
      toast.error("Couldn't run that action", String(e));
    } finally {
      recoveryBusy = false;
    }
  }

  // Partial-success upgrade: a bulk `brew upgrade` that upgraded most packages
  // but exited non-zero on a few (e.g. a cask needing sudo). Report the real
  // outcome and offer a per-package "Run in Terminal" hand-off, where sudo can
  // prompt. Only shown when recovery didn't already claim the job.
  let partialUpgrade = $derived(
    activeJob && !recovery ? classifyPartialUpgrade(activeJob) : null,
  );

  async function runUpgradeInTerminal(name: string) {
    try {
      await openTerminalUpgrade(name);
      watchUpgrade(name);
    } catch (e) {
      toast.error(`Couldn't open Terminal for ${name}`, String(e));
    }
  }

  function stillOutdated(name: string): boolean {
    return packages.outdated.some((p) => p.name === name || p.name.endsWith("/" + name));
  }

  // The Terminal upgrade runs detached — no completion callback — so poll the
  // outdated set until the package drops out (the user finished), then stop.
  // Bounded by a 3-minute timeout. Focus-refresh + the Re-check button also
  // cover it. Each tick's `packages.load(true)` updates the whole UI live.
  function watchUpgrade(name: string) {
    const deadline = Date.now() + 180_000;
    const id = setInterval(() => {
      if (Date.now() > deadline) {
        clearInterval(id);
        return;
      }
      void packages.load(true).then(() => {
        if (!stillOutdated(name)) clearInterval(id);
      });
    }, 8000);
  }

  // ─── Adaptive aria-live for high-volume install streams (security audit §N4).
  //
  // Brew installs can dump hundreds of lines (downloads, tar progress, post-
  // install scripts). At polite aria-live, every line is queued for the screen
  // reader, which floods SR users and renders the drawer effectively unusable.
  //
  // Strategy A: detect "fast streaming" (>3 lines/sec sustained for >5s) and
  // flip the live region to `aria-live="off"` while it lasts. Reverts to
  // `polite` once the stream calms down (no new lines for 1.5s). A separate
  // completion summary line announces "Done in 4.2s" / "Failed after Ns" so SR
  // users still get an exit signal even when the live region was muted.
  //
  // Counters and timestamps are intentionally untracked refs — they're
  // bookkeeping for the rate detector, not reactive state.
  type LiveMode = "polite" | "off";
  let liveMode = $state<LiveMode>("polite");
  let _lastLineCount = 0;
  let _lastLineCountJobId: string | undefined;
  let _windowStartedAt = 0;     // ms — start of the current "watching for surge" window
  let _windowLineCount = 0;     // lines observed inside this window
  let _lastLineAt = 0;          // ms — most recent line arrival
  const SURGE_RATE = 3;         // lines per second
  const SURGE_DURATION_MS = 5_000;
  const CALM_DURATION_MS = 1_500;
  let _calmTimer: ReturnType<typeof setTimeout> | null = null;

  function _resetSurgeWindow(now: number) {
    _windowStartedAt = now;
    _windowLineCount = 0;
  }

  function _scheduleCalmRevert() {
    if (_calmTimer !== null) clearTimeout(_calmTimer);
    _calmTimer = setTimeout(() => {
      liveMode = "polite";
      _calmTimer = null;
      _resetSurgeWindow(Date.now());
    }, CALM_DURATION_MS);
  }

  // auto-scroll on new line + rate-detect to gate aria-live
  $effect(() => {
    if (!activeJob) {
      _lastLineCount = 0;
      _lastLineCountJobId = undefined;
      liveMode = "polite";
      if (_calmTimer !== null) { clearTimeout(_calmTimer); _calmTimer = null; }
      return;
    }
    const count = activeJob.lines.length;
    // Reset counters when the active job changes — surges from a previous job
    // shouldn't mute the next one.
    if (_lastLineCountJobId !== activeJob.jobId) {
      _lastLineCount = 0;
      _lastLineCountJobId = activeJob.jobId;
      liveMode = "polite";
      _resetSurgeWindow(Date.now());
      if (_calmTimer !== null) { clearTimeout(_calmTimer); _calmTimer = null; }
    }
    const added = count - _lastLineCount;
    if (added > 0) {
      const now = Date.now();
      _lastLineAt = now;
      if (_windowStartedAt === 0) _resetSurgeWindow(now);
      _windowLineCount += added;
      const elapsed = now - _windowStartedAt;
      const rate = elapsed > 0 ? (_windowLineCount / (elapsed / 1000)) : 0;
      if (liveMode === "polite"
          && elapsed >= SURGE_DURATION_MS
          && rate >= SURGE_RATE) {
        liveMode = "off";
      }
      if (liveMode === "off") {
        // Refresh the calm timer on every new line — only revert when truly idle.
        _scheduleCalmRevert();
      }
      // Reset the surge window periodically while polite so a slow drip never
      // accumulates into a false-positive surge.
      if (liveMode === "polite" && elapsed > SURGE_DURATION_MS * 2) {
        _resetSurgeWindow(now);
      }
      _lastLineCount = count;
    }
    if (autoScroll && consoleEl) {
      tick().then(() => {
        if (consoleEl) consoleEl.scrollTop = consoleEl.scrollHeight;
      });
    }
  });

  // Completion summary string — short, factual, exit-signal-only — so SR users
  // hear the result even when the per-line live region was muted during a
  // surge. The polite live region on .completion-announce reads this once when
  // it changes; empty string while running emits nothing.
  let completionAnnounce = $derived.by(() => {
    if (!activeJob || activeJob.status === "running") return "";
    if (activeJob.status === "succeeded") return `${activeJob.label}: done.`;
    if (activeJob.status === "failed") return `${activeJob.label}: failed.`;
    if (activeJob.status === "canceled") return `${activeJob.label}: canceled.`;
    return "";
  });

  function onScroll() {
    if (!consoleEl) return;
    // if user scrolled away from bottom, pause autoscroll
    const nearBottom = consoleEl.scrollTop + consoleEl.clientHeight >= consoleEl.scrollHeight - 20;
    autoScroll = nearBottom;
  }

  function classifyLine(line: string): "header" | "error" | "warning" | "success" | "dim" | "default" {
    const trimmed = line.trim();
    if (trimmed.startsWith("==>")) return "header";
    if (/^(error|Error):/i.test(trimmed)) return "error";
    if (/^(warning|Warning):/i.test(trimmed)) return "warning";
    if (/^(Downloading|Pouring|Installing|Fetching)/.test(trimmed)) return "success";
    if (/^\s*\d/.test(trimmed) && /^[\d#%.\s]+$/.test(trimmed)) return "dim";
    return "default";
  }

  function stripAnsi(s: string): string {
    // eslint-disable-next-line no-control-regex
    return s.replace(/\x1b\[[0-9;]*m/g, "");
  }

  async function copyLog() {
    if (!activeJob) return;
    const text = activeJob.lines.map((l: ActivityLine) => l.text).join("\n");
    try {
      await navigator.clipboard.writeText(text);
      toast.success("Copied log to clipboard");
    } catch {
      toast.error("Copy failed");
    }
  }

  function elapsed(j: typeof activeJob): string {
    if (!j) return "";
    if (j.durationMs) return formatMs(j.durationMs);
    const ms = Date.now() - new Date(j.startedAt).getTime();
    return formatMs(ms);
  }
  function formatMs(ms: number): string {
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    return `${m}:${s.toString().padStart(2, "0")}`;
  }
  /** Shorter "4.2s" / "1m 14s" form for the quiet completion footer. */
  function formatElapsed(ms: number): string {
    if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
    const totalSec = Math.round(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    return m > 0 ? `${m}m ${s}s` : `${s}s`;
  }

  function failedFooter(job: typeof activeJob): string {
    if (!job) return "Failed.";
    const base = `Failed${job.durationMs ? ` after ${formatElapsed(job.durationMs)}` : ""}.`;
    // The failure card on the right always renders a notice now (friendly
    // message, Homebrew-error guidance, or app-error report), so always point there.
    return `${base} See the notice at right.`;
  }

  function failureTitle(label: string): string {
    if (label.startsWith("Upgrading ")) return "Upgrade failed";
    if (label.startsWith("Installing ")) return "Install failed";
    if (label.startsWith("Uninstalling ")) return "Uninstall failed";
    return `${label} failed`;
  }
</script>

{#if ui.drawerOpen}
  <div
    class="drawer"
    class:minimized={ui.drawerMinimized}
    style:height={`${ui.drawerMinimized ? 32 : ui.drawerHeight}px`}
  >
    {#if !ui.drawerMinimized}
      <ResizeHandle
        size={ui.drawerHeight}
        min={ACTIVITY_DRAWER_MIN_HEIGHT}
        max={maxHeight}
        defaultSize={ACTIVITY_DRAWER_DEFAULT_HEIGHT}
        orientation="horizontal"
        direction="up"
        label="Resize Activity drawer"
        onChange={(height) => (ui.drawerHeight = height)}
        onCommit={(height) => ui.setActivityDrawerHeight(height)}
      />
    {/if}
    <header class="strip">
      <button class="title" onclick={() => ui.toggleDrawer()} title={ui.drawerMinimized ? "Expand drawer" : "Minimize drawer"}>
        {#if ui.drawerMinimized}<ChevronUp size={14} />{:else}<ChevronDown size={14} />{/if}
        <span>Activity</span>
        {#if activeJob}
          <span class="sep">·</span>
          {#if activeJob.status === "running"}
            <span class="running">{activeJob.label}</span>
            <span class="time mono">{elapsed(activeJob)}</span>
          {:else if activeJob.status === "succeeded"}
            <span class="ok"><CheckCircle2 size={12} /> {activeJob.label}</span>
          {:else if activeJob.status === "failed"}
            <span class="fail"><XCircle size={12} /> {activeJob.label}</span>
          {:else if activeJob.status === "canceled"}
            <span class="dim">{activeJob.label} (canceled)</span>
          {/if}
        {/if}
      </button>
      <div class="controls">
        {#if activeJob?.status === "running"}
          <button class="ctl" onclick={() => activity.cancel(activeJob!.jobId)} title="Cancel">
            <Square size={12} /> Cancel
          </button>
        {/if}
        <button class="ctl" onclick={copyLog} title="Copy log">
          <Copy size={12} />
        </button>
        <button class="ctl" onclick={() => ui.closeDrawer()} title="Close drawer" aria-label="Close drawer">
          <X size={14} />
        </button>
      </div>
    </header>

    {#if activeJob?.status === "running" && activeJob.progress}
      {@const p = activeJob.progress}
      {@const pct = p.total ? Math.min(100, Math.round((p.current / p.total) * 100)) : null}
      <div class="progress-row" role="status" aria-live="off">
        <div class="progress-track">
          <div
            class="progress-fill {pct === null ? 'indeterminate' : ''}"
            style:width={pct === null ? "40%" : `${pct}%`}
          ></div>
        </div>
        <span class="progress-label mono">
          {p.phase}{p.package ? ` ${p.package}` : ""}{p.total ? ` (${p.current} of ${p.total})` : ""}
        </span>
      </div>
    {/if}

    {#if !ui.drawerMinimized}
      <!-- No job tabs: the drawer shows the running job (live) or whichever job
           you pick in the Activity panel. The panel is the single place to
           switch and to remove entries — a tab strip becomes unusable once a
           handful of jobs accumulate. -->

      <!-- aria-live flips between "polite" (slow streams) and "off" (high-volume
           install surges) — see §N4. A separate sr-only completion line below
           guarantees SR users still get an exit signal when muted. -->
      <div class="drawer-body" class:with-notice={activeJob?.status === "failed"}>
        <div class="console" bind:this={consoleEl} onscroll={onScroll} role="log" aria-live={liveMode} aria-atomic="false">
          {#if !activeJob}
            <p class="muted">Quiet. brew commands run by brew-browser appear here.</p>
          {:else if activeJob.lines.length === 0}
            <p class="muted">Waiting for output…</p>
          {:else}
            {#each activeJob.lines as line, i (i)}
              {@const cls = classifyLine(line.text)}
              <div class="line {cls}">{stripAnsi(line.text)}</div>
            {/each}
            {#if activeJob.status !== "running"}
              <!-- Visible footer line. The inline aria-live was removed in §N4;
                   the completion announcer below is the single authoritative
                   polite live region for exit signals so SR users hear it once
                   (and reliably) even when the streaming log was muted mid-surge. -->
              <div class="footer-line {activeJob.status}">
                {#if activeJob.status === "succeeded"}
                  Done{activeJob.durationMs ? ` in ${formatElapsed(activeJob.durationMs)}` : ""}.
                {:else if activeJob.status === "failed"}
                  <span>{failedFooter(activeJob)}</span>
                {:else if activeJob.status === "canceled"}
                  Stopped. Output above.
                {/if}
              </div>
            {/if}
          {/if}
        </div>

        {#if activeJob?.status === "failed"}
          <aside class="failure-card" aria-label="Failure details">
            <div class="failure-card-head">
              <AlertTriangle size={16} />
              <!-- A partial success ("Upgraded N …") isn't a flat failure — soften. -->
              <h3>{partialUpgrade && partialUpgrade.upgraded > 0 ? "Upgrade incomplete" : failureTitle(activeJob.label)}</h3>
            </div>
            {#if recovery}
              <!-- A recoverable brew failure (#13/#102/#100): offer a one-click
                   retry with the right flag instead of pointing at Terminal. -->
              <p>{recovery.reason}</p>
              <div class="recovery-actions">
                {#each recovery.choices as choice (choice.kind)}
                  <button
                    type="button"
                    class="recovery-btn {choice.variant}"
                    disabled={recoveryBusy}
                    title={choice.hint}
                    onclick={() => runRecoveryChoice(recovery!, choice.kind)}
                  >
                    {choice.label}
                  </button>
                {/each}
              </div>
              <p class="recovery-hint">{recovery.choices[0].hint}</p>
            {:else}
              <!-- Message: a curated friendly message wins; else the partial-success
                   summary; else the generic Homebrew / app-error notice. -->
              {#if activeJob.friendlyMessage}
                <p>{activeJob.friendlyMessage}</p>
              {:else if partialUpgrade}
                <p>
                  {#if partialUpgrade.upgraded > 0}
                    Upgraded <strong>{partialUpgrade.upgraded}</strong>
                    {partialUpgrade.upgraded === 1 ? "package" : "packages"} —
                  {/if}
                  {partialUpgrade.failures.length}
                  {partialUpgrade.failures.length === 1 ? "package" : "packages"}
                  couldn't upgrade automatically (often a cask that needs your
                  password, or whose app was moved). Finish each in Terminal, where
                  it can prompt you:
                </p>
              {:else if activeJob.exitCode != null}
                <p>
                  This looks like a <strong>Homebrew</strong> error, not a brew-browser bug —
                  the command ran but exited with status {activeJob.exitCode}. Try the same
                  command in Terminal; if it fails there too, it's a Homebrew or formula issue
                  to report upstream.
                </p>
              {:else}
                <!-- No exit code = brew-browser couldn't run the command (IPC/spawn
                     failure). That IS our bug, so this is the only case that reports. -->
                <p>brew-browser hit an unexpected error running this command.</p>
                <button
                  type="button"
                  class="report-btn"
                  onclick={() => { void openReportIssueFromJob(activeJob!, activeJob!.label); }}
                  title="Open a pre-filled GitHub issue against brew-browser with this output"
                >
                  Report to brew-browser
                </button>
              {/if}

              <!-- Additive per-package Terminal hand-off — shown whenever the failed
                   upgrade names packages, even alongside a curated message (e.g. the
                   sudo-cask case), so the user gets a one-click prompt. -->
              {#if partialUpgrade}
                <ul class="partial-failures">
                  {#each partialUpgrade.failures as name (name)}
                    <li>
                      <code>{name}</code>
                      <button
                        type="button"
                        class="terminal-btn"
                        onclick={() => runUpgradeInTerminal(name)}
                        title={`Open Terminal running: brew upgrade ${name}`}
                      >
                        Run in Terminal
                      </button>
                    </li>
                  {/each}
                </ul>
              {/if}

              <!-- Re-check: BB gets no callback when a Terminal upgrade finishes,
                   so offer a one-click re-read (it also auto-refreshes on focus +
                   while watching the handed-off package). Any brew failure, not
                   our own spawn errors. -->
              {#if activeJob.exitCode != null}
                <button
                  type="button"
                  class="terminal-btn recheck-btn"
                  onclick={() => { void packages.load(true); }}
                  title="Re-read Homebrew after you've finished in Terminal"
                >
                  Re-check
                </button>
              {/if}
            {/if}
          </aside>
        {/if}
      </div>

      <!-- Dedicated polite live region for SR-only completion announcements.
           Stays polite regardless of streaming surge state (§N4 Strategy A). -->
      <div class="sr-only" aria-live="polite" aria-atomic="true">{completionAnnounce}</div>
    {/if}
  </div>
{/if}

<style>
  .drawer {
    border-top: 1px solid var(--color-border);
    background: var(--color-surface);
    display: flex;
    flex-direction: column;
    flex: none;
    height: 280px;
  }
  .drawer:not(.minimized) { min-height: 252px; }
  .drawer.minimized { height: 32px; }

  .strip {
    height: 32px;
    flex: none;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 var(--space-3);
    background: var(--color-surface-raised);
    border-bottom: 1px solid var(--color-border);
    font-size: var(--text-body-sm);
  }
  .title {
    display: inline-flex; align-items: center; gap: var(--space-2);
    color: var(--color-text-primary);
    font-weight: var(--fw-medium);
  }
  .sep { color: var(--color-text-muted); }
  .running { color: var(--color-text-primary); }
  .time { color: var(--color-text-muted); font-size: var(--text-caption); }
  .ok { display: inline-flex; align-items: center; gap: 4px; color: var(--color-success); }
  .fail { display: inline-flex; align-items: center; gap: 4px; color: var(--color-danger); }
  .dim { color: var(--color-text-muted); }

  .controls { display: flex; align-items: center; gap: var(--space-1); }
  .ctl {
    display: inline-flex; align-items: center; gap: 4px;
    padding: 2px var(--space-2);
    border-radius: var(--radius-sm);
    color: var(--color-text-muted);
    font-size: var(--text-caption);
  }
  .ctl:hover { background: var(--color-surface-sunken); color: var(--color-text-primary); }

  /* Live progress bar for a running job (best-effort from brew `==>` markers). */
  .progress-row {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-1) var(--space-3);
    border-bottom: 1px solid var(--color-border);
  }
  .progress-track {
    flex: 1;
    height: 4px;
    border-radius: 2px;
    background: var(--color-surface-sunken);
    overflow: hidden;
  }
  .progress-fill {
    height: 100%;
    border-radius: 2px;
    background: var(--color-accent, var(--color-success));
    transition: width 200ms ease;
  }
  .progress-fill.indeterminate {
    animation: progress-indeterminate 1.1s ease-in-out infinite;
  }
  @keyframes progress-indeterminate {
    0%   { margin-left: -40%; }
    100% { margin-left: 100%; }
  }
  .progress-label {
    color: var(--color-text-muted);
    font-size: var(--text-caption);
    white-space: nowrap;
  }

  .drawer-body {
    flex: 1;
    min-height: 0;
    display: flex;
    align-items: stretch;
    background: var(--color-console-bg);
  }
  .drawer-body.with-notice {
    gap: var(--space-3);
    padding-right: var(--space-3);
  }

  .console {
    flex: 1 1 auto;
    overflow-y: auto;
    min-height: 0;
    background: var(--color-console-bg);
    color: var(--color-console-fg);
    font-family: var(--font-mono);
    font-size: var(--text-mono);
    line-height: var(--lh-mono);
    padding: var(--space-3) var(--space-4);
  }
  .failure-card {
    flex: 0 0 min(360px, 34vw);
    align-self: flex-start;
    margin-top: var(--space-3);
    padding: var(--space-3);
    border: 1px solid color-mix(in oklch, var(--color-danger) 42%, var(--color-border));
    border-radius: var(--radius-lg);
    background: color-mix(in oklch, var(--color-danger-subtle) 58%, var(--color-surface-raised));
    color: var(--color-text-primary);
    box-shadow: var(--shadow-sm);
  }
  .failure-card-head {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-danger-on-subtle, var(--color-danger));
  }
  .failure-card-head h3 {
    margin: 0;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-semibold);
  }
  .failure-card p {
    margin: var(--space-2) 0 0;
    color: var(--color-text-secondary);
    font-size: var(--text-caption);
    line-height: var(--lh-body);
    overflow-wrap: anywhere;
  }
  .failure-card .report-btn {
    margin-top: var(--space-3);
    color: var(--color-danger-on-subtle, var(--color-danger));
  }
  .line {
    white-space: pre-wrap;
    word-break: break-all;
  }
  .line.header  { color: var(--color-console-info); }
  .line.error   { color: var(--color-console-danger); }
  .line.warning { color: var(--color-console-warning); }
  .line.success { color: var(--color-console-success); }
  .line.dim     { color: var(--color-console-dim); }

  .muted { color: var(--color-console-dim); }

  /* Quiet completion line — factual, no celebration. */
  .footer-line {
    margin-top: var(--space-2);
    padding-top: var(--space-2);
    border-top: 1px dashed var(--color-console-dim);
    color: var(--color-console-dim);
    font-style: italic;
    display: flex;
    align-items: center;
    gap: var(--space-3);
    flex-wrap: wrap;
  }
  .footer-line > span {
    min-width: 0;
    flex: 1 1 24rem;
    overflow-wrap: anywhere;
  }
  .footer-line.succeeded { color: var(--color-success); font-style: normal; }
  .footer-line.failed    { color: var(--color-danger);  font-style: normal; }
  .footer-line.canceled  { color: var(--color-console-dim); }

  /* "Report to brew-browser" button — shown only on a failed job. Tone
     matches the danger color of the line itself so the affordance reads
     as paired with the failure summary. */
  .report-btn {
    padding: 2px 10px;
    background: transparent;
    border: 1px solid currentColor;
    border-radius: var(--radius-sm);
    color: inherit;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .report-btn:hover { background: color-mix(in oklch, currentColor 12%, transparent); }
  .report-btn:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
  }

  /* In-app recovery buttons (#13/#102/#100) — paired with the failure card. */
  .recovery-actions {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    margin-top: var(--space-2);
  }
  .recovery-btn {
    padding: 3px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid transparent;
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out),
      opacity var(--motion-duration-fast) var(--motion-ease-out);
  }
  .recovery-btn:disabled { opacity: 0.55; cursor: wait; }
  .recovery-btn.primary {
    background: var(--color-brand);
    color: var(--color-on-brand, white);
    border-color: var(--color-brand);
  }
  .recovery-btn.primary:hover:not(:disabled) {
    background: color-mix(in oklch, var(--color-brand) 88%, black);
  }
  .recovery-btn.danger {
    background: transparent;
    color: var(--color-danger);
    border-color: var(--color-danger);
  }
  .recovery-btn.danger:hover:not(:disabled) {
    background: color-mix(in oklch, var(--color-danger) 12%, transparent);
  }
  .recovery-btn:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
  }
  .recovery-hint {
    margin-top: var(--space-1);
    font-size: var(--text-caption);
    color: var(--color-text-muted);
  }

  .partial-failures {
    list-style: none;
    margin: var(--space-2) 0 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }
  .partial-failures li {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }
  .partial-failures code {
    font-size: var(--text-body-sm);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .terminal-btn {
    flex: none;
    padding: 2px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--color-border);
    background: transparent;
    color: var(--color-text);
    font-size: var(--text-body-sm);
    font-weight: var(--fw-medium);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast) var(--motion-ease-out);
  }
  .terminal-btn:hover { background: color-mix(in oklch, currentColor 12%, transparent); }
  .recheck-btn { margin-top: var(--space-2); align-self: flex-start; }
  .terminal-btn:focus-visible {
    outline: 2px solid var(--color-focus, var(--color-brand, var(--color-accent)));
    outline-offset: 2px;
  }
</style>
