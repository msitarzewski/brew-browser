//! Serde mirrors of `brew --json=v2` output + conversion to our DTOs.
//!
//! Only the fields we actually use are modeled. `#[serde(default)]` is
//! liberally applied so the parser tolerates missing/null fields across
//! brew versions.

use serde::Deserialize;

use crate::types::{
    IconSource, OutdatedPackage, Package, PackageDetail, PackageKind, PackageOption,
};

// ---------- brew info / brew list --installed --json=v2 (formula side) ----------

#[derive(Debug, Deserialize)]
pub struct RawInfoV2 {
    #[serde(default)]
    pub formulae: Vec<RawFormula>,
    #[serde(default)]
    pub casks: Vec<RawCask>,
}

#[derive(Debug, Deserialize)]
pub struct RawFormula {
    pub name: String,
    #[serde(default)]
    pub full_name: Option<String>,
    #[serde(default)]
    pub tap: Option<String>,
    #[serde(default)]
    pub desc: Option<String>,
    #[serde(default)]
    pub license: Option<String>,
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub versions: Option<RawFormulaVersions>,
    /// Upstream `urls: { stable: { url, ... }, head: { url, ... }, ... }`.
    /// We only read the `url` strings — the rest (tag, revision, branch,
    /// checksum) isn't useful for our GitHub-resolution layer. Optional
    /// because brew formula JSON omits `urls` for tap-only or odd shapes.
    #[serde(default)]
    pub urls: Option<RawFormulaUrls>,
    #[serde(default)]
    pub build_dependencies: Vec<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    #[serde(default)]
    pub optional_dependencies: Vec<String>,
    #[serde(default)]
    pub conflicts_with: Vec<String>,
    #[serde(default)]
    pub requirements: Vec<RawRequirement>,
    #[serde(default)]
    pub caveats: Option<String>,
    #[serde(default)]
    pub installed: Vec<RawFormulaInstalled>,
    #[serde(default)]
    pub options: Vec<RawOption>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub outdated: bool,
    /// 30-day analytics installs, if present.
    #[serde(default)]
    pub analytics: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct RawFormulaVersions {
    #[serde(default)]
    pub stable: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    pub head: Option<String>,
}

/// Upstream `urls` object on a formula record. Only the `url` field of
/// each entry is relevant to our GitHub-resolution pass — the tag,
/// revision, branch, and checksum fields are intentionally ignored.
#[derive(Debug, Deserialize)]
pub struct RawFormulaUrls {
    #[serde(default)]
    pub stable: Option<RawUrlEntry>,
    #[serde(default)]
    pub head: Option<RawUrlEntry>,
}

#[derive(Debug, Deserialize)]
pub struct RawUrlEntry {
    #[serde(default)]
    pub url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RawFormulaInstalled {
    pub version: String,
    #[serde(default)]
    pub installed_on_request: bool,
    #[serde(default)]
    pub installed_as_dependency: bool,
}

#[derive(Debug, Deserialize)]
pub struct RawRequirement {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    pub specs: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct RawOption {
    #[serde(default)]
    pub option: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
}

// ---------- brew info --cask --json=v2 ----------

#[derive(Debug, Deserialize)]
pub struct RawCask {
    pub token: String,
    #[serde(default)]
    pub full_token: Option<String>,
    #[serde(default)]
    pub name: Vec<String>,
    #[serde(default)]
    pub tap: Option<String>,
    #[serde(default)]
    pub desc: Option<String>,
    #[serde(default)]
    pub homepage: Option<String>,
    /// Upstream `url` — points at the .pkg/.dmg/.zip artifact. Casks
    /// hosted on GitHub Releases routinely have this field on
    /// `github.com/<o>/<r>/releases/download/...` even when `homepage`
    /// is a marketing/landing page.
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    /// `installed` for casks is either a version string or null.
    #[serde(default)]
    pub installed: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub outdated: bool,
    #[serde(default)]
    pub caveats: Option<String>,
    #[serde(default)]
    pub conflicts_with: Option<serde_json::Value>,
    #[serde(default)]
    pub depends_on: Option<serde_json::Value>,
    #[serde(default)]
    pub artifacts: Option<serde_json::Value>,
}

// ---------- brew outdated --json=v2 ----------

#[derive(Debug, Deserialize)]
pub struct RawOutdatedV2 {
    #[serde(default)]
    pub formulae: Vec<RawOutdatedEntry>,
    #[serde(default)]
    pub casks: Vec<RawOutdatedEntry>,
}

#[derive(Debug, Deserialize)]
pub struct RawOutdatedEntry {
    pub name: String,
    #[serde(default)]
    pub installed_versions: Vec<String>,
    #[serde(default)]
    pub current_version: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub pinned_version: Option<String>,
}

// ---------- Conversions: raw → DTO ----------

impl RawFormula {
    pub fn to_package(&self) -> Package {
        let installed_first = self.installed.first();
        let installed_version = installed_first.map(|i| i.version.clone());
        let installed_on_request = installed_first.map(|i| i.installed_on_request).unwrap_or(false);
        let installed_as_dependency = installed_first
            .map(|i| i.installed_as_dependency)
            .unwrap_or(false);

        let stable_version = self.versions.as_ref().and_then(|v| v.stable.clone());

        // Walk homepage → urls.stable.url → urls.head.url and surface
        // the first GitHub-resolvable URL as a canonical homepage. See
        // `Package::github_homepage` for the rationale (many formulae
        // have non-GitHub homepages but GitHub-hosted source URLs).
        let github_homepage = crate::github::resolve_github_homepage([
            self.homepage.as_deref(),
            self.urls
                .as_ref()
                .and_then(|u| u.stable.as_ref())
                .and_then(|s| s.url.as_deref()),
            self.urls
                .as_ref()
                .and_then(|u| u.head.as_ref())
                .and_then(|h| h.url.as_deref()),
        ]);

        Package {
            name: self.name.clone(),
            full_name: self.full_name.clone().unwrap_or_else(|| self.name.clone()),
            kind: PackageKind::Formula,
            installed_version,
            stable_version,
            description: self.desc.clone(),
            homepage: self.homepage.clone(),
            license: self.license.clone(),
            tap: self.tap.clone(),
            outdated: self.outdated,
            pinned: self.pinned,
            installed_on_request,
            installed_as_dependency,
            // Formulae are CLI tools — no icon to fetch. The frontend
            // renders a glyph fallback for the `None` variant.
            icon_source: IconSource::None,
            github_homepage,
        }
    }

