/**
 * Bundles M5 — frontend guard for the live-refresh result.
 *
 * The backend (`bundles_live`) already applies the fail-soft parse rules
 * (unparseable / newer-than-supported schema → error; malformed entries
 * skipped). This is the one decision the frontend owns: whether a successful
 * live result should REPLACE the bundled set. An empty result must never wipe
 * the shipped recipes, so only a non-empty list replaces.
 */
import type { Bundle } from "$lib/types";

export function shouldReplaceWithLive(live: Bundle[]): boolean {
  return live.length > 0;
}
