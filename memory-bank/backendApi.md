# Backend API Specification

**Owner:** Backend Architect
**Status:** Live spec. Wave 1 wrote it; Waves 2–17 implemented + extended.
**Last updated:** 2026-05-25 (v0.3.0 shipped — adds Phase 15 in-app updater commands + §13.11 today's brew_upgrade_many + brew_list force-refresh signature)

This document is the complete contract for the Rust backend of `brew-browser`. Every Tauri command, every typed payload, every error variant, every IPC pattern lives here. Wave 2 implementation is a mechanical translation of this spec into Rust; Wave 3 validation runs against it.

---

## 0. Guiding principles

1. **Shell out to `brew`.** Never reimplement Homebrew logic. Prefer `--json=v2` outputs. Parse with `serde_json` into typed structs.
2. **Use `tokio::process::Command`.** Never `std::process::Command`. Async only.
3. **No `tauri-plugin-shell`.** The frontend cannot pass arbitrary shell strings. Every brew invocation is constructed in Rust from a small, enumerated set of typed inputs. The IPC boundary is the security boundary.
4. **Serialize writes through a `Mutex<()>`.** Reads can bypass it; writes never do.
5. **Stream long-running work via Tauri events**, never collect into a single oversized string.
6. **Errors are typed.** A single `BrewError` enum serializes to a stable JSON shape the frontend can switch on.
7. **No telemetry. No surprise network calls.** Only `brew` itself + `formulae.brew.sh` for trending.

---

## 1. Command surface — all 6 phases

Every command is `async`. Every command returns `Result<T, BrewError>` (serialized as a Tauri error). Streaming commands return `Result<StreamHandle, BrewError>` immediately and emit events to the provided channel.

### Phase 1 — Read-only browser

| Command | Signature | What it does | Underlying brew | Streams? | Mutex? |
|---|---|---|---|---|---|
| `brew_doctor` | `async fn brew_doctor() -> Result<BrewEnvironment, BrewError>` | Probes whether `brew` is on PATH and returns version + prefix. Called once at startup. | `brew --version` and `brew --prefix` | no | no |
| `brew_list` | `async fn brew_list() -> Result<PackageList, BrewError>` | Lists all installed formulae and casks with versions, descriptions, and install metadata. | `brew info --installed --json=v2` (one call yields both formulae and casks) | no | shared-read |
| `brew_info` | `async fn brew_info(name: String, kind: PackageKind) -> Result<PackageDetail, BrewError>` | Full detail for a single package: deps, conflicts, options, caveats, install state. | `brew info --json=v2 --formula <name>` or `--cask <name>` | no | shared-read |
| `brew_outdated` | `async fn brew_outdated() -> Result<Vec<OutdatedPackage>, BrewError>` | Lists packages with available upgrades (drives the "Updates" badge). | `brew outdated --json=v2 --greedy` | no | shared-read |

### Phase 2 — Search

| Command | Signature | What it does | Underlying brew | Streams? | Mutex? |
|---|---|---|---|---|---|
| `brew_search` | `async fn brew_search(query: String) -> Result<SearchResults, BrewError>` | Searches the Homebrew index for matching formulae and casks. | `brew search --formula <q>` and `brew search --cask <q>` (parallel within the command; plain stdout — no `--json` support) | no | shared-read |
| `brew_search_desc` | `async fn brew_search_desc(query: String) -> Result<SearchResults, BrewError>` | Searches by description text. Optional / "Phase 2.1" if time permits. | `brew search --desc <q>` | no | shared-read |
| `local_search` | `async fn local_search(query: String, locale: Option<String>, state) -> Result<SearchResults, BrewError>` | In-memory search across package token/name, upstream desc, bundled enrichment, category labels, tags, and locale overlay search terms. `locale` selects a partial `enrichment.<locale>.json.gz` overlay when present, while English fields remain searchable fallbacks. | none — scans bundled/user-refreshed catalog already in memory | no | no |

### Phase 3 — Install / uninstall / upgrade (streaming)

All Phase 3 commands return immediately with a `StreamHandle { job_id: Uuid, event_name: String }`. The frontend subscribes to `event_name`; Rust emits `BrewStreamEvent` payloads until the final event with `kind: "exit"`.

| Command | Signature | What it does | Underlying brew | Streams? | Mutex? |
|---|---|---|---|---|---|
| `brew_install` | `async fn brew_install(name: String, kind: PackageKind, on_event: Channel<BrewStreamEvent>) -> Result<JobResult, BrewError>` | Installs a formula or cask, streaming stdout/stderr live. | `brew install --formula <name>` or `--cask <name>` | yes (`on_event` channel) | **WRITE** |
| `brew_uninstall` | `async fn brew_uninstall(name: String, kind: PackageKind, zap: bool, on_event: Channel<BrewStreamEvent>) -> Result<JobResult, BrewError>` | Uninstalls. `zap=true` for casks adds `--zap` to also remove app data. | `brew uninstall --formula <name>` / `brew uninstall --cask <name> [--zap]` | yes | **WRITE** |
| `brew_upgrade` | `async fn brew_upgrade(name: Option<String>, on_event: Channel<BrewStreamEvent>) -> Result<JobResult, BrewError>` | Upgrades a single package, or all packages if `name: None`. | `brew upgrade [<name>]` (no `--json` — we stream raw) | yes | **WRITE** |
| `brew_update` | `async fn brew_update(on_event: Channel<BrewStreamEvent>) -> Result<JobResult, BrewError>` | Refreshes Homebrew's index. Triggers prior to any "check outdated" surface. | `brew update` | yes | **WRITE** |
| `cancel_job` | `async fn cancel_job(job_id: Uuid) -> Result<(), BrewError>` | Best-effort SIGTERM on a running streaming job. See §4.4. | (kills child process) | no | no (locks the job table briefly) |

> **Streaming choice — `Channel<T>` vs `app.emit`.** Use Tauri 2's typed `tauri::ipc::Channel<BrewStreamEvent>` (passed as a command argument from the frontend) rather than global `app.emit`. Channels are per-invocation, automatically scoped, garbage-collected when the JS side drops them, and don't pollute the global event namespace. This is the Tauri 2 idiomatic pattern for per-job streaming.

### Phase 4 — Brewfile snapshot + restore

| Command | Signature | What it does | Underlying brew | Streams? | Mutex? |
|---|---|---|---|---|---|
| `brewfile_dump` | `async fn brewfile_dump(label: String, on_event: Channel<BrewStreamEvent>) -> Result<BrewfileSummary, BrewError>` | Dumps the current Homebrew state to a labeled Brewfile under app-data. | `brew bundle dump --file=<resolved path> --force` | yes (dump is slow on large libraries) | **WRITE** |
| `brewfile_install` | `async fn brewfile_install(id: BrewfileId, on_event: Channel<BrewStreamEvent>) -> Result<JobResult, BrewError>` | Installs every entry in a saved Brewfile. | `brew bundle install --file=<path>` | yes | **WRITE** |
| `brewfile_check` | `async fn brewfile_check(id: BrewfileId) -> Result<BrewfileCheckReport, BrewError>` | Dry-run check: what's missing vs already installed. | `brew bundle check --file=<path> --verbose` | no | shared-read |
| `brewfile_list` | `async fn brewfile_list() -> Result<Vec<BrewfileSummary>, BrewError>` | Lists saved Brewfiles in the app-data directory with metadata. | (filesystem only) | no | no |
| `brewfile_read` | `async fn brewfile_read(id: BrewfileId) -> Result<Brewfile, BrewError>` | Returns full parsed Brewfile content + raw text. | (filesystem only) | no | no |
| `brewfile_delete` | `async fn brewfile_delete(id: BrewfileId) -> Result<(), BrewError>` | Deletes a saved Brewfile. | (filesystem only) | no | no |
| `brewfile_export` | `async fn brewfile_export(id: BrewfileId, target_path: String) -> Result<(), BrewError>` | Copies a saved Brewfile to a user-chosen path (after `tauri-plugin-dialog` picker on the frontend). | (filesystem only) | no | no |
| `brewfile_import` | `async fn brewfile_import(source_path: String, label: String) -> Result<BrewfileSummary, BrewError>` | Imports an external Brewfile into the managed app-data directory. | (filesystem only) | no | no |

### Phase 6 — Trending

| Command | Signature | What it does | Underlying call | Streams? | Mutex? |
|---|---|---|---|---|---|
| `trending_fetch` | `async fn trending_fetch(window: TrendingWindow) -> Result<TrendingReport, BrewError>` | Returns top-N installed packages from Homebrew's published analytics. Cached. | HTTP GET `https://formulae.brew.sh/api/analytics/install/<30d\|90d\|365d>.json` | no | no (uses dedicated trending cache mutex) |
| `trending_clear_cache` | `async fn trending_clear_cache() -> Result<(), BrewError>` | Forces a refetch on next `trending_fetch`. | (clears cache) | no | no |

### Phase 7 — Cask icon extraction (installed)

| Command | Signature | What it does | Underlying call | Streams? | Mutex? |
|---|---|---|---|---|---|
| `cask_icon` | `async fn cask_icon(token: String) -> Result<Option<String>, BrewError>` | Extracts the `.app` bundle icon for an installed cask and returns it as a base64 `data:image/png;base64,...` URL the frontend can drop into `<img src=...>`. Output is a 64×64 PNG. Cached at `<cache_dir>/icons/<token>.png` for 7 days. `Ok(None)` when the cask is not installed or has no usable `.icns` (pkg-installer casks, bare-binary casks, missing Info.plist). | `brew info --json=v2 --cask <token>` (for the `.app` filename) + `/usr/bin/defaults read <Info.plist> CFBundleIconFile` + `/usr/bin/sips -s format png -z 64 64 <input.icns> --out <cache_dir>/icons/<token>.png` | no | no (read-only filesystem op; multiple icon fetches can run concurrently) |

### Phase 8 — Cask icon cascade (uninstalled)

| Command | Signature | What it does | Underlying call | Streams? | Mutex? |
|---|---|---|---|---|---|
| `cask_icon_from_homepage` | `async fn cask_icon_from_homepage(token: String, homepage: String) -> Result<Option<String>, BrewError>` | Probes a small favicon/og:image cascade against an uninstalled cask's homepage and returns a 64×64 PNG as a base64 data URL. Shares the same on-disk cache slot as `cask_icon` (`<cache_dir>/icons/<token>.png`) so a later install transparently overwrites the homepage-derived icon with the real bundle icon. `Ok(None)` is the common case for casks whose homepage exposes nothing usable. | `reqwest::Client` GET requests to `<scheme>://<host>/apple-touch-icon.png`, the homepage HTML (capped at 64 KB) scanned for `<meta og:image>`, and `<scheme>://<host>/favicon.ico` — first 2xx with `image/*` Content-Type wins. Each candidate runs through `/usr/bin/sips -s format png -z 64 64` to normalize. | no | no (read-only network + filesystem op; multiple cascade fetches can run concurrently) |

**Return shape:** `Option<String>` — same shape as `cask_icon`. `Some` is a complete `data:image/png;base64,…` URL; `None` signals "no usable icon — render fallback glyph."

**Cascade order (first 2xx + `image/*` wins):**

1. `<scheme>://<host>/apple-touch-icon.png` — Apple-blessed convention; works for most modern web properties.
2. `<meta property="og:image">` parsed from the homepage HTML — pulls hero/marketing artwork.
3. `<scheme>://<host>/favicon.ico` — the universal fallback.

**Validation:**
- `token` runs through `validate_package_name` (same gate as `cask_icon`).
- `homepage` must parse as `http://` or `https://`. Other schemes (`data:`, `javascript:`, `file:`, `ftp:`) collapse to `Ok(None)` and the sticky-null marker is touched.

**Caching:** PNG sits at `<cache_dir>/icons/<token>.png` — **same path as `cask_icon`**, so when an uninstalled cask becomes installed later, the Phase 7 path overwrites without any rename/migration logic. A 7-day TTL matches `cask_icon`.

**Sticky-null marker:** when the full cascade misses, a zero-byte `<cache_dir>/icons/<token>.png.miss` file is touched so subsequent invocations return `Ok(None)` without re-probing the network for 7 days. The marker uses a `.png.miss` suffix to guarantee it can never collide with a real PNG payload.

**HTTP politeness:**
- `User-Agent: brew-browser/0.1 (+https://github.com/msitarzewski/brew-browser)`
- 5-second timeout per probe.
- Redirects followed by default reqwest policy.
- HTML body capped at 64 KB before parsing.

**Why no Mutex:** Pure read-only op. Multiple cascade fetches for different tokens proceed in parallel — important for Discover/Trending views with dozens of uninstalled casks visible.

**Cases that return `Ok(None)` (Frontend Developer — render a fallback glyph for these):**

1. Homepage URL is non-http(s) or unparseable (sticky-null marker written).
2. All three cascade steps return non-2xx, non-image, empty body, or transport errors.
3. `sips` failed to normalize the fetched bytes (corrupt PNG, exotic ICO variant) — treated as a probe miss to avoid surfacing image-format errors that no end user can act on.
4. Sticky-null marker exists within TTL from a prior failed cascade.

**Cases that return `Err(...)`:**

- Token fails `validate_package_name` (`BrewError::InvalidArgument`).
- Cache directory cannot be created (`BrewError::Io`).
- Reading back a cached PNG to encode as a data URL fails mid-read (`BrewError::Io`).

> **Important distinction for the frontend cache layer:** network flakes (DNS hiccup, transient 500, slow origin past the 5s timeout) all collapse to `Ok(None)` and write the sticky-null marker — they look identical to "the homepage genuinely has no icon" from the frontend's perspective. If you need a different UX for "we'll retry later" vs "permanent miss", you'd have to widen the return shape; today they're indistinguishable by design (UI quiet over correctness-of-categorization).

---

### IconSource — routing hint embedded in every Package

The `Package` DTO carries an `iconSource` field that tells the frontend which command (if any) to invoke for each row, so the routing logic lives with the data instead of being re-derived from `(kind, installedVersion, homepage)` at every render site.

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum IconSource {
    /// Cask is installed → call `cask_icon(token)` (Phase 7).
    InstalledApp,
    /// Cask is not installed but exposes a homepage → call
    /// `cask_icon_from_homepage(token, homepage)` (Phase 8).
    Homepage { homepage: String },
    /// No icon available → render fallback glyph.
    None,
}
```

```ts
export type IconSource =
  | { kind: "installedApp" }
  | { kind: "homepage"; homepage: string }
  | { kind: "none" };

export interface Package {
  // ...all prior fields unchanged...
  iconSource: IconSource;
}
```

**Classification rule (in `RawCask::to_package` and `RawFormula::to_package`):**

| Package state | `iconSource` variant |
|---|---|
| Cask, installed (any) | `InstalledApp` |
| Cask, uninstalled, homepage present (non-empty after trim) | `Homepage { homepage }` |
| Cask, uninstalled, no homepage / empty homepage | `None` |
| Formula (any state) | `None` (always) |

Homepage strings are trimmed; whitespace-only collapses to `None` so a stray `""` or `"\n"` in upstream metadata can't trigger a network probe.

**Return shape:** `Option<String>` where `Some` carries a complete `data:image/png;base64,…` URL string and `None` signals "no icon available — render fallback glyph on the frontend."

**Path resolution:** Resolves to `/Applications/<Name>.app` first, falls back to `~/Applications/<Name>.app`. Files outside those two roots are intentionally ignored (no shell glob, no traversal). Filenames containing `/` or `..` are rejected before disk touch.

**Validation:** `token` runs through `validate_package_name` (rejects empty, leading `-`, shell metacharacters, control chars, anything outside `[A-Za-z0-9._+/-@]`).

**Caching:** PNG sits on disk at `<state.cache_dir>/icons/<token>.png` where `cache_dir` is `~/Library/Application Support/brew-browser/`. Cache hit if mtime is within `ICON_CACHE_TTL` (7 days). On hit we skip `defaults` + `sips` entirely and just base64-read the cached file.

**Why no Mutex:** Pure read-only filesystem op. We don't touch brew state, don't take the write lock. Concurrent calls for different tokens proceed in parallel.

**Cases that return `Ok(None)` (Frontend Developer — render a fallback glyph for these):**

1. Cask not installed (the `installed` field in `brew info` is null).
2. Cask's `artifacts[]` has no `app` entry (e.g. pkg-installer casks like `docker-cli`, font casks, binary-only casks).
3. The `.app` bundle isn't in `/Applications` or `~/Applications` (user moved it; we don't crawl the filesystem).
4. `Contents/Info.plist` exists but `CFBundleIconFile` is unset AND `Contents/Resources/` has no `*.icns`.
5. `brew info --json=v2 --cask <token>` exits non-zero (unknown token, transient brew failure). These collapse to `Ok(None)` so a fetch hiccup doesn't paint an error toast over the Library row.

**Cases that return `Err(...)`:**

- `sips` is missing or crashes mid-conversion (`BrewError::Io`).
- Cache directory cannot be created (`BrewError::Io`).
- `brew` is not on PATH (`BrewError::BrewNotFound`).
- Token fails validation (`BrewError::InvalidArgument`).

---

## 2. Typed return shapes

All structs are `#[derive(Debug, Clone, Serialize, Deserialize)]` with `#[serde(rename_all = "camelCase")]`. The TypeScript equivalents below are what the frontend should declare in `src/lib/types.ts`.

### 2.1 Common enums

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PackageKind {
    Formula,
    Cask,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TrendingWindow {
    #[serde(rename = "30d")] D30,
    #[serde(rename = "90d")] D90,
    #[serde(rename = "365d")] D365,
}
```

```ts
export type PackageKind = "formula" | "cask";
export type TrendingWindow = "30d" | "90d" | "365d";
```

### 2.2 Environment probe

```rust
pub struct BrewEnvironment {
    pub installed: bool,
    pub version: Option<String>,        // e.g. "5.1.13"
    pub prefix: Option<String>,         // e.g. "/opt/homebrew"
    pub path_used: Option<String>,      // resolved absolute path to `brew`
}
```

```ts
export interface BrewEnvironment {
  installed: boolean;
  version: string | null;
  prefix: string | null;
  pathUsed: string | null;
}
```

### 2.3 Package list (Phase 1)

```rust
pub struct Package {
    pub name: String,
    pub full_name: String,         // tap-qualified, e.g. "homebrew/core/wget"
    pub kind: PackageKind,
    pub installed_version: Option<String>,
    pub stable_version: Option<String>,
    pub description: Option<String>,
    pub homepage: Option<String>,
    pub license: Option<String>,
    pub tap: Option<String>,
    pub outdated: bool,
    pub pinned: bool,
    pub installed_on_request: bool, // false = pulled in as a dep
    pub installed_as_dependency: bool,
    pub icon_source: IconSource,    // Phase 8 — routing hint for icon-fetch path
}

pub struct PackageList {
    pub formulae: Vec<Package>,
    pub casks: Vec<Package>,
    pub generated_at: String, // ISO-8601
}
```

```ts
export interface Package {
  name: string;
  fullName: string;
  kind: PackageKind;
  installedVersion: string | null;
  stableVersion: string | null;
  description: string | null;
  homepage: string | null;
  license: string | null;
  tap: string | null;
  outdated: boolean;
  pinned: boolean;
  installedOnRequest: boolean;
  installedAsDependency: boolean;
  iconSource: IconSource; // Phase 8 — routing hint
}

export interface PackageList {
  formulae: Package[];
  casks: Package[];
  generatedAt: string;
}
```

### 2.4 Package detail (Phase 1)

```rust
pub struct PackageDetail {
    pub package: Package,
    pub caveats: Option<String>,
    pub dependencies: Vec<String>,
    pub build_dependencies: Vec<String>,
    pub optional_dependencies: Vec<String>,
    pub conflicts_with: Vec<String>,
    pub requirements: Vec<String>,    // e.g. "macos >= 12"
    pub options: Vec<PackageOption>,
    pub installed_paths: Vec<String>, // kegs / app bundles
    pub analytics_30d_installs: Option<u64>,
    pub raw_json: serde_json::Value,  // full --json=v2 record for the detail panel "raw" tab
}

pub struct PackageOption {
    pub flag: String,
    pub description: String,
}
```

```ts
export interface PackageOption {
  flag: string;
  description: string;
}
export interface PackageDetail {
  package: Package;
  caveats: string | null;
  dependencies: string[];
  buildDependencies: string[];
  optionalDependencies: string[];
  conflictsWith: string[];
  requirements: string[];
  options: PackageOption[];
  installedPaths: string[];
  analytics30dInstalls: number | null;
  rawJson: unknown;
}
```

### 2.5 Outdated (Phase 1 / Phase 3)

```rust
pub struct OutdatedPackage {
    pub name: String,
    pub kind: PackageKind,
    pub installed_versions: Vec<String>,
    pub current_version: String,
    pub pinned: bool,
    pub pinned_version: Option<String>,
}
```

### 2.6 Search results (Phase 2)

```rust
pub struct SearchHit {
    pub name: String,
    pub kind: PackageKind,
    pub installed: bool,                  // cross-referenced against brew_list cache
    pub description: Option<String>,      // populated lazily / from cache
}

pub struct SearchResults {
    pub query: String,
    pub formulae: Vec<SearchHit>,
    pub casks: Vec<SearchHit>,
    pub generated_at: String,
}
```

### 2.7 Streaming events (Phase 3 & 4)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BrewStreamEvent {
    Started { job_id: Uuid, command: String, started_at: String },
    Stdout { job_id: Uuid, line: String, ts: String },
    Stderr { job_id: Uuid, line: String, ts: String },
    Progress { job_id: Uuid, message: String, percent: Option<f32> }, // heuristic; brew rarely emits structured progress
    Exit    { job_id: Uuid, exit_code: i32, success: bool, duration_ms: u64 },
    Canceled { job_id: Uuid },
    Error   { job_id: Uuid, error: BrewError },
}

pub struct StreamHandle {
    pub job_id: Uuid,
}

pub struct JobResult {
    pub job_id: Uuid,
    pub exit_code: i32,
    pub success: bool,
    pub duration_ms: u64,
}
```

```ts
export type BrewStreamEvent =
  | { kind: "started";  jobId: string; command: string; startedAt: string }
  | { kind: "stdout";   jobId: string; line: string; ts: string }
  | { kind: "stderr";   jobId: string; line: string; ts: string }
  | { kind: "progress"; jobId: string; message: string; percent: number | null }
  | { kind: "exit";     jobId: string; exitCode: number; success: boolean; durationMs: number }
  | { kind: "canceled"; jobId: string }
  | { kind: "error";    jobId: string; error: BrewErrorPayload };

export interface JobResult {
  jobId: string;
  exitCode: number;
  success: boolean;
  durationMs: number;
}
```

> **Why a tagged enum?** The frontend `<ActionConsole>` is a single switch on `event.kind`; new variants (e.g. `Progress`) can be added without breaking older consumers.

### 2.8 Brewfile (Phase 4)

```rust
pub type BrewfileId = String; // sanitized filename stem, e.g. "2026-05-23_pre-upgrade"

pub struct BrewfileSummary {
    pub id: BrewfileId,
    pub label: String,
    pub path: String,                 // absolute path on disk
    pub created_at: String,
    pub size_bytes: u64,
    pub counts: BrewfileCounts,
}

pub struct BrewfileCounts {
    pub taps: usize,
    pub formulae: usize,
    pub casks: usize,
    pub mas_apps: usize,
    pub vscode_extensions: usize,
}

pub struct Brewfile {
    pub summary: BrewfileSummary,
    pub entries: BrewfileEntries,
    pub raw_text: String,
}

pub struct BrewfileEntries {
    pub taps: Vec<String>,
    pub formulae: Vec<BrewfileFormula>,
    pub casks: Vec<BrewfileCask>,
    pub mas_apps: Vec<BrewfileMasApp>,
    pub vscode_extensions: Vec<String>,
}

pub struct BrewfileFormula { pub name: String, pub args: Vec<String> }
pub struct BrewfileCask    { pub name: String, pub args: Vec<String> }
pub struct BrewfileMasApp  { pub name: String, pub id: u64 }

pub struct BrewfileCheckReport {
    pub satisfied: bool,
    pub missing_taps: Vec<String>,
    pub missing_formulae: Vec<String>,
    pub missing_casks: Vec<String>,
    pub missing_mas_apps: Vec<String>,
    pub missing_vscode_extensions: Vec<String>,
}
```

### 2.9 Trending (Phase 6)

```rust
pub struct TrendingEntry {
    pub rank: u32,                    // 1-based
    pub name: String,
    pub kind: PackageKind,            // formula vs cask (analytics endpoints are kind-specific)
    pub install_count: u64,
    pub install_count_formatted: String, // "1,234,567"
    pub installed_locally: bool,      // cross-referenced against brew_list
}

pub struct TrendingReport {
    pub window: TrendingWindow,
    pub fetched_at: String,            // ISO-8601 of cache fill time
    pub cache_age_seconds: u64,
    pub total_count: u64,
    pub entries: Vec<TrendingEntry>,   // top 100, frontend can slice
}
```

---

## 3. Error model

### 3.1 The enum

```rust
use thiserror::Error;

#[derive(Debug, Error, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum BrewError {
    #[error("brew CLI not found on PATH")]
    BrewNotFound,

    #[error("brew exited with status {exit_code}: {stderr_excerpt}")]
    BrewExitNonZero {
        command: String,
        exit_code: i32,
        stderr_excerpt: String,        // last ~4 KB of stderr
    },

    #[error("failed to parse brew JSON output: {message}")]
    JsonParse {
        command: String,
        message: String,
        raw_excerpt: String,           // first ~2 KB of the offending blob
    },

    #[error("I/O error: {message}")]
    Io { message: String },

    #[error("network error fetching {url}: {message}")]
    Network { url: String, message: String },

    #[error("HTTP {status} fetching {url}")]
    HttpStatus { url: String, status: u16 },

    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },

    #[error("job {job_id} not found")]
    JobNotFound { job_id: String },

    #[error("operation canceled")]
    Canceled,

    #[error("Brewfile {id} not found")]
    BrewfileNotFound { id: String },

    #[error("internal error: {message}")]
    Internal { message: String },
}
```

### 3.2 Serialization across the IPC boundary

Tauri 2 will JSON-serialize anything that implements `Serialize` on the error type of a `Result`. The frontend receives the JSON shape and `invoke()` throws with it as the rejection value. Concretely:

- Wave 2 must implement `Serialize` on `BrewError` (the `#[derive(Serialize)]` above), **not** rely on Tauri's default string conversion.
- Standard library errors (`std::io::Error`, `serde_json::Error`, `reqwest::Error`) convert into `BrewError` via `From` impls in `error.rs`.
- The Tauri command return type is `Result<T, BrewError>` directly. No need for `Box<dyn Error>` or stringly-typed shims.

### 3.3 TypeScript shape

```ts
export type BrewErrorPayload =
  | { code: "brew_not_found" }
  | { code: "brew_exit_non_zero"; command: string; exitCode: number; stderrExcerpt: string }
  | { code: "json_parse";         command: string; message: string; rawExcerpt: string }
  | { code: "io";                 message: string }
  | { code: "network";            url: string; message: string }
  | { code: "http_status";        url: string; status: number }
  | { code: "invalid_argument";   message: string }
  | { code: "job_not_found";      jobId: string }
  | { code: "canceled" }
  | { code: "brewfile_not_found"; id: string }
  | { code: "internal";           message: string };
```

Frontend pattern:
```ts
try {
  const list = await invoke<PackageList>("brew_list");
} catch (e) {
  const err = e as BrewErrorPayload;
  switch (err.code) { /* ... */ }
}
```

---

## 4. Streaming pattern (canonical)

This is the single pattern used by `brew_install`, `brew_uninstall`, `brew_upgrade`, `brew_update`, `brewfile_dump`, and `brewfile_install`. Implementing it well once means every long-running command behaves identically.

### 4.1 Lifecycle

```
Frontend                             Backend (Rust)
--------                             --------------
const channel = new Channel<E>();
channel.onmessage = (e) => {...};
invoke("brew_install", {
  name, kind: "formula", onEvent: channel,
})
                                     1. acquire WRITE mutex (or queue)
                                     2. spawn `brew install …` via tokio::process
                                     3. emit Started{job_id, command, started_at}
                                     4. for line in stdout: emit Stdout{...}
                                        for line in stderr: emit Stderr{...}
                                     5. on exit: emit Exit{exit_code, success, duration_ms}
                                     6. release mutex
                                     7. return JobResult to invoke()'s promise
```

The command returns its `JobResult` to the original `invoke()` promise. The channel is therefore both a stream and a completion signal — the frontend can wait on the promise (concise) or react to the final `Exit` event (richer).

### 4.2 Tokio plumbing

- Spawn with `tokio::process::Command::new(&brew_path)` after applying `.kill_on_drop(true)`.
- Set `stdin(Stdio::null())`, `stdout(Stdio::piped())`, `stderr(Stdio::piped())`.
- Wrap stdout/stderr in `tokio::io::BufReader` → `.lines()`; for each line, emit a `Stdout`/`Stderr` event with a fresh ISO-8601 timestamp.
- Run two `tokio::spawn` line-pump tasks (one for stdout, one for stderr) and a `child.wait()` task; join them with `tokio::join!`.
- Record `Instant::now()` at spawn; compute `duration_ms` at exit.

### 4.3 Backpressure & flooding

- Lines are pushed to the `Channel<BrewStreamEvent>` as fast as `brew` produces them. Channels are bounded internally by Tauri's IPC; if the frontend can't keep up, events queue in memory.
- For pathological cases (a 10-minute `brew bundle install` of hundreds of casks): cap line length at 4 KB, truncate with `…[truncated]`.
- Do **not** batch lines server-side — the live-stream feel is the point. Frontend can throttle rendering if needed.

### 4.4 Cancellation

- Each running job is tracked in `AppState.jobs: Mutex<HashMap<Uuid, JobHandle>>` where `JobHandle` holds a `tokio::sync::oneshot::Sender<()>` and a `Child` reference.
- `cancel_job(job_id)` looks up the handle, sends SIGTERM via `child.start_kill()`, waits up to 5 s, then SIGKILL.
- The streaming task observes the kill, emits `Canceled { job_id }`, and the awaiting command returns `Err(BrewError::Canceled)`.
- **Caveat**: brew's child processes (e.g. `curl` downloads, `make`) may not stop instantly. The UI should show "Canceling…" until `Canceled` arrives.

### 4.5 Why `Channel<T>` instead of `app.emit`

Tauri 2's `tauri::ipc::Channel` is the idiomatic per-invocation stream:

- Type-safe end-to-end (`BrewStreamEvent` on both sides via TS declaration).
- Automatically scoped to the invocation; closing the channel on the JS side cleans up.
- No global event-name collisions across multiple concurrent jobs.
- The alternative — `app.emit("brew-stream-{job_id}", payload)` — works but requires manual subscription/unsubscription and pollutes the global event bus.

---

## 5. Mutex / managed state pattern

### 5.1 The state struct

```rust
pub struct AppState {
    /// Path to the resolved `brew` binary. Detected once at startup.
    pub brew_path: PathBuf,

    /// Cached brew environment (version, prefix). Invalidated on `brew update` success.
    pub brew_env: RwLock<BrewEnvironment>,

    /// Serializes all WRITE brew operations. Reads bypass this.
    pub brew_write_lock: Mutex<()>,

    /// In-flight streaming jobs, keyed by job_id.
    pub jobs: Mutex<HashMap<Uuid, JobHandle>>,

    /// Trending analytics cache. Per-window.
    pub trending_cache: Mutex<TrendingCache>,

    /// Resolved app-data directory for Brewfiles: ~/Library/Application Support/brew-browser/brewfiles/
    pub brewfiles_dir: PathBuf,

    /// Optional cached package list for cross-referencing (e.g. trending "installed" flag, search "installed" flag). Refreshed after every WRITE.
    pub installed_cache: RwLock<Option<PackageList>>,
}

pub struct JobHandle {
    pub child_id: u32,
    pub started_at: Instant,
    pub cancel_tx: Option<oneshot::Sender<()>>,
}
```

Registered at startup: `tauri::Builder::default().manage(app_state)`.

### 5.2 Lock policy (per command)

| Command | Lock |
|---|---|
| `brew_doctor` | none |
| `brew_list` | none (reads `installed_cache` via `RwLock::read`); shells out only on cache miss |
| `brew_info` | none |
| `brew_outdated` | none |
| `brew_search` / `brew_search_desc` | none |
| `brew_install` / `brew_uninstall` / `brew_upgrade` / `brew_update` | **acquires `brew_write_lock`** for the duration of the child process |
| `brewfile_dump` | **acquires `brew_write_lock`** (brew bundle dump enumerates state) |
| `brewfile_install` | **acquires `brew_write_lock`** |
| `brewfile_check` | none (read-only) |
| `brewfile_list` / `_read` / `_delete` / `_export` / `_import` | none (filesystem) |
| `trending_fetch` / `trending_clear_cache` | uses `trending_cache` mutex only |
| `cancel_job` | uses `jobs` mutex only |

**After any WRITE operation completes successfully**, the command must invalidate `installed_cache` (so the next `brew_list` re-shells). Implement as a small helper `fn invalidate_caches(state: &AppState)`.

### 5.3 Why a single coarse write lock

`brew` does not tolerate concurrent state-mutating invocations (lockfile collisions, partial installs). A single `Mutex<()>` is ~3 lines of code and prevents an entire class of bugs. The trade-off — slightly more queueing for sequential installs — is invisible at UI scale (one user, one window).

If queueing becomes user-visible, we surface a "Queued (waiting for: brew upgrade tree)" hint in `<ActionConsole>` rather than refactoring the lock model.

---

## 6. Trending fetch pattern (Phase 6)

### 6.1 HTTP client

Use `reqwest` (with `rustls-tls` and `json` features), not `tauri-plugin-http`.

- We control the request entirely (no allowlist plumbing).
- One outbound host, hardcoded — no need for the plugin's URL-allowlist features.
- Simpler error model: `reqwest::Error` → `BrewError::Network`.

### 6.2 Endpoints

```
https://formulae.brew.sh/api/analytics/install/30d.json
https://formulae.brew.sh/api/analytics/install/90d.json
https://formulae.brew.sh/api/analytics/install/365d.json
```

Cask analytics (if we choose to include casks in trending):
```
https://formulae.brew.sh/api/analytics/cask-install/30d.json
```

The payload shape per Homebrew docs:
```json
{
  "category": "install",
  "total_items": 12345,
  "start_date": "2026-04-23",
  "end_date": "2026-05-23",
  "total_count": 67890123,
  "formulae": {
    "wget": [ { "number": 1, "formula": "wget", "count": "1,234,567", "percent": "1.81" } ],
    ...
  }
}
```

Phase 6 only needs `formula → count` flattened, sorted, and ranked. Cask trending is a stretch (separate endpoint).

### 6.3 Cache

```rust
pub struct TrendingCache {
    pub d30:  Option<CachedTrending>,
    pub d90:  Option<CachedTrending>,
    pub d365: Option<CachedTrending>,
}

pub struct CachedTrending {
    pub fetched_at: Instant,
    pub report: TrendingReport,
}

const TRENDING_TTL: Duration = Duration::from_secs(60 * 60); // 1 hour
```

Fetch flow:
1. Lock `trending_cache` (short critical section).
2. If `cached.fetched_at.elapsed() < TRENDING_TTL`, return the cached report (update `cache_age_seconds`).
3. Drop the lock. Issue `reqwest::get(url).timeout(Duration::from_secs(10))`.
4. On `Ok` with 2xx: parse, rank, cross-reference against `installed_cache`, store in cache, return.
5. On `Err` / non-2xx: if a stale cache exists, return it with a `cache_age_seconds` flag; otherwise return `BrewError::Network` or `BrewError::HttpStatus`.

### 6.4 Polite client

- Set `User-Agent: brew-browser/<version> (+https://github.com/<repo>)` (post-publish).
- Respect `429 Too Many Requests` by treating the response as a network error and surfacing stale cache if available.
- No retries on first miss — surface to UI, let user retry.

---

## 7. Cargo dependency delta

Add to `[dependencies]` in `src-tauri/Cargo.toml`:

```toml
# Error handling
thiserror = "1"

# Job IDs and timestamps
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }

# HTTP for trending analytics
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls", "gzip"] }

# OS-correct paths for ~/Library/Application Support
dirs = "5"

# Optional but recommended: structured logging
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
```

Update the existing `tauri` line to include the IPC channel feature if not on by default in the installed minor:

```toml
tauri = { version = "2", features = [] }
# Channel<T> ships in stable Tauri 2 — no feature flag needed as of 2.0.
```

Confirmed unchanged: `serde`, `serde_json`, `tokio` (already has `process`, `io-util`, `rt-multi-thread`, `macros`, `sync` — exactly what we need), `tauri-plugin-opener`.

**Total deps added: 6 (`thiserror`, `uuid`, `chrono`, `reqwest`, `dirs`, `tracing` + `tracing-subscriber`).** Tracing is optional but cheap; if minimizing binary size matters, drop tracing and use `eprintln!` for backend diagnostics.

---

## 8. Capability configuration

Update `src-tauri/capabilities/default.json` to:

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "Capability for the main window",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "opener:default",
    "core:event:default"
  ]
}
```

### What is intentionally NOT here

- **No `shell:default` or `shell:allow-execute`.** All brew invocations are inside Rust. The frontend cannot construct an arbitrary `Command`. This is the security posture — `tauri-plugin-shell` is unnecessary attack surface for our model.
- **No `http:default`.** The trending fetch goes through `reqwest` inside Rust, not through `tauri-plugin-http` exposed to JS.
- **No `fs:*`.** Brewfile read/write is mediated by named Tauri commands that only touch a known directory; the frontend cannot pass arbitrary paths to read or write.

If Phase 4's import/export needs OS file pickers, add `tauri-plugin-dialog` and `dialog:default` — but the dialog plugin only opens the picker; the path it returns is still passed back to our `brewfile_import` / `brewfile_export` commands, which validate it.

### Network allowlist + CSP (security hardening, 2026-05-23)

CSP is now set explicitly in `tauri.conf.json` per the wave-security audit (`memory-bank/security.md` M1):

```json
"app": {
  "withGlobalTauri": false,
  "windows": [ ... ],
  "security": {
    "csp": "default-src 'self'; connect-src 'self' https://formulae.brew.sh; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
  }
}
```

Notes on the policy:

- `'unsafe-inline'` on `style-src` is required because Svelte components ship `<style>` blocks that compile inline. Migrating to a nonce-based scheme would require Vite-side plumbing — out of scope for this audit. The other directives are zero-cost belt-and-suspenders.
- `img-src 'self' data:` keeps the `data:image/png;base64,...` icon payload from `cask_icon` / `cask_icon_from_homepage` working.
- `connect-src 'self' https://formulae.brew.sh` is forward-compat: today the trending fetch runs in Rust (not the webview), but adding the host now prevents a future frontend `fetch()` from breaking under a tightened CSP.
- `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'none'` are zero-cost defense in depth.
- `withGlobalTauri: false` is pinned explicitly (was previously the implicit default in Tauri 2) so it stays off across Tauri minor-version updates that could flip the default.

