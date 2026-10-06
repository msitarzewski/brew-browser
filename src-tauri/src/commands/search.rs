//! `brew_search` and `brew_search_desc` commands.
//!
//! `brew search` does not support `--json=v2`, so we parse plain stdout.
//! Per spec §11.1 recommendation we run formula + cask searches in parallel.

use std::collections::HashSet;

use chrono::Utc;
use tauri::State;

use crate::brew::exec::run_brew_capture;
use crate::brew::parse::parse_search_stdout;
use crate::commands::info::validate_package_name;
use crate::error::BrewError;
use crate::state::AppState;
use crate::types::{PackageKind, SearchHit, SearchResults};

#[tauri::command]
pub async fn brew_search(
    query: String,
    state: State<'_, AppState>,
) -> Result<SearchResults, BrewError> {
    validate_search_query(&query)?;
    let path = state.require_brew_path().await?;

    let path1 = path.clone();
    let path2 = path.clone();
    let q1 = query.clone();
    let q2 = query.clone();

    let f_task = tokio::spawn(async move {
        run_brew_capture(
            &path1,
            &["search", "--formula", &q1],
            "brew search --formula",
        )
        .await
    });
    // Casks are macOS-only; on Linux `brew search --cask` is a guaranteed
    // error (Homebrew has no cask support there), so don't spawn it at all —
    // the cask side of the results is simply empty.
    let c_task = tokio::spawn(async move {
        if cfg!(not(target_os = "macos")) {
            return Ok(String::new());
        }
        run_brew_capture(&path2, &["search", "--cask", &q2], "brew search --cask").await
    });

    let (f_res, c_res) = tokio::join!(f_task, c_task);

    let f_outer = f_res.map_err(|e| BrewError::Internal {
        message: format!("formula search task join: {}", e),
    })?;
    let c_outer = c_res.map_err(|e| BrewError::Internal {
        message: format!("cask search task join: {}", e),
    })?;

    // `brew search --formula <q>` and `brew search --cask <q>` each exit 1
    // (with stderr "Error: No formulae or casks found for ...") when their
    // own kind has zero matches. For a formula-only token like `abcl` the
    // cask side legitimately has nothing — that's a "no match", not an
    // error. Treat each side independently: stdout on success, empty on the
    // "no match" exit pattern, propagate everything else as a real error.
    // If BOTH sides fail in unrelated ways, surface the formula error
    // (matches the order the user is most likely searching for).
    let formula_raw = match f_outer {
        Ok(s) => s,
        Err(e) if is_brew_search_no_match(&e) => String::new(),
        Err(e) => return Err(e),
    };
    let cask_raw = match c_outer {
        Ok(s) => s,
        Err(e) if is_brew_search_no_match(&e) => String::new(),
        Err(e) => return Err(e),
    };

    let installed_set = build_installed_set(&state).await;

    let formulae = parse_search_stdout(&formula_raw)
        .into_iter()
        .map(|name| {
            let installed = installed_set.contains(&name);
            SearchHit {
                installed,
                name,
                kind: PackageKind::Formula,
                description: None,
            }
        })
        .collect();
    let casks = parse_search_stdout(&cask_raw)
        .into_iter()
        .map(|name| {
            let installed = installed_set.contains(&name);
            SearchHit {
                installed,
                name,
                kind: PackageKind::Cask,
                description: None,
            }
        })
        .collect();

    Ok(SearchResults {
        query,
        formulae,
        casks,
        generated_at: Utc::now().to_rfc3339(),
    })
}

#[tauri::command]
pub async fn brew_search_desc(
    query: String,
    state: State<'_, AppState>,
) -> Result<SearchResults, BrewError> {
    validate_search_query(&query)?;
    let path = state.require_brew_path().await?;

    let raw = run_brew_capture(&path, &["search", "--desc", &query], "brew search --desc").await?;

    let installed_set = build_installed_set(&state).await;

    // `brew search --desc` output: lines of `<name>: <desc>`.
    let mut formulae = Vec::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("==>") {
            continue;
        }
        if let Some((name, desc)) = line.split_once(':') {
            let name = name.trim().to_string();
            if name.is_empty() {
                continue;
            }
            let installed = installed_set.contains(&name);
            formulae.push(SearchHit {
                installed,
                name,
                kind: PackageKind::Formula,
                description: Some(desc.trim().to_string()),
            });
        }
    }

    Ok(SearchResults {
        query,
        formulae,
        casks: Vec::new(),
        generated_at: Utc::now().to_rfc3339(),
    })
}

