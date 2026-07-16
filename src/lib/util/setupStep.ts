/**
 * Bundles M4 — setup-step rendering mode.
 *
 * Maps a `SetupStep.kind` to how the bundle detail renders it:
 *   - "action": a brew-native step with an in-app button (service/open/reveal).
 *   - "copy":   an external `command` — copy-to-clipboard ONLY, never executed
 *               (the recipe contract requires `external: true`; the app must
 *               never run arbitrary shell).
 *   - "note":   informational text.
 *
 * Unknown kinds fall back to "note" (rendered as inert text) so a
 * forward-compat recipe never grows an unexpected action button.
 */
export type StepMode = "action" | "copy" | "note";

export function stepMode(kind: string): StepMode {
  switch (kind) {
    case "service":
    case "open":
    case "reveal":
      return "action";
    case "command":
      return "copy";
    default:
      return "note";
  }
}