(reqwest runs in the Rust backend, not the webview — but CSP still matters for any future `fetch()` from JS, and it backstops a future `{@html}` slip-up in a Svelte component.)

---

## 8.1 Security hardening helpers (2026-05-23)

The wave-security audit drove a fix-pass that added a small set of reusable security helpers in the backend. They're documented here so future commands that handle paths or URLs from the IPC boundary pick them up automatically.

### Path-sandbox helpers — `commands::brewfile`

```rust
fn is_safe_export_target(dst: &Path, app_data_dir: &Path) -> Result<(), BrewError>
fn is_safe_import_source(src: &Path) -> Result<(), BrewError>
```

`is_safe_export_target` rejects writes inside a denylist of system-owned prefixes (`/etc/`, `/System/`, `/Library/`, `/usr/`, `/bin/`, `/sbin/`, `/var/`, `/private/etc/`, `/private/var/`, `/dev/`, `/Volumes/`) **and** rejects any path that resolves into the app's own data directory (`~/Library/Application Support/brew-browser/`). The canonicalized parent is re-checked so symlink farms pointing back into our state dir can't bypass the lexical gate.

`is_safe_import_source` rejects symlinks (via `symlink_metadata`, no traversal), oversize files (1 MiB cap), and non-text content (NUL byte in first 4 KiB). Together they neutralize the `import(any) → export(any)` arbitrary-file-write primitive that the audit's H2 flagged.

