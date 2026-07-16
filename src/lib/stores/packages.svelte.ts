/**
 * Installed-package store. Backed by `brew_list`.
 * Provides lookups (by name/kind) used across detail panel, palette, trending.
 */

import { brewList } from "$lib/api";
import { isBrewError, type Package, type PackageList } from "$lib/types";

class PackagesStore {
  list: PackageList | null = $state(null);
  loading: boolean = $state(false);
  error: string | null = $state(null);
  lastLoadedAt: number | null = $state(null);

  formulae = $derived(this.list?.formulae ?? []);
  casks    = $derived(this.list?.casks ?? []);
  all      = $derived([...this.formulae, ...this.casks]);

  outdated = $derived(this.all.filter((p) => p.outdated));

  /**
   * Outdated packages that aren't pinned — the honest "updates available" set
   * (#90/#134). A pinned package may have a newer version, but the user has
   * deliberately held it back and `brew upgrade` skips it, so it must not
   * inflate the nag count or the "Upgrade all" set. Lists that want to *show*
   * pinned-but-outdated rows (with a pin badge) still use `outdated`.
   */
  outdatedUpgradable = $derived(this.outdated.filter((p) => !p.pinned));

  async load(force = false) {
    if (this.loading) return;
    if (!force && this.list && this.lastLoadedAt && Date.now() - this.lastLoadedAt < 5_000) {
      return; // micro-cache
    }
    this.loading = true;
    this.error = null;
    try {
      this.list = await brewList(force);
      this.lastLoadedAt = Date.now();
    } catch (e) {
      if (isBrewError(e)) {
        this.error = e.code === "brew_not_found"
          ? "Homebrew was not found on this Mac."
          : `Failed to load packages: ${JSON.stringify(e)}`;
      } else {
        // backend not running yet, or invoke threw a non-BrewError
        this.error = `Backend not available: ${String(e)}`;
      }
    } finally {
      this.loading = false;
    }
  }

  isInstalled(name: string, kind: "formula" | "cask"): boolean {
    return this.all.some((p) => p.name === name && p.kind === kind);
  }

  findInstalled(name: string, kind: "formula" | "cask"): Package | undefined {
    return this.all.find((p) => p.name === name && p.kind === kind);
  }
}

export const packages = new PackagesStore();
