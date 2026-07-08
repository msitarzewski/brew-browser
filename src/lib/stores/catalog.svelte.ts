/**
 * Catalog store (Phase 12a) — wraps the bundled/user-refreshed Homebrew
 * catalog metadata exposed by the 6 `catalog_*` Tauri commands.
 *
 * Owns:
 *   - the cached `CatalogSummary` shown on the Dashboard hero strip
 *   - the in-flight refresh state for the Refresh button
 *   - the derived "is the catalog stale?" gate used by the Discover banner
 *   - per-token lookup wrappers (formula / cask) for any caller that
 *     wants the full record without going through `api.ts` directly
 *
 * The store is intentionally thin: the backend is the source of truth.
 * We never mirror the entire catalog into JS; we cache just the summary
 * + on-demand single-token lookups so the renderer stays light.
 */

import {
  catalogCasksSummary,
  catalogFormulaeSummary,
  catalogLookupCask,
  catalogLookupFormula,
  catalogRefresh,
  catalogSummary,
} from "$lib/api";
import { t } from "$lib/i18n/messages";
import { settings } from "$lib/stores/settings.svelte";
import { ui } from "$lib/stores/ui.svelte";
import { bareToken } from "$lib/util/token";
import {
  brewErrorMessage,
  isBrewError,
  type Cask,
  type CatalogSummary,
  type Formula,
  type PackageKind,
} from "$lib/types";

/**
 * Feature #2 — deprecation status for one token, derived from the
 * bundled-catalog flags. `disabled` is the stronger state; callers
 * pick the badge with `disabled` winning over `deprecated`. `reason`
 * is the catalog reason string (offline baseline) — never a
 * replacement token (the catalog has none).
 */
export interface PackageStatus {
  deprecated: boolean;
  disabled: boolean;
  reason: string | null;
}

class CatalogStore {
  /** Last-known summary, or `null` until `ensureLoaded()` resolves. */
  summary: CatalogSummary | null = $state(null);

  /** True while a `catalog_refresh` IPC call is in flight. UI disables
      the Refresh button on this so a double-click can't queue. */
  refreshing: boolean = $state(false);

  /** Human-readable message from the most recent refresh failure, or
      `null` after a successful refresh / when no refresh has happened. */
  refreshError: string | null = $state(null);

  private summaryLoadPromise: Promise<void> | null = null;

  /**
   * Per-token description maps, populated lazily on first call to
   * `ensureSummariesLoaded()`. Used by `descOf(name, kind)` for the
   * fallback subtitle in the Discover browse list — shows the upstream
   * Homebrew `desc` field when AI Features is off OR the token isn't
   * in the enrichment bundle.
   *
   * Two maps (not one merged) because formula and cask namespaces
   * overlap (e.g., `python` is a formula AND a cask). The Discover
   * row caller already knows the kind, so two-map lookup costs zero.
   */
  private descByFormula: Map<string, string> | null = null;
  private descByCask: Map<string, string> | null = null;
  /** Per-token stable version maps. Same population path as the desc
   *  maps — populated by `ensureSummariesLoaded()`. Powers list views'
   *  Version column for uninstalled packages (installed packages get
   *  their version from `packages.findInstalled(...).installedVersion`
   *  instead). */
  private versionByFormula: Map<string, string> | null = null;
  private versionByCask: Map<string, string> | null = null;
  /** Feature #2 — per-token deprecation status maps, same population
   *  path as the desc/version maps. Discover rows render off
   *  `CatalogEntrySummary` (flags-only — no `Package`), so `statusOf()`
   *  is the source for the row badge there. Keyed by token; `reason` is
   *  the catalog reason string (offline baseline, no replacement). */
  private statusByFormula: Map<string, PackageStatus> | null = null;
  private statusByCask: Map<string, PackageStatus> | null = null;
  private summariesLoadPromise: Promise<void> | null = null;

