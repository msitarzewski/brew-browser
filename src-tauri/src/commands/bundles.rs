//! Bundles command. Returns the curated bundle recipes from the generated
//! `bundles.json`, embedded into the binary at compile time via `include_str!`
//! — the same mechanism the bundled `categories.json` uses (`commands::categories`).
//! No runtime file dependency, no disk read on every call.
//!
//! The `bundles.json` artifact is produced by `scripts/validate-recipes.mjs`
//! (concatenates the validated `recipes/*.json`). This module reads the copy
//! staged at `src-tauri/data/bundles.json`.
//!
//! Tolerant decode: the file is parsed as a JSON value first, then each entry
//! in `bundles[]` is deserialized independently. A single malformed recipe is
//! skipped (logged), never fatal — so one bad live-refreshed recipe can't take
//! down the whole list.

use std::collections::HashMap;

use serde::Deserialize;

use crate::enrichment::normalize_locale;
use crate::types::{Bundle, BundleLink, BundlesFile, SetupStep};

const BUNDLES_JSON: &str = include_str!("../../data/bundles.json");
const BUNDLES_RU_JSON: &str = include_str!("../../data/bundles.ru.json");

/// Locale overlay for user-facing bundle prose. Kept separate from
/// `bundles.json` so recipe IDs, package names, commands, URLs, and the
/// contribution contract remain stable across locales.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BundleLocaleFile {
    locale: String,
    bundles: Vec<BundleLocalePatch>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BundleLocalePatch {
    id: String,
    name: Option<String>,
    tagline: Option<String>,
    description: Option<String>,
    capability_notes: HashMap<String, String>,
    setup: Vec<SetupStepLocalePatch>,
    caveats: Option<String>,
    links: Vec<BundleLinkLocalePatch>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SetupStepLocalePatch {
    index: usize,
    label: Option<String>,
    text: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BundleLinkLocalePatch {
    url: String,
    label: Option<String>,
}

/// Parse a `bundles.json` string into the valid bundles, skipping any single
/// malformed entry. Split out from the command so it's unit-testable without
/// a Tauri runtime.
///
/// Fast path: strict-parse the whole file into [`BundlesFile`] — the common
/// case where every recipe is valid. Only if that fails (a single malformed
/// recipe fails the whole `Vec<Bundle>` decode) do we fall back to a per-entry
/// tolerant parse that salvages the good recipes and skips (logs) the bad one.
/// A completely unparseable file yields an empty list.
///
/// `pub(crate)` so the live-refresh path (`crate::bundles_live`) reuses the
/// exact same tolerant decode on the host-served payload.
pub(crate) fn parse_bundles(json: &str) -> Vec<Bundle> {
    if let Ok(file) = serde_json::from_str::<BundlesFile>(json) {
        return file.bundles;
    }

    // Tolerant fallback: one bad recipe must not sink the batch.
    let root: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("bundles.json is not valid JSON: {e}");
            return Vec::new();
        }
    };

    let Some(entries) = root.get("bundles").and_then(|b| b.as_array()) else {
        tracing::warn!("bundles.json has no `bundles` array");
        return Vec::new();
    };

    entries
        .iter()
        .filter_map(|entry| match serde_json::from_value::<Bundle>(entry.clone()) {
            Ok(bundle) => Some(bundle),
            Err(e) => {
                let id = entry.get("id").and_then(|v| v.as_str()).unwrap_or("<unknown>");
                tracing::warn!("skipping malformed bundle '{id}': {e}");
                None
            }
        })
        .collect()
}

fn localized_overlay_json(locale: &str) -> Option<&'static str> {
    match locale {
        "ru" => Some(BUNDLES_RU_JSON),
        _ => None,
    }
}

