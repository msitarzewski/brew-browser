//! HTTP client for the opt-in *live* Bundles refresh (v0.7.0).
//!
//! Mirrors `enrichment::live` / `trending::history::client`: a small soft-fail
//! GET client against the same first-party static host, a distinct `/bundles/*`
//! path. The `Settings::live_bundles_enabled` toggle authorizes a call here and
//! the master `paranoid_mode` / Offline Mode switch hard-blocks it regardless
//! (both enforced by `AppState::require_live_bundles`).
//!
//! Endpoint (published by the M5 release/publish job):
//!   GET /bundles/bundles.json  → the concatenated recipe set (same shape as
//!                                the bundled `bundles.json`)
//!
//! Fail-soft everywhere: any error — 404 (the endpoint may not exist yet),
//! network, unparseable payload, or a `schemaVersion` newer than this build
//! supports — leaves the app on its bundled copy. An empty payload never wipes
//! the shipped set (the store replaces only on a non-empty result).

use std::time::Duration;

use tauri::State;

use crate::commands::bundles::{localized_bundles_with_overlay, parse_bundles};
use crate::enrichment::normalize_locale;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::Bundle;

/// Subpath on `brew-browser.zerologic.com` — the same first-party host as Live
/// enrichment / Enhanced Trending (public, disclosed in `README.md` +
/// `memory-bank/security.md`), a distinct `/bundles/*` path. Not a Homebrew
/// endpoint; its own trust boundary.
const BASE: &str = "https://brew-browser.zerologic.com/bundles";

/// 10s, matching the enrichment / trending-history clients. Static JSON from
/// Caddy — a slow response means the upstream is wedged, not that more time helps.
const TIMEOUT: Duration = Duration::from_secs(10);

/// Highest `schemaVersion` this build understands. A live payload declaring a
/// newer schema is refused (fail-soft to the bundled copy) so a forward-schema
/// push can't feed this build a shape it can't safely read. Matches the
/// bundled `bundles.json` (`schemaVersion: 1`).
pub const SUPPORTED_SCHEMA_VERSION: u64 = 1;

/// Tauri command: fetch + parse the live bundles. Gated on the opt-in toggle
/// AND network (paranoid/offline) via `require_live_bundles`. Returns the
/// parsed bundles on success; the frontend replaces its list only when the
/// result is non-empty. Every failure mode is an `Err` the store swallows,
/// keeping the bundled copy.
#[tauri::command]
pub async fn bundles_live(
    locale: Option<String>,
    state: State<'_, AppState>,
) -> Result<Vec<Bundle>, BrewError> {
    state.require_live_bundles().await?;
    let body = fetch_bundles_text().await?;
    let bundles = parse_live_payload(&body)?;
    let normalized = normalize_locale(locale.as_deref());
    if normalized == "en" {
        return Ok(bundles);
    }
    match fetch_bundles_locale_text(normalized).await {
        Ok(overlay) => Ok(localized_bundles_with_overlay(bundles, normalized, &overlay)),
        Err(e) => {
            tracing::warn!("live bundles locale overlay '{normalized}' unavailable: {e}");
            Ok(bundles)
        }
    }
}

/// Parse a host-served `bundles.json` body with the M5 fail-soft rules:
///   - unparseable top-level JSON → `Err` (keep bundled),
///   - `schemaVersion` > [`SUPPORTED_SCHEMA_VERSION`] → `Err` (keep bundled),
///   - otherwise → `Ok(bundles)` using the SAME tolerant per-entry decode as
///     the bundled loader ([`parse_bundles`]): a single malformed recipe is
///     skipped, not fatal. The list may be empty; the caller decides whether
///     to replace (it must not on empty).
///
/// Pure (no I/O) so the fail-soft matrix is unit-testable without a network.
pub fn parse_live_payload(json: &str) -> Result<Vec<Bundle>, BrewError> {
    // Top-level must be valid JSON; anything else is a keep-bundled failure.
    let root: serde_json::Value = serde_json::from_str(json).map_err(|e| BrewError::Network {
        url: format!("{BASE}/bundles.json"),
        message: format!("live bundles.json is not valid JSON: {e}"),
    })?;

    // A newer-than-supported schema means the shape may have changed
    // incompatibly — refuse and keep the bundled copy (fail-soft).
    let schema = root.get("schemaVersion").and_then(|v| v.as_u64()).unwrap_or(0);
    if schema > SUPPORTED_SCHEMA_VERSION {
        return Err(BrewError::Internal {
            message: format!(
                "live bundles.json schemaVersion {schema} is newer than supported \
                 ({SUPPORTED_SCHEMA_VERSION}); keeping bundled copy"
            ),
        });
    }

    // Same tolerant decode as the bundled loader (M2): skip malformed entries.
    Ok(parse_bundles(json))
}

