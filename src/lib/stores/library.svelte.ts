/**
 * Library tab view state. Lifted out of the component so other surfaces
 * (Dashboard's "Updates available" card, command palette in future) can
 * preset the filter before navigating.
 *
 * The state survives section switches within a session but is not persisted
 * to localStorage — by design. Reloading the app returns to the default
 * "All" view.
 */

export type LibraryFilter =
  | "all"
  | "formulae"
  | "casks"
  | "outdated"
  /** #90 — show only pinned packages (held back from `brew upgrade`).
      Keys on `Package.pinned` (formulae + casks). Always available. */
  | "pinned"
  /** Feature #3 — installed-on-request ("Manual") vs installed-as-a-
      dependency-only ("Dependency"). Both key on the per-keg brew flags
      carried on `Package` (`installedOnRequest` / `installedAsDependency`).
      Platform-agnostic — they apply to formulae, which exist on Linux, so
      (unlike the Casks pill) they are NOT dropped under `isLinux`. Installed
      casks always report on-request=true, so they only ever match Manual. */
  | "manual"
  | "dependency"
  /** v0.5.0 — show only packages with at least one known vulnerability.
      The pill is hidden in the UI when `vulnerabilities.enabled` is false
      (no point showing a filter for data we don't have); jumping into
      this filter via the Dashboard "View vulnerable packages →" link
      first ensures the feature is enabled. */
  | "vulnerable";

/**
 * Feature #3 predicates — the single source of truth for the Manual /
 * Dependency split, shared by the Library filter switch and the pill
 * counts so the two can never drift.
 *
 * Semantics (parity contract, must match the native shell):
 *   - MANUAL    = the keg's `installedOnRequest` flag is true.
 *   - DEPENDENCY = `installedAsDependency` is true AND `installedOnRequest`
 *                  is false. The on-request exclusion makes the two filters
 *                  mutually exclusive: a both-flags-true package (user asked
 *                  for something that is also a dep of another) counts as
 *                  Manual only. Dependency is formula-only in practice —
 *                  installed casks always report on-request=true upstream.
 *
 * A package with neither flag set (rare/legacy kegs) matches neither — it
 * still shows under All. We never fabricate a default flag.
 *
 * Predicates only read `Package` flags, so they live here as plain pure
 * functions (no `$state`, no IPC) and are trivially unit-testable.
 */
export function isManual(p: PackageFlags): boolean {
  return p.installedOnRequest;
}

export function isDependencyOnly(p: PackageFlags): boolean {
  return p.installedAsDependency && !p.installedOnRequest;
}

/** Minimal shape the Feature #3 predicates read — a structural subset of
 *  `Package` so the predicates (and their tests) don't drag the full DTO. */
export interface PackageFlags {
  installedOnRequest: boolean;
  installedAsDependency: boolean;
}

class LibraryStore {
  filter: LibraryFilter = $state("all");

  setFilter(f: LibraryFilter) {
    this.filter = f;
  }
}

export const library = new LibraryStore();
