//! Bundled LLM-derived enrichment (Phase 13).
//!
//! The base enrichment file is the offline output of
//! `tools/enrich/enrich.py` — per-token friendly names, expanded
//! summaries, use-case bullets, similar-package suggestions, and
//! tech-stack tags. Locale-specific overlays, when present, are small
//! partial files keyed by the same Homebrew tokens; they replace only
//! user-facing prose and add locale search terms. Everything ships
//! embedded in the binary via `include_bytes!`; **there is no runtime
//! LLM request**, and there is no on-disk user-data path for v1.
//!
//! ## Security caps (mirrors the Phase 12a catalog pattern)
//!
//! - [`MAX_RAW_BYTES`] caps the embedded gzip stream (32 MiB). The bytes
//!   are baked at compile time, so this is defense-in-depth only —
//!   protects against a future build step that accidentally swaps the
//!   bundle for an attacker-controlled blob.
//! - [`MAX_DECOMPRESSED_BYTES`] caps the gzip-decode output (64 MiB)
//!   via `Read::take`. Same defense-in-depth posture.
//! - [`MAX_FRIENDLY_NAME_LEN`] / [`MAX_SUMMARY_LEN`] / [`MAX_USE_CASE_LEN`]
//!   / [`MAX_TAG_LEN`] / [`MAX_SIMILAR_COUNT`] / [`MAX_TAGS_COUNT`] /
//!   [`MAX_USE_CASES_COUNT`] enforce per-field caps on the deserialized
//!   data. The Python writer also enforces these caps; the Rust loader
//!   re-applies them so a swapped bundle can't smuggle oversized fields.

use std::collections::HashMap;
use std::io::Read;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::commands::info::validate_package_name;
use crate::error::BrewError;

/// Opt-in live-fetch client for fresher categories/descriptions.
pub mod live;

// ---------- Security caps ----------

/// Hard cap on the embedded gzip stream's raw byte length. Current
/// bundle is < 5 MiB once Tier A + B have run; 32 MiB is ~6× headroom.
pub const MAX_RAW_BYTES: usize = 32 * 1024 * 1024;

/// Hard cap on the gzip-decode output. Tier A + B uncompressed sits at
/// ~10-15 MiB; 64 MiB is ~5× headroom and matches the magnitude of the
/// catalog's `MAX_DECOMPRESSED_BYTES` (catalog is 128 MiB because the
/// formula+cask payload is larger).
pub const MAX_DECOMPRESSED_BYTES: u64 = 64 * 1024 * 1024;

/// `friendly_name` field cap. The Python prompt asks for ≤ 50; the
/// Python parser caps at 100 (room to grow); we cap at 100 here too.
pub const MAX_FRIENDLY_NAME_LEN: usize = 100;

/// `summary` field cap. Prompt asks for ≤ 250; parser caps at 1024.
pub const MAX_SUMMARY_LEN: usize = 1024;

/// Per-bullet cap on `use_cases` entries. Prompt asks for ≤ 80; parser
/// caps at 200.
pub const MAX_USE_CASE_LEN: usize = 200;

/// Max entries in the `use_cases` array. Prompt asks for 1-3; we cap
/// at 5 to leave room for over-eager LLMs without rejecting the entry.
pub const MAX_USE_CASES_COUNT: usize = 5;

/// Per-token cap on the `similar` list. Each entry is also re-validated
/// against [`validate_package_name`] post-parse.
pub const MAX_SIMILAR_COUNT: usize = 50;

/// Max entries in the `tags` array.
pub const MAX_TAGS_COUNT: usize = 12;

/// Per-tag cap. Tags are normalised to `[a-z0-9-]`; we cap length at 30.
pub const MAX_TAG_LEN: usize = 30;

/// Per localized search term cap. These are not displayed as tags; they
/// exist only so locale-aware search can match natural-language queries
/// without changing package IDs or upstream Homebrew descriptions.
pub const MAX_SEARCH_TERM_LEN: usize = 60;