Both helpers are wired into `brewfile_export` and `brewfile_import` before the `tokio::fs::copy`.

### Token validator — `commands::info::validate_cask_token`

```rust
pub fn validate_cask_token(token: &str) -> Result<(), BrewError>
```

Strict superset of `validate_package_name` for tokens that compose into filesystem paths. Adds:
- rejects `/` (cask tokens never contain it),
- rejects leading `.` (no hidden-file shapes),
- rejects bare `.` and `..` (parent / current dir),
- rejects empty or `.` / `..` segments split on `.` (catches `foo..bar`).

`validate_package_name` is still the right choice for formulae (tap-qualified names contain `/`). Apply `validate_cask_token` anywhere a user-influenced token reaches the filesystem — currently `cask_icon` and `cask_icon_from_homepage`, both **before** any cache path is constructed.

### SSRF gate — `commands::cask_icon_homepage::is_public_host` + custom redirect policy

```rust
pub(crate) fn is_public_host(host: &str) -> bool
```

Rejects hosts that fall in any non-public IP range or known-internal TLD:
- IPv4: loopback (`127.0.0.0/8`), private (`10`, `172.16/12`, `192.168/16`), link-local (`169.254/16` — includes AWS IMDS `169.254.169.254`), unspecified (`0.0.0.0`), broadcast, multicast, documentation, CGNAT (`100.64/10`), benchmarking (`198.18/15`).
- IPv6: loopback, unspecified, multicast, ULA (`fc00::/7`), link-local (`fe80::/10`), IPv4-mapped private addresses.
- Hostnames: `localhost`, `*.local`, `*.internal`.

