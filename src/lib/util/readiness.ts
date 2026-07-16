/**
 * Bundles M1 — pure readiness gate.
 *
 * Turns `(bundle.requires, capabilityNotes, profile) → verdict + reason` with
 * no IPC, so it's vitest-able directly. This is the SHARED parity algorithm:
 * the Rust/TS and Swift shells must produce byte-identical verdicts + reason
 * strings for identical inputs. The canonical spec + expected strings live in
 * `test-fixtures/readiness-cases.json` (the `_comment` field) — that fixture
 * is the source of truth; keep this in lockstep with it and the Swift port.
 */

import type {
  BundleRequires,
  Readiness,
  SystemProfile,
} from "$lib/types";

/** Human label for an arch value, used in the "Built for {ArchLabel}." reason. */
function archLabel(arch: BundleRequires["arch"]): string {
  switch (arch) {
    case "apple-silicon":
      return "Apple Silicon";
    case "intel":
      return "Intel";
    case "linux":
      return "Linux";
    default:
      return arch;
  }
}

/**
 * Capability note for the largest integer tier key `≤ ram`, or `null` when
 * there are no notes or `ram` is below the smallest key. Keys are strings in
 * the JSON (`{ "8": "...", "16": "..." }`) — parsed to ints for comparison.
 */
function nearestTierNote(
  capabilityNotes: Record<string, string> | null,
  ram: number,
): string | null {
  if (!capabilityNotes) {
    return null;
  }
  let bestKey = -1;
  let bestNote: string | null = null;
  for (const [key, note] of Object.entries(capabilityNotes)) {
    const tier = parseInt(key, 10);
    if (Number.isNaN(tier)) {
      continue;
    }
    if (tier <= ram && tier > bestKey) {
      bestKey = tier;
      bestNote = note;
    }
  }
  return bestNote;
}

/**
 * Readiness verdict for a bundle against the host profile.
 *
 * Order (matches the fixture exactly):
 *   1. no `requires`             → ready ("Ready.")
 *   2. arch mismatch             → blocked ("Built for {ArchLabel}.")
 *   3. ram < minRamGB            → blocked ("Needs ≥{min} GB RAM (you have {ram} GB).")
 *   4. freeDiskGB < minDiskGB    → blocked ("Needs ≥{min} GB free disk (you have {free} GB).")
 *   5. ram < recommendedRamGB    → marginal (nearest tier note ?? generic)
 *   6. else                      → ready (nearest tier note ?? "Ready.")
 */
export function readiness(
  requires: BundleRequires | null,
  capabilityNotes: Record<string, string> | null,
  profile: SystemProfile,
): Readiness {
  if (requires === null) {
    return { verdict: "ready", reason: "Ready." };
  }

  if (requires.arch !== "any" && requires.arch !== profile.arch) {
    return { verdict: "blocked", reason: `Built for ${archLabel(requires.arch)}.` };
  }

  if (profile.ramGB < requires.minRamGB) {
    return {
      verdict: "blocked",
      reason: `Needs ≥${requires.minRamGB} GB RAM (you have ${profile.ramGB} GB).`,
    };
  }

  if (profile.freeDiskGB < requires.minDiskGB) {
    return {
      verdict: "blocked",
      reason: `Needs ≥${requires.minDiskGB} GB free disk (you have ${profile.freeDiskGB} GB).`,
    };
  }

  const note = nearestTierNote(capabilityNotes, profile.ramGB);

  if (profile.ramGB < requires.recommendedRamGB) {
    return {
      verdict: "marginal",
      reason: note ?? `Below the recommended ${requires.recommendedRamGB} GB — may be slow.`,
    };
  }

  return { verdict: "ready", reason: note ?? "Ready." };
}
