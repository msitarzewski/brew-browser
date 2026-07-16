//  AppSettings.swift
//  BrewBrowser (native Swift port)
//
//  Native Swift port of the Tauri/Rust settings model. Reads and writes the
//  SAME `settings.json` file (same path, same camelCase schema, same clamps,
//  same atomic-write contract) the Tauri app uses, so the two apps interoperate.
//
//  Rust source of truth:
//    - src-tauri/src/commands/settings.rs
//        * struct Settings (camelCase wire keys) .................. ~L55-164
//        * Default impl ............................................ ~L173-209
//        * clamp() ranges + skip-list cap ......................... ~L211-270
//        * MAX_SETTINGS_BYTES (1 MiB) ............................. ~L45
//        * SettingsLoadState (FirstLaunch / Loaded / Corrupt) ..... ~L295-333
//        * load_at_startup (file-absent vs corrupt vs loaded) ..... ~L351-410
//        * persist (clamp -> serialize -> cap check -> atomic) .... ~L468-500
//    - src-tauri/src/state.rs
//        * resolve_app_data_dir ................................... ~L388-398
//        * require_network / require_*_* gates (paranoid + corrupt) ~L278-365
//
//  Path parity: the Rust side resolves `dirs::data_dir()` which on macOS is
//  `~/Library/Application Support`, then pushes "brew-browser" and
//  "settings.json". We mirror that with FileManager's .applicationSupportDirectory.

import Foundation

// MARK: - Enums (kebab-case wire format, mirroring Rust `#[serde(rename_all = "kebab-case")]`)

/// Catalog auto-refresh cadence.
///
/// Mirrors Rust `CatalogAutoRefresh` (`commands/settings.rs` ~L274-282).
/// Wire-format is kebab-case to match the frontend TypeScript union
/// (`"off" | "weekly" | "daily"`). Default `.off`.
public enum CatalogAutoRefresh: String, Codable, Sendable, CaseIterable {
    case off = "off"
    case weekly = "weekly"
    case daily = "daily"

    /// Rust `#[default]` is `Off` (`commands/settings.rs` ~L278-279).
    public static let `default`: CatalogAutoRefresh = .off
}

/// Cask icon fetching mode.
///
/// Mirrors Rust `CaskIconMode` (`commands/settings.rs` ~L286-293).
/// Wire-format is kebab-case. Default `.all` (preserves Phase 8 behaviour).
public enum CaskIconMode: String, Codable, Sendable, CaseIterable {
    case off = "off"
    case installedOnly = "installed-only"
    case all = "all"

    /// Rust `#[default]` is `All` (`commands/settings.rs` ~L291-292).
    public static let `default`: CaskIconMode = .all
}

// MARK: - Codable DTO (exact on-disk wire shape)

/// Plain Codable mirror of the on-disk JSON. JSON keys are camelCase
/// **verbatim** — we declare them explicitly via `CodingKeys` so there is
/// NO key-conversion strategy in play (matches Rust
/// `#[serde(rename_all = "camelCase")]` on `commands/settings.rs` ~L56).
///
/// Every field is decoded defensively with its default if the key is absent,
/// mirroring Rust's `#[serde(default)]` on every field — this is what gives
/// forward/back compatibility (an older app reading a newer file, or vice
/// versa). See the per-field `#[serde(default)]` annotations in
/// `commands/settings.rs` ~L106-163.
// Internal (not private) so the test target can exercise the forward-compat
// decode contract (`decodeIfPresent` → defaults) via `@testable`. Still
// module-internal — not part of the public API.
struct SettingsDTO: Codable {
    var paranoidMode: Bool
    var catalogAutoRefresh: CatalogAutoRefresh
    var catalogStaleBannerDays: UInt32
    var caskIconMode: CaskIconMode
    var trendingTtlMinutes: UInt32
    var githubEnabled: Bool
    var aiFeaturesEnabled: Bool
    var updateAutoCheck: Bool
    var skippedUpdateVersions: [String]
    var enhancedTrendingEnabled: Bool
    var vulnerabilityScanningEnabled: Bool
    var liveEnrichmentEnabled: Bool
    var liveBundlesEnabled: Bool

