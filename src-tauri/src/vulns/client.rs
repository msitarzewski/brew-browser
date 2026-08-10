//! Subprocess wrapper around the official `brew vulns` subcommand.
//!
//! `brew vulns` ships from `Homebrew/homebrew-brew-vulns` (installed as
//! a tap subcommand) and queries OSV.dev via its GIT ecosystem,
//! mapping each installed formula's source URL + version tag to known
//! CVEs / GHSAs. We shell out to it rather than re-implementing the
//! OSV query layer so we inherit upstream improvements automatically
//! (the maintainer ships fixes when OSV schema or coverage changes).
//!
//! ## JSON shape — defensive parsing
//!
//! The exact `--json` output schema is not pinned by a captured fixture
//! yet (brew-vulns isn't installed in CI). Every field carries
//! `#[serde(default)]` so unknown / missing keys absorb cleanly, and
//! [`Severity`] has a `#[serde(other)]` catch-all so unrecognized levels
//! render as `unknown` rather than failing the whole scan. A real-output
//! fixture lands in Step 2 QA and may tighten this shape.
//!
//! ## Outbound paths
//!
//! `brew vulns` itself talks to:
//! - `api.osv.dev` (Google) — vulnerability lookup by source repo
//! - `api.github.com` / `gitlab.com` / `codeberg.org` — source URL +
//!   version tag resolution
//!
//! All of these are gated by [`crate::state::AppState::require_vulnerability_scanning`]
//! at the IPC layer — Offline Mode + per-feature toggle compose
//! identically to the trending-history pattern.

use std::path::Path;
use std::process::Stdio;

use serde::{Deserialize, Deserializer, Serialize};

use crate::brew::exec::{brew_command, run_brew_capture};
use crate::error::{truncate_tail, BrewError};

/// Tolerant subprocess wrapper for `brew vulns`. Differs from
/// [`run_brew_capture`] in one critical way: it treats exit code **1
/// as success** because brew-vulns follows the standard CI-scanner
/// convention — exit 0 means "scan succeeded, no findings", exit 1
/// means "scan succeeded, findings present", exit ≥ 2 is a real
/// error. Without this distinction we'd throw away the JSON output
/// on every install that actually has vulnerabilities (the common case).
///
/// Stdout is captured and returned regardless. Stderr is captured only
/// for inclusion in the error excerpt when exit ≥ 2.
async fn run_vulns_capture(
    brew: &Path,
    args: &[&str],
    display_command: &str,
) -> Result<String, BrewError> {
    let mut cmd = brew_command(brew);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let output = cmd.output().await.map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
        _ => BrewError::Io {
            message: format!("failed to spawn brew: {e}"),
        },
    })?;

    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let exit = output.status.code().unwrap_or(-1);

    // Exit 0 OR 1 → return stdout. Exit ≥ 2 (or signal-killed = -1)
    // → real failure, surface the typed error like run_brew_capture.
    if exit == 0 || exit == 1 {
        return Ok(stdout);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let excerpt = truncate_tail(stderr.trim_end(), MAX_STDERR_EXCERPT);
    Err(BrewError::BrewExitNonZero {
        command: display_command.to_string(),
        exit_code: exit,
        stderr_excerpt: excerpt,
        friendly_message: Some(
            "brew vulns failed unexpectedly. See Activity drawer for details.".into(),
        ),
    })
}

/// Canonical install command for `brew vulns`. Surfaced in the
/// `VulnsNotInstalled` error so the frontend "Install brew-vulns"
/// affordance shows the exact command the user (or our own
/// install-helper IPC) will run.
pub const BREW_VULNS_INSTALL_CMD: &str = "brew update";

/// Hard cap on stderr captured into error excerpts. Matches
/// [`crate::brew::exec`]'s constant so error shapes stay uniform.
const MAX_STDERR_EXCERPT: usize = 4096;

// ----- Wire types (brew vulns --json) -----

/// Severity level reported by `brew vulns`. The wire format is
/// UPPERCASE strings (`"HIGH"`, `"MEDIUM"`, `"LOW"`, `"CRITICAL"`,
/// `"UNKNOWN"`) — pinned by the real-output fixture in
/// [`tests::raw_scan_result_parses_real_brew_vulns_output`]. We
/// serialize as lowercase for the wire-to-frontend hop (the frontend
/// store + tone mapping use lowercase) and accept either case on
/// deserialize so we're robust to a future formatting shift.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Critical,
    High,
    Medium,
    Low,
    /// Catch-all for severities we don't recognize (e.g. a future OSV
    /// addition or a brew-vulns formatting change). Renders as
    /// "unknown" in the UI rather than disappearing.
    Unknown,
}