Wired in two places:
1. **`parse_http_url`** — rejects the initial probe URL at parse time. A malicious homepage like `http://169.254.169.254/` never makes a request.
2. **`reqwest::redirect::Policy::custom`** in `build_http_client` — re-checks the host of *every* redirect hop. A public-DNS hostname that redirects to a private IP is stopped mid-cascade.

The string-based check does not protect against DNS rebinding (attacker controls a public hostname whose A record points to a private IP). That class of attack is mitigated by the content-type filter (non-`image/*` bodies are discarded before any data reaches the renderer) and the 5s per-probe timeout (bounds time-based exfil).

### Concurrency cap — `cask_icon_from_homepage` probe semaphore

A process-wide `tokio::sync::Semaphore` with `MAX_CONCURRENT_PROBES = 16` slots lives in a `OnceLock` and gates the cascade. A burst of Discover or Trending renders can't fan out unbounded outbound connections; the cap protects both us (file-descriptor budget) and the receiving CDNs (per-IP rate limits).

### Bundle-resources traversal gate — `cask_icon::safe_join_in_resources`

```rust
fn safe_join_in_resources(resources: &Path, candidate: &str) -> Option<PathBuf>
```

When `CFBundleIconFile` (or any bundle-side value) names a candidate to look up under `Contents/Resources/`, the helper canonicalizes both `resources` and the joined path, then verifies the joined path is still inside `resources`. Returns `None` for any traversal attempt, broken symlink, or non-existent file. Use this pattern anywhere code joins an attacker-influenced string onto a known-safe directory.

---

## 9. File layout for Rust code

Recommendation: **split `lib.rs` into modules.** A single file gets unmanageable past ~500 LOC, and we'll be well past that by Phase 4.

```
src-tauri/src/
├── lib.rs                  # Tauri Builder, invoke_handler, setup hook, module wiring
├── main.rs                 # (unchanged) calls brew_browser_lib::run()
├── error.rs                # BrewError + From impls
├── state.rs                # AppState, JobHandle, helpers (invalidate_caches, resolve_brew_path)
├── brew/
│   ├── mod.rs              # re-exports
│   ├── exec.rs             # run_brew_capture(), run_brew_streaming() — the two canonical patterns
│   ├── parse.rs            # serde structs mirroring `brew --json=v2` shapes + From → our typed shapes
│   └── paths.rs            # resolve `brew` on PATH, prefix detection
├── commands/
│   ├── mod.rs              # re-exports for invoke_handler!
│   ├── env.rs              # brew_doctor
│   ├── list.rs             # brew_list, brew_outdated
│   ├── info.rs             # brew_info
│   ├── search.rs           # brew_search, brew_search_desc
│   ├── actions.rs          # brew_install, brew_uninstall, brew_upgrade, brew_update, cancel_job
│   ├── brewfile.rs         # brewfile_* commands
│   └── trending.rs         # trending_fetch, trending_clear_cache
├── trending/
│   ├── mod.rs
│   ├── client.rs           # reqwest wrapper
│   └── cache.rs            # TrendingCache struct + TTL logic
└── types.rs                # Shared serialized DTOs (Package, PackageList, etc.) — frontend-facing
```