    /// Explicit keys = no automatic conversion. These are the literal JSON
    /// keys the Tauri app writes (`commands/settings.rs` field names under
    /// `rename_all = "camelCase"`).
    enum CodingKeys: String, CodingKey {
        case paranoidMode
        case catalogAutoRefresh
        case catalogStaleBannerDays
        case caskIconMode
        case trendingTtlMinutes
        case githubEnabled
        case aiFeaturesEnabled
        case updateAutoCheck
        case skippedUpdateVersions
        case enhancedTrendingEnabled
        case vulnerabilityScanningEnabled
        case liveEnrichmentEnabled
        case liveBundlesEnabled
    }

    /// All-defaults DTO. Mirrors Rust `impl Default for Settings`
    /// (`commands/settings.rs` ~L173-209): paranoid OFF, refresh Off,
    /// banner-days 14, icons All, TTL 60, github OFF, AI ON, auto-check OFF,
    /// empty skip list, enhanced-trending OFF, vuln-scanning OFF.
    /// Explicit memberwise init — the custom `init(from:)` below suppresses
    /// Swift's synthesized memberwise initializer, so we declare it ourselves.
    init(
        paranoidMode: Bool,
        catalogAutoRefresh: CatalogAutoRefresh,
        catalogStaleBannerDays: UInt32,
        caskIconMode: CaskIconMode,
        trendingTtlMinutes: UInt32,
        githubEnabled: Bool,
        aiFeaturesEnabled: Bool,
        updateAutoCheck: Bool,
        skippedUpdateVersions: [String],
        enhancedTrendingEnabled: Bool,
        vulnerabilityScanningEnabled: Bool,
        liveEnrichmentEnabled: Bool,
        liveBundlesEnabled: Bool
    ) {
        self.paranoidMode = paranoidMode
        self.catalogAutoRefresh = catalogAutoRefresh
        self.catalogStaleBannerDays = catalogStaleBannerDays
        self.caskIconMode = caskIconMode
        self.trendingTtlMinutes = trendingTtlMinutes
        self.githubEnabled = githubEnabled
        self.aiFeaturesEnabled = aiFeaturesEnabled
        self.updateAutoCheck = updateAutoCheck
        self.skippedUpdateVersions = skippedUpdateVersions
        self.enhancedTrendingEnabled = enhancedTrendingEnabled
        self.vulnerabilityScanningEnabled = vulnerabilityScanningEnabled
        self.liveEnrichmentEnabled = liveEnrichmentEnabled
        self.liveBundlesEnabled = liveBundlesEnabled
    }

    static func defaults() -> SettingsDTO {
        SettingsDTO(
            paranoidMode: false,
            catalogAutoRefresh: .off,
            catalogStaleBannerDays: 14,
            caskIconMode: .all,
            trendingTtlMinutes: 60,
            githubEnabled: false,
            aiFeaturesEnabled: true,
            updateAutoCheck: false,
            skippedUpdateVersions: [],
            enhancedTrendingEnabled: false,
            vulnerabilityScanningEnabled: false,
            liveEnrichmentEnabled: false,
            liveBundlesEnabled: false
        )
    }