/// Detect the "no matches" exit pattern from `brew search --formula <q>` or
/// `brew search --cask <q>`. brew exits 1 with stderr starting with
/// `"Error: No formulae or casks found for"` when the requested kind has zero
/// hits — that's a "no match", not a real failure. We want the search command
/// to treat this as an empty result on that side, not as a typed error.
fn is_brew_search_no_match(e: &BrewError) -> bool {
    match e {
        BrewError::BrewExitNonZero {
            exit_code,
            stderr_excerpt,
            ..
        } if *exit_code == 1 => stderr_excerpt.contains("No formulae or casks found"),
        _ => false,
    }
}

// ----------------------------------------------------------------------------
// local_search — in-memory union search across name + AI summary + friendly
// name + upstream desc + category labels + (Tier B) tags.
//
// `brew search` only matches package names; `brew search --desc` adds brew's
// own `desc` field. Neither has any knowledge of our local data:
//   - AI-curated `friendlyName` (e.g. "VLC media player" for token `vlc`)
//   - AI summary (1-2 sentence "what + when" description)
//   - Category labels ("AI & ML", "Video & Audio")
//   - Enrichment tags (Tier B)
//
// This command scans everything we have in-process from the catalog +
// enrichment + categories caches. ~16k entries × ~6 fields × substring scan =
// well under 20ms even for 3-term queries. Returns the same `SearchResults`
// shape as `brew_search` so callers can swap with no other changes.
//
// Multi-term queries are AND'd: every term must match at least one field.
// Per-term score = max(weight × match) across fields. Total = sum across
// terms. Cap at TOP_N results to keep the UI list comfortable.
// ----------------------------------------------------------------------------

const LOCAL_SEARCH_TOP_N: usize = 200;

/// Field-match weights. Higher = more authoritative match. Tuned so a
/// query that matches a package's name always outranks one that only
/// matches a free-form description, and category-label matches sit
/// between "name" and "summary" (they're a strong intent signal — the
/// user is asking for a domain — but less specific than a name match).
///
/// The `#[allow(dead_code)]` works around a Rust dead-code analyzer
/// quirk: when these `pub const`s are only referenced from a closure
/// defined inside an `async fn` in the same module, the analyzer
/// sometimes flags them unused even when they're materially in the
/// emitted code. The references at the call sites below are real.
#[allow(dead_code)]
mod weight {
    pub const NAME_EXACT: u32 = 1000;
    pub const NAME_STARTS_WITH: u32 = 700;
    pub const NAME_SUBSTRING: u32 = 500;
    pub const FRIENDLY_NAME: u32 = 350;
    pub const CATEGORY_LABEL: u32 = 280;
    pub const SUMMARY: u32 = 180;
    pub const DESC: u32 = 120;
    pub const TAG: u32 = 100;
}