/// `GET /bundles/bundles.json` → raw body text (so `parse_live_payload` can run
/// the tolerant decode). Mirrors the enrichment client's `get_json`, but keeps
/// the body as text rather than decoding into a fixed type.
async fn fetch_bundles_text() -> Result<String, BrewError> {
    let url = format!("{BASE}/bundles.json");
    fetch_text(&url).await
}

async fn fetch_bundles_locale_text(locale: &str) -> Result<String, BrewError> {
    let url = format!("{BASE}/bundles.{locale}.json");
    fetch_text(&url).await
}

async fn fetch_text(url: &str) -> Result<String, BrewError> {
    let client = build_client()?;
    let resp = client.get(url).send().await.map_err(|e| {
        if let Some(status) = e.status() {
            BrewError::HttpStatus {
                url: url.to_string(),
                status: status.as_u16(),
            }
        } else {
            BrewError::Network {
                url: url.to_string(),
                message: e.to_string(),
            }
        }
    })?;

    let status = resp.status();
    if !status.is_success() {
        return Err(BrewError::HttpStatus {
            url: url.to_string(),
            status: status.as_u16(),
        });
    }

    resp.text().await.map_err(|e| BrewError::Network {
        url: url.to_string(),
        message: format!("reading response body failed: {e}"),
    })
}

fn build_client() -> Result<reqwest::Client, BrewError> {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .user_agent(concat!(
            "brew-browser/",
            env!("CARGO_PKG_VERSION"),
            " (+https://github.com/msitarzewski/brew-browser)"
        ))
        .build()
        .map_err(|e| BrewError::Network {
            url: BASE.into(),
            message: e.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_TWO: &str = r#"{
        "schemaVersion": 1,
        "bundles": [
            { "id": "a", "name": "A", "tagline": "t", "category": "Data",
              "packages": [{ "name": "redis", "kind": "formula" }] },
            { "id": "b", "name": "B", "tagline": "t", "category": "Media",
              "packages": [{ "name": "mpv", "kind": "formula" }] }
        ]
    }"#;

    #[test]
    fn newer_schema_keeps_bundled() {
        // schemaVersion 2 > supported 1 → refuse (Err), even though the
        // bundles array is otherwise valid.
        let json = r#"{ "schemaVersion": 2, "bundles": [
            { "id": "a", "name": "A", "tagline": "t", "category": "AI",
              "packages": [{ "name": "ollama", "kind": "formula" }] } ] }"#;
        assert!(parse_live_payload(json).is_err(), "newer schema must keep bundled");
    }

    #[test]
    fn valid_current_schema_replaces() {
        // A valid schema-1 payload (a newer DATA push) parses and replaces.
        let out = parse_live_payload(VALID_TWO).expect("valid payload parses");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, "a");
        assert_eq!(out[1].id, "b");
    }

    #[test]
    fn malformed_top_level_falls_back() {
        assert!(parse_live_payload("{ not json at all").is_err());
        assert!(parse_live_payload("<html>404</html>").is_err());
    }

    #[test]
    fn one_malformed_entry_is_skipped_rest_kept() {
        // Same tolerance as the bundled loader: the bad middle recipe is
        // dropped, the two good ones survive.
        let json = r#"{ "schemaVersion": 1, "bundles": [
            { "id": "good1", "name": "G1", "tagline": "t", "category": "Data",
              "packages": [{ "name": "redis", "kind": "formula" }] },
            { "id": "bad", "name": "Bad", "packages": "not-an-array" },
            { "id": "good2", "name": "G2", "tagline": "t", "category": "Media",
              "packages": [{ "name": "mpv", "kind": "formula" }] }
        ] }"#;
        let out = parse_live_payload(json).expect("valid top-level parses");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, "good1");
        assert_eq!(out[1].id, "good2");
    }

    #[test]
    fn empty_payload_yields_empty_not_error() {
        // An empty (but well-formed) payload parses to an empty list — the
        // store guards against replacing the shipped set with nothing.
        let json = r#"{ "schemaVersion": 1, "bundles": [] }"#;
        let out = parse_live_payload(json).expect("empty is well-formed");
        assert!(out.is_empty());
    }
}