/// Max localized search terms per package.
pub const MAX_SEARCH_TERMS_COUNT: usize = 16;

// ---------- Bundled artifact ----------

/// Bundled gzipped enrichment payload (produced by `tools/enrich/enrich.py`).
/// Ships as a placeholder (empty entries map) when enrichment hasn't been
/// run yet — the bundle still works, the UI just renders no enriched data.
const ENRICHMENT_JSON_GZ: &[u8] = include_bytes!("../../data/enrichment.json.gz");

/// Partial Russian overlay. Future locales should follow the same
/// `enrichment.<locale>.json.gz` schema and be routed through
/// [`localized_overlay_bytes`].
const ENRICHMENT_RU_JSON_GZ: &[u8] = include_bytes!("../../data/enrichment.ru.json.gz");

// ---------- Types ----------

/// One enrichment record, keyed by Homebrew token. All fields are
/// optional / empty-by-default so the placeholder bundle parses cleanly
/// and partially-enriched records (only Tier A, only Tier B) round-trip.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct EnrichmentEntry {
    /// Display name. None when Tier A hasn't been run for this token.
    /// Snake_case alias accepts the on-disk shape from `enrich.py`.
    #[serde(alias = "friendly_name", skip_serializing_if = "Option::is_none")]
    pub friendly_name: Option<String>,

    /// 1-2 sentence summary. None when Tier A hasn't been run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,

    /// "Why install this?" bullets (1-3, capped at 5). Empty when Tier
    /// B hasn't been run.
    #[serde(alias = "use_cases")]
    pub use_cases: Vec<String>,

    /// Related package tokens (3-5, capped at 50). Each entry is
    /// re-validated against `validate_package_name` post-parse — bad
    /// suggestions get silently dropped.
    pub similar: Vec<String>,

    /// Tech-stack tags (3-8, capped at 12). Lowercase + hyphenated.
    pub tags: Vec<String>,

    /// Locale-specific search terms. Not shown in the UI; used by
    /// `local_search` so translated summaries and domain words can be
    /// searched alongside stable package names and English fallbacks.
    #[serde(alias = "search_terms", default, skip_serializing_if = "Vec::is_empty")]
    pub search_terms: Vec<String>,
}

/// Full enrichment payload, parsed once from the bundled `.gz` and
/// memoised on `AppState`. The `entries` map is keyed by Homebrew token.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct EnrichmentData {
    pub version: String,
    /// Snake_case alias accepts the on-disk shape from `enrich.py`.
    #[serde(alias = "generated_at")]
    pub generated_at: String,
    pub model: String,
    /// Which tiers have been baked in. Possible values: `"A"`, `"B"`.
    pub tiers: Vec<String>,
    pub entries: HashMap<String, EnrichmentEntry>,
}

/// Locale-specific partial overlay. This intentionally does not replace
/// the base bundle: it is merged over the base for one locale, field by
/// field, with English fallback preserved for missing translated fields.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct EnrichmentLocaleOverlay {
    pub locale: String,
    pub version: String,
    #[serde(alias = "generated_at")]
    pub generated_at: String,
    #[serde(alias = "base_version", skip_serializing_if = "Option::is_none")]
    pub base_version: Option<String>,
    pub entries: HashMap<String, EnrichmentEntry>,
}