#[tauri::command]
pub async fn local_search(
    query: String,
    state: State<'_, AppState>,
) -> Result<SearchResults, BrewError> {
    validate_search_query(&query)?;

    // Parse terms: split on whitespace, lowercase, dedupe-by-set, drop empty.
    let mut terms: Vec<String> = query
        .split_whitespace()
        .map(|t| t.to_ascii_lowercase())
        .filter(|t| !t.is_empty())
        .collect();
    terms.sort();
    terms.dedup();
    if terms.is_empty() {
        return Ok(SearchResults {
            query,
            formulae: vec![],
            casks: vec![],
            generated_at: Utc::now().to_rfc3339(),
        });
    }

    // Pull the three in-process caches we'll scan. All three are
    // Arc-cloned out of their respective locks so the rest of this
    // function operates on cheap references with no contention.
    let catalog = {
        let guard = state.catalog.read().await;
        std::sync::Arc::clone(&*guard)
    };
    let enrichment = match crate::commands::enrichment::enrichment_data(state.clone()).await {
        Ok(arc) => Some(arc),
        Err(_) => None, // best-effort; if enrichment fails we just lose AI fields
    };
    let categories = match crate::commands::categories::categories_data(state.clone()).await {
        Ok(arc) => Some(arc),
        Err(_) => None,
    };

    let installed_set = build_installed_set(&state).await;

    // Build a token → Vec<category_label> map once so per-row scoring is
    // a cheap lookup instead of an O(categories) scan per token.
    let mut formula_labels: std::collections::HashMap<&str, Vec<&str>> =
        std::collections::HashMap::new();
    let mut cask_labels: std::collections::HashMap<&str, Vec<&str>> =
        std::collections::HashMap::new();
    if let Some(cat) = categories.as_deref() {
        for (token, slugs) in cat.formulae.iter() {
            let labels: Vec<&str> = slugs
                .iter()
                .filter_map(|s| cat.categories.get(s).map(|m| m.label.as_str()))
                .collect();
            if !labels.is_empty() {
                formula_labels.insert(token.as_str(), labels);
            }
        }
        for (token, slugs) in cat.casks.iter() {
            let labels: Vec<&str> = slugs
                .iter()
                .filter_map(|s| cat.categories.get(s).map(|m| m.label.as_str()))
                .collect();
            if !labels.is_empty() {
                cask_labels.insert(token.as_str(), labels);
            }
        }
    }

    // Per-package scoring. Returns Some((score, description)) when ALL
    // terms find a match somewhere in the package's searchable fields.
    // Description is the best free-text we found for the row (AI summary
    // preferred over upstream desc) so the frontend can show it without
    // a second IPC round-trip.
    let score_pkg =
        |name: &str, desc: Option<&str>, labels: &[&str]| -> Option<(u32, Option<String>)> {
            // AI summary + friendly name from enrichment, if available.
            let entry = enrichment.as_deref().and_then(|e| e.entries.get(name));
            let friendly = entry.and_then(|e| e.friendly_name.as_deref());
            let summary = entry.and_then(|e| e.summary.as_deref());
            let tags: Vec<&str> = entry
                .map(|e| e.tags.iter().map(|s| s.as_str()).collect())
                .unwrap_or_default();

            let name_lc = name.to_ascii_lowercase();
            let desc_lc = desc.map(|s| s.to_ascii_lowercase());
            let friendly_lc = friendly.map(|s| s.to_ascii_lowercase());
            let summary_lc = summary.map(|s| s.to_ascii_lowercase());
            let labels_lc: Vec<String> = labels.iter().map(|s| s.to_ascii_lowercase()).collect();
            let tags_lc: Vec<String> = tags.iter().map(|s| s.to_ascii_lowercase()).collect();

            let mut total: u32 = 0;
            for term in &terms {
                let mut best: u32 = 0;
                // Name match — exact > starts-with > substring.
                if name_lc == *term {
                    best = best.max(weight::NAME_EXACT);
                } else if name_lc.starts_with(term) {
                    best = best.max(weight::NAME_STARTS_WITH);
                } else if name_lc.contains(term) {
                    best = best.max(weight::NAME_SUBSTRING);
                }
                // friendly name substring.
                if let Some(fl) = &friendly_lc {
                    if fl.contains(term) {
                        best = best.max(weight::FRIENDLY_NAME);
                    }
                }
                // category labels — substring on any label.
                for label in &labels_lc {
                    if label.contains(term) {
                        best = best.max(weight::CATEGORY_LABEL);
                        break;
                    }
                }
                // summary substring.
                if let Some(sl) = &summary_lc {
                    if sl.contains(term) {
                        best = best.max(weight::SUMMARY);
                    }
                }
                // desc substring.
                if let Some(dl) = &desc_lc {
                    if dl.contains(term) {
                        best = best.max(weight::DESC);
                    }
                }
                // tag substring.
                for tag in &tags_lc {
                    if tag.contains(term) {
                        best = best.max(weight::TAG);
                        break;
                    }
                }

                if best == 0 {
                    // This term didn't match anywhere — AND semantics means the
                    // whole package is rejected.
                    return None;
                }
                total = total.saturating_add(best);
            }

            // Description to show in the row: AI summary preferred over upstream desc.
            let display_desc = summary
                .map(|s| s.to_string())
                .or_else(|| desc.map(|s| s.to_string()));
            Some((total, display_desc))
        };

    // Score every formula + cask.
    let mut formula_hits: Vec<(u32, SearchHit)> = Vec::new();
    for (token, formula) in catalog.formulae.iter() {
        let labels = formula_labels
            .get(token.as_str())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);
        if let Some((score, desc)) = score_pkg(token, formula.desc.as_deref(), labels) {
            formula_hits.push((
                score,
                SearchHit {
                    name: token.clone(),
                    kind: PackageKind::Formula,
                    installed: installed_set.contains(token),
                    description: desc,
                },
            ));
        }
    }
    let mut cask_hits: Vec<(u32, SearchHit)> = Vec::new();
    for (token, cask) in catalog.casks.iter() {
        let labels = cask_labels
            .get(token.as_str())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);
        if let Some((score, desc)) = score_pkg(token, cask.desc.as_deref(), labels) {
            cask_hits.push((
                score,
                SearchHit {
                    name: token.clone(),
                    kind: PackageKind::Cask,
                    installed: installed_set.contains(token),
                    description: desc,
                },
            ));
        }
    }

    // Sort by score desc, then name asc within ties.
    formula_hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.name.cmp(&b.1.name)));
    cask_hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.name.cmp(&b.1.name)));

    // Apply combined cap, splitting fairly between formulae and casks.
    let (f_final, c_final) = fair_split(formula_hits.len(), cask_hits.len(), LOCAL_SEARCH_TOP_N);

    let formulae: Vec<SearchHit> = formula_hits
        .into_iter()
        .take(f_final)
        .map(|(_, h)| h)
        .collect();
    let casks: Vec<SearchHit> = cask_hits
        .into_iter()
        .take(c_final)
        .map(|(_, h)| h)
        .collect();

    Ok(SearchResults {
        query,
        formulae,
        casks,
        generated_at: Utc::now().to_rfc3339(),
    })
}