fn apply_setup_patch(steps: &mut [SetupStep], patch: &SetupStepLocalePatch) {
    let Some(step) = steps.get_mut(patch.index) else { return };
    if let Some(label) = patch.label.as_ref().filter(|s| !s.is_empty()) {
        step.label = Some(label.clone());
    }
    if let Some(text) = patch.text.as_ref().filter(|s| !s.is_empty()) {
        step.text = Some(text.clone());
    }
}

fn apply_link_patch(links: &mut [BundleLink], patch: &BundleLinkLocalePatch) {
    if patch.url.is_empty() {
        return;
    }
    let Some(label) = patch.label.as_ref().filter(|s| !s.is_empty()) else {
        return;
    };
    if let Some(link) = links.iter_mut().find(|link| link.url == patch.url) {
        link.label = label.clone();
    }
}

fn apply_bundle_patch(bundle: &mut Bundle, patch: &BundleLocalePatch) {
    if let Some(name) = patch.name.as_ref().filter(|s| !s.is_empty()) {
        bundle.name = name.clone();
    }
    if let Some(tagline) = patch.tagline.as_ref().filter(|s| !s.is_empty()) {
        bundle.tagline = tagline.clone();
    }
    if let Some(description) = patch.description.as_ref().filter(|s| !s.is_empty()) {
        bundle.description = Some(description.clone());
    }
    for (key, value) in &patch.capability_notes {
        if !key.is_empty() && !value.is_empty() {
            bundle.capability_notes.insert(key.clone(), value.clone());
        }
    }
    for setup_patch in &patch.setup {
        apply_setup_patch(&mut bundle.setup, setup_patch);
    }
    if let Some(caveats) = patch.caveats.as_ref().filter(|s| !s.is_empty()) {
        bundle.caveats = Some(caveats.clone());
    }
    for link_patch in &patch.links {
        apply_link_patch(&mut bundle.links, link_patch);
    }
}

/// Return a localized copy of bundle data. Unknown locales intentionally return
/// the English source so live recipe refresh and future locale work keep a
/// stable fallback.
pub(crate) fn localized_bundles(bundles: Vec<Bundle>, locale: Option<&str>) -> Vec<Bundle> {
    let normalized = normalize_locale(locale);
    if normalized == "en" {
        return bundles;
    }

    let Some(json) = localized_overlay_json(normalized) else {
        return bundles;
    };
    localized_bundles_with_overlay(bundles, normalized, json)
}

/// Apply an explicit locale overlay to a bundle list. Live bundle refresh uses
/// this only when a matching live overlay was fetched from the same host; it
/// deliberately avoids applying the embedded overlay to potentially newer live
/// recipe prose.
pub(crate) fn localized_bundles_with_overlay(
    mut bundles: Vec<Bundle>,
    normalized_locale: &str,
    overlay_json: &str,
) -> Vec<Bundle> {
    let overlay = match serde_json::from_str::<BundleLocaleFile>(overlay_json) {
        Ok(file) if normalize_locale(Some(&file.locale)) == normalized_locale => file,
        Ok(_) => return bundles,
        Err(e) => {
            tracing::warn!("bundles locale overlay '{normalized_locale}' failed to parse: {e}");
            return bundles;
        }
    };
    let patches: HashMap<String, BundleLocalePatch> = overlay
        .bundles
        .into_iter()
        .filter(|patch| !patch.id.is_empty())
        .map(|patch| (patch.id.clone(), patch))
        .collect();
    for bundle in &mut bundles {
        if let Some(patch) = patches.get(&bundle.id) {
            apply_bundle_patch(bundle, patch);
        }
    }
    bundles
}

