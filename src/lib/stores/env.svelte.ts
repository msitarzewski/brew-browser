/**
 * Environment store — tracks the `brew_doctor` probe result.
 * Drives the footer status dot (green / amber / red), tooltip text, and
 * the "Homebrew not found" empty/error states.
 *
 * Also owns the missing-Homebrew onboarding gate: `system_status` on
 * startup, then a 2 s `brew_redetect` poll while brew is missing. The
 * moment brew appears, polling stops and the library loads — no relaunch.
 */

import { brewDoctor, brewRedetect, systemStatus } from "$lib/api";
import { t } from "$lib/i18n/messages";
import { packages } from "$lib/stores/packages.svelte";
import { ui } from "$lib/stores/ui.svelte";
import { isBrewError, brewErrorMessage } from "$lib/types";
import type { BrewEnvironment, SystemStatus } from "$lib/types";

class EnvStore {
  /** latest BrewEnvironment from the backend, or null until first probe completes. */
  report: BrewEnvironment | null = $state(null);
  /** an error from the most recent probe attempt, if any. */
  error: string | null = $state(null);
  /** a probe is in flight. */
  loading: boolean = $state(false);
  /** ms-since-epoch of the last completed probe (success or fail). */
  lastCheckedAt: number | null = $state(null);

  /** Latest `system_status` / `brew_redetect` snapshot (onboarding gate). */
  status: SystemStatus | null = $state(null);
  /** True once the initial `system_status` probe has settled (success or fail). */
  statusChecked: boolean = $state(false);

  /** 2 s `brew_redetect` poll handle while brew is missing. */
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  /** True when we have a confirmed-installed brew. False if probe failed or installed=false. */
  installed = $derived(this.report?.installed === true);

  /**
   * Onboarding gate: brew is *confirmed* missing (probe settled and said
   * no). `+page.svelte` renders OnboardingView instead of the shell while
   * this is true. Stays false until the first probe settles so a slow IPC
   * round-trip doesn't flash the onboarding screen at users who have brew.
   */
  brewMissing = $derived(this.statusChecked && this.status?.brewFound === false);

  /** Human-readable summary for a tooltip. */
  summary = $derived.by(() => {
    if (this.loading && !this.report) return t("brew.status.checking", ui.locale);
    if (this.error) return t("brew.status.unknownWithError", ui.locale, { error: this.error });
    if (!this.report) return t("brew.status.unknown", ui.locale);
    if (!this.report.installed) return t("brew.status.notFoundOnPath", ui.locale);
    const parts: string[] = [];
    if (this.report.version) parts.push(`Homebrew ${this.report.version}`);
    if (this.report.prefix) parts.push(`prefix ${this.report.prefix}`);
    return parts.join(" · ") || t("brew.status.installed", ui.locale);
  });

  /** Short label for the footer ("brew 5.1.13" / "brew" / "brew not found"). */
  shortLabel = $derived.by(() => {
    if (!this.report) return "brew";
    if (!this.report.installed) return "brew not found";
    if (this.report.version) return `brew ${this.report.version}`;
    return "brew";
  });

  async refresh(): Promise<void> {
    this.loading = true;
    try {
      const r = await brewDoctor();
      this.report = r;
      this.error = null;
    } catch (e) {
      this.report = { installed: false, version: null, prefix: null, pathUsed: null };
      this.error = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
    } finally {
      this.loading = false;
      this.lastCheckedAt = Date.now();
    }
  }

  /**
   * Like `refresh()`, but a no-op when the last probe completed less than
   * `minIntervalMs` ago. Used by foreground listeners (focus, visibilitychange)
   * which can fire rapidly when the user alt-tabs back and forth — we don't
   * need to spawn `brew --version` twice in five seconds. The 5-minute
   * backstop in `startEnvProbe()` still runs unconditionally.
   *
   * Security audit §L5 (memory-bank/security.md) — keeps the env-probe quiet
   * for telemetry-conscious users without sacrificing freshness on real
   * environment changes.
   */
  async refreshIfStale(minIntervalMs = 30_000): Promise<void> {
    if (this.loading) return;
    if (this.lastCheckedAt !== null && Date.now() - this.lastCheckedAt < minIntervalMs) {
      return;
    }
    await this.refresh();
  }

  /**
   * Initial onboarding probe. On failure (backend not ready, command
   * missing) the gate stays open — `brewMissing` remains false and the
   * packages store's `brew_not_found` message is the fallback.
   */
  async checkSystemStatus(): Promise<void> {
    try {
      this.applyStatus(await systemStatus());
    } catch {
      this.statusChecked = true;
    }
  }

  /**
   * Fold a status snapshot into state and manage the redetect poll:
   * brew missing → keep (or start) the 2 s poll; brew present → stop
   * polling, and if this is the missing→found flip, re-probe the env and
   * force-load the library so the app comes alive without a relaunch.
   */
  applyStatus(s: SystemStatus): void {
    const wasMissing = this.status?.brewFound === false;
    this.status = s;
    this.statusChecked = true;
    if (!s.brewFound) {
      this.startBrewPolling();
    } else {
      this.stopBrewPolling();
      if (wasMissing) {
        void this.refresh();
        void packages.load(true);
      }
    }
  }

  private startBrewPolling(): void {
    if (this.pollTimer !== null) return;
    this.pollTimer = setInterval(() => {
      void brewRedetect().then(
        (s) => this.applyStatus(s),
        () => {}, // transient IPC failure — keep polling
      );
    }, 2_000);
  }

  stopBrewPolling(): void {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }
}

export const env = new EnvStore();

/**
 * Install foreground listeners so the env probe re-runs when the user comes
 * back to the app, plus a periodic refresh fallback while focused. Returns
 * an unsubscribe.
 */
export function startEnvProbe(): () => void {
  // Initial probe.
  void env.refresh();

  let intervalId: ReturnType<typeof setInterval> | null = null;

  // Foreground triggers debounce-skip when the last probe was <30s ago — alt-tab
  // bursts shouldn't spawn `brew --version` repeatedly. See §L5.
  const onVisibilityChange = () => {
    if (typeof document !== "undefined" && document.visibilityState === "visible") {
      void env.refreshIfStale();
    }
  };
  const onFocus = () => {
    void env.refreshIfStale();
  };

  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", onVisibilityChange);
  }
  if (typeof window !== "undefined") {
    window.addEventListener("focus", onFocus);
    // Backstop: re-probe every 5 minutes regardless. Cheap (sub-100ms native call).
    intervalId = setInterval(() => void env.refresh(), 5 * 60 * 1000);
  }

  return () => {
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", onVisibilityChange);
    }
    if (typeof window !== "undefined") {
      window.removeEventListener("focus", onFocus);
    }
    if (intervalId !== null) clearInterval(intervalId);
  };
}

/**
 * Onboarding gate bootstrap — run the initial `system_status` probe;
 * `applyStatus` keeps a 2 s `brew_redetect` poll alive while brew is
 * missing and tears it down (plus loads the library) the moment it
 * appears. Returns an unsubscribe that stops any in-flight polling.
 */
export function startOnboardingGate(): () => void {
  void env.checkSystemStatus();
  return () => env.stopBrewPolling();
}