    pub fn to_detail(&self, raw_json: serde_json::Value) -> PackageDetail {
        let pkg = self.to_package();
        let requirements: Vec<String> = self
            .requirements
            .iter()
            .filter_map(|r| {
                let name = r.name.clone()?;
                Some(match &r.version {
                    Some(v) => format!("{} {}", name, v),
                    None => name,
                })
            })
            .collect();

        let options = self
            .options
            .iter()
            .filter_map(|o| {
                Some(PackageOption {
                    flag: o.option.clone()?,
                    description: o.description.clone().unwrap_or_default(),
                })
            })
            .collect();

        let analytics30d_installs = extract_analytics_30d(&self.analytics);

        PackageDetail {
            package: pkg,
            caveats: self.caveats.clone(),
            dependencies: self.dependencies.clone(),
            build_dependencies: self.build_dependencies.clone(),
            optional_dependencies: self.optional_dependencies.clone(),
            conflicts_with: self.conflicts_with.clone(),
            requirements,
            options,
            installed_paths: Vec::new(),
            analytics30d_installs,
            raw_json,
            exists_in_applications: false,
            is_mas: false,
        }
    }
}

impl RawCask {
    pub fn to_package(&self) -> Package {
        // Classify icon source up-front so the frontend can route each
        // row to the right command without re-deriving the rule:
        //   installed         → `cask_icon` (.app bundle extraction, Phase 7)
        //   uninstalled + URL → `cask_icon_from_homepage` (favicon cascade, Phase 8)
        //   neither           → glyph fallback
        // Homepage strings are trimmed; empty-after-trim collapses to None so
        // a stray `""` from upstream metadata can't trigger a network call.
        let icon_source = if self.installed.is_some() {
            IconSource::InstalledApp
        } else {
            match self.homepage.as_ref() {
                Some(h) if !h.trim().is_empty() => IconSource::Homepage {
                    homepage: h.trim().to_string(),
                },
                _ => IconSource::None,
            }
        };

        // Walk homepage → top-level url and surface the first
        // GitHub-resolvable URL as a canonical homepage. See
        // `Package::github_homepage`. Casks with GitHub-Releases
        // artifacts but marketing-page homepages are common.
        let github_homepage = crate::github::resolve_github_homepage([
            self.homepage.as_deref(),
            self.url.as_deref(),
        ]);

        Package {
            name: self.token.clone(),
            full_name: self.full_token.clone().unwrap_or_else(|| self.token.clone()),
            kind: PackageKind::Cask,
            installed_version: self.installed.clone(),
            stable_version: self.version.clone(),
            description: self.desc.clone(),
            homepage: self.homepage.clone(),
            license: None,
            tap: self.tap.clone(),
            outdated: self.outdated,
            pinned: self.pinned,
            // Casks don't track on-request vs dependency.
            installed_on_request: self.installed.is_some(),
            installed_as_dependency: false,
            icon_source,
            github_homepage,
        }
    }

