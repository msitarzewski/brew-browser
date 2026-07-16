/**
 * vulnerabilities.svelte.ts — v0.5.0
 *
 * Opt-in vulnerability-scanning store. Wraps the four `vulns_*` IPC
 * commands and projects the backend's `{kind:name:version}`-keyed scan
 * report into a frontend-friendly `{kind:name}` Map (the "what does
 * the user have vulnerable RIGHT NOW" view — versioning is the
 * backend cache's concern, not ours).
 *
 * Gating: every fetch path consults the settings store before invoking
 * the IPC so the backend's `feature_disabled` / `paranoid_mode_blocked`
 * errors are never the primary trigger — the UI stays quiet until the
 * user has opted in via Settings → Network.
 *
 * Error routing:
 *   - `vulns_not_installed` — captured into `lastScanError` for the
 *     Settings card to surface the install affordance. Not a toast
 *     (the install button is the user-facing remediation, not a
 *     transient notice).
 *   - Everything else — `reportableToastError` so the user gets the
 *     "Report to brew-browser" action.
 *
 * Reactivity: Svelte 5 doesn't track `Map.set()` mutations, so writes
 * reassign the Map (mirrors `trendingHistory.seriesByKey` and the
 * `services.setPending` pattern). Reads are O(1) via `byPackage`.
 */

import {
  vulnsInstallHelper,
  vulnsInvalidate,
  vulnsScanAll,
  vulnsScanOne,
} from "$lib/api";
import { t } from "$lib/i18n/messages";
import { settings } from "$lib/stores/settings.svelte";
import { toast } from "$lib/stores/toast.svelte";
import { ui } from "$lib/stores/ui.svelte";
import {
  brewErrorMessage,
  isBrewError,
  type BrewErrorPayload,
  type PackageKind,
  type RawVuln,
  type Severity,
} from "$lib/types";
import { reportableToastError } from "$lib/util/reportIssue";
import { ruPlural } from "$lib/i18n/messages";

/**
 * One per-package vulnerability record. Keyed in the store by
 * `"{kind}:{name}"` — version lives on the record itself so callers
 * can render "vulnerable in 1.2.3" without a second lookup.
 */
export interface VulnRecord {
  kind: PackageKind;
  name: string;
  version: string;
  scannedAt: Date;
  vulns: RawVuln[];
}

/**
 * Aggregated severity rollup across every record currently in the
 * store. Derived via `$derived` so callers can bind directly without
 * recomputing.
 */
export interface SeverityCounts {
  critical: number;
  high: number;
  medium: number;
  low: number;
  unknown: number;
  /** Sum of the five severity buckets above. */
  total: number;
  /** Count of records where `vulns.length > 0` (i.e. packages that
      have at least one finding). Distinct from `total`, which counts
      individual findings. */
  vulnerablePackages: number;
}

// ----- Internal helpers -----

/** Map key form used by the store. NOT the same as the backend's
    on-disk storage key — that one includes the version. */
function keyFor(kind: PackageKind, name: string): string {
  return `${kind}:${name}`;
}

/**
 * Split the backend's storage-key form `"{kind}:{name}:{version}"`.
 * Splits into three parts max so a name containing `:` (unlikely in
 * practice but defensive) doesn't shred the version off. Mirrors a
 * Rust `splitn(3, ':')`.
 *
 * Returns null on a malformed key — caller should skip the entry
 * rather than crash.
 */
function parseKey(
  entriesKey: string,
): { kind: PackageKind; name: string; version: string } | null {
  const firstColon = entriesKey.indexOf(":");
  if (firstColon <= 0) return null;
  const lastColon = entriesKey.lastIndexOf(":");
  if (lastColon === firstColon) return null;
  const kindRaw = entriesKey.slice(0, firstColon);
  const name = entriesKey.slice(firstColon + 1, lastColon);
  const version = entriesKey.slice(lastColon + 1);
  if (kindRaw !== "formula" && kindRaw !== "cask") return null;
  if (!name || !version) return null;
  return { kind: kindRaw as PackageKind, name, version };
}