`lib.rs` shrinks to:
```rust
mod error;
mod state;
mod types;
mod brew;
mod trending;
mod commands;

use commands::*;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| { state::initialize(app)?; Ok(()) })
        .invoke_handler(tauri::generate_handler![
            brew_doctor,
            brew_list, brew_outdated,
            brew_info,
            brew_search, brew_search_desc,
            brew_install, brew_uninstall, brew_upgrade, brew_update, cancel_job,
            brewfile_dump, brewfile_install, brewfile_check,
            brewfile_list, brewfile_read, brewfile_delete, brewfile_export, brewfile_import,
            trending_fetch, trending_clear_cache,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

### Why modules over a single file

- Reviewability: each command in a < 100-line file with its parser nearby.
- Test isolation: `brew::parse` can be unit-tested without spawning processes by feeding it canned `--json=v2` fixtures.
- Refactor headroom: swapping `reqwest` for `tauri-plugin-http` (or splitting trending into its own crate) is local.

---

## 10. Test plan

### 10.1 Unit tests (in `src-tauri/src/`, `#[cfg(test)] mod tests`)

Owned by Backend Architect (Wave 2 writes the tests alongside the code).

- **`brew::parse`** — Feed real `brew info --json=v2` fixtures (captured from Beast, committed to `src-tauri/tests/fixtures/`) and assert they parse into `Package` / `PackageDetail`.
- **`error`** — Round-trip every `BrewError` variant through `serde_json::to_string` and back; assert the discriminant tag is the expected `code` string.
- **`trending::cache`** — TTL expiry, stale-on-error behavior, per-window isolation.
- **`commands::brewfile`** — Brewfile parsing from canned `Brewfile` text (taps/formulae/casks/mas/vscode).
- **`brew::paths`** — `resolve_brew_path` returns the expected path when `brew` is on PATH, returns `BrewError::BrewNotFound` when not.

### 10.2 Integration tests (`src-tauri/tests/*.rs`)

Hit the real `brew` on the dev machine. Skipped via `#[ignore]` in CI without brew; opt-in via `cargo test -- --ignored`.

- **`integration_brew_list`** — `brew_list().await` returns non-empty `formulae` on a dev box with brew.
- **`integration_brew_info`** — `brew_info("git", Formula)` returns dependencies including known transitive deps.
- **`integration_brew_outdated`** — does not panic; structurally valid.
- **`integration_install_uninstall`** — installs `tree` (tiny, dependency-free), asserts streaming events arrive in order (`Started` → ≥1 `Stdout` → `Exit { success: true }`), then uninstalls. Gated behind an env flag `BREW_BROWSER_DESTRUCTIVE_TESTS=1`.
- **`integration_trending`** — fetches 30d window, asserts ≥10 entries; second call within TTL is served from cache (assert `cache_age_seconds > 0`).
- **`integration_brewfile_roundtrip`** — `brewfile_dump("test")` → `brewfile_read(id)` → assert formulae count > 0 → `brewfile_delete(id)`.

### 10.3 Manual smoke tests (run before each phase merge)

- Launch the app, see installed formulae and casks load within 2 s on a 100-package library.
- Click a package, see detail panel populate.
- Search "wget", see matches; toggle formula/cask filter.
- Install `tree`, watch live stdout in `<ActionConsole>`, see "outdated" badge update.
- Uninstall `tree`, see it disappear from list.
- Snapshot to Brewfile, view in app, delete.
- Trending tab loads, top entry is sane (e.g. `git`, `node`).
- Cancel an in-progress install — `<ActionConsole>` shows "Canceling…" then "Canceled".

### 10.4 Wave 3 ownership

The **API Tester** agent in Wave 3 will:
1. Implement the unit and integration tests above.
2. Add fuzz inputs for `brew_search` query escaping.
3. Run the manual smoke suite and stamp results into `apiTests.md`.

The **Reality Checker** will:
1. Verify error paths look sane in the actual UI (kill brew mid-install, simulate offline trending).
2. Confirm no telemetry / unexpected outbound traffic via `lsof -i` or Little Snitch during a 5-minute session.

---

## 10.5 Implementation drift from spec (Wave 2)

Recorded inline by the Wave 2 implementor:

- **`BrewStreamEvent` derives `Serialize` only, not `Deserialize`.** // IMPL DRIFT 2026-05-23: `BrewError` (embedded in the `Error` variant) is `Serialize`-only, so the parent enum can't derive `Deserialize`. The event flows backend → frontend only, so this is correct — the TS type in `types.ts` describes the wire shape directly.
- **`run_brew_streaming` takes `Arc<Mutex<HashMap<Uuid, JobHandle>>>` (the jobs map), not `Arc<AppState>`.** // IMPL DRIFT 2026-05-23: `AppState` cannot be `Clone` (it holds `RwLock`s) and Tauri owns the `&AppState` lifetime. Passing the jobs Arc directly is cleaner and keeps the streaming helper independent of `AppState`'s shape.
- **`BrewError` derives `Clone`.** // IMPL DRIFT 2026-05-23: needed so the streaming helper can emit `Error { error: BrewError }` and *also* return it from the command — the value is consumed twice.
- **Per-command write-lock guard uses `lock_owned().await`** so the guard outlives the streaming child without binding to the `State` lifetime. Functionally equivalent to the spec's `Mutex<()>`.
- **Input validation added at the IPC boundary** for package names (`commands::info::validate_package_name`) and search queries — rejects leading-dash strings to prevent flag injection, even though `brew` itself would catch most cases. Defense in depth.
- **`brewfile_check` shells out via `tokio::process::Command::output()` directly** rather than `run_brew_capture` because non-zero exit is a legitimate signal ("not satisfied") that should still surface the structured report.
- **`brew_doctor` populates `BrewEnvironment` even when `brew` is missing** — returns `{ installed: false, version: null, prefix: null, pathUsed: null }` rather than `BrewError::BrewNotFound`, because the frontend uses this command to *decide* whether to show the "brew not found" banner.
- **`BrewExitNonZero` gained an optional `friendly_message` field** (Pass-3 error polish 2026-05-23). // IMPL DRIFT: `BrewError::BrewExitNonZero` now serializes an optional `friendlyMessage: string` when stderr matches a known upstream-bug pattern (see §3.4). The field is `#[serde(skip_serializing_if = "Option::is_none")]` so the wire shape stays backwards-compatible — existing frontend `isBrewError` type guards and `switch (err.code)` consumers keep working unchanged. Populated by `brew::error_patterns::friendlify` from both `run_brew_capture` and `run_brew_streaming`.

### 3.4 Friendly error mapping (`brew::error_patterns`)

A small, hand-curated catalog turns known upstream Homebrew failures into a one-sentence friendly message for the toast layer. The verbatim stderr is still preserved in `BrewExitNonZero.stderr_excerpt` and rendered in the Activity drawer — `friendlify` only drives the toast.

**Pattern catalog (initial — keep it small):**

| Pattern in stderr | Gated to | Friendly message |
|---|---|---|
| `key not found:` + `Homebrew::Bundle::Brew::Topo` | `brew bundle dump` / `brew bundle install` | "Homebrew's `brew bundle` hit an internal topo-sort error on one of your installed formulae. This is an upstream Homebrew bug, not a brew-browser issue. Try `brew untap` on a recently-added tap, or see the full output in Activity." |
| `Please report this issue:` + `docs.brew.sh/Troubleshooting` | any command | "Homebrew reported an internal error and asked you to report it upstream. See the full output in Activity, and visit https://docs.brew.sh/Troubleshooting for next steps." |

**TypeScript shape (frontend):**

```ts
// BrewErrorPayload — only the brew_exit_non_zero variant grew a field
| { code: "brew_exit_non_zero";
    command: string;
    exitCode: number;
    stderrExcerpt: string;
    friendlyMessage?: string }   // present only when a pattern matched
```

The toast renderer should prefer `friendlyMessage` when present, falling back to the existing `${command} exited ${exitCode}: ${stderrExcerpt}` summary otherwise. The Activity drawer continues to show the raw `stderrExcerpt` verbatim.

**Adding a new pattern:** append to `friendlify()` in `src-tauri/src/brew/error_patterns.rs` with a positive unit test using real captured stderr. This is polish — three or four patterns max; if the catalog grows past that, revisit whether the friendly message should live with the call-site instead.

## 11. Open questions deferred to Wave 2 implementation

1. **`brew search` parsing.** Plain stdout, no `--json`. Lines are package names; sometimes prefixed with `==> Formulae` / `==> Casks` section headers. Wave 2 implementor decides whether to call `brew search --formula` and `brew search --cask` separately (cleaner) or once and parse headers (one fewer process). Recommendation: separate, parallel via `tokio::try_join!`.
2. **Outdated `--greedy`.** `--greedy` includes auto-updating casks. Phase 1 UX may want both views. Default to greedy and let the frontend filter.
3. **Cask trending.** MVP Phase 6 covers formulae only. Cask trending is a separate endpoint; trivial to add but ranking semantics (combined vs. separate tabs) are a UX call — defer to UX Architect's `uxArchitecture.md`.
4. **Tracing destination.** `tracing-subscriber` to stderr is fine for dev; production should log to `~/Library/Logs/brew-browser/`. Wave 2 implementor adds a simple file-rolling layer or skips it.
5. **Brewfile label sanitization.** Strip everything but `[A-Za-z0-9_-]`, max 64 chars, prefix with ISO date if user provides empty. Implementor's call.

These don't block the spec; they're micro-decisions for the implementer that don't change the public API.

---

## 12. Summary cheat sheet (for Frontend Developer)

- **20 commands total** across 6 phases (1 env + 4 list/info/outdated + 2 search + 5 actions + 8 brewfile + 2 trending — counting `cancel_job` with actions).
- **All commands are `async` and return `Result<T, BrewError>`.**
- **Streaming commands** take a `Channel<BrewStreamEvent>` argument and emit live; the final event's `kind` is `"exit"` or `"canceled"`.
- **Errors are tagged JSON** — switch on `error.code`.
- **Camel-case JSON everywhere** (`installedVersion`, not `installed_version`).
- **No shell plugin** — all brew commands are constructed in Rust from typed enums.
- **One mutex** serializes all brew writes; reads are concurrent.
- **Trending caches 1 hour** in process memory; per-window.

---

*End of spec. Wave 2 implementation begins from this file.*

---

## 13. Phase 9 + 11 + 12 + 13 commands