    pub fn to_detail(&self, raw_json: serde_json::Value) -> PackageDetail {
        let pkg = self.to_package();
        let conflicts_with = match &self.conflicts_with {
            Some(serde_json::Value::Array(arr)) => arr
                .iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect(),
            Some(serde_json::Value::Object(map)) => map
                .values()
                .filter_map(|v| {
                    v.as_array().map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_str().map(|s| s.to_string()))
                            .collect::<Vec<_>>()
                    })
                })
                .flatten()
                .collect(),
            _ => Vec::new(),
        };

        let dependencies = match &self.depends_on {
            Some(serde_json::Value::Object(map)) => {
                let mut deps = Vec::new();
                if let Some(serde_json::Value::Array(arr)) = map.get("formula") {
                    for v in arr {
                        if let Some(s) = v.as_str() {
                            deps.push(s.to_string());
                        }
                    }
                }
                if let Some(serde_json::Value::Array(arr)) = map.get("cask") {
                    for v in arr {
                        if let Some(s) = v.as_str() {
                            deps.push(s.to_string());
                        }
                    }
                }
                deps
            }
            _ => Vec::new(),
        };

        let (exists_in_applications, is_mas) = if cfg!(target_os = "macos") {
            let mut candidates = cask_app_filenames(&self.artifacts);
            let token = self.token.trim();
            if !token.is_empty() {
                let mut chars = token.chars();
                if let Some(first) = chars.next() {
                    let capitalized = first.to_uppercase().collect::<String>() + chars.as_str();
                    candidates.push(format!("{}.app", capitalized));
                }
                candidates.push(format!("{}.app", token));
            }
            for n in &self.name {
                let n_trimmed = n.trim();
                if !n_trimmed.is_empty() {
                    candidates.push(format!("{}.app", n_trimmed));
                }
            }
            let mut found = false;
            let mut mas = false;
            for name in &candidates {
                if check_app_exists_macos(name) {
                    found = true;
                    if check_app_is_mas_macos(name) {
                        mas = true;
                    }
                }
            }
            (found, mas)
        } else {
            (false, false)
        };

        PackageDetail {
            package: pkg,
            caveats: self.caveats.clone(),
            dependencies,
            build_dependencies: Vec::new(),
            optional_dependencies: Vec::new(),
            conflicts_with,
            requirements: Vec::new(),
            options: Vec::new(),
            installed_paths: extract_cask_paths(&self.artifacts),
            analytics30d_installs: None,
            raw_json,
            exists_in_applications,
            is_mas,
        }
    }
}

impl RawOutdatedEntry {
    pub fn to_dto(&self, kind: PackageKind) -> OutdatedPackage {
        OutdatedPackage {
            name: self.name.clone(),
            kind,
            installed_versions: self.installed_versions.clone(),
            current_version: self.current_version.clone(),
            pinned: self.pinned,
            pinned_version: self.pinned_version.clone(),
        }
    }
}