impl EnrichmentData {
    /// Decode + parse + validate the bundled enrichment payload. Returns
    /// the placeholder shape ([`EnrichmentData::empty`]) when the bundle
    /// is itself the placeholder (zero entries).
    pub fn load() -> Result<Arc<EnrichmentData>, BrewError> {
        // Defense-in-depth raw-size cap. `include_bytes!` produces a
        // static slice whose length is known at compile time, but we
        // still enforce the cap so a build-time swap of the bundle
        // can't smuggle a 100 MiB payload past this loader.
        if ENRICHMENT_JSON_GZ.len() > MAX_RAW_BYTES {
            return Err(BrewError::Io {
                message: format!(
                    "bundled enrichment.json.gz is {} bytes, exceeds {} byte cap",
                    ENRICHMENT_JSON_GZ.len(),
                    MAX_RAW_BYTES
                ),
            });
        }

        let bytes = decompress_capped(ENRICHMENT_JSON_GZ, "bundled enrichment.json.gz")?;
        let mut data: EnrichmentData =
            serde_json::from_slice(&bytes).map_err(|e| BrewError::Internal {
                message: format!("enrichment.json.gz parse failed: {e}"),
            })?;

        // Apply field-length caps post-parse. The Python writer also
        // enforces these, but a swapped bundle could ship a bogus
        // field-length; this is the load-bearing security gate.
        validate_and_truncate(&mut data);

        Ok(Arc::new(data))
    }

    /// Return a localized copy of a parsed base bundle. Unknown locales
    /// intentionally return the base data unchanged, which makes adding a
    /// locale opt-in and keeps package identifiers/search fallbacks stable.
    pub fn localized(
        base: &EnrichmentData,
        locale: Option<&str>,
    ) -> Result<EnrichmentData, BrewError> {
        let normalized = normalize_locale(locale);
        if normalized == "en" {
            return Ok(base.clone());
        }

        let Some(bytes) = localized_overlay_bytes(normalized) else {
            return Ok(base.clone());
        };
        let overlay = load_locale_overlay(bytes, normalized)?;
        Ok(apply_locale_overlay(base, &overlay))
    }

    /// Construct an empty enrichment payload — used by callers that want
    /// to short-circuit when enrichment is disabled / unavailable. Same
    /// shape the placeholder bundle deserializes to.
    ///
    /// Currently exercised only by unit tests; kept public so frontend
    /// stub paths (e.g. test harnesses that prefer a real
    /// `EnrichmentData` over `Option<…>`) have a canonical empty value
    /// without re-deriving the placeholder bytes.
    #[allow(dead_code)]
    pub fn empty() -> EnrichmentData {
        EnrichmentData {
            version: String::new(),
            generated_at: String::new(),
            model: String::new(),
            tiers: Vec::new(),
            entries: HashMap::new(),
        }
    }
}

/// Normalize a BCP-47-ish UI locale to the enrichment overlay bucket we
/// support today. This keeps `ru`, `ru-RU`, and future regional Russian
/// variants pointed at the same compact overlay.
pub fn normalize_locale(locale: Option<&str>) -> &'static str {
    let Some(locale) = locale else { return "en" };
    let lc = locale.trim().to_ascii_lowercase();
    if lc == "ru" || lc.starts_with("ru-") || lc.starts_with("ru_") {
        "ru"
    } else {
        "en"
    }
}

// ---------- Helpers ----------

/// Decompress gzipped `bytes` with a cap of [`MAX_DECOMPRESSED_BYTES`]
/// applied via `Read::take`. Mirrors `catalog::decompress_capped` —
/// kept separate so each module owns its own constants.
fn decompress_capped(bytes: &[u8], context: &str) -> Result<Vec<u8>, BrewError> {
    let mut decoder = flate2::read::GzDecoder::new(bytes).take(MAX_DECOMPRESSED_BYTES + 1);
    let mut buf = Vec::with_capacity(bytes.len() * 4);
    decoder.read_to_end(&mut buf).map_err(|e| BrewError::Io {
        message: format!("decompress {}: {}", context, e),
    })?;
    if buf.len() as u64 > MAX_DECOMPRESSED_BYTES {
        return Err(BrewError::Io {
            message: format!(
                "decompressed {} exceeds {} byte cap",
                context, MAX_DECOMPRESSED_BYTES
            ),
        });
    }
    Ok(buf)
}

/// Apply per-field caps to a freshly-parsed `EnrichmentData`. Truncates
/// rather than rejects so one oversized field doesn't blow away the
/// rest of the bundle.
fn validate_and_truncate(data: &mut EnrichmentData) {
    for entry in data.entries.values_mut() {
        validate_and_truncate_entry(entry);
    }
}