/** Numeric rank for max-severity sorting. Higher = more severe. */
function severityRank(s: Severity): number {
  switch (s) {
    case "critical": return 4;
    case "high":     return 3;
    case "medium":   return 2;
    case "low":      return 1;
    case "unknown":  return 0;
  }
}

/** Highest-severity rank across a record's findings. Records with no
    findings collapse to -1 so they sort last regardless of name. */
function maxSeverityRank(record: VulnRecord): number {
  if (record.vulns.length === 0) return -1;
  let max = 0;
  for (const v of record.vulns) {
    const r = severityRank(v.severity);
    if (r > max) max = r;
  }
  return max;
}

// ----- Store -----

class VulnerabilitiesStore {
  /** All known scan records, keyed by `keyFor(kind, name)`. Reassigned
      (not mutated) on every write so Svelte 5 reactivity picks up. */
  records: Map<string, VulnRecord> = $state(new Map());

  /** True while any scan IPC is in flight. */
  loading: boolean = $state(false);

  /** Surfaced in the Settings panel when set. Routed here (not toasted)
      so the "Install brew-vulns" affordance is the user's primary
      remediation path, not a transient notification. Cleared by the
      next successful scan. */
  lastScanError: string | null = $state(null);

  /** Machine-readable companion for UI states that should not depend on
      localized human prose. */
  lastScanErrorCode: BrewErrorPayload["code"] | null = $state(null);

  /** ISO-derived timestamp from the most recent scan report, or null
      before the first scan. */
  lastScannedAt: Date | null = $state(null);

  /** "live" when the most recent scan re-shelled `brew vulns`,
      "cache" when the backend fingerprint-skip path served the
      previous report. Null before the first scan. */
  source: "live" | "cache" | null = $state(null);

  /** Wall-clock when this app session started (store construction ≈ app load).
      A scan whose timestamp predates it was served from cache on launch — so a
      confident "no vulnerabilities" all-clear would be stale. */
  readonly #sessionStart = Date.now();

  /** True only when `d` is a scan that ran during THIS session (not a hydrated
      cache report). Gates green "all clean" claims — a security tool must not
      imply safety it verified in a previous session / hours ago. */
  scannedThisSession(d: Date | null): boolean {
    return d !== null && d.getTime() >= this.#sessionStart;
  }

  /** Aggregated counts across `records`. */
  severityCounts: SeverityCounts = $derived.by(() => {
    const counts: SeverityCounts = {
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
      unknown: 0,
      total: 0,
      vulnerablePackages: 0,
    };
    for (const rec of this.records.values()) {
      if (rec.vulns.length > 0) counts.vulnerablePackages += 1;
      for (const v of rec.vulns) {
        counts[v.severity] += 1;
        counts.total += 1;
      }
    }
    return counts;
  });

  /** Records that have at least one finding, sorted by max severity
      desc then name. Backs the Security tab list. */
  vulnerableRecords: VulnRecord[] = $derived.by(() => {
    const out: VulnRecord[] = [];
    for (const rec of this.records.values()) {
      if (rec.vulns.length > 0) out.push(rec);
    }
    out.sort((a, b) => {
      const dr = maxSeverityRank(b) - maxSeverityRank(a);
      if (dr !== 0) return dr;
      return a.name.localeCompare(b.name);
    });
    return out;
  });

  /** Per-package lookup — same key form `keyFor(kind, name)`. Returns
      undefined when no scan record exists for the pair (distinct from
      "scanned, found nothing", which returns a record with
      `vulns.length === 0`). */
  byPackage(kind: PackageKind, name: string): VulnRecord | undefined {
    return this.records.get(keyFor(kind, name));
  }