fn extract_analytics_30d(v: &Option<serde_json::Value>) -> Option<u64> {
    let v = v.as_ref()?;
    // Shape (when present): {"install": {"30d": {"<name>": <count>}}}
    let installs_30d = v.get("install")?.get("30d")?;
    let obj = installs_30d.as_object()?;
    // Pick the single value (key is the formula name).
    obj.values().next().and_then(|x| x.as_u64())
}

fn extract_cask_paths(artifacts: &Option<serde_json::Value>) -> Vec<String> {
    let arr = match artifacts.as_ref().and_then(|v| v.as_array()) {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for entry in arr {
        let obj = match entry.as_object() {
            Some(o) => o,
            None => continue,
        };
        for (key, value) in obj {
            if key == "app" || key == "binary" {
                if let Some(list) = value.as_array() {
                    for x in list {
                        if let Some(s) = x.as_str() {
                            out.push(s.to_string());
                        }
                    }
                }
            }
        }
    }
    out
}

fn cask_app_filenames(artifacts: &Option<serde_json::Value>) -> Vec<String> {
    let mut out = Vec::new();
    let Some(arr) = artifacts.as_ref().and_then(|v| v.as_array()) else {
        return out;
    };
    for entry in arr {
        let Some(obj) = entry.as_object() else {
            continue;
        };
        if let Some(serde_json::Value::Array(apps)) = obj.get("app") {
            for a in apps {
                if let Some(s) = a.as_str() {
                    out.push(s.to_string());
                } else if let Some(o) = a.as_object() {
                    if let Some(s) = o.get("target").and_then(|v| v.as_str()) {
                        out.push(s.to_string());
                    } else if let Some(s) = o.get("source").and_then(|v| v.as_str()) {
                        let basename = std::path::Path::new(s)
                            .file_name()
                            .map(|n| n.to_string_lossy().into_owned())
                            .unwrap_or_else(|| s.to_string());
                        out.push(basename);
                    }
                }
            }
        }
    }
    out
}

fn check_app_exists_macos(filename: &str) -> bool {
    if !filename.ends_with(".app") || filename.contains('/') || filename.contains("..") {
        return false;
    }
    let mut candidates = Vec::with_capacity(2);
    candidates.push(std::path::PathBuf::from("/Applications").join(filename));
    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join("Applications").join(filename));
    }
    candidates.into_iter().any(|p| p.is_dir())
}

fn check_app_is_mas_macos(filename: &str) -> bool {
    if !filename.ends_with(".app") || filename.contains('/') || filename.contains("..") {
        return false;
    }
    let mut candidates = Vec::with_capacity(2);
    candidates.push(std::path::PathBuf::from("/Applications").join(filename));
    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join("Applications").join(filename));
    }
    candidates.into_iter().any(|p| {
        p.is_dir() && p.join("Contents").join("_MASReceipt").join("receipt").exists()
    })
}

// ---------- brew search plain stdout ----------