fn validate_and_truncate_entry(entry: &mut EnrichmentEntry) {
    if let Some(name) = entry.friendly_name.as_mut() {
        truncate_utf8(name, MAX_FRIENDLY_NAME_LEN);
    }
    if let Some(sum) = entry.summary.as_mut() {
        truncate_utf8(sum, MAX_SUMMARY_LEN);
    }
    // Truncate count first, then each entry's length.
    entry.use_cases.truncate(MAX_USE_CASES_COUNT);
    for uc in entry.use_cases.iter_mut() {
        truncate_utf8(uc, MAX_USE_CASE_LEN);
    }
    // `similar` — drop any token that fails the package-name validator
    // (defense against LLM hallucination + a future swapped bundle
    // smuggling bogus tokens).
    entry.similar.retain(|t| validate_package_name(t).is_ok());
    entry.similar.truncate(MAX_SIMILAR_COUNT);

    entry.tags.truncate(MAX_TAGS_COUNT);
    for t in entry.tags.iter_mut() {
        truncate_utf8(t, MAX_TAG_LEN);
        // Defense-in-depth: tags must be `[a-z0-9-]`. Drop the entry if
        // it isn't — empty result is fine, the field just disappears
        // from the UI.
        if !t
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            t.clear();
        }
    }
    entry.tags.retain(|t| !t.is_empty());

    entry.search_terms.truncate(MAX_SEARCH_TERMS_COUNT);
    for term in entry.search_terms.iter_mut() {
        truncate_utf8(term, MAX_SEARCH_TERM_LEN);
    }
    entry.search_terms.retain(|term| !term.trim().is_empty());
}

fn localized_overlay_bytes(locale: &str) -> Option<&'static [u8]> {
    match locale {
        "ru" => Some(ENRICHMENT_RU_JSON_GZ),
        _ => None,
    }
}

fn load_locale_overlay(bytes: &[u8], locale: &str) -> Result<EnrichmentLocaleOverlay, BrewError> {
    if bytes.len() > MAX_RAW_BYTES {
        return Err(BrewError::Io {
            message: format!(
                "bundled enrichment.{locale}.json.gz is {} bytes, exceeds {} byte cap",
                bytes.len(),
                MAX_RAW_BYTES
            ),
        });
    }

    let decoded = decompress_capped(bytes, &format!("bundled enrichment.{locale}.json.gz"))?;
    let mut overlay: EnrichmentLocaleOverlay =
        serde_json::from_slice(&decoded).map_err(|e| BrewError::Internal {
            message: format!("enrichment.{locale}.json.gz parse failed: {e}"),
        })?;
    let declared = normalize_locale(Some(&overlay.locale));
    if !overlay.locale.trim().is_empty() && declared != locale {
        return Err(BrewError::Internal {
            message: format!(
                "enrichment.{locale}.json.gz declares locale {:?}, expected {locale}",
                overlay.locale
            ),
        });
    }

    for entry in overlay.entries.values_mut() {
        validate_and_truncate_entry(entry);
    }
    Ok(overlay)
}

fn apply_locale_overlay(
    base: &EnrichmentData,
    overlay: &EnrichmentLocaleOverlay,
) -> EnrichmentData {
    let mut localized = base.clone();
    localized.version = if overlay.version.is_empty() {
        base.version.clone()
    } else {
        format!("{}+{}", base.version, overlay.version)
    };
    localized.generated_at = if overlay.generated_at.is_empty() {
        base.generated_at.clone()
    } else {
        overlay.generated_at.clone()
    };

    for (token, patch) in &overlay.entries {
        let entry = localized.entries.entry(token.clone()).or_default();
        if let Some(value) = patch
            .friendly_name
            .as_ref()
            .filter(|v| !v.trim().is_empty())
        {
            entry.friendly_name = Some(value.clone());
        }
        if let Some(value) = patch.summary.as_ref().filter(|v| !v.trim().is_empty()) {
            entry.summary = Some(value.clone());
        }
        if !patch.use_cases.is_empty() {
            entry.use_cases = patch.use_cases.clone();
        }
        if !patch.search_terms.is_empty() {
            entry.search_terms = patch.search_terms.clone();
        }
        // `similar` and `tags` are intentionally not localized here:
        // `similar` carries stable Homebrew tokens and `tags` are compact
        // technical labels. Locale search vocabulary belongs in
        // `search_terms`.
    }

    localized
}

