/**
 * partialUpgrade.ts — recognize a bulk `brew upgrade` that mostly SUCCEEDED but
 * exited non-zero because one or more individual packages errored.
 *
 * `brew upgrade` (especially `--greedy`, which targets self-updating casks)
 * routinely upgrades dozens of packages and then exits status 1 because a cask
 * needed `sudo` to delete old files, or its app was removed, or it's
 * incompatible with the OS. The blunt exit-code check then shows a scary
 * "Upgrade failed" even though almost everything upgraded — the single largest
 * source of misfiled "[brew-browser] Upgrade(-all) failed" reports.
 *
 * `classifyPartialUpgrade` is a PURE function of a failed {@link ActivityJob}:
 * it reads brew's own output for the "Upgraded N packages" summary and the
 * per-package `Error: <name>: …` lines, so the UI can report the real outcome
 * ("Upgraded 74 · 2 had errors") and offer a per-package "Run in Terminal"
 * button (where sudo can actually prompt). Mirrors `recovery.ts`'s shape.
 */

import type { ActivityJob } from "$lib/types";

export interface PartialUpgrade {
  /** Count of packages brew reported upgrading (0 when not parseable). */
  upgraded: number;
  /** Package tokens that errored, in first-seen order, de-duped. */
  failures: string[];
}

// "==> Upgraded 74 outdated packages" / "Upgraded 3 packages".
const UPGRADED_SUMMARY = /Upgraded\s+(\d+)\s+(?:outdated\s+)?packages?/i;
// "==> Upgrading <token>" — fallback count when no summary line is present.
const UPGRADING_LINE = /^==>\s*Upgrading\s+(\S+)/;
// "Error: miniconda: …" / "Error: temurin@17: …" — a per-package failure. The
// token charset matches a brew package name (incl. @version and tap/ paths);
// the trailing ": " is what distinguishes it from "Error: Refusing to load …".
const ERROR_LINE = /^Error:\s+([A-Za-z0-9@._+/-]+):\s/;

/**
 * Classify a failed `brew upgrade` job as a partial success, or null when it
 * isn't one. Null means: not a failed upgrade, no exit code (our own spawn
 * failure — stays a report), or no named per-package failures to act on (falls
 * through to the generic "Homebrew error" notice). Pure — safe in a `$derived`.
 */
export function classifyPartialUpgrade(job: ActivityJob): PartialUpgrade | null {
  // brew ran and exited non-zero. No exit code = IPC/spawn failure (our bug).
  if (job.status !== "failed" || job.exitCode == null) return null;
  // Only the upgrade path — install/uninstall failures go to recovery.ts.
  if (!/\bupgrade\b/.test(job.command)) return null;

  const lines = job.lines.map((l) => l.text);
  const failures: string[] = [];
  let upgrading = 0;
  for (const raw of lines) {
    const line = raw.trim();
    const err = line.match(ERROR_LINE);
    if (err && !failures.includes(err[1])) failures.push(err[1]);
    if (UPGRADING_LINE.test(line)) upgrading += 1;
  }

  // No actionable per-package failure → let the generic notice handle it.
  if (failures.length === 0) return null;

  const summary = lines.join("\n").match(UPGRADED_SUMMARY);
  const upgraded = summary
    ? parseInt(summary[1], 10)
    : Math.max(0, upgrading - failures.length);

  return { upgraded, failures };
}