/// Parse `brew search` plain-stdout output, skipping section headers
/// (`==> Formulae`, `==> Casks`) and `If you meant ...` advice.
///
/// Returns just the package tokens, one per line, in document order.
pub fn parse_search_stdout(raw: &str) -> Vec<String> {
    raw.lines()
        .map(|l| l.trim())
        .filter(|l| {
            !l.is_empty()
                && !l.starts_with("==>")
                && !l.starts_with("If you meant")
                && !l.starts_with("Warning:")
                && !l.starts_with("Error:")
        })
        // brew search may print multiple tokens per line separated by whitespace
        .flat_map(|l| l.split_whitespace().map(|s| s.to_string()))
        .filter(|s| !s.is_empty())
        .collect()
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::PackageKind;

    /// Load a fixture file relative to `src-tauri/tests/fixtures/`.
    fn load_fixture(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join(name);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read fixture {}: {}", path.display(), e))
    }

    // ---------- RawFormula → Package ----------

    #[test]
    fn raw_formula_parses_brew_info_wget_fixture() {
        let raw = load_fixture("brew_info_wget.json");
        let parsed: RawInfoV2 = serde_json::from_str(&raw)
            .expect("brew info wget fixture must parse into RawInfoV2");
        assert_eq!(parsed.formulae.len(), 1, "wget fixture should yield one formula");
        assert!(parsed.casks.is_empty(), "wget fixture casks should be empty");

        let pkg = parsed.formulae[0].to_package();
        assert_eq!(pkg.name, "wget");
        assert_eq!(pkg.full_name, "wget");
        assert_eq!(pkg.kind, PackageKind::Formula);
        assert_eq!(pkg.description.as_deref(), Some("Internet file retriever"));
        assert_eq!(pkg.license.as_deref(), Some("GPL-3.0-or-later"));
        assert_eq!(pkg.tap.as_deref(), Some("homebrew/core"));
        assert_eq!(pkg.stable_version.as_deref(), Some("1.25.0"));
        assert_eq!(
            pkg.homepage.as_deref(),
            Some("https://www.gnu.org/software/wget/")
        );
    }

    #[test]
    fn raw_formula_to_detail_extracts_dependencies() {
        let raw = load_fixture("brew_info_wget.json");
        let parsed: RawInfoV2 = serde_json::from_str(&raw).expect("parse");
        let raw_value: serde_json::Value = serde_json::from_str(&raw).expect("value");
        let detail = parsed.formulae[0].to_detail(raw_value);

        // wget's known direct dependencies in homebrew/core
        assert!(
            detail.dependencies.contains(&"openssl@3".to_string()),
            "wget should depend on openssl@3, got {:?}",
            detail.dependencies
        );
        assert!(
            detail.dependencies.contains(&"libidn2".to_string()),
            "wget should depend on libidn2, got {:?}",
            detail.dependencies
        );
        // build_dependencies should include pkgconf
        assert!(
            detail.build_dependencies.contains(&"pkgconf".to_string()),
            "wget should have pkgconf as build dep, got {:?}",
            detail.build_dependencies
        );
        // raw_json should be preserved for the "raw" tab
        assert!(detail.raw_json.is_object());
    }

    #[test]
    fn raw_formula_list_parses_list_formula_fixture() {
        let raw = load_fixture("brew_list_formula.json");
        let parsed: RawInfoV2 =
            serde_json::from_str(&raw).expect("brew_list_formula fixture must parse");
        assert!(!parsed.formulae.is_empty());
        // The first entry must convert without panic and produce sensible defaults.
        let pkg = parsed.formulae[0].to_package();
        assert_eq!(pkg.kind, PackageKind::Formula);
        assert!(!pkg.name.is_empty(), "name should not be empty");
        assert!(!pkg.full_name.is_empty(), "full_name should fall back to name");
    }

    /// Phase 13b/12g — `github_homepage` resolution.
    ///
    /// Formulae with a non-GitHub homepage but a GitHub-hosted
    /// `urls.stable.url` should still surface a canonical GitHub
    /// homepage on the Package (the personal-stats card on the
    /// Dashboard counts these).
    #[test]
    fn formula_resolves_github_homepage_from_urls_stable_when_homepage_is_non_github() {
        let raw_json = serde_json::json!({
            "formulae": [{
                "name": "foo",
                "homepage": "https://www.example.org/foo",
                "urls": {
                    "stable": {
                        "url": "https://github.com/example-org/foo/archive/refs/tags/v1.2.3.tar.gz"
                    }
                }
            }],
            "casks": []
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.formulae[0].to_package();
        assert_eq!(
            pkg.homepage.as_deref(),
            Some("https://www.example.org/foo"),
            "raw homepage stays unchanged"
        );
        assert_eq!(
            pkg.github_homepage.as_deref(),
            Some("https://github.com/example-org/foo"),
            "github_homepage canonicalized from urls.stable.url"
        );
    }

    /// Formula homepage IS GitHub → resolution wins immediately on
    /// homepage; urls fallthrough never consulted.
    #[test]
    fn formula_resolves_github_homepage_from_homepage_first() {
        let raw_json = serde_json::json!({
            "formulae": [{
                "name": "foo",
                "homepage": "https://github.com/canonical-owner/foo",
                "urls": {
                    "stable": {
                        "url": "https://github.com/other-owner/foo/archive/refs/tags/v1.tar.gz"
                    }
                }
            }],
            "casks": []
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.formulae[0].to_package();
        assert_eq!(
            pkg.github_homepage.as_deref(),
            Some("https://github.com/canonical-owner/foo"),
            "homepage wins over urls.stable.url"
        );
    }

    /// Formula with no GitHub-resolvable URL → github_homepage stays None.
    #[test]
    fn formula_with_no_github_url_has_none_github_homepage() {
        let raw_json = serde_json::json!({
            "formulae": [{
                "name": "foo",
                "homepage": "https://www.example.org/foo",
                "urls": {
                    "stable": {
                        "url": "https://ftp.example.com/foo-1.0.tar.gz"
                    }
                }
            }],
            "casks": []
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.formulae[0].to_package();
        assert!(pkg.github_homepage.is_none());
    }

    /// Formula head url fills in when both homepage and stable url miss.
    #[test]
    fn formula_falls_through_to_head_url() {
        let raw_json = serde_json::json!({
            "formulae": [{
                "name": "foo",
                "homepage": "https://example.org",
                "urls": {
                    "head": {
                        "url": "https://github.com/example/foo.git"
                    }
                }
            }],
            "casks": []
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.formulae[0].to_package();
        assert_eq!(
            pkg.github_homepage.as_deref(),
            Some("https://github.com/example/foo"),
            "head url resolves when homepage and stable url miss"
        );
    }

    // ---------- RawCask → Package ----------

    #[test]
    fn raw_cask_parses_brew_info_firefox_fixture() {
        let raw = load_fixture("brew_info_firefox.json");
        let parsed: RawInfoV2 = serde_json::from_str(&raw)
            .expect("brew info firefox fixture must parse into RawInfoV2");
        assert!(parsed.formulae.is_empty(), "firefox fixture formulae should be empty");
        assert_eq!(parsed.casks.len(), 1, "firefox fixture should yield one cask");

        let pkg = parsed.casks[0].to_package();
        assert_eq!(pkg.name, "firefox");
        assert_eq!(pkg.full_name, "firefox");
        assert_eq!(pkg.kind, PackageKind::Cask);
        assert_eq!(pkg.description.as_deref(), Some("Web browser"));
        assert_eq!(pkg.tap.as_deref(), Some("homebrew/cask"));
        assert!(pkg.stable_version.is_some(), "cask should have a stable_version");
        // Cask info from formulae.brew.sh has no license field — we tolerate it.
        assert_eq!(pkg.license, None);
    }

    #[test]
    fn raw_cask_to_detail_extracts_artifacts() {
        let raw = load_fixture("brew_info_firefox.json");
        let parsed: RawInfoV2 = serde_json::from_str(&raw).expect("parse");
        let raw_value: serde_json::Value = serde_json::from_str(&raw).expect("value");
        let detail = parsed.casks[0].to_detail(raw_value);
        // Firefox cask artifacts include "Firefox.app".
        assert!(
            detail.installed_paths.iter().any(|p| p.contains("Firefox")),
            "expected installed_paths to mention Firefox.app, got {:?}",
            detail.installed_paths
        );
    }

    #[test]
    fn raw_cask_list_parses_list_cask_fixture() {
        let raw = load_fixture("brew_list_cask.json");
        let parsed: RawInfoV2 =
            serde_json::from_str(&raw).expect("brew_list_cask fixture must parse");
        assert!(!parsed.casks.is_empty());
        let pkg = parsed.casks[0].to_package();
        assert_eq!(pkg.kind, PackageKind::Cask);
        assert!(!pkg.name.is_empty());
    }

    /// Cask with non-GitHub `homepage` but GitHub Releases `url` →
    /// github_homepage resolves from the binary URL. This is the bulk
    /// of the coverage win on the Dashboard's personal-stats card.
    #[test]
    fn cask_resolves_github_homepage_from_url_when_homepage_is_non_github() {
        let raw_json = serde_json::json!({
            "formulae": [],
            "casks": [{
                "token": "foo-app",
                "homepage": "https://foo-app.com",
                "url": "https://github.com/example-org/foo-app/releases/download/v1.2.3/foo-1.2.3.dmg",
                "version": "1.2.3"
            }]
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.casks[0].to_package();
        assert_eq!(
            pkg.homepage.as_deref(),
            Some("https://foo-app.com"),
            "raw homepage stays unchanged"
        );
        assert_eq!(
            pkg.github_homepage.as_deref(),
            Some("https://github.com/example-org/foo-app"),
            "github_homepage resolved from cask url field"
        );
    }

    /// Cask with neither GitHub homepage nor GitHub url → None.
    #[test]
    fn cask_with_no_github_url_has_none_github_homepage() {
        let raw_json = serde_json::json!({
            "formulae": [],
            "casks": [{
                "token": "foo-app",
                "homepage": "https://foo-app.com",
                "url": "https://cdn.foo-app.com/releases/foo-1.0.dmg",
                "version": "1.0"
            }]
        });
        let parsed: RawInfoV2 = serde_json::from_value(raw_json).expect("parse");
        let pkg = parsed.casks[0].to_package();
        assert!(pkg.github_homepage.is_none());
    }

    // ---------- RawOutdatedEntry → OutdatedPackage ----------

    #[test]
    fn raw_outdated_parses_fixture() {
        let raw = load_fixture("brew_outdated.json");
        let parsed: RawOutdatedV2 =
            serde_json::from_str(&raw).expect("brew_outdated fixture must parse");
        assert!(!parsed.formulae.is_empty(), "should have at least one outdated formula");

        let first = &parsed.formulae[0];
        let dto = first.to_dto(PackageKind::Formula);
        assert_eq!(dto.name, first.name);
        assert_eq!(dto.kind, PackageKind::Formula);
        assert!(!dto.current_version.is_empty());
        assert!(!dto.installed_versions.is_empty());
    }

    // ---------- parse_search_stdout ----------

    #[test]
    fn parse_search_stdout_handles_plain_token_list() {
        let raw = "wget\nwget2\nwgetpaste\n";
        let out = parse_search_stdout(raw);
        assert_eq!(out, vec!["wget", "wget2", "wgetpaste"]);
    }

    #[test]
    fn parse_search_stdout_skips_section_headers_and_advice() {
        let raw = load_fixture("brew_search_with_sections.txt");
        let out = parse_search_stdout(&raw);
        // No `==>` lines, no "If you meant ..." lines.
        assert!(!out.iter().any(|t| t.starts_with("==>")));
        assert!(!out.iter().any(|t| t == "If"));
        // Real package tokens are present.
        assert!(out.contains(&"wget".to_string()));
        assert!(out.contains(&"wget-gui".to_string()));
    }

    #[test]
    fn parse_search_stdout_real_fixture_yields_tokens() {
        let raw = load_fixture("brew_search_wget.txt");
        let out = parse_search_stdout(&raw);
        assert!(out.contains(&"wget".to_string()));
        assert!(out.contains(&"wget2".to_string()));
    }

    #[test]
    fn parse_search_stdout_drops_warnings_and_errors() {
        let raw = "Warning: not great\nError: missing\nactual-pkg\n";
        let out = parse_search_stdout(raw);
        assert_eq!(out, vec!["actual-pkg"]);
    }

    #[test]
    fn parse_search_stdout_splits_multi_token_lines() {
        // Some brew versions print whitespace-separated tokens on one line.
        let raw = "wget wget2 wgetpaste\n";
        let out = parse_search_stdout(raw);
        assert_eq!(out, vec!["wget", "wget2", "wgetpaste"]);
    }

    #[test]
    fn parse_search_stdout_empty_input_yields_empty_vec() {
        assert!(parse_search_stdout("").is_empty());
        assert!(parse_search_stdout("\n\n\n").is_empty());
    }

    // ---------- extract_analytics_30d ----------

    #[test]
    fn extract_analytics_30d_returns_none_when_missing() {
        assert_eq!(extract_analytics_30d(&None), None);
        assert_eq!(extract_analytics_30d(&Some(serde_json::json!({}))), None);
    }

    #[test]
    fn extract_analytics_30d_returns_value_when_present() {
        let v = serde_json::json!({
            "install": {
                "30d": { "wget": 42_u64 }
            }
        });
        assert_eq!(extract_analytics_30d(&Some(v)), Some(42));
    }

    // ---------- icon_source classifier (Phase 8) ----------

    use crate::types::IconSource;

    fn cask_with(
        installed: Option<&str>,
        homepage: Option<&str>,
    ) -> RawCask {
        RawCask {
            token: "demo".into(),
            full_token: None,
            name: Vec::new(),
            tap: None,
            desc: None,
            homepage: homepage.map(|s| s.to_string()),
            url: None,
            version: None,
            installed: installed.map(|s| s.to_string()),
            pinned: false,
            outdated: false,
            caveats: None,
            conflicts_with: None,
            depends_on: None,
            artifacts: None,
        }
    }

    #[test]
    fn cask_icon_source_installed_uses_installed_app_variant() {
        // An installed cask always routes to the Phase 7 .app-bundle path,
        // regardless of whether a homepage is present.
        let cask = cask_with(Some("1.0.0"), Some("https://example.com"));
        match cask.to_package().icon_source {
            IconSource::InstalledApp => {}
            other => panic!("expected InstalledApp, got {:?}", other),
        }
    }

    #[test]
    fn cask_icon_source_installed_without_homepage_still_installed_app() {
        let cask = cask_with(Some("1.0.0"), None);
        assert!(matches!(
            cask.to_package().icon_source,
            IconSource::InstalledApp
        ));
    }

    #[test]
    fn cask_icon_source_uninstalled_with_homepage_uses_cascade_variant() {
        let cask = cask_with(None, Some("https://example.com"));
        match cask.to_package().icon_source {
            IconSource::Homepage { homepage } => {
                assert_eq!(homepage, "https://example.com");
            }
            other => panic!("expected Homepage, got {:?}", other),
        }
    }

    #[test]
    fn cask_icon_source_trims_homepage_whitespace() {
        // A stray newline / spaces in upstream metadata mustn't leak into
        // the URL the favicon cascade probes.
        let cask = cask_with(None, Some("  https://example.com\n"));
        match cask.to_package().icon_source {
            IconSource::Homepage { homepage } => {
                assert_eq!(homepage, "https://example.com");
            }
            other => panic!("expected Homepage, got {:?}", other),
        }
    }

    #[test]
    fn cask_icon_source_uninstalled_with_empty_homepage_is_none() {
        // Empty / whitespace-only strings shouldn't trigger a network probe.
        for empty in ["", "   ", "\n\t"] {
            let cask = cask_with(None, Some(empty));
            assert!(
                matches!(cask.to_package().icon_source, IconSource::None),
                "homepage={:?} should classify as None",
                empty
            );
        }
    }

    #[test]
    fn cask_icon_source_uninstalled_without_homepage_is_none() {
        let cask = cask_with(None, None);
        assert!(matches!(cask.to_package().icon_source, IconSource::None));
    }

    #[test]
    fn formula_icon_source_is_always_none() {
        // Formulae are CLI tools — no icon to fetch even if a homepage exists.
        let raw = RawFormula {
            name: "wget".into(),
            full_name: None,
            tap: None,
            desc: None,
            license: None,
            homepage: Some("https://www.gnu.org/software/wget/".into()),
            versions: None,
            urls: None,
            build_dependencies: vec![],
            dependencies: vec![],
            optional_dependencies: vec![],
            conflicts_with: vec![],
            requirements: vec![],
            caveats: None,
            installed: vec![],
            options: vec![],
            pinned: false,
            outdated: false,
            analytics: None,
        };
        assert!(matches!(raw.to_package().icon_source, IconSource::None));
    }

    #[test]
    fn test_raw_cask_exists_in_applications_fallback_candidates() {
        let raw = RawCask {
            token: "codex".into(),
            full_token: None,
            name: vec!["Codex".into()],
            tap: None,
            desc: None,
            homepage: None,
            url: None,
            version: None,
            installed: None,
            pinned: false,
            outdated: false,
            caveats: None,
            conflicts_with: None,
            depends_on: None,
            artifacts: None,
        };
        let detail = raw.to_detail(serde_json::Value::Null);
        let _ = detail.exists_in_applications;
        let _ = detail.is_mas;
    }
}