    /// Decode defensively: any missing key falls back to its default. Mirrors
    /// Rust `#[serde(default)]` on every field. An unknown enum *variant*
    /// (e.g. `"every-blue-moon"` for catalogAutoRefresh) is a hard decode
    /// error in both Rust serde and Swift — by design it surfaces as Corrupt
    /// (see `AppSettings.load()` and the Rust `unknown_enum_variant_is_corrupt`
    /// test, `commands/settings.rs` ~L730-754).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsDTO.defaults()
        paranoidMode = try c.decodeIfPresent(Bool.self, forKey: .paranoidMode) ?? d.paranoidMode
        catalogAutoRefresh = try c.decodeIfPresent(CatalogAutoRefresh.self, forKey: .catalogAutoRefresh) ?? d.catalogAutoRefresh
        catalogStaleBannerDays = try c.decodeIfPresent(UInt32.self, forKey: .catalogStaleBannerDays) ?? d.catalogStaleBannerDays
        caskIconMode = try c.decodeIfPresent(CaskIconMode.self, forKey: .caskIconMode) ?? d.caskIconMode
        trendingTtlMinutes = try c.decodeIfPresent(UInt32.self, forKey: .trendingTtlMinutes) ?? d.trendingTtlMinutes
        githubEnabled = try c.decodeIfPresent(Bool.self, forKey: .githubEnabled) ?? d.githubEnabled
        aiFeaturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiFeaturesEnabled) ?? d.aiFeaturesEnabled
        updateAutoCheck = try c.decodeIfPresent(Bool.self, forKey: .updateAutoCheck) ?? d.updateAutoCheck
        skippedUpdateVersions = try c.decodeIfPresent([String].self, forKey: .skippedUpdateVersions) ?? d.skippedUpdateVersions
        enhancedTrendingEnabled = try c.decodeIfPresent(Bool.self, forKey: .enhancedTrendingEnabled) ?? d.enhancedTrendingEnabled
        vulnerabilityScanningEnabled = try c.decodeIfPresent(Bool.self, forKey: .vulnerabilityScanningEnabled) ?? d.vulnerabilityScanningEnabled
        liveEnrichmentEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveEnrichmentEnabled) ?? d.liveEnrichmentEnabled
        liveBundlesEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveBundlesEnabled) ?? d.liveBundlesEnabled
    }
}

// MARK: - Load state (three-state, mirroring Rust SettingsLoadState)

/// Three-state load result, mirroring Rust `SettingsLoadState`
/// (`commands/settings.rs` ~L301-313).
///
/// The distinction between `.firstLaunch` and `.corrupt` is load-bearing
/// (security review §12d): the former applies defaults (paranoid OFF), the
/// latter fails closed (paranoid effectively ON until the user repairs the
/// file or resets to defaults).
public enum SettingsLoadState: Sendable, Equatable {
    /// `settings.json` did not exist. Defaults apply, paranoid OFF.
    case firstLaunch
    /// Successfully parsed (and clamped).
    case loaded
    /// File present but unreadable (bad JSON, oversize, read error, unknown
    /// enum variant). Fail closed: network gates deny until repaired.
    case corrupt(message: String)
}

// MARK: - Observable settings model

/// Hard cap on settings.json size. Mirrors Rust `MAX_SETTINGS_BYTES`
/// (`commands/settings.rs` ~L45): 1 MiB. Enforced on both read and write.
private let maxSettingsBytes: Int = 1024 * 1024

/// Live, observable application settings.
///
/// Self-contained: depends on no other app types. Reads/writes the same
/// `settings.json` the Tauri app uses so both apps interoperate.
///
/// - `load()` mirrors Rust `load_at_startup` (`commands/settings.rs` ~L351-410).
/// - `save()` mirrors Rust `persist` (`commands/settings.rs` ~L468-500):
///   clamp -> serialize -> 1 MiB cap check -> atomic write (temp + rename).
/// - Gating helpers mirror `AppState::require_network` /
///   `require_enhanced_trending` / `require_vulnerability_scanning`
///   (`state.rs` ~L291-365).
@MainActor
@Observable
public final class AppSettings {

    /// Process-wide shared instance so the main window and the Settings scene
    /// observe the same settings (a toggle flipped in Settings updates gating
    /// everywhere). Mirrors the LocalPrefs.shared pattern.
    public static let shared = AppSettings.load()

    // MARK: Clamp ranges (mirror Rust associated consts, commands/settings.rs ~L212-223)

    /// Inclusive `[min, max]` for `catalogStaleBannerDays` — Rust
    /// `CATALOG_STALE_DAYS_MIN`/`MAX` (1, 365).
    public static let catalogStaleDaysRange: ClosedRange<UInt32> = 1...365
    /// Inclusive `[min, max]` for `trendingTtlMinutes` — Rust
    /// `TRENDING_TTL_MIN`/`MAX` (5, 1440).
    public static let trendingTtlRange: ClosedRange<UInt32> = 5...1440
    /// Max entries kept in `skippedUpdateVersions` — Rust
    /// `SKIPPED_UPDATE_VERSIONS_CAP` (10). FIFO eviction of the oldest.
    public static let skippedUpdateVersionsCap: Int = 10

    // MARK: Stored properties (one per setting; camelCase JSON keys)