/// Split a combined `top_n` result budget across the formula/cask hit counts:
/// take up to half from each, then spill any unused capacity to the longer
/// side. The returned counts always sum to at most `top_n`.
///
/// This replaces an earlier inline split whose spill term double-counted the
/// already-taken side and could return up to ~1.5×`top_n`. Mirrors the native
/// `LocalSearch.fairSplit` so both shells bound results identically.
fn fair_split(formula_len: usize, cask_len: usize, top_n: usize) -> (usize, usize) {
    let f_cap = top_n / 2;
    let c_cap = top_n - f_cap;
    let mut f_final = formula_len.min(f_cap);
    let mut c_final = cask_len.min(c_cap);
    let remaining = top_n - f_final - c_final;
    if remaining > 0 {
        let f_spill = remaining.min(formula_len - f_final);
        f_final += f_spill;
        c_final += (remaining - f_spill).min(cask_len - c_final);
    }
    (f_final, c_final)
}

fn validate_search_query(q: &str) -> Result<(), BrewError> {
    if q.trim().is_empty() {
        return Err(BrewError::InvalidArgument {
            message: "search query is empty".into(),
        });
    }
    if q.len() > 200 {
        return Err(BrewError::InvalidArgument {
            message: "search query is too long".into(),
        });
    }
    // Allow most printable chars; brew search accepts regex,
    // but reject leading `-` to prevent flag injection.
    if q.trim_start().starts_with('-') {
        return Err(BrewError::InvalidArgument {
            message: "search query may not start with '-'".into(),
        });
    }
    Ok(())
}

async fn build_installed_set(state: &AppState) -> HashSet<String> {
    let cache = state.installed_cache.read().await;
    let mut set = HashSet::new();
    if let Some(list) = cache.as_ref() {
        for p in list.formulae.iter().chain(list.casks.iter()) {
            set.insert(p.name.clone());
        }
    }
    set
}