/// Return the curated bundles bundled with the app. Infallible — a parse
/// problem degrades to fewer (or zero) bundles rather than erroring the call.
#[tauri::command]
pub async fn bundles(locale: Option<String>) -> Vec<Bundle> {
    localized_bundles(parse_bundles(BUNDLES_JSON), locale.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_bundles_parse() {
        let list = parse_bundles(BUNDLES_JSON);
        assert_eq!(list.len(), 9, "expected 9 first-party bundles");

        // Spot-check local-llm: 2 packages, requires.minRamGB == 8, and a
        // service setup step for ollama.
        let llm = list
            .iter()
            .find(|b| b.id == "local-llm")
            .expect("local-llm bundle must be present");
        assert_eq!(llm.packages.len(), 2, "local-llm has 2 packages");
        assert_eq!(llm.packages[0].name, "ollama");
        assert_eq!(llm.packages[0].kind, "formula");
        let requires = llm.requires.as_ref().expect("local-llm declares requires");
        assert_eq!(requires.min_ram_gb, 8);
        assert!(
            llm.setup.iter().any(|s| s.kind == "service" && s.service.as_deref() == Some("ollama")),
            "local-llm has a service setup step for ollama"
        );
        // The intent paragraph must survive the Rust round-trip to the frontend
        // (the `description` field is on the struct, not silently dropped).
        assert!(
            llm.description.as_deref().is_some_and(|d| !d.is_empty()),
            "local-llm's description paragraph must reach the frontend"
        );

        // Spot-check the agentic bundle: present, carries a description, and
        // includes the coding agent + version control.
        let agentic = list
            .iter()
            .find(|b| b.id == "agentic-web-dev")
            .expect("agentic-web-dev bundle must be present");
        assert!(agentic.description.as_deref().is_some_and(|d| !d.is_empty()));
        assert!(agentic.packages.iter().any(|p| p.name == "opencode"));
        assert!(agentic.packages.iter().any(|p| p.name == "git"));
    }

    #[test]
    fn ru_overlay_localizes_user_facing_fields_only() {
        let list = localized_bundles(parse_bundles(BUNDLES_JSON), Some("ru-RU"));
        let llm = list
            .iter()
            .find(|b| b.id == "local-llm")
            .expect("local-llm bundle must be present");
        assert_eq!(llm.name, "Локальные LLM");
        assert_eq!(llm.packages[0].name, "ollama", "package token stays stable");
        assert_eq!(llm.setup[0].label.as_deref(), Some("Запустить сервер Ollama"));
        assert!(llm
            .capability_notes
            .get("16")
            .is_some_and(|note| note.contains("13–14B")));
    }

    #[test]
    fn malformed_bundle_is_skipped_not_fatal() {
        // Two valid recipes surrounding one that can't deserialize (packages
        // is the wrong shape). The batch must yield the two good ones.
        let json = r#"{
            "schemaVersion": 1,
            "bundles": [
                { "id": "good-one", "name": "Good One", "tagline": "t", "category": "Data", "packages": [{ "name": "redis", "kind": "formula" }] },
                { "id": "bad", "name": "Bad", "packages": "not-an-array" },
                { "id": "good-two", "name": "Good Two", "tagline": "t", "category": "Media", "packages": [{ "name": "mpv", "kind": "formula" }] }
            ]
        }"#;
        let list = parse_bundles(json);
        assert_eq!(list.len(), 2, "the malformed middle recipe is skipped");
        assert_eq!(list[0].id, "good-one");
        assert_eq!(list[1].id, "good-two");
    }

    #[test]
    fn unknown_fields_are_ignored() {
        // Forward-compat: a recipe from a newer schema (extra top-level key)
        // still parses; the unknown field is dropped.
        let json = r#"{
            "schemaVersion": 2,
            "bundles": [
                { "id": "fut", "name": "Future", "tagline": "t", "category": "AI",
                  "packages": [{ "name": "ollama", "kind": "formula" }],
                  "somethingNew": { "nested": true } }
            ]
        }"#;
        let list = parse_bundles(json);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "fut");
    }

    #[test]
    fn empty_on_garbage_input() {
        assert!(parse_bundles("not json at all").is_empty());
        assert!(parse_bundles(r#"{ "schemaVersion": 1 }"#).is_empty());
    }
}
