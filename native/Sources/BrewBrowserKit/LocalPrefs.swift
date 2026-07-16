//
//  LocalPrefs.swift
//  BrewBrowser
//
//  Native macOS port of the browser-localStorage-backed UI preferences from the
//  Tauri app's `src/lib/stores/ui.svelte.ts`. These prefs are intentionally kept
//  separate from the gated `settings.json`; in the web app they lived in
//  `localStorage`, here they live in `UserDefaults.standard`.
//
//  Ported keys / defaults / clamps (see `src/lib/stores/ui.svelte.ts`):
//    - theme              -> "system"      (ui.svelte.ts:97, :305-313, applyTheme :338-348)
//    - defaultSection     -> "dashboard"   (ui.svelte.ts:107, DEFAULT_SECTION_VALUES :40-48)
//    - confirmDestructive -> true          (ui.svelte.ts:117, :231-242)
//    - activityMaxJobs    -> 50, clamp 1...1000      (ui.svelte.ts:25-27, :122, :244-248)
//    - activityMaxLines   -> 500, clamp 100...10000  (ui.svelte.ts:28-30, :123, :250-254)
//    - sidebarCollapsed   -> false         (ui.svelte.ts:128, :275-289)
//
//  Skipped on purpose (handled elsewhere / dead in the native port):
//    - detail-pane-width   (ui.svelte.ts:9-14, :315-335)
//    - vibrancy-material   (ui.svelte.ts:32-36, :217-229)
//

import AppKit
import Observation

/// App appearance preference. Mirrors `ThemePreference` ("light" | "dark" |
/// "system") from `src/lib/stores/ui.svelte.ts:97`. `system` follows macOS.
enum AppTheme: String, CaseIterable, Sendable {
    case light
    case dark
    case system

    /// Capitalized, human-readable label for menus / pickers.
    var label: String {
        switch self {
        case .light: return L10n.string("theme.light")
        case .dark: return L10n.string("theme.dark")
        case .system: return L10n.string("theme.system")
        }
    }
}

/// Which section the app opens on at launch. Mirrors the `DEFAULT_SECTION_VALUES`
/// allow-list in `src/lib/stores/ui.svelte.ts:40-48`.
enum LandingSection: String, CaseIterable, Sendable {
    case dashboard
    case library
    case discover
    case trending
    case snapshots
    case services
    case activity

    /// Capitalized, human-readable label (e.g. "Dashboard").
    var label: String {
        switch self {
        case .dashboard: return L10n.string("nav.dashboard")
        case .library: return L10n.string("nav.library")
        case .discover: return L10n.string("nav.discover")
        case .trending: return L10n.string("nav.trending")
        case .snapshots: return L10n.string("nav.snapshots")
        case .services: return L10n.string("nav.services")
        case .activity: return L10n.string("nav.activity")
        }
    }
}

/// Observable model for the localStorage-backed UI preferences, persisted to
/// `UserDefaults.standard` under the `"brew-browser."` key prefix. Each property
/// writes through on set; the two Int caps are clamped on set just like
/// `clampInt` in `src/lib/stores/ui.svelte.ts:50-56`.
@MainActor
@Observable
final class LocalPrefs {

    // MARK: - UserDefaults keys

    /// All keys live under this prefix, matching the Tauri app's convention
    /// (e.g. `brew-browser.theme`, `src/lib/stores/ui.svelte.ts:301`).
    private enum Key {
        static let theme = "brew-browser.theme"
        static let defaultSection = "brew-browser.default-section"
        static let confirmDestructive = "brew-browser.confirm-destructive"
        static let greedyUpgrade = "brew-browser.greedy-upgrade"
        static let activityMaxJobs = "brew-browser.activity.max-jobs"
        static let activityMaxLines = "brew-browser.activity.max-lines"
        static let sidebarCollapsed = "brew-browser.sidebar-collapsed"
        static let notifyOnTaskCompletion = "brew-browser.notify-on-task-completion"
        static let recentSearches = "brew-browser.discover.recent-searches"
    }