// Suppressed: validate_package_name lives in commands::info; we don't
// reuse it here because search queries are not package names.
#[allow(dead_code)]
fn _force_link_validate_package_name() {
    let _ = validate_package_name("noop");
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::{fair_split, is_brew_search_no_match, validate_search_query};
    use crate::error::BrewError;

    // ---------- fair_split ----------

    #[test]
    fn fair_split_bounds_total_to_top_n_with_spill() {
        // Both sides huge → an even half-and-half split, total == top_n.
        assert_eq!(fair_split(3000, 3000, 200), (100, 100));
        // Few formulae → the unused formula half spills to casks; total == top_n.
        assert_eq!(fair_split(10, 300, 200), (10, 190));
        // Symmetric: few casks → spill to formulae.
        assert_eq!(fair_split(300, 10, 200), (190, 10));
        // Both sides under their half → everything returned, no spill needed.
        assert_eq!(fair_split(3, 2, 200), (3, 2));
    }

    #[test]
    fn fair_split_never_exceeds_top_n() {
        for (f, c) in [(0, 0), (1, 10_000), (10_000, 1), (10_000, 10_000), (99, 101)] {
            let (ff, cf) = fair_split(f, c, 200);
            assert!(ff + cf <= 200, "f={f} c={c} -> {ff}+{cf} > 200");
            assert!(ff <= f && cf <= c);
        }
    }

    // ---------- is_brew_search_no_match ----------

    #[test]
    fn detects_no_match_exit_pattern() {
        let err = BrewError::BrewExitNonZero {
            command: "brew search --cask abcl".into(),
            exit_code: 1,
            stderr_excerpt: "Error: No formulae or casks found for \"abcl\".".into(),
            friendly_message: None,
        };
        assert!(is_brew_search_no_match(&err));
    }

    #[test]
    fn does_not_classify_other_exit_one_as_no_match() {
        let err = BrewError::BrewExitNonZero {
            command: "brew search --formula xyz".into(),
            exit_code: 1,
            stderr_excerpt: "Error: Permission denied".into(),
            friendly_message: None,
        };
        assert!(!is_brew_search_no_match(&err));
    }

    #[test]
    fn does_not_classify_non_brew_errors_as_no_match() {
        assert!(!is_brew_search_no_match(&BrewError::BrewNotFound));
        assert!(!is_brew_search_no_match(&BrewError::InvalidArgument {
            message: "noop".into(),
        }));
    }

    #[test]
    fn does_not_classify_exit_2_as_no_match() {
        // Different exit codes should NOT match — keeps the gate tight to
        // the exact "no match" pattern brew uses.
        let err = BrewError::BrewExitNonZero {
            command: "brew search --formula x".into(),
            exit_code: 2,
            stderr_excerpt: "Error: No formulae or casks found for x".into(),
            friendly_message: None,
        };
        assert!(!is_brew_search_no_match(&err));
    }

    fn err_message(r: Result<(), BrewError>) -> String {
        match r {
            Err(BrewError::InvalidArgument { message }) => message,
            other => panic!("expected InvalidArgument, got {:?}", other),
        }
    }

    // ---------- Happy path ----------

    #[test]
    fn accepts_plain_query() {
        validate_search_query("wget").expect("plain query");
        validate_search_query("python@3").expect("@ ok in query");
        validate_search_query("foo bar").expect("spaces allowed");
        validate_search_query("/regex.*/").expect("regex form allowed");
    }

    #[test]
    fn accepts_query_with_internal_dash() {
        // Internal `-` is fine; only leading `-` is flag-injection territory.
        validate_search_query("foo-bar").expect("internal dash");
        validate_search_query("a-b-c").expect("multi dash");
    }

    // ---------- Empty / oversize ----------

    #[test]
    fn rejects_empty_query() {
        let msg = err_message(validate_search_query(""));
        assert!(msg.contains("empty"), "got {:?}", msg);
    }

    #[test]
    fn rejects_whitespace_only_query() {
        let msg = err_message(validate_search_query("   "));
        assert!(msg.contains("empty"), "got {:?}", msg);
        let msg = err_message(validate_search_query("\t\n"));
        assert!(msg.contains("empty"), "got {:?}", msg);
    }

    #[test]
    fn rejects_oversize_query() {
        let huge = "a".repeat(201);
        let msg = err_message(validate_search_query(&huge));
        assert!(msg.contains("too long"), "got {:?}", msg);
    }

    #[test]
    fn accepts_max_size_query() {
        validate_search_query(&"a".repeat(200)).expect("200 chars allowed");
    }

    // ---------- Flag injection ----------

    #[test]
    fn rejects_leading_dash_query() {
        for s in &["-rm", "--force", "-version", "-"] {
            let msg = err_message(validate_search_query(s));
            assert!(
                msg.contains("may not start with '-'"),
                "input {:?} -> msg {:?}",
                s,
                msg
            );
        }
    }

    #[test]
    fn rejects_leading_dash_with_leading_whitespace() {
        // trim_start().starts_with('-') catches whitespace-prefixed flags.
        let r = validate_search_query("  --force");
        assert!(
            matches!(r, Err(BrewError::InvalidArgument { .. })),
            "whitespace-prefixed flag should be rejected"
        );
    }

    #[test]
    fn allows_internal_dash_after_letter() {
        validate_search_query("a-b").expect("internal dash is fine");
    }
}