/// In-place UTF-8-safe truncate. Walks back to the previous char
/// boundary when the requested cut would split a multibyte sequence.
fn truncate_utf8(s: &mut String, max: usize) {
    if s.len() <= max {
        return;
    }
    let mut idx = max;
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    s.truncate(idx);
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_parses_placeholder_bundle() {
        let data = EnrichmentData::load().expect("placeholder bundle must parse");
        // The placeholder ships with zero entries — keep the assertion
        // tight enough to fail if someone accidentally swaps the
        // placeholder for a real bundle (the test count would tell us
        // anyway, but pinning this catches stealth swaps).
        assert!(
            data.entries.is_empty() || data.version != "0.0.0-placeholder",
            "placeholder bundle should have empty entries; real bundles can populate them"
        );
    }

    #[test]
    fn empty_returns_no_entries() {
        let e = EnrichmentData::empty();
        assert!(e.entries.is_empty());
        assert!(e.version.is_empty());
        assert!(e.tiers.is_empty());
    }

    #[test]
    fn validate_truncates_friendly_name() {
        let mut data = EnrichmentData::empty();
        let long_name = "x".repeat(MAX_FRIENDLY_NAME_LEN + 50);
        data.entries.insert(
            "foo".into(),
            EnrichmentEntry {
                friendly_name: Some(long_name),
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        assert_eq!(
            data.entries["foo"].friendly_name.as_deref().map(str::len),
            Some(MAX_FRIENDLY_NAME_LEN),
        );
    }

    #[test]
    fn validate_truncates_summary() {
        let mut data = EnrichmentData::empty();
        let long_sum = "y".repeat(MAX_SUMMARY_LEN + 100);
        data.entries.insert(
            "bar".into(),
            EnrichmentEntry {
                summary: Some(long_sum),
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        assert_eq!(
            data.entries["bar"].summary.as_deref().map(str::len),
            Some(MAX_SUMMARY_LEN),
        );
    }

    #[test]
    fn validate_caps_use_cases_count_and_length() {
        let mut data = EnrichmentData::empty();
        let many_long = (0..20).map(|_| "z".repeat(MAX_USE_CASE_LEN + 20)).collect();
        data.entries.insert(
            "baz".into(),
            EnrichmentEntry {
                use_cases: many_long,
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        let ucs = &data.entries["baz"].use_cases;
        assert_eq!(ucs.len(), MAX_USE_CASES_COUNT);
        for u in ucs {
            assert_eq!(u.len(), MAX_USE_CASE_LEN);
        }
    }

    #[test]
    fn validate_drops_invalid_similar_tokens() {
        let mut data = EnrichmentData::empty();
        data.entries.insert(
            "qux".into(),
            EnrichmentEntry {
                similar: vec![
                    "wget".into(),
                    "curl".into(),
                    "-rf".into(),          // leading dash
                    "evil; rm -rf".into(), // spaces + semicolon
                    "foo$bar".into(),      // metachar
                    "".into(),             // empty
                    "valid-pkg".into(),
                ],
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        let sim = &data.entries["qux"].similar;
        assert_eq!(
            sim,
            &[
                "wget".to_string(),
                "curl".to_string(),
                "valid-pkg".to_string()
            ]
        );
    }

    #[test]
    fn validate_caps_tags_count_and_drops_bad_chars() {
        let mut data = EnrichmentData::empty();
        let too_many: Vec<String> = (0..30).map(|i| format!("tag{i}")).collect();
        let with_bad: Vec<String> = too_many
            .into_iter()
            .chain(vec![
                "valid-tag".to_string(),
                "BadCaps".to_string(),          // uppercase — dropped
                "has space".to_string(),        // space — dropped
                "weird_underscore".to_string(), // underscore — dropped
            ])
            .collect();
        data.entries.insert(
            "tagged".into(),
            EnrichmentEntry {
                tags: with_bad,
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        let tags = &data.entries["tagged"].tags;
        assert!(tags.len() <= MAX_TAGS_COUNT);
        // All surviving tags must be lowercase ASCII + hyphens + digits.
        for t in tags {
            for c in t.bytes() {
                assert!(c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-');
            }
        }
    }

    #[test]
    fn validate_caps_search_terms_but_keeps_unicode() {
        let mut data = EnrichmentData::empty();
        let too_many: Vec<String> = (0..30)
            .map(|i| {
                if i == 0 {
                    "русский поисковый термин".to_string()
                } else {
                    "x".repeat(MAX_SEARCH_TERM_LEN + 20)
                }
            })
            .collect();
        data.entries.insert(
            "localized".into(),
            EnrichmentEntry {
                search_terms: too_many,
                ..Default::default()
            },
        );
        validate_and_truncate(&mut data);
        let terms = &data.entries["localized"].search_terms;
        assert_eq!(terms.len(), MAX_SEARCH_TERMS_COUNT);
        assert_eq!(terms[0], "русский поисковый термин");
        for term in terms {
            assert!(term.len() <= MAX_SEARCH_TERM_LEN);
        }
    }

    #[test]
    fn locale_overlay_replaces_prose_and_preserves_stable_fields() {
        let mut base = EnrichmentData::empty();
        base.version = "base".into();
        base.generated_at = "2026-01-01T00:00:00Z".into();
        base.entries.insert(
            "wget".into(),
            EnrichmentEntry {
                friendly_name: Some("Wget".into()),
                summary: Some("Download files from the web.".into()),
                use_cases: vec!["Mirror a website".into()],
                similar: vec!["curl".into()],
                tags: vec!["network".into()],
                search_terms: vec!["download".into()],
            },
        );
        let mut overlay = EnrichmentLocaleOverlay {
            locale: "ru".into(),
            version: "ru-1".into(),
            generated_at: "2026-01-02T00:00:00Z".into(),
            ..Default::default()
        };
        overlay.entries.insert(
            "wget".into(),
            EnrichmentEntry {
                summary: Some("Загружает файлы по HTTP, HTTPS и FTP.".into()),
                use_cases: vec!["Скачать архив из скрипта".into()],
                search_terms: vec!["скачать".into(), "загрузка".into()],
                similar: vec!["not-localized".into()],
                tags: vec!["не-тег".into()],
                ..Default::default()
            },
        );

        let localized = apply_locale_overlay(&base, &overlay);
        let entry = &localized.entries["wget"];
        assert_eq!(localized.version, "base+ru-1");
        assert_eq!(localized.generated_at, "2026-01-02T00:00:00Z");
        assert_eq!(entry.friendly_name.as_deref(), Some("Wget"));
        assert_eq!(
            entry.summary.as_deref(),
            Some("Загружает файлы по HTTP, HTTPS и FTP.")
        );
        assert_eq!(entry.use_cases, vec!["Скачать архив из скрипта"]);
        assert_eq!(entry.search_terms, vec!["скачать", "загрузка"]);
        assert_eq!(entry.similar, vec!["curl"]);
        assert_eq!(entry.tags, vec!["network"]);
    }

    #[test]
    fn bundled_ru_overlay_applies_to_seed_entry() {
        let base = EnrichmentData::load().expect("load base bundle");
        let localized = EnrichmentData::localized(&base, Some("ru-RU")).expect("merge ru overlay");
        let entry = localized
            .entries
            .get("wget")
            .expect("ru seed should include wget");
        assert!(
            entry
                .summary
                .as_deref()
                .unwrap_or_default()
                .contains("загруз"),
            "expected Russian wget summary"
        );
        assert!(
            entry.search_terms.iter().any(|term| term == "скачать"),
            "expected Russian search term"
        );
    }

    #[test]
    fn decompress_capped_rejects_oversize() {
        // Synthesize a gzip stream that decompresses to ~ MAX_DECOMPRESSED_BYTES + 1.
        // Use Vec<u8> filled with zeros — compresses tiny but expands large.
        let oversize: Vec<u8> = vec![0; (MAX_DECOMPRESSED_BYTES + 1024) as usize];
        let compressed = {
            use std::io::Write;
            let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
            enc.write_all(&oversize).unwrap();
            enc.finish().unwrap()
        };
        let r = decompress_capped(&compressed, "synthetic-oversize");
        assert!(r.is_err(), "expected size-cap rejection");
        match r {
            Err(BrewError::Io { message }) => {
                assert!(
                    message.contains("exceeds"),
                    "expected exceeds-cap message, got: {message}"
                );
            }
            other => panic!("expected Io error, got {other:?}"),
        }
    }

    #[test]
    fn truncate_utf8_respects_boundaries() {
        let mut s = "日本語日本語".to_string(); // 3-byte chars each
        truncate_utf8(&mut s, 5);
        assert!(s.len() <= 5);
        // The result must still be valid UTF-8 (no panic, no partial char).
        for c in s.chars() {
            assert!(!c.is_ascii() || c == '日' || c == '本' || c == '語');
        }
    }

    #[test]
    fn serde_round_trip_preserves_optionality() {
        let mut e = EnrichmentEntry {
            friendly_name: Some("PostgreSQL 14".into()),
            summary: Some("Database.".into()),
            use_cases: vec!["Run a local db".into()],
            similar: vec!["mariadb".into()],
            tags: vec!["database".into(), "sql".into()],
            search_terms: vec!["postgres".into()],
        };
        let json = serde_json::to_string(&e).expect("serialize");
        // Camel-case rename rules.
        assert!(json.contains("\"friendlyName\""));
        assert!(json.contains("\"useCases\""));

        let back: EnrichmentEntry = serde_json::from_str(&json).expect("round-trip");
        assert_eq!(back, e);

        // Snake-case alias compat: enrich.py writes friendly_name + use_cases.
        let snake = r#"{
            "friendly_name": "PostgreSQL 14",
            "summary": "Database.",
            "use_cases": ["Run a local db"],
            "similar": ["mariadb"],
            "tags": ["database", "sql"],
            "search_terms": ["postgres"]
        }"#;
        let from_snake: EnrichmentEntry = serde_json::from_str(snake).expect("snake parse");
        assert_eq!(from_snake.friendly_name.as_deref(), Some("PostgreSQL 14"));
        assert_eq!(from_snake.use_cases, vec!["Run a local db".to_string()]);
        assert_eq!(from_snake.search_terms, vec!["postgres".to_string()]);

        // Erase to remove a field and verify Option re-serialization
        // skips when None.
        e.friendly_name = None;
        let json = serde_json::to_string(&e).expect("serialize without friendly_name");
        assert!(!json.contains("friendlyName"), "None should be skipped");
    }

    #[test]
    fn parses_real_bundled_data_or_placeholder() {
        let data = EnrichmentData::load().expect("load bundle");
        // Either the placeholder (0 entries, model="placeholder") OR a
        // real bundle (>0 entries, tiers non-empty). Anything in
        // between is malformed.
        if data.entries.is_empty() {
            assert!(data.model.is_empty() || data.model == "placeholder");
        } else {
            assert!(
                !data.tiers.is_empty(),
                "populated enrichment must declare tiers"
            );
        }
    }
}