**Author:** Technical Writer (post-implementation pass, 2026-05-24 evening)
**Scope:** Tauri commands shipped after the original spec (Phase 9 categories, Phase 11 Dashboard/Services/Disk, Phase 12a–12f Catalog/Settings/GitHub, Phase 13 enrichment).
**Note:** Phase 11 disk + services commands landed in commit `84ad010` (slightly before this Phase 12 cluster) but were not in the original spec; they're included here for completeness.

All commands are registered in `src-tauri/src/lib.rs` via `tauri::generate_handler!` and re-exported through `src-tauri/src/commands/mod.rs`. Each row notes whether the command consults `state.require_network(feature)` — the single paranoid-mode chokepoint introduced by Phase 12d.

### 13.1 Phase 9 — Categories

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `categories_data` | `async fn categories_data(state) -> Result<Arc<CategoriesData>, BrewError>` | Returns the full categories.json payload (838 KB embedded via `include_str!`). Memoised on `AppState.categories_cache` so the parse happens once per process. | no (bundled, no I/O) | none | `commands/categories.rs:41` |

### 13.2 Phase 11 — Disk usage

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `disk_usage` | `async fn disk_usage(state) -> Result<DiskUsageReport, BrewError>` | Returns sizes for Cellar / Caskroom / var/log / cache via parallel `du -sk` calls (`tokio::join!`). 60s cache on `AppState.disk_usage_cache`. | no (local FS only) | none | `commands/disk_usage.rs:109` |
| `disk_usage_clear_cache` | `async fn disk_usage_clear_cache(state) -> Result<(), BrewError>` | Invalidates the 60s cache so the next `disk_usage` re-runs `du`. Backs the Dashboard Refresh button. | no | none | `commands/disk_usage.rs:195` |
| `open_in_finder` | `async fn open_in_finder(path: String, state) -> Result<(), BrewError>` | Reveals a path in Finder via `/usr/bin/open -R`. Canonicalises the target and the Homebrew prefix + cache roots, then enforces the target is inside one of them — blocks attempted reveals of `/etc/passwd` or `~/.ssh/`. | no | none | `commands/disk_usage.rs:202` |

### 13.3 Phase 11b — Services

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `services_list` | `async fn services_list(state) -> Result<Arc<Vec<Service>>, BrewError>` | Shells `brew services list --json` and parses. 5s cache on `AppState.services_cache`. | no | none | `commands/services.rs:56` |
| `services_clear_cache` | `async fn services_clear_cache(state) -> Result<(), BrewError>` | Drops the 5s cache so the next list re-shells `brew services list`. | no | none | `commands/services.rs:78` |
| `services_start` | `async fn services_start(name: String, state) -> Result<(), BrewError>` | Shells `brew services start <name>`. Takes the write lock (launchctl state mutation). Validates the service name against `^[A-Za-z0-9._\-+@]{1,128}$` even though argv passing is shell-safe — defense in depth. | no | none | `commands/services.rs:124` |
| `services_stop` | `async fn services_stop(name: String, state) -> Result<(), BrewError>` | Shells `brew services stop <name>`. Same validator + lock. | no | none | `commands/services.rs:129` |
| `services_restart` | `async fn services_restart(name: String, state) -> Result<(), BrewError>` | Shells `brew services restart <name>`. Same validator + lock. | no | none | `commands/services.rs:134` |

### 13.4 Phase 12a — Bundled catalog + refresh

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `catalog_summary` | `async fn catalog_summary(state) -> Result<CatalogSummary, BrewError>` | Returns `{ as_of, source: "bundled" \| "user-refreshed", formula_count, cask_count, days_old }` for the currently active catalog. | no (in-memory) | none | `commands/catalog.rs:106` |
| `catalog_refresh` | `async fn catalog_refresh(state) -> Result<CatalogSummary, BrewError>` | Fetches both `formula.json` and `cask.json` from `formulae.brew.sh`, gzip-compresses, atomic-writes to `app_data_dir/catalog/`, reloads, swaps the AppState Arc. Single-flight via `try_lock` (second click → `InvalidArgument` "already in progress"). 60s reqwest timeout. 64 MiB streaming raw cap. | **yes** ("catalog_refresh") | none | `commands/catalog.rs:112` |
| `catalog_lookup_formula` | `async fn catalog_lookup_formula(name: String, state) -> Result<Option<Formula>, BrewError>` | HashMap lookup against the active catalog. `validate_package_name` gates the input even though the read is in-memory (defense-in-depth uniform validator). | no | none | `commands/catalog.rs:189` |
| `catalog_lookup_cask` | `async fn catalog_lookup_cask(name: String, state) -> Result<Option<Cask>, BrewError>` | HashMap lookup for casks. Uses the stricter `validate_cask_token` (rejects `/`, leading `.`, `..` segments). | no | none | `commands/catalog.rs:202` |
| `catalog_formulae_summary` | `async fn catalog_formulae_summary(state) -> Result<Vec<CatalogEntrySummary>, BrewError>` | Light shape `{name, desc, deprecated, disabled}` for every formula, sorted alphabetically. Backs Discover search. | no | none | `commands/catalog.rs:212` |
| `catalog_casks_summary` | `async fn catalog_casks_summary(state) -> Result<Vec<CatalogEntrySummary>, BrewError>` | Same shape for casks. | no | none | `commands/catalog.rs:232` |

### 13.5 Phase 12b — Brew analytics + app version

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `brew_get_analytics` | `async fn brew_get_analytics(state) -> Result<bool, BrewError>` | Shells `brew analytics state`, parses first stdout line only with strict match (handles trailing-period and non-period variants brew has shipped). Returns `true` when analytics enabled. | no | none | `commands/brew_env.rs:48` |
| `brew_set_analytics` | `async fn brew_set_analytics(enabled: bool, state) -> Result<(), BrewError>` | Shells `brew analytics on\|off`. Takes the write lock — brew mutates its config files. | no | none | `commands/brew_env.rs:60` |
| `app_version` | `fn app_version<R: Runtime>(app: AppHandle<R>) -> String` | Returns the app's version from `tauri::App::package_info().version`. Synchronous, no I/O. Avoids a renderer-side `package.json` read that would require an `fs:*` capability. | no | none | `commands/brew_env.rs:77` |

### 13.6 Phase 12d — Settings persistence

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `settings_get` | `async fn settings_get(state) -> Result<Settings, BrewError>` | Returns the in-memory cached settings. `FirstLaunch` → defaults, `Corrupt` → `BrewError::Internal` so the UI can surface a reset prompt. | no | none | `commands/settings.rs:400` |
| `settings_set` | `async fn settings_set(settings: Settings, state) -> Result<Settings, BrewError>` | Validates, clamps, atomic-writes to `app_data_dir/settings.json`, updates in-memory cache. Returns the clamped settings (frontend sees what was actually written). | no | none | `commands/settings.rs:415` |
| `settings_reset` | `async fn settings_reset(state) -> Result<Settings, BrewError>` | Overwrites with `Settings::default()`. Used by the corrupt-file recovery affordance in Settings → Network. | no | none | `commands/settings.rs:431` |

### 13.7 Phase 12c + 12e — GitHub anonymous + Device Flow

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `github_repo_stats` | `async fn github_repo_stats(homepage: String, state) -> Result<Option<RepoStats>, BrewError>` | Fetches stars / forks / last release / archived state for a GitHub-hosted package homepage. Two gates: Settings `github_enabled` (defaults false) short-circuits to `Ok(None)`, then `require_network`. URL allowlist via `parse_github_url`. 24h disk cache. | **yes** ("github_repo_stats") | optional (uses Keychain token if present to lift 60→5000/hr rate limit) | `commands/github.rs:39` |
| `github_status` | `async fn github_status(state) -> Result<GithubStatusDto, BrewError>` | Returns `{ signed_in, username, scopes }` from Keychain. **No token ever crosses IPC.** No network. | no (Keychain only) | reads Keychain | `commands/github.rs:88` |
| `github_signin_start` | `async fn github_signin_start(state) -> Result<DeviceFlowStart, BrewError>` | POSTs `client_id` + scope to `github.com/login/device/code`. Returns `{ device_code, user_code, verification_uri, expires_in, interval }`. | **yes** ("github_signin") | none (start of flow) | `commands/github.rs:98` |
| `github_signin_poll` | `async fn github_signin_poll(device_code: String, state) -> Result<PollResultDto, BrewError>` | POSTs to `github.com/login/oauth/access_token`. Returns `Pending`, `SlowDown`, `Success { username, scopes }`, `Denied`, `Expired`. On success, writes the token + scopes to Keychain. | **yes** ("github_signin") | none (writes Keychain on success) | `commands/github.rs:111` |
| `github_signout` | `async fn github_signout(state) -> Result<(), BrewError>` | Deletes both Keychain entries (`github_access_token`, `github_access_scopes`). Pure local reduction of state — not gated by paranoid mode. | no | deletes Keychain | `commands/github.rs:123` |

### 13.8 Phase 12f — GitHub authed actions

All six commands share the `authed_gate` helper in `commands/github.rs:152` which enforces, in order: paranoid → URL allowlist → token-from-Keychain → `public_repo` scope check → client build. None of these calls touch the network until the gate chain passes.

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `github_star` | `async fn github_star(homepage: String, state) -> Result<(), BrewError>` | PUT `/user/starred/{owner}/{repo}`. 204 = success. | **yes** ("github_star") | AuthRequired + ScopeRequired(`public_repo`) | `commands/github.rs:188` |
| `github_unstar` | `async fn github_unstar(homepage: String, state) -> Result<(), BrewError>` | DELETE same path. 204 = success (idempotent). | **yes** ("github_unstar") | same | `commands/github.rs:197` |
| `github_is_starred` | `async fn github_is_starred(homepage: String, state) -> Result<bool, BrewError>` | GET same path. 204 = starred, 404 = not. Backs the toggle button's initial state. | **yes** ("github_is_starred") | same | `commands/github.rs:206` |
| `github_watch` | `async fn github_watch(homepage: String, state) -> Result<(), BrewError>` | PUT `/repos/{owner}/{repo}/subscription` with `{subscribed: true, ignored: false}`. | **yes** ("github_watch") | same | `commands/github.rs:215` |
| `github_unwatch` | `async fn github_unwatch(homepage: String, state) -> Result<(), BrewError>` | DELETE same. | **yes** ("github_unwatch") | same | `commands/github.rs:224` |
| `github_create_issue` | `async fn github_create_issue(homepage: String, title: String, body: String, labels: Vec<String>, state) -> Result<CreatedIssue, BrewError>` | POST `/repos/{owner}/{repo}/issues`. Title ≤ 256 chars with control-char strip, body ≤ 64 KiB with null-byte strip, labels ≤ 10 entries matching `^[A-Za-z0-9_./-]+$`. Returns `{ number, html_url }`. | **yes** ("github_create_issue") | same | `commands/github.rs:233` |

### 13.9 Phase 13 — Enrichment

| Command | Signature | Purpose | Paranoid gate | Auth | Source |
|---|---|---|---|---|---|
| `enrichment_data` | `async fn enrichment_data(locale: Option<String>, state) -> Result<Arc<EnrichmentData>, BrewError>` | Returns the full bundled enrichment payload, optionally merged with a small locale overlay such as `enrichment.ru.json.gz`. Base English data is memoised on `AppState.enrichment_cache`; localized copies are memoised by locale in `enrichment_locale_cache`. Zero runtime LLM calls; bundles are `include_bytes!`d at compile time. | no (bundled) | none | `commands/enrichment.rs:23` |
| `enrichment_lookup` | `async fn enrichment_lookup(name: String, locale: Option<String>, state) -> Result<Option<EnrichmentEntry>, BrewError>` | Per-token lookup with the same locale overlay semantics as `enrichment_data`. `validate_package_name` gates the input. Returns `None` when the token is missing (placeholder bundle, unmapped package). | no | none | `commands/enrichment.rs:65` |