  /** Whether scanning is currently enabled (toggle on + Offline Mode
      off). Drives whether `scanIfNeeded` will actually fetch. */
  get enabled(): boolean {
    return (
      settings.effective.vulnerabilityScanningEnabled === true &&
      settings.effective.paranoidMode === false
    );
  }

  /** Lazy fetch on first interest — call from views that surface
      vulnerability data (Security tab, Dashboard exposure card). No-op
      when scanning is disabled OR when we already have records. */
  async scanIfNeeded(): Promise<void> {
    if (!this.enabled) return;
    if (this.records.size > 0) return;
    if (this.loading) return;
    await this.scanAll(false);
  }

  /** Trigger a full scan. `force=true` bypasses the backend's
      fingerprint-skip predicate (the Refresh button's path). */
  async scanAll(force = false): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const report = await vulnsScanAll(force);
      this.#applyReport(report.entries, new Date(report.scannedAt));
      this.source = report.source;
      this.lastScannedAt = new Date(report.scannedAt);
      this.lastScanError = null;
      this.lastScanErrorCode = null;
    } catch (e) {
      if (isBrewError(e) && e.code === "vulns_not_installed") {
        // Helper isn't installed yet — surface in the Settings card,
        // don't toast. The install affordance is the remediation path.
        this.lastScanErrorCode = e.code;
        this.lastScanError = brewErrorMessage(e, ui.locale);
      } else {
        this.lastScanErrorCode = isBrewError(e) ? e.code : null;
        this.lastScanError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
        reportableToastError(t("vulnerabilities.scanFailed", ui.locale), e);
      }
    } finally {
      this.loading = false;
    }
  }

  /** Re-scan a single formula. Used by the PackageDetail
      "Check now" button. */
  async scanOne(kind: PackageKind, name: string): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    try {
      const vulns = await vulnsScanOne(name);
      // Look up the existing record so we can keep its version; if we
      // don't have one yet (rare — PackageDetail usually triggers a
      // scan-all first), keep version unknown and let the next full
      // scan reconcile.
      const existing = this.records.get(keyFor(kind, name));
      const record: VulnRecord = {
        kind,
        name,
        version: existing?.version ?? "",
        scannedAt: new Date(),
        vulns,
      };
      this.records = new Map(this.records).set(keyFor(kind, name), record);
      this.lastScanError = null;
      this.lastScanErrorCode = null;
    } catch (e) {
      if (isBrewError(e) && e.code === "vulns_not_installed") {
        this.lastScanErrorCode = e.code;
        this.lastScanError = brewErrorMessage(e, ui.locale);
      } else {
        this.lastScanErrorCode = isBrewError(e) ? e.code : null;
        this.lastScanError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
        reportableToastError(t("vulnerabilities.scanOneFailed", ui.locale, { name }), e);
      }
    } finally {
      this.loading = false;
    }
  }

  /** Drop a single cache entry on both sides (backend + local Map).
      Called by ActionButtons after a successful upgrade / uninstall
      so a stale CVE record can't outlive the version it referenced.
      Best-effort — backend failure is logged-and-ignored since this
      is cleanup, not load-bearing. */
  async invalidate(
    kind: PackageKind,
    name: string,
    version: string,
  ): Promise<void> {
    try {
      await vulnsInvalidate(kind, name, version);
    } catch (e) {
      // Local cleanup still happens below — the worst case is the
      // backend's on-disk cache keeps the stale entry until the next
      // full scan reconciles. Don't surface this to the user.
      console.warn("vulns: invalidate IPC failed (continuing with local cleanup)", e);
    }
    const next = new Map(this.records);
    next.delete(keyFor(kind, name));
    this.records = next;
  }

  /** Run the one-click installer for the `brew vulns` subcommand.
      Returns the captured stdout — caller decides whether to toast a
      success message. Errors propagate so the caller can decide
      between toast and inline display. */
  async installHelper(): Promise<string> {
    const stdout = await vulnsInstallHelper();
    // Successful install clears the "not installed" state; the next
    // scan call will populate real records.
    this.lastScanError = null;
    this.lastScanErrorCode = null;
    return stdout;
  }

  /** Wipe all in-memory state. Called when the user toggles the
      feature off via Settings. Does NOT touch the backend disk cache
      — that survives toggle-off so re-enabling later is instant. */
  clear(): void {
    this.records = new Map();
    this.loading = false;
    this.lastScanError = null;
    this.lastScanErrorCode = null;
    this.lastScannedAt = null;
    this.source = null;
    // Reset the once-per-session notification flag so re-enabling the
    // feature can surface the heads-up again.
    this.#hasNotifiedExposure = false;
  }

  /** Surface a one-time-per-session heads-up when the user has known
      vulnerabilities elsewhere in their install. Designed for the "you
      just installed X — by the way, here's the security context of
      your existing install" moment, NOT for app-open or refresh.
      Callers are install / upgrade / upgrade-all action handlers
      (post-scan); refresh paths skip this to avoid noise.

      Throttled to once per app session — the flag resets when the
      feature is toggled off via `clear()` so a user can re-enable and
      see it again. No-op when the feature is disabled or when no
      vulnerable packages are known. */
  maybeNotifyExposure(): void {
    if (this.#hasNotifiedExposure) return;
    if (!this.enabled) return;
    const counts = this.severityCounts;
    if (counts.vulnerablePackages === 0) return;
    this.#hasNotifiedExposure = true;

    // Severity adjective for the title — match the highest tier that
    // has any findings, so a single critical lands harder than "11
    // packages have known vulnerabilities" without it.
    const locale = ui.locale;
    let qualifier = "known";
    if (counts.critical > 0) qualifier = locale === "ru" ? "критическими" : "critical";
    else if (counts.high > 0) qualifier = locale === "ru" ? "высокими" : "high-severity";
    else if (counts.medium > 0) qualifier = locale === "ru" ? "средними" : "medium-severity";
    else if (locale === "ru") qualifier = "известными";

    const noun = counts.vulnerablePackages === 1 ? "package" : "packages";
    const title = locale === "ru"
      ? `${counts.vulnerablePackages} ${ruPlural(counts.vulnerablePackages, "пакет", "пакета", "пакетов")} с ${qualifier} уязвимостями`
      : `${counts.vulnerablePackages} ${noun} with ${qualifier} vulnerabilities`;
    toast.info(
      title,
      locale === "ru" ? "Подробности — в карточке «Уязвимости» на сводке." : "See the Exposure card on the Dashboard for details.",
      {
        label: locale === "ru" ? "Открыть сводку" : "View Dashboard",
        onClick: () => ui.setSection("dashboard"),
      },
    );
  }

  // ----- Private -----

  /** Once-per-app-session guard for `maybeNotifyExposure`. Reset by
      `clear()` so toggle-off + toggle-on can re-surface the heads-up. */
  #hasNotifiedExposure: boolean = false;

  /** Apply a backend `VulnScanReport.entries` payload to the local
      Map. Reassigns the Map so Svelte 5 reactivity fires. */
  #applyReport(
    entries: Record<string, { scannedAt: string; vulns: RawVuln[] }>,
    fallbackScannedAt: Date,
  ): void {
    const next = new Map<string, VulnRecord>();
    for (const [storageKey, record] of Object.entries(entries)) {
      const parsed = parseKey(storageKey);
      if (!parsed) continue;
      next.set(keyFor(parsed.kind, parsed.name), {
        kind: parsed.kind,
        name: parsed.name,
        version: parsed.version,
        scannedAt: record.scannedAt ? new Date(record.scannedAt) : fallbackScannedAt,
        vulns: record.vulns ?? [],
      });
    }
    this.records = next;
  }
}

export const vulnerabilities = new VulnerabilitiesStore();