    /// Master "block all outbound network" switch. Default `false`.
    /// (`commands/settings.rs` paranoid_mode ~L61)
    public var paranoidMode: Bool

    /// Catalog auto-refresh cadence. Default `.off`.
    /// (`commands/settings.rs` catalog_auto_refresh ~L67)
    public var catalogAutoRefresh: CatalogAutoRefresh

    /// Show the "catalog is N days old" banner at this age. Default 14,
    /// clamped to `[1, 365]`. (`commands/settings.rs` ~L72)
    public var catalogStaleBannerDays: UInt32

    /// Cask icon fetching mode. Default `.all`.
    /// (`commands/settings.rs` cask_icon_mode ~L78)
    public var caskIconMode: CaskIconMode

    /// Trending cache TTL in minutes. Default 60, clamped to `[5, 1440]`.
    /// (`commands/settings.rs` ~L84)
    public var trendingTtlMinutes: UInt32

    /// GitHub repo-stat probes (opt-in). Default `false`.
    /// (`commands/settings.rs` github_enabled ~L93)
    public var githubEnabled: Bool

    /// Master AI-features rendering toggle. Default `true`.
    /// (`commands/settings.rs` ai_features_enabled ~L107)
    public var aiFeaturesEnabled: Bool

    /// Opt-in daily auto-check for in-app updates. Default `false`.
    /// (`commands/settings.rs` update_auto_check ~L118)
    public var updateAutoCheck: Bool

    /// Versions the user dismissed. Bounded at 10 entries, FIFO.
    /// (`commands/settings.rs` skipped_update_versions ~L126)
    public var skippedUpdateVersions: [String]

    /// Opt-in enhanced trending history (project infra). Default `false`.
    /// (`commands/settings.rs` enhanced_trending_enabled ~L143)
    public var enhancedTrendingEnabled: Bool

    /// Opt-in vulnerability scanning. Default `false`.
    /// (`commands/settings.rs` vulnerability_scanning_enabled ~L163)
    public var vulnerabilityScanningEnabled: Bool

    /// Opt-in live category/description refresh (project infra). Default `false`.
    /// (`commands/settings.rs` live_enrichment_enabled)
    public var liveEnrichmentEnabled: Bool

    /// Opt-in live Bundles-catalog refresh (project infra, M5). Default `false`.
    /// Fetches `bundles/bundles.json` from the same first-party host; unlike
    /// enrichment it is NOT an AI feature, so its gate omits the AI requirement.
    /// The Tauri `Settings` struct ignores this key until its own M5 lands
    /// (`#[serde(default)]`, no `deny_unknown_fields`), so writing it is
    /// forward-compatible across shells.
    public var liveBundlesEnabled: Bool

    /// Current load state. `.corrupt` fails closed (paranoid effectively ON).
    /// Mirrors the in-memory `SettingsLoadState` slot in `state.rs`.
    public private(set) var loadState: SettingsLoadState

    // MARK: Init

    /// Initialize from a DTO + load state. Applies clamps on the way in
    /// (mirrors Rust clamping after every load).
    private init(dto: SettingsDTO, loadState: SettingsLoadState) {
        self.paranoidMode = dto.paranoidMode
        self.catalogAutoRefresh = dto.catalogAutoRefresh
        self.catalogStaleBannerDays = dto.catalogStaleBannerDays
        self.caskIconMode = dto.caskIconMode
        self.trendingTtlMinutes = dto.trendingTtlMinutes
        self.githubEnabled = dto.githubEnabled
        self.aiFeaturesEnabled = dto.aiFeaturesEnabled
        self.updateAutoCheck = dto.updateAutoCheck
        self.skippedUpdateVersions = dto.skippedUpdateVersions
        self.enhancedTrendingEnabled = dto.enhancedTrendingEnabled
        self.vulnerabilityScanningEnabled = dto.vulnerabilityScanningEnabled
        self.liveEnrichmentEnabled = dto.liveEnrichmentEnabled
        self.liveBundlesEnabled = dto.liveBundlesEnabled
        self.loadState = loadState
        self.clamp()
    }

    // MARK: Path resolution