### 13.10 New error variants

The session added five typed error variants to `BrewError` (in `src-tauri/src/error.rs`), all serialised as tagged JSON the frontend can switch on:

- `ParanoidModeBlocked { feature: String }` — emitted by every gated command when `require_network` denies. Frontend toast routes by `feature`.
- `GithubRateLimited { reset_at: i64 }` — emitted when GitHub returns `403` + `X-RateLimit-Remaining: 0`. `reset_at` is the unix timestamp. **No retry, no backoff** — callers honour the server's reset window.
- `KeychainUnavailable { message: String }` — emitted when the macOS Keychain returns an error. No disk fallback. Frontend surfaces "Keychain unavailable — sign in unavailable until repaired".
- `AuthRequired` — emitted by Phase 12f action commands when no token is in the Keychain. No network attempt is made.
- `ScopeRequired { scope: String }` — emitted when the cached scopes from sign-in don't include the requested scope. As of v0.3.0 the scope can be `public_repo` (star/file-issue) or `notifications` (watch/unwatch); the per-action `authed_gate(scope)` parameterizes this.

### 13.11 Phase 15 — In-app updater (v0.3.0)

Four commands wrapping `tauri-plugin-updater`. All check `state.require_network("update_check")` first so Offline Mode kills the path even when the plugin would otherwise reach the manifest endpoint.

| Command | Signature | Purpose | Paranoid gate | Source |
|---|---|---|---|---|
| `update_check_now` | `async fn update_check_now(app, state) -> Result<UpdateCheckOutcome, BrewError>` | Fetch the manifest at `brew-browser.zerologic.com/updater.json`, compare against the running `CARGO_PKG_VERSION`, consult the user's skip-list. Returns `{kind: "upToDate"}` or `{kind: "available", version, currentVersion, notes, pubDate, skipped}` (flat — NOT nested under `.info`; that wire-shape bug was caught in the Phase 15 fix-up). Offline Mode surfaces as `ParanoidModeBlocked`, not a `blocked` variant. | **yes** ("update_check") | `commands/updater.rs:419` |
| `update_install` | `async fn update_install(version: String, app, state) -> Result<(), BrewError>` | Validates the caller-supplied `version` against the in-memory cached `Available` payload (stale-UI guard), runs the explicit downgrade-rejection check, then delegates to the plugin's `download_and_install`. Plugin performs sha256 + minisign verification against the embedded `UPDATER_PUBKEY`. On success, clears `cached_available` + flips `last_outcome` back to `UpToDate` so the install button doesn't re-fire. | **yes** ("update_check") | `commands/updater.rs:445` |
| `update_skip` | `async fn update_skip(version: String, state) -> Result<(), BrewError>` | Pushes onto the FIFO-capped (10) `skipped_update_versions` field in `settings.json`. **Refuses on Corrupt settings** (would otherwise silently revoke paranoid-on lockdown by writing `Settings::default()`). FirstLaunch materializes defaults with the skip recorded. **No** require_network gate — purely local state. | no | `commands/updater.rs:556` |
| `update_relaunch` | `async fn update_relaunch(app) -> Result<(), BrewError>` | Spawns a 50ms-delayed `tauri::AppHandle::restart()` so the IPC response makes it back to the renderer before the process dies. The plugin's macOS install path replaces the .app bundle but doesn't auto-restart — this bridges that. | no | `commands/updater.rs:584` |

Wire-shape pin: `UpdateCheckOutcome` is `#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]` on an enum with `UpToDate` (unit variant) and `Available { version, current_version, notes, pub_date, skipped }`. Frontend matches by flat fields, not by nested `.info`.

### 13.12 Phase 17 — `brew_upgrade_many` + `brew_list(force)` (v0.3.0)