  /** Lazy-load the catalog summary on first access. Safe to call from
      multiple mount points (the Dashboard hero + the Discover banner
      both read it). */
  async ensureLoaded(): Promise<void> {
    if (this.summary || this.summaryLoadPromise) {
      return this.summaryLoadPromise ?? Promise.resolve();
    }
    this.summaryLoadPromise = (async () => {
      try {
        this.summary = await catalogSummary();
      } catch (e) {
        // Summary load is a pure in-memory backend read — failures here
        // are surprising but should never break the UI shell. Record on
        // refreshError so the Dashboard can surface "catalog unavailable"
        // without throwing.
        this.refreshError = isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e);
      } finally {
        this.summaryLoadPromise = null;
      }
    })();
    return this.summaryLoadPromise;
  }

  /** Trigger a backend refresh. Updates `summary` on success; records
      a typed message on `refreshError` on failure. Handles the two
      domain-specific error codes (`paranoid_mode_blocked` and
      `brew_exit_non_zero`) with friendlier copy than the generic
      `brewErrorMessage` so the user knows exactly what to do. */
  async refresh(): Promise<boolean> {
    if (this.refreshing) return false;
    this.refreshing = true;
    this.refreshError = null;
    try {
      this.summary = await catalogRefresh();
      return true;
    } catch (e) {
      if (isBrewError(e)) {
        switch (e.code) {
          case "paranoid_mode_blocked":
            this.refreshError =
              t("catalog.refresh.offlineBlocked", ui.locale);
            break;
          case "brew_exit_non_zero":
            this.refreshError =
              e.friendlyMessage ?? t("catalog.refresh.brewFailed", ui.locale, { code: e.exitCode });
            break;
          default:
            this.refreshError = brewErrorMessage(e, ui.locale);
        }
      } else {
        this.refreshError = String(e);
      }
      return false;
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * Lazy-load the per-token description maps. Runs once per process;
   * subsequent calls are no-ops (or wait on the in-flight promise).
   * Fast: two IPC round-trips that read pre-parsed in-memory backend
   * state (`catalog_formulae_summary` + `catalog_casks_summary`).
   * Total payload is ~16k records × ~80 bytes = ~1.3 MiB JSON each,
   * roughly 50–150 ms cold then memoised forever.
   */
  async ensureSummariesLoaded(): Promise<void> {
    if (this.descByFormula && this.descByCask) return;
    if (this.summariesLoadPromise) return this.summariesLoadPromise;
    this.summariesLoadPromise = (async () => {
      try {
        const [formulae, casks] = await Promise.all([
          catalogFormulaeSummary(),
          catalogCasksSummary(),
        ]);
        const fm = new Map<string, string>();
        const fv = new Map<string, string>();
        const fs = new Map<string, PackageStatus>();
        for (const e of formulae) {
          if (e.desc) fm.set(e.name, e.desc);
          if (e.version) fv.set(e.name, e.version);
          // Only store a status for tokens that actually carry a flag —
          // keeps the map tiny (a few hundred of ~8k formulae) and a
          // miss reads as "no badge", which is exactly right.
          if (e.deprecated || e.disabled) {
            fs.set(e.name, {
              deprecated: e.deprecated,
              disabled: e.disabled,
              reason: (e.disabled ? e.disableReason : e.deprecationReason) ?? null,
            });
          }
        }
        const cm = new Map<string, string>();
        const cv = new Map<string, string>();
        const cs = new Map<string, PackageStatus>();
        for (const e of casks) {
          if (e.desc) cm.set(e.name, e.desc);
          if (e.version) cv.set(e.name, e.version);
          if (e.deprecated || e.disabled) {
            cs.set(e.name, {
              deprecated: e.deprecated,
              disabled: e.disabled,
              reason: (e.disabled ? e.disableReason : e.deprecationReason) ?? null,
            });
          }
        }
        this.descByFormula = fm;
        this.descByCask = cm;
        this.versionByFormula = fv;
        this.versionByCask = cv;
        this.statusByFormula = fs;
        this.statusByCask = cs;
      } catch {
        // Best-effort; subtitle fallback just stays null on failure.
        this.descByFormula = new Map();
        this.descByCask = new Map();
        this.versionByFormula = new Map();
        this.versionByCask = new Map();
        this.statusByFormula = new Map();
        this.statusByCask = new Map();
      } finally {
        this.summariesLoadPromise = null;
      }
    })();
    return this.summariesLoadPromise;
  }

  /**
   * Sync per-token description lookup. Returns the upstream Homebrew
   * `desc` for a known formula/cask, or `null` when the token isn't in
   * the catalog (or the summary maps haven't loaded yet — caller should
   * have awaited `ensureSummariesLoaded()` first).
   *
   * Used by Discover row rendering as the fallback subtitle when AI
   * Features is off or the enrichment bundle has no friendly name for
   * the token.
   */
  descOf(name: string, kind: PackageKind): string | null {
    const map = kind === "formula" ? this.descByFormula : this.descByCask;
    return map?.get(name) ?? map?.get(bareToken(name)) ?? null;
  }

  /**
   * Sync per-token stable-version lookup. Returns the upstream stable
   * version when known, null otherwise (or when the summary maps
   * haven't loaded yet — caller should `ensureSummariesLoaded()` first).
   *
   * Use for Discover / Trending Version columns to show "what brew
   * would install if you ran `brew install <name>` right now". Library
   * shows `Package.installedVersion` directly (the user's actually-on-
   * disk version) — different concept, same column slot.
   */
  versionOf(name: string, kind: PackageKind): string | null {
    const map = kind === "formula" ? this.versionByFormula : this.versionByCask;
    return map?.get(name) ?? map?.get(bareToken(name)) ?? null;
  }

  /**
   * Feature #2 — sync per-token deprecation-status lookup. Returns the
   * catalog status (deprecated/disabled flags + reason) for a flagged
   * token, or `null` when the token isn't flagged (the common case) or
   * the summary maps haven't loaded yet (caller should
   * `ensureSummariesLoaded()` first).
   *
   * Discover rows render off `CatalogEntrySummary` (no `Package`), so
   * this is the source for the row badge there. PackageDetail uses the
   * richer `Package` flags from `brew info` instead (it also has the
   * replacement token, which the catalog lacks).
   */
  statusOf(name: string, kind: PackageKind): PackageStatus | null {
    const map = kind === "formula" ? this.statusByFormula : this.statusByCask;
    return map?.get(name) ?? map?.get(bareToken(name)) ?? null;
  }

  /** Convenience wrapper around `catalog_lookup_formula`. Returns `null`
      on miss (or on error — callers that need to distinguish should
      invoke `catalogLookupFormula` directly). */
  async lookupFormula(name: string): Promise<Formula | null> {
    try {
      return await catalogLookupFormula(name);
    } catch {
      return null;
    }
  }

  /** Convenience wrapper around `catalog_lookup_cask`. */
  async lookupCask(name: string): Promise<Cask | null> {
    try {
      return await catalogLookupCask(name);
    } catch {
      return null;
    }
  }

  /** Pretty "today" / "1 day old" / "N days old" label for the
      Dashboard hero strip. Returns "—" when the summary hasn't loaded
      yet so the spot doesn't flash empty. */
  get daysOldLabel(): string {
    if (!this.summary) return "—";
    const n = this.summary.daysOld;
    if (n <= 0) return "today";
    if (n === 1) return "1 day old";
    return `${n} days old`;
  }

  /** True when the active catalog is older than the user's stale-banner
      threshold (default 14 days from `settings.catalogStaleBannerDays`).
      Returns `false` until both the summary and the settings are loaded
      so the Discover banner doesn't flash on first paint. */
  get isStale(): boolean {
    if (!this.summary) return false;
    const threshold = settings.effective.catalogStaleBannerDays;
    return this.summary.daysOld > threshold;
  }
}

export const catalog = new CatalogStore();
