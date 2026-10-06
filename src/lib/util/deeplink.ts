/**
 * Deep-link parsing for the `brewbrowser://` URL scheme.
 *
 * Supported form: `brewbrowser://bundle/<id>` → open the Bundles section on the
 * matching bundle (e.g. `brewbrowser://bundle/local-llm`). Kept as a pure,
 * side-effect-free function so it can be unit-tested without the Tauri runtime
 * — mirroring the Rust/native deep-link helpers. The caller validates `<id>`
 * against the loaded bundle catalog and owns all navigation.
 *
 * This is INBOUND parsing (a link the OS handed us), distinct from the outbound
 * scheme allowlist in `url.ts` (what we hand to the opener).
 */

export type DeepLinkTarget = { kind: "bundle"; id: string };

/**
 * Parse a `brewbrowser://` URL into a navigation target, or `null` when it is
 * malformed or not a shape we handle. Never throws.
 *
 * Tolerates both `brewbrowser://bundle/<id>` (host = `bundle`) and
 * `brewbrowser:///bundle/<id>` (empty host, `bundle` as the first path segment),
 * since different platforms normalize the authority differently.
 */
export function parseDeepLink(raw: string): DeepLinkTarget | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "brewbrowser:") return null;

  const segments = [url.hostname, ...url.pathname.split("/")].filter(Boolean);
  if (segments[0] !== "bundle") return null;

  const id = segments[1] ? decodeURIComponent(segments[1]) : "";
  if (!id) return null;

  return { kind: "bundle", id };
}