    /// How many recent Discover searches to retain (mirrors the Tauri
    /// `search.recent` cap in `src/lib/stores/search.svelte.ts`).
    static let recentSearchesMax = 8

    // MARK: - Defaults & clamps (from ui.svelte.ts)

    private static let defaultTheme: AppTheme = .system
    private static let defaultLandingSection: LandingSection = .dashboard
    private static let defaultConfirmDestructive = true
    /// Greedy upgrades (include self-updating casks) — off by default, mirrors
    /// the Tauri `ui.greedyUpgrade` (ui.svelte.ts). Issues #47/#31.
    private static let defaultGreedyUpgrade = false
    private static let defaultSidebarCollapsed = false
    /// Native-only: post a macOS notification when a brew task finishes while
    /// the app isn't frontmost. Opt-in (off) so we never prompt unprompted.
    private static let defaultNotifyOnTaskCompletion = false

    /// `ACTIVITY_MAX_JOBS_*` — ui.svelte.ts:25-27.
    private static let activityMaxJobsDefault = 50
    private static let activityMaxJobsRange = 1...1000
    /// `ACTIVITY_MAX_LINES_*` — ui.svelte.ts:28-30.
    private static let activityMaxLinesDefault = 500
    private static let activityMaxLinesRange = 100...10_000

    // MARK: - Properties

    /// Appearance preference; applies to `NSApp.appearance` via `applyTheme()`.
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    /// Section to land on at launch (ui.svelte.ts:107).
    var defaultSection: LandingSection {
        didSet { defaults.set(defaultSection.rawValue, forKey: Key.defaultSection) }
    }

    /// Whether destructive actions require a confirm dialog (ui.svelte.ts:117).
    var confirmDestructive: Bool {
        didSet { defaults.set(confirmDestructive, forKey: Key.confirmDestructive) }
    }

    /// Whether `brew upgrade` runs with `--greedy` so self-updating casks are
    /// included (#47/#31). Off by default. Mirrors Tauri `ui.greedyUpgrade`.
    var greedyUpgrade: Bool {
        didSet { defaults.set(greedyUpgrade, forKey: Key.greedyUpgrade) }
    }

    /// Max retained Activity jobs; clamped to 1...1000 (ui.svelte.ts:244-248).
    var activityMaxJobs: Int {
        didSet {
            let clamped = Self.clamp(activityMaxJobs, to: Self.activityMaxJobsRange)
            if clamped != activityMaxJobs {
                activityMaxJobs = clamped
                return // re-entrant set will persist
            }
            defaults.set(activityMaxJobs, forKey: Key.activityMaxJobs)
        }
    }

    /// Max retained Activity log lines; clamped to 100...10000 (ui.svelte.ts:250-254).
    var activityMaxLines: Int {
        didSet {
            let clamped = Self.clamp(activityMaxLines, to: Self.activityMaxLinesRange)
            if clamped != activityMaxLines {
                activityMaxLines = clamped
                return // re-entrant set will persist
            }
            defaults.set(activityMaxLines, forKey: Key.activityMaxLines)
        }
    }