impl<'de> Deserialize<'de> for Severity {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        // Accept any case + any unknown value. brew vulns ships UPPERCASE
        // (HIGH/MEDIUM/...) but OSV API and possible future formats might
        // use other casings — case-fold once at the boundary so the rest
        // of the codebase never has to think about it.
        let raw: Option<String> = Option::deserialize(d)?;
        Ok(
            match raw.as_deref().map(str::to_ascii_lowercase).as_deref() {
                Some("critical") => Severity::Critical,
                Some("high") => Severity::High,
                Some("medium") | Some("moderate") => Severity::Medium,
                Some("low") => Severity::Low,
                _ => Severity::Unknown,
            },
        )
    }
}

impl Default for Severity {
    fn default() -> Self {
        Severity::Unknown
    }
}

/// One vulnerability entry from `brew vulns --json`. Field shape pinned
/// by the real-output fixture in
/// [`tests::raw_scan_result_parses_real_brew_vulns_output`].
///
/// Wire shape uses snake_case (`fixed_versions`, not `fixedIn`) and a
/// few fields can be null (`summary`). We map those to camelCase + safe
/// defaults at this boundary so the rest of the codebase (cache,
/// enrich, frontend) sees a single canonical shape.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawVuln {
    /// CVE, GHSA, or OSV identifier (e.g. `CVE-2024-1234`,
    /// `GHSA-xxxx-xxxx-xxxx`, `OSV-2023-1328`). Empty string when the
    /// upstream entry has no canonical ID — should be rare in practice.
    pub id: String,

    /// Severity label. brew vulns ships UPPERCASE; case-folded at parse
    /// time via the custom [`Severity`] deserializer.
    pub severity: Severity,

    /// One-line title. brew vulns sends `null` when no summary is
    /// available; mapped to empty string for ergonomic frontend
    /// handling (the frontend already treats "" as "no summary").
    #[serde(deserialize_with = "string_or_null")]
    pub summary: String,

    /// Multi-line body. brew vulns doesn't currently expose this — it's
    /// populated by the [`crate::vulns::enrich`] layer when GHSA
    /// enrichment is on and the ID is a GHSA-prefixed entry.
    pub details: String,

    /// Patched version. brew vulns sends `fixed_versions: [String]`
    /// (often empty); we surface the first entry as a scalar for the
    /// frontend's "Upgrade to fix" affordance — almost all OSV entries
    /// carry zero or one, and the "earliest patch" is what matters.
    ///
    /// Serialized to camelCase `fixedIn` for the frontend.
    #[serde(
        rename = "fixed_versions",
        alias = "fixedVersions",
        alias = "fixedIn",
        deserialize_with = "first_string_or_none"
    )]
    pub fixed_in: Option<String>,

    /// External references — typically the advisory URL and links to
    /// the upstream commit / patch. brew vulns doesn't currently expose
    /// this; populated by GHSA enrichment.
    pub references: Vec<String>,

    /// ISO-8601 timestamp when the advisory was first published. brew
    /// vulns doesn't currently expose this; populated by GHSA
    /// enrichment.
    pub published: Option<String>,
}

/// Map JSON `null` or missing → `String::new()`. Used for `summary`
/// since brew vulns sends explicit `null` for entries OSV hasn't
/// summarized.
fn string_or_null<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let v: Option<String> = Option::deserialize(d)?;
    Ok(v.unwrap_or_default())
}

/// Map JSON `[String]` → `Option<String>` taking the first element.
/// Used for `fixed_versions` since brew vulns sends an array but the
/// frontend treats patched-version as a scalar (first-patch wins).
/// Empty array or missing → `None`. Defensive: also accepts a bare
/// string (in case a future brew vulns release switches the shape).
fn first_string_or_none<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    use serde::de::Error;
    use serde_json::Value;
    let v = Value::deserialize(d)?;
    match v {
        Value::Null => Ok(None),
        Value::String(s) => Ok(if s.is_empty() { None } else { Some(s) }),
        Value::Array(arr) => Ok(arr
            .into_iter()
            .find_map(|x| x.as_str().map(|s| s.to_string()))),
        other => Err(D::Error::custom(format!(
            "fixed_versions: expected null|string|array, got {other:?}"
        ))),
    }
}