    /// Resolve `~/Library/Application Support/brew-browser/settings.json`.
    ///
    /// Mirrors Rust `state::resolve_app_data_dir` + `settings::settings_path`
    /// (`state.rs` ~L388-398, `commands/settings.rs` ~L340-342): `dirs::data_dir()`
    /// on macOS == `.applicationSupportDirectory`, then "brew-browser",
    /// then "settings.json".
    public static func settingsURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return appSupport
            .appendingPathComponent("brew-browser", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    // MARK: Load

    /// Synchronous startup loader. Mirrors Rust `load_at_startup`
    /// (`commands/settings.rs` ~L351-410):
    ///
    /// - File absent (or path unresolvable) → `.firstLaunch`: defaults apply,
    ///   paranoid OFF.
    /// - File present, > 1 MiB, unreadable, bad JSON, or unknown enum variant
    ///   → `.corrupt`: fail closed.
    /// - File present and parses cleanly → `.loaded`, with numeric clamps
    ///   re-applied (defense against a hand-edited settings.json).
    public static func load() -> AppSettings {
        let url: URL
        do {
            url = try settingsURL()
        } catch {
            // Cannot even resolve Application Support — treat as first launch
            // (defaults, paranoid OFF) rather than failing closed: there is no
            // file to be "corrupt", this matches Rust's NotFound → FirstLaunch.
            return AppSettings(dto: .defaults(), loadState: .firstLaunch)
        }

        // File-absent → FirstLaunch (Rust: metadata NotFound, ~L356-358).
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppSettings(dto: .defaults(), loadState: .firstLaunch)
        }

        // Size cap pre-check (Rust: meta.len() > MAX_SETTINGS_BYTES, ~L369-383).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxSettingsBytes {
            let msg = "settings.json is \(size) bytes, exceeds \(maxSettingsBytes)-byte cap"
            return AppSettings(dto: .defaults(), loadState: .corrupt(message: msg))
        }

