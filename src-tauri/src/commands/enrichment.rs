//! Enrichment commands (Phase 13).
//!
//! Surfaces the bundled `enrichment.json.gz` payload via two IPC
//! commands. Both delegate to the parser in
//! [`crate::enrichment::EnrichmentData`] — there is no runtime LLM
//! traffic; the bundle is the canonical artifact.
//!
//! See `commands::categories` for the parallel pattern used by the
//! Phase 9 categories payload — both modules memoise the parsed
//! payload on `AppState` so the parse happens once per process.

use std::sync::Arc;

use tauri::State;

use crate::commands::info::validate_package_name;
use crate::enrichment::{normalize_locale, EnrichmentData, EnrichmentEntry};
use crate::error::BrewError;
use crate::state::AppState;

/// Return the full enrichment payload. Memoised on `AppState` so
/// subsequent calls are an Arc-clone, not a re-parse.
#[tauri::command]
pub async fn enrichment_data(
    locale: Option<String>,
    state: State<'_, AppState>,
) -> Result<Arc<EnrichmentData>, BrewError> {
    let locale = normalize_locale(locale.as_deref());
    if locale != "en" {
        {
            let cached = state.enrichment_locale_cache.lock().await;
            if let Some(data) = cached.get(locale) {
                return Ok(Arc::clone(data));
            }
        }

        let base = enrichment_base_data(state.clone()).await?;
        let localized = Arc::new(EnrichmentData::localized(&base, Some(locale))?);
        let mut cached = state.enrichment_locale_cache.lock().await;
        cached.insert(locale.to_string(), Arc::clone(&localized));
        return Ok(localized);
    }

    enrichment_base_data(state).await
}

async fn enrichment_base_data(
    state: State<'_, AppState>,
) -> Result<Arc<EnrichmentData>, BrewError> {
    {
        let cached = state.enrichment_cache.lock().await;
        if let Some(data) = cached.as_ref() {
            return Ok(Arc::clone(data));
        }
    }

    let arc = EnrichmentData::load()?;
    let mut cached = state.enrichment_cache.lock().await;
    *cached = Some(Arc::clone(&arc));
    Ok(arc)
}

/// Lookup a single token. Returns `None` when the token is missing
/// (placeholder bundle, unmapped package, etc.). Validates the input
/// name first so an IPC caller can't probe with shell metacharacters.
#[tauri::command]
pub async fn enrichment_lookup(
    name: String,
    locale: Option<String>,
    state: State<'_, AppState>,
) -> Result<Option<EnrichmentEntry>, BrewError> {
    validate_package_name(&name)?;
    let data = enrichment_data(locale, state).await?;
    Ok(data.entries.get(&name).cloned())
}

// ---------- Live enrichment (opt-in) ----------
//
// Fresh categories/descriptions from brew-browser.zerologic.com/enrichment/*.
// Each command is gated by `require_live_enrichment` (paranoid + per-feature
// toggle) and soft-fails — the frontend overlays the result on the bundled
// baseline and ignores errors (keeps bundled). Mirrors `trending_history_*`.

/// Freshness probe — the frontend polls this on catalog refresh to decide
/// whether to pull a newer categories file or invalidate per-token caches.
#[tauri::command]
pub async fn enrichment_live_version(
    state: State<'_, AppState>,
) -> Result<crate::enrichment::live::LiveEnrichmentVersion, BrewError> {
    state.require_live_enrichment().await?;
    crate::enrichment::live::fetch_version().await
}

/// Full live categories file. Frontend pulls it only when the probe's
/// `categoriesVersion` is newer than the version it already holds.
#[tauri::command]
pub async fn enrichment_live_categories(
    state: State<'_, AppState>,
) -> Result<crate::commands::categories::CategoriesData, BrewError> {
    state.require_live_enrichment().await?;
    crate::enrichment::live::fetch_categories().await
}

/// Per-token live enrichment, fetched on demand for packages the app shows.
#[tauri::command]
pub async fn enrichment_live_entry(
    name: String,
    state: State<'_, AppState>,
) -> Result<EnrichmentEntry, BrewError> {
    state.require_live_enrichment().await?;
    crate::enrichment::live::fetch_entry(&name).await
}