/// One `brew vulns` scan record for a single installed formula. The
/// `vulnerabilities` vec is empty when the formula was scanned and
/// nothing was found — that's a positive "clean at this version"
/// signal, distinct from "no scan record exists".
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawScanResult {
    pub formula: String,
    pub version: String,
    pub vulnerabilities: Vec<RawVuln>,
}

// ----- Subprocess wrappers -----

/// Probe whether the `brew vulns` subcommand is available. Runs
/// `brew commands --include-aliases` and grep-checks the listing —
/// fast (no scanning, no network) and unambiguous regardless of
/// brew-vulns version.
///
/// Returns:
/// - `Ok(true)` — `vulns` is in the installed-subcommands list.
/// - `Ok(false)` — listing succeeded but no `vulns` entry.
/// - `Err(BrewNotFound)` — brew itself isn't on PATH.
/// - `Err(BrewExitNonZero | Io)` — listing failed for some other reason.
pub async fn check_brew_vulns_installed(brew: &Path) -> Result<bool, BrewError> {
    // `brew-vulns` ships as a formula (recommended install:
    // `brew install homebrew/brew-vulns/brew-vulns`) whose `bin/brew-vulns`
    // shim becomes a `brew vulns` external subcommand via brew's
    // PATH-based dispatch.
    //
    // The cleanest probe is `brew --prefix brew-vulns`:
    //   - exit 0 + prefix path on stdout → installed
    //   - exit 1 + "No available formula" on stderr → not installed
    //
    // **Why not `brew commands --quiet --include-aliases`?** That output
    // lists built-in subcommands and tap-resident commands but **NOT**
    // external `brew-FOO` binaries from installed formulae. A user with
    // brew-vulns correctly installed via the formula would still appear
    // "not installed" — caught in a v0.5.0 smoke test (the user could
    // run `brew vulns` from CLI but our UI showed the install
    // affordance regardless).
    //
    // First try the legacy check: `brew --prefix brew-vulns` (if installed via custom tap).
    let mut cmd = brew_command(brew);
    cmd.args(["--prefix", "brew-vulns"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    if let Ok(output) = cmd.output().await {
        if output.status.success() {
            return Ok(true);
        }
    }

    // Fallback: check if `vulns` is a built-in subcommand in Homebrew 6.0+ via `brew help vulns`.
    let mut cmd = brew_command(brew);
    cmd.args(["help", "vulns"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let output = cmd.output().await.map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
        _ => BrewError::Io {
            message: format!("brew help vulns spawn: {e}"),
        },
    })?;

    Ok(output.status.success())
}

/// Scan all installed formulae. Caller must have verified the gate
/// (`require_vulnerability_scanning`) and the install probe
/// ([`check_brew_vulns_installed`]) first.
///
/// Returns one [`RawScanResult`] per installed formula brew-vulns
/// was able to process. Formulae from unsupported source forges
/// (non-GitHub/GitLab/Codeberg) are silently absent from the result —
/// they're a documented coverage gap, not an error.
pub async fn scan_all(brew: &Path) -> Result<Vec<RawScanResult>, BrewError> {
    // No --formula → scan everything installed. `--json` is the
    // structured output mode brew-vulns supports for CI consumption.
    // Uses the tolerant wrapper because brew-vulns exits 1 on
    // "findings present" (CI-scanner convention) and we want the JSON.
    // `--quiet` suppresses brew's own progress/banner chatter so it can't land
    // on stdout and break JSON parsing (parity with the native scanner, and
    // belt-and-suspenders for issue #62). parse_scan_output also salvages JSON
    // from any residual noise.
    let raw =
        run_vulns_capture(brew, &["vulns", "--quiet", "--json"], "brew vulns --quiet --json")
            .await?;
    parse_scan_output(&raw, "brew vulns --quiet --json")
}

/// Scan a single formula by name. Used by the PackageDetail
/// "Check vulnerabilities" button. Returns just the flattened
/// [`RawVuln`] list since the caller already knows the formula name.
pub async fn scan_one(brew: &Path, formula: &str) -> Result<Vec<RawVuln>, BrewError> {
    validate_formula_name(formula)?;
    let display = format!("brew vulns --quiet --json --formula {formula}");
    // Tolerant wrapper — same exit-1-is-findings semantics as scan_all.
    // `--quiet` parity with scan_all (issue #62).
    let raw = run_vulns_capture(
        brew,
        &["vulns", "--quiet", "--json", "--formula", formula],
        &display,
    )
    .await?;
    let results = parse_scan_output(&raw, &display)?;
    // brew vulns IGNORES --formula and returns the WHOLE install set, so keep
    // only the requested formula's record — otherwise the detail card shows
    // every other package's CVEs (boost/icu/jxl/…) under this one. brew vulns
    // may echo a tap-qualified name under its bare form (or vice-versa), so
    // match the exact name OR the last `/`-segment (issue #92).
    let want_tail = formula.rsplit('/').next().unwrap_or(formula);
    Ok(results
        .into_iter()
        .find(|r| r.formula == formula || r.formula.rsplit('/').next() == Some(want_tail))
        .map(|r| r.vulnerabilities)
        .unwrap_or_default())
}

/// Install `brew vulns` via `brew install homebrew/brew-vulns/brew-vulns`.
/// Wired by the `vulns_install_helper` IPC in Step 3 — frontend confirms
/// the install with the user, then this runs the actual subprocess.
///
/// Returns the captured stdout on success (typically the install
/// progress lines) so the Activity drawer can show what brew did.
pub async fn install_brew_vulns(brew: &Path) -> Result<String, BrewError> {
    run_brew_capture(
        brew,
        &["update"],
        BREW_VULNS_INSTALL_CMD,
    )
    .await
}

// ----- Parsing + validation -----

/// Parse the JSON output of `brew vulns --json`. The expected shape is
/// an array of [`RawScanResult`]; we also accept a single object as a
/// defensive fallback in case brew-vulns ever switches to one-object-
/// per-line output (rare but precedented for `brew info --json`).
fn parse_scan_output(raw: &str, display_command: &str) -> Result<Vec<RawScanResult>, BrewError> {
    // Empty output → no installed formulae had results. Treat as empty
    // vec rather than a parse failure.
    if raw.trim().is_empty() {
        return Ok(Vec::new());
    }
    // Fast path: the whole stdout is the JSON document (the common case).
    if let Some(parsed) = try_parse_records(raw) {
        return Ok(parsed);
    }
    // Salvage: older brew / brew-vulns versions can print a banner or notice
    // on stdout around the `--json` document (issue #62 — `whatcable` on brew
    // 5.1.15 produced "expected value at line 1 column 1"). Slice the JSON
    // document out of the surrounding line-oriented noise and retry.
    if let Some(slice) = extract_json_document(raw) {
        if let Some(parsed) = try_parse_records(&slice) {
            return Ok(parsed);
        }
        // A JSON-looking payload was present but malformed → a genuine
        // problem worth surfacing (keeps the garbage-input contract).
        return Err(BrewError::JsonParse {
            command: display_command.to_string(),
            message: "vulns parse: could not parse JSON document in output".to_string(),
            raw_excerpt: raw.chars().take(400).collect(),
        });
    }
    // No JSON structure at all on a clean exit (run_vulns_capture already
    // surfaced exit ≥2 as an error before we got here). Treat as "nothing to
    // report" — consistent with scan_all silently omitting unsupported-forge
    // formulae — rather than a scary parse error in the user's face.
    Ok(Vec::new())
}

/// Try both documented shapes: an array (the norm) then a single object
/// (defensive fallback). `None` if the input isn't valid JSON in either shape.
fn try_parse_records(s: &str) -> Option<Vec<RawScanResult>> {
    if let Ok(arr) = serde_json::from_str::<Vec<RawScanResult>>(s) {
        return Some(arr);
    }
    serde_json::from_str::<RawScanResult>(s)
        .ok()
        .map(|one| vec![one])
}

/// Extract the JSON document from line-oriented CLI noise: from the first
/// line that (left-trimmed) starts with `[`/`{` to the last line that
/// (right-trimmed) ends with `]`/`}`. Line-granular so a stray bracket in a
/// mid-sentence warning doesn't derail extraction. `None` when no such
/// bracketed block exists (pure prose → caller treats as "no results").
fn extract_json_document(raw: &str) -> Option<String> {
    let lines: Vec<&str> = raw.lines().collect();
    let start = lines.iter().position(|l| {
        let t = l.trim_start();
        t.starts_with('[') || t.starts_with('{')
    })?;
    let end = lines.iter().rposition(|l| {
        let t = l.trim_end();
        t.ends_with(']') || t.ends_with('}')
    })?;
    if start > end {
        return None;
    }
    Some(lines[start..=end].join("\n"))
}

/// Validate a brew formula name before passing it to `brew vulns
/// --formula`. Brew formula names are lowercase alphanumeric with
/// `-`, `_`, `+`, `@`, `.`; we reject anything else as defense in
/// depth against shell-meta injection (Command::new + .arg() is
/// already argv-safe but the explicit check makes the contract
/// obvious in code review).
pub fn validate_formula_name(name: &str) -> Result<(), BrewError> {
    if name.is_empty() || name.len() > 128 {
        return Err(BrewError::InvalidArgument {
            message: format!("invalid formula name length: {}", name.len()),
        });
    }
    // Allow `/` so tap-qualified names (`user/repo/name`) pass — brew vulns
    // accepts them and users scan formulae from third-party taps (issue #92,
    // `anomalyco/tap/opencode`). `Command::arg` is argv-safe (no shell) and the
    // vulns cache keys names into a JSON map string, NOT a filesystem path
    // (see vulns/cache.rs), so `/` introduces no injection/traversal risk; the
    // structure guard below keeps the surface tight.
    let ok = name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '+' | '@' | '.' | '/'));
    if !ok {
        return Err(BrewError::InvalidArgument {
            message: format!("invalid character(s) in formula name: {name}"),
        });
    }
    // A tap-qualified name is `user/repo/name` (2 slashes) or shorthand `user/name` (1 slash);
    // a bare name has none. Reject anything else — empty segments, leading/trailing slash,
    // `a//b`, `.`/`..` path segments, or deeper paths.
    let segments: Vec<&str> = name.split('/').collect();
    let well_formed = matches!(segments.len(), 1 | 2 | 3)
        && segments.iter().all(|s| !s.is_empty() && *s != "." && *s != "..");
    if !well_formed {
        return Err(BrewError::InvalidArgument {
            message: format!("invalid character(s) in formula name: {name}"),
        });
    }
    Ok(())
}