    /// Whether the sidebar is collapsed to an icon-only rail (ui.svelte.ts:128).
    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Key.sidebarCollapsed) }
    }

    /// Native-only: macOS notification when a brew task finishes in the
    /// background. Off by default. Toggling on requests notification auth.
    var notifyOnTaskCompletion: Bool {
        didSet { defaults.set(notifyOnTaskCompletion, forKey: Key.notifyOnTaskCompletion) }
    }

    /// Recent Discover search terms, newest first. Mirrors the Tauri
    /// `search.recent` chips (`src/lib/stores/search.svelte.ts:42-43`); the web
    /// app kept these only in memory, here they persist to `UserDefaults` so the
    /// chips survive relaunch. Capped + deduped via ``recordSearch(_:)``.
    var recentSearches: [String] {
        didSet { defaults.set(recentSearches, forKey: Key.recentSearches) }
    }

    /// Push a term to the front of `recentSearches`, deduped (case-insensitive)
    /// and capped at ``recentSearchesMax`` — the native analog of the Tauri
    /// `recent = [q, ...recent.filter(r => r !== q)].slice(0, 8)` line. No-op for
    /// blank input.
    func recordSearch(_ term: String) {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var next = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        next.insert(q, at: 0)
        recentSearches = Array(next.prefix(Self.recentSearchesMax))
    }

    /// Clear all recent searches (the "Clear" affordance on the chip row).
    func clearRecentSearches() {
        recentSearches = []
    }

    // MARK: - Shared instance

    /// Process-wide instance, loaded from `UserDefaults` on first access.
    static let shared = LocalPrefs()

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Init

    /// Reads each pref from `UserDefaults` with the documented fallbacks, clamping
    /// the two Int caps on read so a corrupted/hostile value can't survive
    /// (mirrors clamp-on-read in ui.svelte.ts:258-271).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // theme — validate against the enum, else fall back to system.
        if let raw = defaults.string(forKey: Key.theme), let parsed = AppTheme(rawValue: raw) {
            self.theme = parsed
        } else {
            self.theme = Self.defaultTheme
        }

        // defaultSection — validate against the allow-list, else dashboard.
        if let raw = defaults.string(forKey: Key.defaultSection),
           let parsed = LandingSection(rawValue: raw) {
            self.defaultSection = parsed
        } else {
            self.defaultSection = Self.defaultLandingSection
        }

        // confirmDestructive — absent key defaults to true.
        if defaults.object(forKey: Key.confirmDestructive) != nil {
            self.confirmDestructive = defaults.bool(forKey: Key.confirmDestructive)
        } else {
            self.confirmDestructive = Self.defaultConfirmDestructive
        }

        // greedyUpgrade — absent key defaults to false.
        if defaults.object(forKey: Key.greedyUpgrade) != nil {
            self.greedyUpgrade = defaults.bool(forKey: Key.greedyUpgrade)
        } else {
            self.greedyUpgrade = Self.defaultGreedyUpgrade
        }

        // activityMaxJobs — clamp on read.
        if defaults.object(forKey: Key.activityMaxJobs) != nil {
            self.activityMaxJobs = Self.clamp(
                defaults.integer(forKey: Key.activityMaxJobs),
                to: Self.activityMaxJobsRange
            )
        } else {
            self.activityMaxJobs = Self.activityMaxJobsDefault
        }

        // activityMaxLines — clamp on read.
        if defaults.object(forKey: Key.activityMaxLines) != nil {
            self.activityMaxLines = Self.clamp(
                defaults.integer(forKey: Key.activityMaxLines),
                to: Self.activityMaxLinesRange
            )
        } else {
            self.activityMaxLines = Self.activityMaxLinesDefault
        }

        // sidebarCollapsed — absent key defaults to false.
        if defaults.object(forKey: Key.sidebarCollapsed) != nil {
            self.sidebarCollapsed = defaults.bool(forKey: Key.sidebarCollapsed)
        } else {
            self.sidebarCollapsed = Self.defaultSidebarCollapsed
        }

        // notifyOnTaskCompletion — absent key defaults to false (opt-in).
        if defaults.object(forKey: Key.notifyOnTaskCompletion) != nil {
            self.notifyOnTaskCompletion = defaults.bool(forKey: Key.notifyOnTaskCompletion)
        } else {
            self.notifyOnTaskCompletion = Self.defaultNotifyOnTaskCompletion
        }

        // recentSearches — absent key defaults to empty; only keep strings.
        self.recentSearches = (defaults.array(forKey: Key.recentSearches) as? [String]) ?? []
    }

    // MARK: - Theme application

    /// Applies `theme` to the app's appearance. `light`/`dark` force the
    /// corresponding `NSAppearance`; `system` clears the override so macOS
    /// decides. Native analog of `applyTheme` in ui.svelte.ts:338-348.
    func applyTheme() {
        let appearance: NSAppearance?
        switch theme {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .system: appearance = nil
        }
        NSApplication.shared.appearance = appearance
    }

    // MARK: - Helpers

    /// Clamp `value` into `range` (mirrors `clampInt`, ui.svelte.ts:50-56).
    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