        // Read (Rust: std::fs::read, ~L385-393).
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return AppSettings(
                dto: .defaults(),
                loadState: .corrupt(message: "read \(url.path): \(error.localizedDescription)")
            )
        }

        // Belt-and-suspenders post-read size cap (Rust checks pre-read via
        // metadata; we re-check the bytes we actually got).
        if data.count > maxSettingsBytes {
            let msg = "settings.json is \(data.count) bytes, exceeds \(maxSettingsBytes)-byte cap"
            return AppSettings(dto: .defaults(), loadState: .corrupt(message: msg))
        }

        // Parse (Rust: serde_json::from_slice; bad JSON or unknown enum
        // variant → Corrupt, ~L395-409).
        do {
            let dto = try JSONDecoder().decode(SettingsDTO.self, from: data)
            // init applies clamp() (Rust: s.clamp() after a good parse, ~L397).
            return AppSettings(dto: dto, loadState: .loaded)
        } catch {
            return AppSettings(
                dto: .defaults(),
                loadState: .corrupt(message: "parse \(url.path): \(error.localizedDescription)")
            )
        }
    }

    // MARK: Clamp

    /// Re-apply the numeric clamps + skip-list cap. Idempotent. Mirrors Rust
    /// `Settings::clamp` (`commands/settings.rs` ~L227-241): clamp banner-days
    /// to `[1,365]`, TTL to `[5,1440]`, and prune the skip list to the most
    /// recent 10 (FIFO — oldest dropped).
    public func clamp() {
        catalogStaleBannerDays = catalogStaleBannerDays.clamped(to: Self.catalogStaleDaysRange)
        trendingTtlMinutes = trendingTtlMinutes.clamped(to: Self.trendingTtlRange)
        if skippedUpdateVersions.count > Self.skippedUpdateVersionsCap {
            let excess = skippedUpdateVersions.count - Self.skippedUpdateVersionsCap
            skippedUpdateVersions.removeFirst(excess)
        }
    }

    /// Push `version` onto `skippedUpdateVersions` with de-dup + FIFO eviction.
    /// Mirrors Rust `Settings::push_skipped_version`
    /// (`commands/settings.rs` ~L253-269): if already at the tail, no-op
    /// (returns `false`); otherwise drop any existing entry, append, and evict
    /// the oldest while over cap. Returns `true` when the list changed.
    @discardableResult
    public func pushSkippedVersion(_ version: String) -> Bool {
        if skippedUpdateVersions.last == version { return false }
        skippedUpdateVersions.removeAll { $0 == version }
        skippedUpdateVersions.append(version)
        while skippedUpdateVersions.count > Self.skippedUpdateVersionsCap {
            skippedUpdateVersions.removeFirst()
        }
        return true
    }

    // MARK: Save

    /// Errors surfaced by `save()`.
    public enum SaveError: Error, CustomStringConvertible {
        /// Serialized payload exceeds the 1 MiB cap.
        case oversize(bytes: Int)
        /// Underlying filesystem failure.
        case io(String)

        public var description: String {
            switch self {
            case .oversize(let bytes):
                return "serialized settings are \(bytes) bytes, exceeds \(maxSettingsBytes)-byte cap"
            case .io(let message):
                return "settings save failed: \(message)"
            }
        }
    }

    /// Serialize + atomically persist. Mirrors Rust `persist`
    /// (`commands/settings.rs` ~L468-500):
    ///   1. clamp numerics (no-op if already in range),
    ///   2. serialize to pretty JSON bytes (camelCase keys, verbatim),
    ///   3. reject if over the 1 MiB cap (`SaveError.oversize`),
    ///   4. ensure the parent dir exists (defense-in-depth mkdir),
    ///   5. atomic write: write to a sibling temp file, then rename into place.
    ///
    /// On success the load state becomes `.loaded` (a corrupt file the user
    /// just overwrote via Reset/Save is now good).
    public func save() throws {
        clamp()

        let dto = SettingsDTO(
            paranoidMode: paranoidMode,
            catalogAutoRefresh: catalogAutoRefresh,
            catalogStaleBannerDays: catalogStaleBannerDays,
            caskIconMode: caskIconMode,
            trendingTtlMinutes: trendingTtlMinutes,
            githubEnabled: githubEnabled,
            aiFeaturesEnabled: aiFeaturesEnabled,
            updateAutoCheck: updateAutoCheck,
            skippedUpdateVersions: skippedUpdateVersions,
            enhancedTrendingEnabled: enhancedTrendingEnabled,
            vulnerabilityScanningEnabled: vulnerabilityScanningEnabled,
            liveEnrichmentEnabled: liveEnrichmentEnabled,
            liveBundlesEnabled: liveBundlesEnabled
        )

        let encoder = JSONEncoder()
        // Pretty + sorted keys ≈ Rust `to_vec_pretty`. (No keyEncodingStrategy:
        // the DTO's CodingKeys are already the exact camelCase wire keys.)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let bytes: Data
        do {
            bytes = try encoder.encode(dto)
        } catch {
            throw SaveError.io("serialize settings: \(error.localizedDescription)")
        }

        // Size cap (Rust: pre-write byte-length check, ~L473-481).
        guard bytes.count <= maxSettingsBytes else {
            throw SaveError.oversize(bytes: bytes.count)
        }

        let url: URL
        do {
            url = try Self.settingsURL()
        } catch {
            throw SaveError.io("resolve settings path: \(error.localizedDescription)")
        }

        let dir = url.deletingLastPathComponent()
        // Defense-in-depth mkdir (Rust: create_dir_all if missing, ~L486-495).
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw SaveError.io("create settings parent \(dir.path): \(error.localizedDescription)")
            }
        }

        // Atomic write: temp sibling + rename. Mirrors Rust
        // `util::fs::atomic_write` (temp + fsync + rename). `.atomic` asks the
        // OS to write to a temp file and rename into place — no torn writes.
        do {
            try bytes.write(to: url, options: [.atomic])
        } catch {
            throw SaveError.io("atomic write \(url.path): \(error.localizedDescription)")
        }

        loadState = .loaded
    }

    /// Reset every field to its default and persist. Mirrors the Rust
    /// `settings_reset` command (overwrite settings.json with `Settings::default`).
    /// Used by the "Settings file is unreadable → Reset to defaults" affordance.
    public func reset() {
        let d = SettingsDTO.defaults()
        paranoidMode = d.paranoidMode
        catalogAutoRefresh = d.catalogAutoRefresh
        catalogStaleBannerDays = d.catalogStaleBannerDays
        caskIconMode = d.caskIconMode
        trendingTtlMinutes = d.trendingTtlMinutes
        githubEnabled = d.githubEnabled
        aiFeaturesEnabled = d.aiFeaturesEnabled
        updateAutoCheck = d.updateAutoCheck
        skippedUpdateVersions = d.skippedUpdateVersions
        enhancedTrendingEnabled = d.enhancedTrendingEnabled
        vulnerabilityScanningEnabled = d.vulnerabilityScanningEnabled
        liveBundlesEnabled = d.liveBundlesEnabled
        try? save()   // save() sets loadState = .loaded on success
    }

    // MARK: - Gating helpers (mirror Rust AppState gates, state.rs ~L278-365)

    /// `true` when the settings file failed to load (fail-closed posture).
    /// Drives the "Settings file unreadable — reset to defaults?" UX and
    /// forces every network gate below to deny.
    public var isCorrupt: Bool {
        if case .corrupt = loadState { return true }
        return false
    }

    /// Master outbound-network gate. Mirrors Rust `AppState::require_network`
    /// (`state.rs` ~L291-302):
    ///   - `.firstLaunch` → allow (defaults, paranoid OFF),
    ///   - `.loaded` with paranoid OFF → allow,
    ///   - paranoid ON OR `.corrupt` → deny (fail closed).
    ///
    /// `feature` is accepted for call-site parity / future toast routing; the
    /// decision does not depend on it (matches the Rust gate's behaviour).
    public func networkAllowed(_ feature: String) -> Bool {
        if isCorrupt { return false }
        return !paranoidMode
    }

    /// Composed gate for vulnerability scanning. Mirrors Rust
    /// `AppState::require_vulnerability_scanning` (`state.rs` ~L355-364):
    /// allowed only when not paranoid, not corrupt, AND the per-feature
    /// toggle is on.
    public var vulnerabilityScanningAllowed: Bool {
        !paranoidMode && !isCorrupt && vulnerabilityScanningEnabled
    }

    /// Composed gate for GitHub repo-stat probes. Mirrors the github_enabled
    /// opt-in composed with the paranoid/corrupt master gate (the GitHub
    /// command short-circuits when off; paranoid overrides regardless —
    /// `commands/settings.rs` ~L87-93, `state.rs` require_network).
    public var githubAllowed: Bool {
        !paranoidMode && !isCorrupt && githubEnabled
    }

    /// Composed gate for enhanced trending history. Mirrors Rust
    /// `AppState::require_enhanced_trending` (`state.rs` ~L321-334): allowed
    /// only when not paranoid, not corrupt, AND the per-feature toggle is on.
    public var enhancedTrendingAllowed: Bool {
        !paranoidMode && !isCorrupt && enhancedTrendingEnabled
    }

    /// Composed gate for live category/description updates. Mirrors Rust
    /// `AppState::require_live_enrichment`: allowed only when not paranoid, not
    /// corrupt, the per-feature toggle is on, AND AI features are on (enrichment
    /// is an AI feature).
    public var liveEnrichmentAllowed: Bool {
        !paranoidMode && !isCorrupt && liveEnrichmentEnabled && aiFeaturesEnabled
    }

    /// Composed gate for the live Bundles-catalog refresh (M5). Opt-in +
    /// network only — bundles are not AI-derived, so (unlike live enrichment)
    /// this does NOT require `aiFeaturesEnabled`.
    public var liveBundlesAllowed: Bool {
        !paranoidMode && !isCorrupt && liveBundlesEnabled
    }

    /// Whether AI-derived UI (categories, enrichment, donut, pills, summaries,
    /// use-cases, similar packages, tags) should render. This is a pure
    /// rendering gate — no I/O, network, or LLM calls — so it is NOT subject
    /// to paranoid/corrupt (matches Rust `ai_features_enabled`,
    /// `commands/settings.rs` ~L95-107).
    public var aiFeaturesVisible: Bool {
        aiFeaturesEnabled
    }
}

// MARK: - Helpers

private extension Comparable {
    /// Clamp to an inclusive range. Equivalent to Rust's `Ord::clamp`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