/// Detect whether a brew error message indicates the `vulns`
/// subcommand isn't installed. Brew's wording for unknown commands has
/// been stable: `"Error: Unknown command: vulns"`. This helper lets the
/// IPC layer convert a generic [`BrewError::BrewExitNonZero`] into
/// [`BrewError::VulnsNotInstalled`] so the frontend can surface the
/// one-click install affordance.
#[allow(dead_code)]
pub fn looks_like_subcommand_missing(stderr_excerpt: &str) -> bool {
    let lower = stderr_excerpt.to_lowercase();
    lower.contains("unknown command: vulns") || lower.contains("unknown command \"vulns\"")
}

/// Quick liveness probe used by tests and the install-helper to
/// confirm `brew --version` itself runs cleanly. Not strictly needed
/// in production but useful for "is this brew install healthy?"
/// diagnostics.
#[allow(dead_code)]
async fn brew_version(brew: &Path) -> Result<String, BrewError> {
    let mut cmd = brew_command(brew);
    cmd.args(["--version"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = cmd.output().await.map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
        _ => BrewError::Io {
            message: format!("brew --version spawn: {e}"),
        },
    })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        return Err(BrewError::BrewExitNonZero {
            command: "brew --version".into(),
            exit_code: output.status.code().unwrap_or(-1),
            stderr_excerpt: truncate_tail(stderr.trim_end(), MAX_STDERR_EXCERPT),
            friendly_message: None,
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    // ----- Severity parsing -----

    #[test]
    fn severity_parses_known_lowercase_levels() {
        let cases = [
            ("\"critical\"", Severity::Critical),
            ("\"high\"", Severity::High),
            ("\"medium\"", Severity::Medium),
            ("\"low\"", Severity::Low),
        ];
        for (input, expected) in cases {
            let got: Severity = serde_json::from_str(input).expect(input);
            assert_eq!(got, expected, "input: {input}");
        }
    }

    #[test]
    fn severity_unknown_value_falls_back_to_unknown() {
        // Critical: a future OSV severity addition must not fail the
        // whole scan parse. The entry still renders, just labeled
        // "unknown".
        let got: Severity = serde_json::from_str("\"informational\"").expect("parses");
        assert_eq!(got, Severity::Unknown);
    }

    #[test]
    fn severity_default_is_unknown() {
        assert_eq!(Severity::default(), Severity::Unknown);
    }

    // ----- RawVuln parsing -----

    #[test]
    fn raw_vuln_parses_full_object() {
        let json = r#"{
            "id": "GHSA-xxxx-xxxx-xxxx",
            "severity": "high",
            "summary": "Buffer overflow in foo",
            "details": "Long form details here",
            "fixedIn": "3.2.1",
            "references": ["https://example.com/advisory"],
            "published": "2024-09-01T00:00:00Z"
        }"#;
        let v: RawVuln = serde_json::from_str(json).expect("parse");
        assert_eq!(v.id, "GHSA-xxxx-xxxx-xxxx");
        assert_eq!(v.severity, Severity::High);
        assert_eq!(v.fixed_in.as_deref(), Some("3.2.1"));
        assert_eq!(v.references.len(), 1);
    }

    #[test]
    fn raw_vuln_parses_empty_object_with_defaults() {
        // Defensive: a future brew-vulns release that adds or renames
        // fields must not break parsing of the records we already
        // understand. Empty object → all defaults.
        let v: RawVuln = serde_json::from_str("{}").expect("parse");
        assert_eq!(v.id, "");
        assert_eq!(v.severity, Severity::Unknown);
        assert!(v.fixed_in.is_none());
        assert!(v.references.is_empty());
    }

    #[test]
    fn raw_vuln_ignores_unknown_fields() {
        // Forward-compat: extra fields a future release adds must not
        // panic the parse.
        let json = r#"{"id":"CVE-2024-1","severity":"low","newField":"future"}"#;
        let v: RawVuln = serde_json::from_str(json).expect("parse");
        assert_eq!(v.id, "CVE-2024-1");
        assert_eq!(v.severity, Severity::Low);
    }

    // ----- parse_scan_output -----

    #[test]
    fn parse_scan_output_handles_array() {
        let json = r#"[
            {"formula":"openssl@3","version":"3.2.0","vulnerabilities":[
                {"id":"GHSA-1","severity":"critical","summary":"boom"}
            ]},
            {"formula":"curl","version":"8.4.0","vulnerabilities":[]}
        ]"#;
        let parsed = parse_scan_output(json, "test").expect("parse");
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].formula, "openssl@3");
        assert_eq!(parsed[0].vulnerabilities.len(), 1);
        assert!(parsed[1].vulnerabilities.is_empty(), "clean scan ≠ absence");
    }

    #[test]
    fn parse_scan_output_handles_empty_string() {
        // brew vulns with no installed formulae or all-clean output
        // could emit an empty string. Treat as Vec::new(), not parse
        // failure.
        assert_eq!(parse_scan_output("", "test").expect("parse").len(), 0);
        assert_eq!(parse_scan_output("   \n", "test").expect("parse").len(), 0);
    }

    #[test]
    fn parse_scan_output_handles_single_object_fallback() {
        // If brew-vulns ever ships single-object-per-formula output
        // (no array wrapper), the fallback path catches it.
        let json = r#"{"formula":"curl","version":"8.4.0","vulnerabilities":[]}"#;
        let parsed = parse_scan_output(json, "test").expect("parse");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].formula, "curl");
    }

    #[test]
    fn parse_scan_output_returns_json_parse_error_on_garbage() {
        let err = parse_scan_output("{garbage]", "brew vulns --json").unwrap_err();
        match err {
            BrewError::JsonParse {
                command,
                raw_excerpt,
                ..
            } => {
                assert_eq!(command, "brew vulns --json");
                assert!(raw_excerpt.contains("garbage"));
            }
            other => panic!("expected JsonParse, got {other:?}"),
        }
    }

    #[test]
    fn parse_scan_output_salvages_json_behind_leading_noise() {
        // Issue #62: a brew banner/notice on stdout before the --json document.
        let raw = "Warning: some brew notice\n[{\"formula\":\"curl\",\"version\":\"8.4.0\",\"vulnerabilities\":[]}]";
        let parsed = parse_scan_output(raw, "brew vulns --quiet --json").expect("salvaged");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].formula, "curl");
    }

    #[test]
    fn parse_scan_output_salvages_json_between_noise_lines() {
        let raw = "==> downloading advisories\n[{\"formula\":\"openssl@3\",\"version\":\"3.2.0\",\"vulnerabilities\":[]}]\n==> done";
        let parsed = parse_scan_output(raw, "brew vulns --quiet --json").expect("salvaged");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].formula, "openssl@3");
    }

    #[test]
    fn parse_scan_output_pure_prose_yields_empty_not_error() {
        // No JSON structure at all on a clean exit → treat as "no results"
        // rather than a json_parse error in the user's face (issue #62).
        assert_eq!(
            parse_scan_output("whatcable: skipped (unsupported source)\n", "test")
                .expect("no error")
                .len(),
            0
        );
    }

    #[test]
    fn parse_scan_output_malformed_payload_still_errors() {
        // A bracketed-but-broken payload is a genuine problem, still surfaced.
        let err = parse_scan_output("notice\n[ {broken json ]\n", "brew vulns --quiet --json")
            .unwrap_err();
        assert!(matches!(err, BrewError::JsonParse { .. }));
    }

    #[test]
    fn extract_json_document_skips_surrounding_lines() {
        let raw = "lead\n  [1,2,3]  \ntrail";
        assert_eq!(extract_json_document(raw).as_deref(), Some("  [1,2,3]  "));
        assert_eq!(extract_json_document("no json here").as_deref(), None);
    }

    // ----- validate_formula_name -----

    #[test]
    fn validate_formula_name_accepts_typical_names() {
        for name in [
            "curl",
            "openssl@3",
            "python@3.12",
            "node",
            "git-lfs",
            "lib_foo",
        ] {
            assert!(validate_formula_name(name).is_ok(), "should accept: {name}");
        }
    }

    #[test]
    fn validate_formula_name_accepts_tap_qualified_names() {
        // Issue #92: third-party tap formulae are `user/repo/name` or `user/name`.
        for name in [
            "anomalyco/tap/opencode",
            "homebrew/core/wget",
            "user-name/repo_2/formula@1.2",
            "anomalyco/opencode",
            "homebrew/wget",
        ] {
            assert!(validate_formula_name(name).is_ok(), "should accept: {name}");
        }
    }

    #[test]
    fn validate_formula_name_rejects_malformed_slashes() {
        // `/` is allowed only in the exact `user/repo/name` or `user/name` shape.
        for bad in [
            "/leading",
            "trailing/",
            "a//b",
            "a/b/c/d",
            "a/../b",
            "../etc/passwd",
            "./relative",
        ] {
            assert!(validate_formula_name(bad).is_err(), "should reject: {bad}");
        }
    }

    #[test]
    fn validate_formula_name_rejects_shell_meta() {
        for bad in ["curl; rm -rf /", "curl|nc", "curl`whoami`", "curl $(id)"] {
            assert!(validate_formula_name(bad).is_err(), "should reject: {bad}");
        }
    }

    #[test]
    fn validate_formula_name_rejects_empty_and_oversize() {
        assert!(validate_formula_name("").is_err());
        let oversize = "a".repeat(129);
        assert!(validate_formula_name(&oversize).is_err());
    }

    // ----- looks_like_subcommand_missing -----

    #[test]
    fn detects_subcommand_missing_from_stderr() {
        assert!(looks_like_subcommand_missing(
            "Error: Unknown command: vulns"
        ));
        assert!(looks_like_subcommand_missing(
            "Error: Unknown command \"vulns\""
        ));
        assert!(!looks_like_subcommand_missing("Error: brew is not happy"));
        assert!(!looks_like_subcommand_missing(""));
    }

    // ----- Real brew vulns --json fixture (pin against regression) -----

    /// Captured 2026-05-27 from `brew vulns --json` on a real install.
    /// Pins the wire shape: UPPERCASE severities, `fixed_versions: []`
    /// (not `fixed_in: String`), nullable `summary`, extra fields
    /// (`tag`, `repo_url`, `aliases`) that we ignore harmlessly.
    ///
    /// Critical regression guard: before this fixture, severities were
    /// silently coerced to `Unknown` (rename_all = "lowercase" doesn't
    /// case-fold deserialization) and `fixed_in` never populated
    /// (`fixed_versions` key was unrecognized). Both ship features
    /// (severity-toned UI + Upgrade-to-fix button) — both broke
    /// invisibly until a real fixture caught it.
    const REAL_BREW_VULNS_OUTPUT: &str = r#"[
      {
        "formula": "augeas",
        "version": "1.14.1",
        "tag": "release-1.14.1",
        "repo_url": "https://github.com/hercules-team/augeas",
        "vulnerabilities": [
          {
            "id": "CVE-2025-2588",
            "severity": "LOW",
            "summary": null,
            "aliases": [],
            "fixed_versions": []
          },
          {
            "id": "OSV-2020-1540",
            "severity": "MEDIUM",
            "summary": "UNKNOWN READ in eval_expr",
            "aliases": [],
            "fixed_versions": []
          }
        ]
      },
      {
        "formula": "openjpeg",
        "version": "2.5.4",
        "tag": "v2.5.4",
        "repo_url": "https://github.com/uclouvain/openjpeg",
        "vulnerabilities": [
          {
            "id": "OSV-2025-219",
            "severity": "HIGH",
            "summary": "Heap-buffer-overflow in opj_j2k_read_tile_header",
            "aliases": [],
            "fixed_versions": ["d33cbecc148d3affcdf403211fddc2cc5d442379"]
          }
        ]
      },
      {
        "formula": "p11-kit",
        "version": "0.26.2",
        "tag": "0.26.2",
        "repo_url": "https://github.com/p11-glue/p11-kit",
        "vulnerabilities": [
          {
            "id": "OSV-2023-197",
            "severity": "UNKNOWN",
            "summary": "Global-buffer-overflow in base_C_MessageEncryptInit",
            "aliases": [],
            "fixed_versions": []
          }
        ]
      }
    ]"#;

    #[test]
    fn raw_scan_result_parses_real_brew_vulns_output() {
        let parsed = parse_scan_output(REAL_BREW_VULNS_OUTPUT, "fixture").expect("parses");
        assert_eq!(parsed.len(), 3);

        // augeas: 2 vulns, lowercase + mixed
        let augeas = &parsed[0];
        assert_eq!(augeas.formula, "augeas");
        assert_eq!(augeas.version, "1.14.1");
        assert_eq!(augeas.vulnerabilities.len(), 2);

        let cve = &augeas.vulnerabilities[0];
        assert_eq!(cve.id, "CVE-2025-2588");
        assert_eq!(cve.severity, Severity::Low, "LOW must case-fold to Low");
        assert_eq!(cve.summary, "", "null summary must map to empty string");
        assert!(cve.fixed_in.is_none(), "empty fixed_versions → None");

        let osv = &augeas.vulnerabilities[1];
        assert_eq!(osv.severity, Severity::Medium, "MEDIUM must case-fold");
        assert_eq!(osv.summary, "UNKNOWN READ in eval_expr");

        // openjpeg: HIGH + non-empty fixed_versions
        let opj = &parsed[1];
        let high = &opj.vulnerabilities[0];
        assert_eq!(high.severity, Severity::High);
        assert_eq!(
            high.fixed_in.as_deref(),
            Some("d33cbecc148d3affcdf403211fddc2cc5d442379"),
            "first fixed_versions element must surface as fixed_in"
        );

        // p11-kit: UNKNOWN severity must round-trip as Severity::Unknown
        // (not Critical, not High, etc — sanity that the catch-all works)
        let p11 = &parsed[2];
        assert_eq!(p11.vulnerabilities[0].severity, Severity::Unknown);
    }

    #[test]
    fn severity_case_folds_all_known_forms() {
        // Both uppercase (real brew vulns) and lowercase (our existing
        // wire convention) deserialize cleanly.
        for case in ["HIGH", "high", "High", "hIgH"] {
            let json = format!("\"{case}\"");
            let got: Severity = serde_json::from_str(&json).expect(case);
            assert_eq!(got, Severity::High, "case-fold failed for: {case}");
        }
    }

    #[test]
    fn severity_accepts_moderate_alias_for_medium() {
        // GHSA uses "MODERATE" where OSV uses "MEDIUM". Both must
        // render as the same in-app severity so the UI doesn't show
        // a Github-sourced vuln as Unknown when the OSV-sourced one
        // is Medium.
        let got: Severity = serde_json::from_str("\"MODERATE\"").expect("parses");
        assert_eq!(got, Severity::Medium);
    }

    #[test]
    fn fixed_versions_array_takes_first_element() {
        let json = r#"{"id":"X","severity":"high","fixed_versions":["3.2.1","3.3.0"]}"#;
        let v: RawVuln = serde_json::from_str(json).expect("parse");
        assert_eq!(
            v.fixed_in.as_deref(),
            Some("3.2.1"),
            "first patch version wins (earliest available fix)"
        );
    }

    #[test]
    fn fixed_versions_empty_array_is_none() {
        let json = r#"{"id":"X","severity":"low","fixed_versions":[]}"#;
        let v: RawVuln = serde_json::from_str(json).expect("parse");
        assert!(v.fixed_in.is_none());
    }

    #[test]
    fn fixed_versions_string_fallback_works() {
        // Defensive: if brew vulns ever switches back to a scalar field
        // (renames `fixed_versions` to a bare string), our deserializer
        // accepts that too. Stays useful through a future schema flip.
        let json = r#"{"id":"X","severity":"high","fixed_versions":"3.2.1"}"#;
        let v: RawVuln = serde_json::from_str(json).expect("parse");
        assert_eq!(v.fixed_in.as_deref(), Some("3.2.1"));
    }

    // ----- BREW_VULNS_INSTALL_CMD constant -----

    #[test]
    fn install_command_constant_is_the_canonical_form() {
        // The string is referenced by VulnsNotInstalled's install_command
        // field — keep this test as a tripwire if the constant ever
        // changes (e.g. a maintainer transfer).
        assert_eq!(
            BREW_VULNS_INSTALL_CMD,
            "brew update"
        );
    }
}