| Command | Signature | Purpose | Notes |
|---|---|---|---|
| `brew_upgrade_many` | `async fn brew_upgrade_many(names: Vec<String>, on_event, state) -> Result<JobResult, BrewError>` | Runs a single `brew upgrade <n1> <n2> ...` invocation for a curated subset of packages (selected via Dashboard's "Choose…" modal). Validates every name through `validate_package_name`. Empty list → `InvalidArgument` (caller should use `brew_upgrade(None)` for upgrade-all). Takes `brew_write_lock`, invalidates `installed_cache` on success. | `commands/actions.rs:123` |
| `brew_list` (signature change) | `async fn brew_list(state, force: Option<bool>) -> Result<PackageList, BrewError>` | Now takes `force: Option<bool>`. When `Some(true)`, bypasses `state.installed_cache` before fetching. Wired to the Dashboard Refresh button + post-action reloads so `brew upgrade` runs in the user's terminal aren't masked by a stale cache forever. | `commands/list.rs:13` |

### 13.13 Phase 15 — New error variants

In addition to the Phase 12f set in §13.10, three more typed variants were added to `BrewError` in `src-tauri/src/error.rs` for the updater path:

- `HashMismatch { expected: String, actual: String }` — sha256 disagreement between the downloaded artifact and the manifest's `sha256` field. Currently only constructed by the mock backend in tests; the production plugin runs minisign-only as of `tauri-plugin-updater 2.10.1`. Wired so a v0.3.1+ manifest sha256 pre-check has the typed error ready.
- `SignatureVerificationFailed { message: String }` — minisign verification of the downloaded artifact failed against the embedded public key. Fail-closed: the `.app.tar.gz` is deleted before this error returns.
- `DowngradeRejected { current: String, target: String }` — explicit downgrade-attack defense in `run_install`. Defense in depth on top of the plugin's own version comparator.

All three are mirrored in the frontend `BrewErrorPayload` union with friendly messages via `brewErrorMessage` (`src/lib/types.ts`).

### 13.14 v0.4.0 — Velocity scoring + opt-in trending history

**Settings:** new `enhanced_trending_enabled: bool` field on the `Settings` struct (`src-tauri/src/commands/settings.rs`). `#[serde(default)]`, defaults `false` in `Settings::default()`. Forward-compat tested: a v0.3.x `settings.json` missing this field reads cleanly as `false`.

**New gate:** `AppState::require_enhanced_trending()` (`src-tauri/src/state.rs:269`) composes the master `require_network` gate with the per-feature toggle. Returns:

- `Err(ParanoidModeBlocked { feature: "trending_history" })` when paranoid is on (master switch wins; routes to Offline Mode toggle in UI)
- `Err(FeatureDisabled { feature: "trending_history" })` when paranoid is off but the per-feature toggle is off
- `Err(FeatureDisabled)` on `FirstLaunch` (defaults make the toggle false — fresh-install opt-in posture preserved)
- `Ok(())` only when both gates open

**New error variant:** `BrewError::FeatureDisabled { feature: String }` (`src-tauri/src/error.rs:80`). Serializes as `{"code": "feature_disabled", "feature": "..."}`. Distinct from `ParanoidModeBlocked` so the frontend toast routes to the per-feature toggle, not the master switch.

**Extended IPC return shape:** `TrendingEntry` (`src-tauri/src/types.rs:340`) gains three optional fields:

```rust
pub struct TrendingEntry {
    // ... existing fields ...
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_on_request_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_on_request_count_formatted: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub velocity_index: Option<f64>,
    // ...
}
```

All three are `skip_serializing_if = "Option::is_none"` so the wire shape stays backward-compatible with v0.3.x clients reading the older shape.

**`trending_fetch` orchestration change:** the existing IPC now eager-warms all three windows (30d, 90d, 365d) via `tokio::task::JoinSet` on the first call so velocity can be back-filled from the cross-window join. Each window fetch is itself a `tokio::join!` over `install` + `install-on-request` endpoints — so a cold cache triggers 6 concurrent HTTP requests bounded by the slowest. Subsequent calls within TTL hit the cache for all three and skip the network.

**Velocity math:** server-side in `trending::velocity::velocity_index(c30, c90, c365) -> Option<f64>` (`src-tauri/src/trending/velocity.rs`). Returns `None` on degenerate inputs (zero `c365`, non-monotonic windows, annual monthly average < 1.0). The JS collector mirrors this byte-for-byte in `tools/trending-collector/lib/common.js` so client-computed and server-precomputed values agree.

**New IPCs for the opt-in history endpoint:**

| Command | Signature | Purpose | `require_enhanced_trending` | File |
|---|---|---|---|---|
| `trending_history_index` | `async fn trending_history_index(state) -> Result<TrendingHistoryIndex, BrewError>` | Fetch the summary blob (top-500 packages by velocity + ~30-point compact sparkline per row) from `brew-browser.zerologic.com/trending-history/index.json`. Cached 6h per-process via `TrendingHistoryCache`. Single call on Trending tab mount; powers per-row inline sparklines without per-row HTTP. | **yes** | `commands/trending.rs:244` |
| `trending_history_fetch` | `async fn trending_history_fetch(name: String, kind: PackageKind, state) -> Result<TrendingHistorySeries, BrewError>` | Fetch the per-package full series from `brew-browser.zerologic.com/trending-history/{kind}/{name}.json`. URL builder validates `name` against strict `[A-Za-z0-9._+@-]+` allowlist (rejects path traversal, shell-metas, spaces). LRU-evicted at 500 packages. | **yes** | `commands/trending.rs:283` |

**New history wire types** (`src-tauri/src/types.rs:367-440`):

- `TrendingHistorySource` — enum `{ Seed, Daily }`. `seed` is one of the three derived bootstrap buckets; `daily` is a real nightly snapshot. UI fades or labels the historical-only portion distinctly.
- `TrendingHistoryPoint` — `{ date, count_30d?, count_90d?, count_365d?, count_install_on_request_30d?, estimated_daily_installs?, source }`. The `estimated_daily_installs` is server-computed via adjacent-day `count_30d` subtraction (only when both points are `daily` source).
- `TrendingHistorySeries` — `{ name, kind, points, generated_at, cache_age_seconds }`. The full per-package response shape.
- `TrendingHistoryIndex` — `{ generated_at, packages: Vec<TrendingHistoryIndexEntry>, cache_age_seconds }`.
- `TrendingHistoryIndexEntry` — `{ name, kind, velocity_index?, sparkline: Vec<u64> }`. Compact per-package summary for the index.

**Per-package cache:** `TrendingHistoryCache` (`src-tauri/src/trending/history/cache.rs`) — single-slot `index` + `HashMap<HistoryKey, CachedSeries>` for per-package series. TTL 6h matching the nightly collector cadence. Cap 500 entries with oldest-by-`fetched_at` eviction.

**Tests:** +33 backend tests across all three steps (473 → 506). Critical invariants pinned:

- Toggle off → `FeatureDisabled` (not `ParanoidModeBlocked`) — frontend routes correctly
- Paranoid on, toggle on → `ParanoidModeBlocked` — master switch wins
- FirstLaunch → `FeatureDisabled` — no zerologic.com traffic until explicit opt-in
- Corrupt settings → `ParanoidModeBlocked` (fail-closed via inner gate)
- URL builder rejects `../`, `/`, ` `, `;` — exhaustively tested
- Velocity returns `None` for degenerate / too-small / non-monotonic inputs

### 13.15 v0.5.0 — Opt-in vulnerability scanning

**Settings:** new `vulnerability_scanning_enabled: bool` field on the `Settings` struct (`src-tauri/src/commands/settings.rs:163`). `#[serde(default)]`, defaults `false` in `Settings::default()`. Forward-compat tested: a v0.4.x `settings.json` missing this field reads cleanly as `false`. Distinct from `enhanced_trending_enabled` and `github_enabled` — each opt-in surface has its own toggle so users can grant consent at the right granularity.

**New gate:** `AppState::require_vulnerability_scanning()` (`src-tauri/src/state.rs:355`) composes the master `require_network` gate with the per-feature toggle. Returns:

- `Ok(())` when paranoid OFF and `vulnerability_scanning_enabled == true`
- `Err(FeatureDisabled { feature: "vulnerability_scanning" })` when paranoid OFF but toggle OFF (also returned for `FirstLaunch`)
- `Err(ParanoidModeBlocked { feature: "vulnerability_scanning" })` when paranoid ON regardless of toggle, AND when settings are `Corrupt` (inner gate fires)

Five rejection paths pinned by tests at `src-tauri/src/state.rs:602-680`.

**New error variant:** `BrewError::VulnsNotInstalled { install_command: String }` (`src-tauri/src/error.rs:172`). Returned by `vulns_scan_all` / `vulns_scan_one` when the `brew vulns` subcommand is not installed. The frontend surfaces an install affordance instead of a toast — the user-facing remediation is the one-click installer, not a transient notice.

**New module:** `src-tauri/src/vulns/` (4 files, ~2,100 lines + the IPC handler):

- `mod.rs` — module header + re-exports.
- `client.rs` (~580 lines) — `check_brew_vulns_installed`, `scan_all`, `scan_one`, `install_brew_vulns`, `validate_formula_name`, `looks_like_subcommand_missing` helper, private `run_vulns_capture` (tolerant subprocess wrapper). Defines `Severity` enum (custom case-folding `Deserialize`), `RawVuln`, `RawScanResult`, plus deserialize helpers `string_or_null` + `first_string_or_none` for wire-shape normalization. `BREW_VULNS_INSTALL_CMD` constant pinned at `"brew install homebrew/brew-vulns/brew-vulns"`. All subprocess invocations go through `tokio::process::Command::new(brew).args(["vulns", ...])` — argv-safe + validator-checked.

  Two subprocess-integration subtleties that warrant calling out (pinned by tests + comments at the trap sites):

  1. **`check_brew_vulns_installed` uses `brew --prefix brew-vulns`**, NOT `brew commands --include-aliases`. brew-vulns ships as a regular formula whose `bin/brew-vulns` shim becomes a `brew vulns` external subcommand via brew's PATH-based dispatch — and `brew commands` does NOT enumerate external `brew-FOO` binaries from installed formulae. `brew --prefix <formula>` exits 0 with the prefix path when present, exit 1 with "No available formula" when not — clean status-code-only probe, no output parsing.
  2. **`scan_all` / `scan_one` use the private `run_vulns_capture` helper**, NOT `run_brew_capture`. brew-vulns follows the standard CI-scanner convention: exit 0 means "scan succeeded, no findings", exit 1 means "scan succeeded, findings present", exit ≥ 2 is a real error. `run_brew_capture` rejects every non-zero exit as `BrewExitNonZero` — which would throw away the JSON output on every install that actually has vulnerabilities (the common case). `run_vulns_capture` accepts both 0 and 1 and only typed-errors on ≥ 2.
- `cache.rs` (~550 lines) — `VulnsCache` with per-package TTL (`VULNS_CACHE_TTL = 6 hours`) and install-set fingerprint slot. `MAX_VULNS_CACHE_BYTES = 1 MiB` cap on both load and save. `VulnKey { kind, name, version }` newtype with `to_storage_key` / `parse` for the `"formula:name:version"` storage form. `get_fresh` honours TTL; `get_any` returns even stale; `put` / `invalidate` / `record_fingerprint` / `should_skip_full_scan` round out the surface. Atomic-write via the shared helper; fail-soft on corrupt + future-schema.
- `fingerprint.rs` (~150 lines) — `compute(installed: &[InstalledRef]) -> String`. Sorts the input by `(kind, name, version)`, builds canonical `kind:name:version` lines, hashes the joined bytes with SHA-256, returns lowercase hex. Deterministic across runs / machines / Rust versions (DefaultHasher's salt randomisation would silently invalidate the cached fingerprint on every launch).
- `enrich.rs` (~900 lines) — `GhsaCache` parallel to `VulnsCache` (`MAX_GHSA_CACHE_BYTES = 2 MiB`), `GhsaAdvisory` wire shape, `cache_path()`, and the `enrich(state, vulns)` async fn. Iterates GHSA-prefixed IDs in the input slice, consults the cache first, fetches missing IDs from `api.github.com/advisories/{GHSA_ID}` (only when `settings.github_enabled` is on — triple-defense after the outer gates), best-effort on 403 / 429 / network error (logs, leaves the OSV record unchanged).

**New AppState field:** `vulns_cache: Arc<Mutex<VulnsCache>>` + `ghsa_cache: Arc<Mutex<GhsaCache>>`. Hydrated lazily on the first scan via `ensure_cache_hydrated` — avoids paying the file-read cost when the user never opts in.

**New IPCs (4):**

| Command | Signature | Purpose | `require_vulnerability_scanning` | `require_network` | File |
|---|---|---|---|---|---|
| `vulns_scan_all` | `async fn vulns_scan_all(state, force: bool) -> Result<VulnScanReport, BrewError>` | Full-install-set scan. `force=false` returns the cached report when the install-set fingerprint matches; `force=true` (Refresh button) always re-shells. Per-package GHSA enrichment is best-effort. Writes results + fingerprint back to the cache + persists. | **yes** | (composed into the gate above) | `commands/vulns.rs:177` |
| `vulns_scan_one` | `async fn vulns_scan_one(state, name: String) -> Result<Vec<RawVuln>, BrewError>` | Single-formula scan, used by PackageDetail "Check vulnerabilities". `validate_formula_name` gates the input. Caches when the installed version is resolvable from `installed_cache`; otherwise returns live without caching (cache entry needs a version for the key). | **yes** | (composed) | `commands/vulns.rs:263` |
| `vulns_install_helper` | `async fn vulns_install_helper(state) -> Result<String, BrewError>` | One-click installer for the `brew vulns` subcommand. Runs `brew install homebrew/brew-vulns/brew-vulns` under the write lock. Returns captured stdout for Activity-drawer surfacing. **Gated only by `require_network`** — the per-feature toggle is intentionally bypassed (first-run flow is "install → toggle on → scan"). | no (intentional) | **yes** ("vulns_install") | `commands/vulns.rs:317` |
| `vulns_invalidate` | `async fn vulns_invalidate(state, kind, name, version) -> Result<(), BrewError>` | Drop a single cache entry by `VulnKey`. Called by post-install / post-upgrade / post-uninstall hooks so a CVE record for a version the user no longer has can't outlive its referent. **Ungated** — cleanup after state changes is always safe, and removing data is never a privacy concern. | no | no | `commands/vulns.rs:346` |

**New wire types** (`src-tauri/src/commands/vulns.rs:57-79` + `src-tauri/src/vulns/{client,cache,enrich}.rs`):

- `VulnScanReport { entries: HashMap<String, ScanRecord>, scanned_at: DateTime<Utc>, source: String, install_fingerprint: String }` — the `vulns_scan_all` response. `source` is `"live"` for a fresh subprocess invocation, `"cache"` for the fingerprint-skip path. `entries` is keyed by `"formula:name:version"` so the frontend's `(kind, name, version)` lookup stays O(1).
- `ScanRecord { vulns: Vec<RawVuln>, scanned_at: DateTime<Utc> }` — per-package cache entry.
- `VulnKey { kind: PackageKind, name: String, version: String }` — the cache key. Casks are accepted in the type but produce empty results (brew-vulns is formula-only).
- `RawVuln { id: String, severity: Severity, summary: String, details: String, references: Vec<String>, fixed_in: Option<String>, published: Option<String> }` — canonical in-app shape. The wire format from `brew vulns --json` uses snake_case + nullable `summary` + `fixed_versions: [String]` (array, often empty); we normalize at the parse boundary:
  - `summary: null` → `""` via the `string_or_null` deserializer
  - `fixed_versions: ["3.2.1", ...]` → `fixed_in: Some("3.2.1")` (first element wins — earliest patch) via the `first_string_or_none` deserializer (also accepts a bare string for forward-compat)
  - `aliases`, `tag`, `repo_url` and other extras from the wire are ignored harmlessly via `#[serde(default)]`
  - Shape regression-pinned by `vulns::client::tests::raw_scan_result_parses_real_brew_vulns_output` using a captured fixture from real `brew vulns --json` output
- `Severity { Critical, High, Medium, Low, Unknown }` — custom case-folding `Deserialize` accepts UPPERCASE (real brew-vulns wire format), lowercase (the convention elsewhere in the codebase), and `"MODERATE"` as a GHSA-flavored alias for `Medium`. Unknown / missing values fall back to `Unknown` so a brew-vulns release that adds a new severity label doesn't break us. **The default `#[serde(rename_all = "lowercase")]` does NOT case-fold on deserialize — this is a custom impl, not the derived one.**
- `GhsaAdvisory { ghsa_id, summary, description?, severity, html_url?, references }` — best-effort enrichment payload.

**Subprocess safety:** every formula name passed to `brew vulns` (whether from `vulns_scan_one` or derived from the install set in `vulns_scan_all`) runs through `validate_formula_name` against `^[a-z0-9._@+-]+$`. Defense-in-depth — `Command::new + .arg()` is already argv-safe, but the validator mirrors the same pattern used for `services_list` (§13.3) and `validate_cask_token` (§13.7) so the surface stays uniform.

**Tests:** +72 backend tests across the four-module set (cache: 14, client: 16, fingerprint: 8, enrich: 12, commands/vulns: 1 gate test, state: 5 `require_vulnerability_scanning_*` tests, settings: forward-compat + camelCase round-trip, error: VulnsNotInstalled serialization). Backend total moves from 507 → 579+.

Critical invariants pinned:

- Toggle off → `FeatureDisabled` (not `ParanoidModeBlocked`) — frontend routes correctly to the per-feature card, not Offline Mode
- Paranoid on, toggle on → `ParanoidModeBlocked` — master switch wins
- FirstLaunch → `FeatureDisabled` — no OSV traffic until explicit opt-in
- Corrupt settings → `ParanoidModeBlocked` (fail-closed via inner gate)
- `vulns_install_helper` only checks `require_network`, not the per-feature toggle
- `validate_formula_name` rejects shell metas, empties, oversize input
- `VULNS_CACHE_TTL` is 6 hours (`cache_ttl_is_six_hours` test)
- Cache corrupt → empty cache returned, no panic
- GHSA enrichment soft-fails when `github_enabled` is off
- Install-set fingerprint is deterministic across runs (sorted input → stable hash)
