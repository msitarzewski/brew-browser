import SwiftUI

/// The sidebar sections, mirroring the shipped app's navigation. Spike wires up
/// Library for real; the rest are placeholders to prove the NavigationSplitView
/// chrome and selection model.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case library   = "Library"
    case discover  = "Discover"
    case trending  = "Trending"
    case snapshots = "Snapshots"
    case services  = "Services"
    case activity  = "Activity"
    case bundles   = "Bundles"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .dashboard: return L10n.string("nav.dashboard")
        case .library:   return L10n.string("nav.library")
        case .discover:  return L10n.string("nav.discover")
        case .trending:  return L10n.string("nav.trending")
        case .snapshots: return L10n.string("nav.snapshots")
        case .services:  return L10n.string("nav.services")
        case .activity:  return L10n.string("nav.activity")
        case .bundles:   return L10n.string("nav.bundles")
        }
    }

    /// SF Symbol for the sidebar row — all system symbols, no custom assets.
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .library:   return "books.vertical"
        case .discover:  return "sparkles.rectangle.stack"
        case .trending:  return "chart.line.uptrend.xyaxis"
        case .snapshots: return "camera"
        case .services:  return "gearshape.2"
        case .activity:  return "list.bullet.rectangle"
        case .bundles:   return "square.stack.3d.up"
        }
    }
}

/// Library type filter — drives the segmented control above the Library table.
/// Mirrors the Tauri Library pill set. `.vulnerable` is only meaningful once an
/// install-wide scan has populated `AppModel.vulnIndex`, and (like Tauri) is
/// only offered when vulnerability scanning is enabled — see
/// `AppModel.availableLibraryFilters`.
enum LibraryFilter: String, CaseIterable, Identifiable, Hashable {
    case all        = "All"
    case formulae   = "Formulae"
    case casks      = "Casks"
    case outdated   = "Outdated"
    case pinned     = "Pinned"
    case manual     = "Manual"
    case dependency = "Dependency"
    case vulnerable = "Vulnerable"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:        return L10n.string("filter.all")
        case .formulae:   return L10n.string("package.kind.formulae")
        case .casks:      return L10n.string("package.kind.casks")
        case .outdated:   return L10n.string("filter.outdated")
        case .pinned:     return L10n.string("package.pinned")
        case .manual:     return L10n.string("filter.manual")
        case .dependency: return L10n.string("filter.dependency")
        case .vulnerable: return L10n.string("filter.vulnerable")
        }
    }
}

/// A flattened Library table row. Built in `AppModel.libraryRows` so the
/// `Table` columns are pure value reads (name/version/kind + the precomputed
/// outdated flag and AI-gated enrichment summary).
struct LibraryRow: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    /// AI friendly name (dimmed subtitle under the token), when AI features on
    /// and it differs from the token. Empty otherwise. Matches Tauri PackageRow.
    let friendlyName: String
    let version: String
    let kind: InstalledPackage.Kind
    let isOutdated: Bool
    let summary: String
    /// Highest-severity known finding for this package, or nil when the package
    /// is clean / not-yet-scanned. Drives the per-row severity dot. Populated
    /// from `AppModel.vulnIndex`; empty until an install-wide scan has run.
    let maxSeverity: VulnSeverity?
    /// Number of known findings (any severity) — backs the dot's hover tooltip.
    let vulnCount: Int
    /// Deprecation/disabled baseline, enriched from the bundled catalog by token.
    /// Flags-only here (the catalog carries no replacement) — the detail panel
    /// adds the replacement from brew info. Clean when the catalog isn't loaded
    /// or the package isn't deprecated/disabled (no badge then). Feature #2.
    let deprecation: DeprecationStatus

    /// Whether the package is pinned (held back from `brew upgrade`). Drives the
    /// row's "Pinned" badge (#90). From `InstalledPackage.pinned`.
    let pinned: Bool

    /// Comparable proxy for sorting the Outdated column (`Bool` isn't
    /// `Comparable`). Outdated rows sort high so descending surfaces them first.
    var outdatedRank: Int { isOutdated ? 1 : 0 }
}

/// A Discover table row — a catalog package (available, maybe not installed)
/// with its install state + AI-gated summary precomputed for pure-value columns.
struct DiscoverRow: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(token)" }
    let token: String
    let name: String
    /// AI friendly name (dimmed subtitle), when AI on + differs from token.
    let friendlyName: String
    let version: String
    let kind: InstalledPackage.Kind
    let homepage: String
    let summary: String
    let isInstalled: Bool
    /// Highest-severity known finding, or nil when clean / not-yet-scanned.
    /// Drives the per-row severity dot, same source as Library (`vulnIndex`).
    let maxSeverity: VulnSeverity?
    /// Number of known findings (any severity) — backs the dot's hover tooltip.
    let vulnCount: Int
    /// Deprecation/disabled baseline from the catalog (flags-only; the catalog
    /// is the row source for Discover, so it has no replacement). Feature #2.
    let deprecation: DeprecationStatus

    var installedRank: Int { isInstalled ? 1 : 0 }
}

/// A Trending table row — a leaderboard entry joined with catalog desc/version,
/// install state, and (when Enhanced Trending is on) velocity + sparkline.
struct TrendingRow: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(token)" }
    let rank: Int
    let token: String
    let name: String
    /// AI friendly name (dimmed subtitle), when AI on + differs from token.
    /// Empty otherwise. Same source as Library/Discover (matches Tauri).
    let friendlyName: String
    let version: String
    let kind: InstalledPackage.Kind
    let homepage: String
    let summary: String
    let installCount: Int
    let isInstalled: Bool
    /// Velocity index (enhanced layer); nil when Enhanced Trending is off or
    /// the package isn't in the history index.
    let velocity: Double?
    /// Inline sparkline points (enhanced layer); empty when off/absent.
    let sparkline: [Double]
    /// Highest-severity known finding, or nil when clean / not-yet-scanned.
    /// Drives the per-row severity dot, same source as Library (`vulnIndex`).
    let maxSeverity: VulnSeverity?
    /// Number of known findings (any severity) — backs the dot's hover tooltip.
    let vulnCount: Int

    /// Comparable proxy so velocity sorts with no-velocity rows pinned low.
    var velocityRank: Double { velocity ?? -Double.greatestFiniteMagnitude }
    /// Comparable proxy for the Installed column (`Bool` isn't `Comparable`).
    var installedRank: Int { isInstalled ? 1 : 0 }
}

@MainActor
@Observable
public final class AppModel {
    var selection: Section = .dashboard
    var installed: [InstalledPackage] = []
    public var isLoading = false
    var loadError: String?

    // Snapshots (Brewfile dump/restore) — see SnapshotStore.
    var snapshots: [Snapshot] = []
    var snapshotsLoading = false

    /// Global toolbar search text (the single `.searchable` field on the detail
    /// column). Drives both the toolbar suggestions and the Library table
    /// filter — there is exactly one search field in the toolbar.
    var globalQuery: String = ""

    /// Library type filter — the segmented control above the table. Dashboard
    /// entry points set `.outdated` (Updates) or `.all` (installed / search).
    var libraryFilter: LibraryFilter = .all

    /// Active category filter for the Library, set by tapping a slice in the
    /// Dashboard "Top categories in your library" card. `nil` = no category
    /// filter. Mirrors the Tauri behavior where that card filters the Library
    /// (installed packages), not the full Discover catalog. See #58.
    var libraryCategory: String? = nil

    /// Human label for the active Library category filter (for the chip).
    var libraryCategoryLabel: String? {
        guard let slug = libraryCategory else { return nil }
        return categoryCatalog?.allCategories().first { $0.slug == slug }?.label ?? slug
    }

    /// Sort order for the Library `Table`, bound to its `sortOrder:`. Defaults
    /// to ascending by name (the stock first-column-ascending convention).
    var librarySort: [KeyPathComparator<LibraryRow>] = [
        KeyPathComparator(\LibraryRow.name, order: .forward)
    ]

    /// Set of outdated package names for O(1) per-row tagging, keyed by BARE
    /// token. `brew outdated` reports tap formulae fully-qualified
    /// (`shivammathur/php/php@8.4`) while `brew info --installed` — the source
    /// of the Library rows — reports the bare token (`php@8.4`). Matching the
    /// raw names dropped tap-installed packages from the Outdated filter and
    /// their outdated dot; normalising both sides through `bareToken` fixes it
    /// (same tap-name class as #92). Compare with `bareToken(pkg.name)`.
    private var outdatedNames: Set<String> { Set(outdated.map { Self.bareToken($0.name) }) }

    /// The Library rows after the type filter + text query, before sorting.
    /// Each row carries its outdated flag and (AI-gated) enrichment summary so
    /// the `Table` columns are pure value reads.
    var libraryRows: [LibraryRow] {
        let outdatedSet = outdatedNames
        let showSummary = settings.aiFeaturesVisible
        // Filter off the single shared toolbar search field (`globalQuery`).
        // Library must NOT add its own `.searchable` — two .searchable in one
        // toolbar both claim the `com.apple.SwiftUI.search` item id and AppKit
        // throws "NSToolbar already contains an item…" → SIGTRAP on layout.
        let q = globalQuery.trimmingCharacters(in: .whitespaces)

        return installed.compactMap { pkg in
            let vuln = vulnIndex[pkg.name]
            switch libraryFilter {
            case .all:        break
            case .formulae:   guard pkg.kind == .formula else { return nil }
            case .casks:      guard pkg.kind == .cask else { return nil }
            case .outdated:   guard outdatedSet.contains(Self.bareToken(pkg.name)) else { return nil }
            case .pinned:     guard pkg.pinned else { return nil }
            // Manual = installed on request; Dependency = a formula NOT on request
            // (casks are always on-request, so never appear under Dependency) (#3).
            case .manual:     guard pkg.installedOnRequest else { return nil }
            case .dependency: guard pkg.kind == .formula && !pkg.installedOnRequest else { return nil }
            case .vulnerable: guard (vuln?.total ?? 0) > 0 else { return nil }
            }
            if !q.isEmpty, !pkg.name.localizedCaseInsensitiveContains(q) { return nil }
            if let slug = libraryCategory,
               !(categoryCatalog?.isMember(token: pkg.name, kind: pkg.kind, slug: slug) ?? false) {
                return nil
            }
            let entry = showSummary ? enrichmentEntry(for: pkg.name) : nil
            let friendly = entry?.friendlyName ?? ""
            return LibraryRow(
                name: pkg.name,
                friendlyName: (friendly != pkg.name) ? friendly : "",
                version: pkg.version,
                kind: pkg.kind,
                isOutdated: outdatedSet.contains(Self.bareToken(pkg.name)),
                summary: showSummary ? (entry?.summary ?? "") : "",
                maxSeverity: (vuln?.total ?? 0) > 0 ? vuln?.maxSeverity : nil,
                vulnCount: vuln?.total ?? 0,
                deprecation: deprecationStatus(pkg.name, pkg.kind),
                pinned: pkg.pinned
            )
        }
    }

    /// `libraryRows` with the table's current `sortOrder` applied.
    var sortedLibraryRows: [LibraryRow] {
        libraryRows.sorted(using: librarySort)
    }

    /// Per-filter row counts for the segmented control labels.
    func libraryFilterCount(_ filter: LibraryFilter) -> Int {
        switch filter {
        case .all:        return installed.count
        case .formulae:   return installed.lazy.filter { $0.kind == .formula }.count
        case .casks:      return installed.lazy.filter { $0.kind == .cask }.count
        case .outdated:   return outdatedNames.count
        case .pinned:     return installed.lazy.filter { $0.pinned }.count
        case .manual:     return installed.lazy.filter { $0.installedOnRequest }.count
        case .dependency: return installed.lazy.filter { $0.kind == .formula && !$0.installedOnRequest }.count
        case .vulnerable: return vulnerableCount
        }
    }

    /// Filters offered by the Library segmented control. `.vulnerable` is hidden
    /// unless vulnerability scanning is enabled (mirrors the Tauri Library pill
    /// set, which only appends "vulnerable" when `vulnerabilities.enabled`).
    var availableLibraryFilters: [LibraryFilter] {
        LibraryFilter.allCases.filter { filter in
            filter != .vulnerable || settings.vulnerabilityScanningAllowed
        }
    }

    // ---- Discover (catalog browse) ----
    /// Full catalog, loaded lazily from the bundled gzip on first Discover open.
    var catalog: [CatalogPackage] = []
    var catalogLoading = false
    /// Selected category slug for the Discover filter; nil = All.
    var discoverCategory: String? = nil {
        didSet {
            // A new category invalidates any drilled-into sub-group selection.
            if discoverCategory != oldValue { discoverSubgroupKey = nil }
        }
    }
    /// Active co-occurrence sub-group within the selected category (feature #6).
    /// nil = show every member of the category (flat). Set by tapping a sub-group
    /// chip; cleared whenever the category changes. Only meaningful when
    /// ``discoverSubgroups`` is non-empty.
    var discoverSubgroupKey: String? = nil
    /// Sort order for the Discover `Table`.
    var discoverSort: [KeyPathComparator<DiscoverRow>] = [
        KeyPathComparator(\DiscoverRow.name, order: .forward)
    ]
    /// (slug, label) list for the Discover category Picker (from the bundled
    /// category catalog; empty until the catalog is open).
    var categoryList: [(slug: String, label: String)] {
        catalog.isEmpty ? [] : (categoryCatalog?.allCategories() ?? [])
    }

    /// Category tiles for the Discover browse grid (glyph + label + catalog
    /// count, descending). Empty until the bundled category catalog is parsed.
    var categoryTiles: [CategoryTile] {
        categoryCatalog?.tiles() ?? []
    }

    /// Co-occurrence sub-groups for the active Discover category (feature #6).
    /// Surfaces ONLY when exactly one category is selected AND no search text is
    /// narrowing the list — multi-narrowed / searched views stay flat (the same
    /// rule as the Tauri shell). Empty otherwise. NOT a true taxonomy: each
    /// bucket is a co-assigned category slug (or "General" for solo members);
    /// see ``CategoryCatalog/subgroups(in:)``.
    var discoverSubgroups: [CategorySubgroup] {
        guard let slug = discoverCategory,
              catalog.isEmpty == false,
              globalQuery.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        return categoryCatalog?.subgroups(in: slug) ?? []
    }

    /// Active-catalog freshness summary (bundled vs user-refreshed copy). Loaded
    /// lazily by ``loadCatalogSummary``; drives the Dashboard freshness strip +
    /// Discover stale banner.
    var catalogSummary: CatalogSummary?
    /// True while a "Refresh from brew.sh" is in flight (mirrors the Tauri
    /// `catalog.refreshing`). Disables the Refresh buttons.
    var catalogRefreshing = false
    /// Human message from the most recent failed refresh, else nil.
    var catalogRefreshError: String?

    /// Whether the active catalog is older than the user's stale threshold
    /// (`settings.catalogStaleBannerDays`, default 14). False until the summary
    /// loads so the banner/strip don't flash on first paint. Mirrors the Tauri
    /// `catalog.isStale` getter.
    var catalogIsStale: Bool {
        guard let s = catalogSummary else { return false }
        return s.daysOld > Int(settings.catalogStaleBannerDays)
    }

    /// "today" / "1 day old" / "N days old" / "—" — matches the Tauri
    /// `daysOldLabel` getter. "—" until the summary loads so the spot doesn't
    /// flash empty.
    var catalogDaysOldLabel: String {
        guard let s = catalogSummary else { return "—" }
        return L10n.catalogAge(days: s.daysOld)
    }

    /// Discover rows: catalog filtered by category + the shared search field,
    /// enrichment-joined, install-state flagged. (Single `.searchable` rule:
    /// reuses `globalQuery`, never adds its own field — see libraryRows.)
    var discoverRows: [DiscoverRow] {
        guard !catalog.isEmpty else { return [] }
        let showSummary = settings.aiFeaturesVisible
        let showVulns = settings.vulnerabilityScanningAllowed
        let q = globalQuery.trimmingCharacters(in: .whitespaces)
        let cat = discoverCategory
        // Drill into a co-occurrence sub-group only when one is active AND the
        // list isn't otherwise narrowed by search (sub-groups are defined only
        // for a single selected category — see discoverSubgroups). Feature #6.
        let subKey = (cat != nil && q.isEmpty) ? discoverSubgroupKey : nil

        return catalog.compactMap { pkg in
            if let cat, !(categoryCatalog?.isMember(token: pkg.token, kind: pkg.kind, slug: cat) ?? false) {
                return nil
            }
            if let cat, let subKey,
               !(categoryCatalog?.memberInSubgroup(token: pkg.token, kind: pkg.kind,
                                                    slug: cat, subgroupKey: subKey) ?? false) {
                return nil
            }
            let searchEntry = enrichmentEntry(for: pkg.token)
            if !q.isEmpty,
               !catalogPackageMatches(pkg, query: q, entry: searchEntry) {
                return nil
            }
            let entry = showSummary ? enrichmentEntry(for: pkg.token) : nil
            let friendly = entry?.friendlyName ?? ""
            let vuln = showVulns ? vulnIndex[pkg.token] : nil
            return DiscoverRow(
                token: pkg.token,
                name: pkg.displayName,
                friendlyName: (friendly != pkg.token) ? friendly : "",
                version: pkg.version,
                kind: pkg.kind,
                homepage: pkg.homepage,
                summary: showSummary ? (entry?.summary ?? pkg.desc) : pkg.desc,
                isInstalled: isPackageInstalled(token: pkg.token, kind: pkg.kind),
                maxSeverity: (vuln?.total ?? 0) > 0 ? vuln?.maxSeverity : nil,
                vulnCount: vuln?.total ?? 0,
                deprecation: pkg.deprecation
            )
        }
    }

    var sortedDiscoverRows: [DiscoverRow] { discoverRows.sorted(using: discoverSort) }

    /// Load + decompress the bundled catalog on first Discover open.
    /// Parse the bundled categories.json + enrichment.json OFF the main thread,
    /// then backfill the bits that read them (category breakdown, open detail).
    /// Replaces the old synchronous stored-property inits that blocked first
    /// paint by several seconds in debug. Deduped + idempotent.
    func loadBundledData() async {
        if bundledDataLoaded { return }
        bundledDataLoaded = true
        let (cat, enr, bnd) = await Task.detached(priority: .userInitiated) {
            (CategoryCatalog.loadBundled(), EnrichmentCatalog.loadBundled(locale: L10n.activeLanguage), BundleCatalog().load(locale: L10n.activeLanguage))
        }.value
        categoryCatalog = cat
        enrichment = enr
        bundles = bnd
        if !installed.isEmpty { categories = cat?.breakdown(installed: installed) ?? [] }
        if let pkg = detailPackage, settings.aiFeaturesVisible {
            detailEnrichment = enrichmentEntry(for: pkg.name)
        }
        // M5: if the user opted in, refresh the Bundles catalog from the project
        // host in the background — never blocks first paint, silently keeps the
        // bundled copy on any failure.
        if settings.liveBundlesAllowed {
            Task { await refreshLiveBundles() }
        }
    }

    /// Opt-in live Bundles refresh (M5). Fetches `bundles/bundles.json` from the
    /// project host and REPLACES `bundles` on success. Any failure (offline,
    /// 404, network, malformed, or a newer-than-supported schema) leaves the
    /// bundled catalog untouched. A valid-but-empty payload is ignored too, so a
    /// blank file can't wipe the six shipped recipes. Gated on
    /// `settings.liveBundlesAllowed` (opt-in + network).
    func refreshLiveBundles() async {
        guard settings.liveBundlesAllowed else { return }
        if let live = await bundleLive.fetchBundles(locale: L10n.activeLanguage), !live.isEmpty {
            bundles = live
        }
    }

    func loadCatalog() async {
        guard catalog.isEmpty, !catalogLoading else { return }
        catalogLoading = true
        catalog = await catalogService.all()
        // Build the token→package index here (at load time), NOT lazily inside
        // the `trendingRows` computed property — mutating @Observable state
        // during view-body evaluation is unreliable and was leaving Trending
        // descriptions/versions blank.
        var byID: [String: CatalogPackage] = [:]
        byID.reserveCapacity(catalog.count)
        var depByID: [String: DeprecationStatus] = [:]
        for p in catalog {
            byID[p.id] = p
            if !p.deprecation.isClean { depByID[p.id] = p.deprecation }
        }
        catalogByID = byID
        deprecationByID = depByID
        catalogLoading = false
    }

    /// Lazy-load the active-catalog freshness summary (bundled or user-refreshed)
    /// for the Dashboard strip + Discover banner. Idempotent.
    func loadCatalogSummary() async {
        guard catalogSummary == nil else { return }
        catalogSummary = await catalogService.summary()
    }

    /// "Refresh from brew.sh" — re-download the Homebrew catalog, persist the
    /// user copy, and swap it in. Gated on Offline Mode (the master network
    /// gate) like every other outbound call. On success the in-memory catalog +
    /// summary go fresh and the dashboard categories rebuild; on failure the
    /// message lands in `catalogRefreshError`. Mirrors the Tauri
    /// `catalog.refresh()` store action + `refreshCatalog` Dashboard handler.
    func refreshCatalogFromBrewSh() async {
        guard !catalogRefreshing else { return }
        guard settings.networkAllowed("catalog_refresh") else {
            catalogRefreshError = L10n.string("catalog.refresh.offlineBlocked")
            return
        }
        catalogRefreshing = true
        catalogRefreshError = nil
        defer { catalogRefreshing = false }
        // Mirror the Tauri catalog sync: run `brew update` as a streaming Activity
        // job first, so the refresh shows live in the Activity drawer (and the
        // brew metadata is fresh) before we pull the catalog JSON from brew.sh.
        await startJob("Updating Homebrew", args: ["update"], startedAt: Date().timeIntervalSince1970)
        do {
            let summary = try await catalogService.refresh()
            // Swap the freshly-parsed catalog in + rebuild the token index.
            catalog = await catalogService.all()
            var byID: [String: CatalogPackage] = [:]
            byID.reserveCapacity(catalog.count)
            var depByID: [String: DeprecationStatus] = [:]
            for p in catalog {
                byID[p.id] = p
                if !p.deprecation.isClean { depByID[p.id] = p.deprecation }
            }
            catalogByID = byID
            deprecationByID = depByID
            catalogSummary = summary
            // Rebuild the dashboard category breakdown against the fresh catalog.
            if !installed.isEmpty {
                categories = categoryCatalog?.breakdown(installed: installed) ?? []
            }
            // Opt-in live categories may also have advanced — best-effort pull.
            await refreshLiveCategoriesIfNewer()
        } catch {
            catalogRefreshError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Record a committed Discover search term into the persisted recent list
    /// (deduped, capped). Called when the user submits a search while on the
    /// Discover section. Delegates to `LocalPrefs.recordSearch`.
    func recordDiscoverSearch(_ term: String) {
        LocalPrefs.shared.recordSearch(term)
    }

    /// token+kind → catalog package, for joining desc/version/homepage onto
    /// token+kind → catalog package, for joining desc/version/homepage onto
    /// Trending rows. Populated by `loadCatalog` (not lazily during render).
    private var catalogByID: [String: CatalogPackage] = [:]
    /// "kind:token" → catalog deprecation status, for badging Library rows
    /// (which are `brew list` `InstalledPackage`s with no catalog flags of their
    /// own) and Discover rows from the offline baseline. Built alongside
    /// `catalogByID` in `loadCatalog`/`refreshCatalogFromBrewSh`. The native
    /// analogue of the Tauri catalog store's `deprecatedBy*`/`disabledBy*` maps.
    private var deprecationByID: [String: DeprecationStatus] = [:]

    /// Catalog deprecation/disabled status for a token+kind (offline baseline).
    /// Bare-token fallback for tap-qualified names, mirroring `catalogLookup`.
    /// Returns a clean status (no badge) when the catalog isn't loaded or the
    /// package isn't flagged. The native analogue of the Tauri `statusOf`.
    func deprecationStatus(_ token: String, _ kind: InstalledPackage.Kind) -> DeprecationStatus {
        if let hit = deprecationByID["\(kind.rawValue):\(token)"] { return hit }
        let bare = Self.bareToken(token)
        if bare != token, let hit = deprecationByID["\(kind.rawValue):\(bare)"] { return hit }
        return DeprecationStatus()
    }
    /// Homebrew analytics report tap formulae fully-qualified (`user/tap/name`),
    /// but the bundled catalog + enrichment are keyed by the bare name. Returns
    /// the last `/`-segment; bare tokens pass through unchanged.
    static func bareToken(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }

    func installedPackageMatching(token: String, kind: InstalledPackage.Kind) -> InstalledPackage? {
        if let exact = installed.first(where: { $0.kind == kind && $0.name == token }) {
            return exact
        }
        let bare = Self.bareToken(token)
        guard bare != token else { return nil }
        return installed.first { $0.kind == kind && $0.name == bare }
    }

    func isPackageInstalled(token: String, kind: InstalledPackage.Kind) -> Bool {
        installedPackageMatching(token: token, kind: kind) != nil
    }

    private func catalogLookup(_ token: String, _ kind: InstalledPackage.Kind) -> CatalogPackage? {
        if let hit = catalogByID["\(kind.rawValue):\(token)"] { return hit }
        let bare = Self.bareToken(token)
        return bare != token ? catalogByID["\(kind.rawValue):\(bare)"] : nil
    }

    // ---- Trending (install leaderboard + computed velocity + opt-in sparkline) ----
    var trendingWindow: TrendingWindow = .d30
    var trendingEntries: [TrendingEntry] = []
    var trendingLoading = false
    /// Sparkline overlay (opt-in Enhanced Trending only): token+kind → points
    /// from the zerologic history index. Velocity itself is NOT from here — it's
    /// computed from the 3 analytics windows (matching Tauri); this index only
    /// supplies the inline sparkline shape.
    private var sparklineIndex: [String: [Double]] = [:]
    /// Default sort = Velocity desc — "trending" should lead with what's
    /// surging, not just most-installed (matches the Tauri v0.4.0 default).
    /// Velocity is computed from the analytics windows, so it's always present.
    var trendingSort: [KeyPathComparator<TrendingRow>] = [
        KeyPathComparator(\TrendingRow.velocityRank, order: .reverse)
    ]

    var trendingRows: [TrendingRow] {
        guard !trendingEntries.isEmpty else { return [] }
        let showSummary = settings.aiFeaturesVisible
        let showVulns = settings.vulnerabilityScanningAllowed
        return trendingEntries.map { e in
            let cat = catalogLookup(e.token, e.kind)
            let id = "\(e.kind.rawValue):\(e.token)"
            let entry = showSummary ? enrichmentEntry(for: e.token) : nil
            let friendly = entry?.friendlyName ?? ""
            let vuln = showVulns ? vulnIndex[e.token] : nil
            return TrendingRow(
                rank: e.rank,
                token: e.token,
                name: cat?.displayName ?? e.token,
                friendlyName: (friendly != e.token) ? friendly : "",
                version: cat?.version ?? "—",
                kind: e.kind,
                homepage: cat?.homepage ?? "",
                summary: showSummary ? (entry?.summary ?? cat?.desc ?? "")
                                     : (cat?.desc ?? ""),
                installCount: e.installCount,
                isInstalled: isPackageInstalled(token: e.token, kind: e.kind),
                velocity: e.velocity,                 // computed from analytics windows
                sparkline: sparklineIndex[id] ?? [],  // opt-in enhanced overlay
                maxSeverity: (vuln?.total ?? 0) > 0 ? vuln?.maxSeverity : nil,
                vulnCount: vuln?.total ?? 0
            )
        }
    }

    var sortedTrendingRows: [TrendingRow] { trendingRows.sorted(using: trendingSort) }

    /// Inline sparklines need the opt-in Enhanced Trending endpoint. Velocity
    /// (the column) is always computed from analytics, so it shows regardless.
    var enhancedTrendingOn: Bool { settings.enhancedTrendingAllowed }

    /// Epoch seconds of the last successful trending fetch (for the "Updated Ns
    /// ago" label). nil until the first load.
    var trendingFetchedAt: Double?

    /// Load the install leaderboard (with computed velocity) for the window.
    /// Pulls the opt-in sparkline overlay too when Enhanced Trending is on.
    /// `force` bypasses the 60-min cache (Refresh button / ⌘R).
    func loadTrending(force: Bool = false) async {
        if catalog.isEmpty { await loadCatalog() }
        trendingLoading = trendingEntries.isEmpty || force
        let now = Date().timeIntervalSince1970
        trendingEntries = await trendingService.leaderboard(window: trendingWindow, now: now, force: force)
        trendingFetchedAt = now
        trendingLoading = false
        // Opt-in sparkline overlay only (velocity already computed above).
        if enhancedTrendingOn, sparklineIndex.isEmpty || force {
            let idx = await trendingHistory.index()
            var map: [String: [Double]] = [:]
            for e in idx {
                let kind = e.kind == "cask" ? "cask" : "formula"
                map["\(kind):\(e.name)"] = e.sparkline
            }
            sparklineIndex = map
        }
    }

    /// Force-refresh trending (Refresh button / ⌘R) — bypasses the cache.
    func refreshTrending() async { await loadTrending(force: true) }

    /// Switch the trending window and reload.
    func setTrendingWindow(_ w: TrendingWindow) async {
        guard w != trendingWindow else { return }
        trendingWindow = w
        await loadTrending()
    }

    /// Whether cask icon fetching is allowed right now — Offline Mode off AND the
    /// cask-icon setting isn't `off`. Mirrors the Tauri `cask_icon` gate.
    private var caskIconsEnabled: Bool {
        guard !settings.paranoidMode else { return false }
        return settings.caskIconMode != .off
    }

    /// Resolve a row's icon into `iconCache` (async, fire-and-forget from the
    /// view's `.task`). Casks only; formulae always render the SF Symbol.
    func resolveIcon(token: String, kind: InstalledPackage.Kind, homepage: String) async {
        guard kind == .cask, iconCache[token] == nil else { return }
        if let url = await iconService.iconFileURL(token: token, homepage: homepage, enabled: caskIconsEnabled) {
            iconCache[token] = url
        }
    }

    /// Type-ahead suggestions for the toolbar search — top installed matches.
    var suggestions: [InstalledPackage] {
        let q = globalQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(
            installed
                .filter { $0.name.localizedCaseInsensitiveContains(q) }
                .prefix(8)
        )
    }

    /// Commit a search selection: jump to Library, pre-filtered to that name
    /// via the shared toolbar search field.
    func openInLibrary(_ pkg: InstalledPackage) {
        globalQuery = pkg.name
        libraryFilter = .all
        libraryCategory = nil
        selection = .library
    }

    /// Open the full Library (cleared filters). Used by the "installed" stat.
    func openLibrary() {
        globalQuery = ""
        libraryFilter = .all
        libraryCategory = nil
        selection = .library
    }

    /// Open Library filtered to outdated packages. Used by the Updates stat/card.
    func openOutdatedInLibrary() {
        globalQuery = ""
        libraryFilter = .outdated
        libraryCategory = nil
        selection = .library
    }

    /// Jump to the Library filtered to a category — the click target for the
    /// Dashboard "Top categories in your library" card. Shows the user's
    /// INSTALLED packages in that category, not the full Discover catalog (#58).
    func jumpToLibraryCategory(_ slug: String) {
        globalQuery = ""
        libraryFilter = .all
        // Empty / "other" buckets have no real slug to filter on — just open
        // the full library.
        libraryCategory = (slug.isEmpty || slug == "__other__" || slug == "other") ? nil : slug
        selection = .library
    }

    /// Clear the active Library category filter (the chip's ✕).
    func clearLibraryCategory() {
        libraryCategory = nil
    }

    /// Open the Activity history — the "more in Activity →" deep-link from the
    /// Dashboard "Recent changes" card. The full change history lives there; the
    /// card only previews the most recent few.
    func openActivity() {
        selection = .activity
    }

    /// The most-recent package changes (installed / upgraded / uninstalled),
    /// derived purely from the existing persisted job history — no new data, no
    /// new subprocess. Drives the Dashboard "Recent changes" card; capped to a
    /// short preview (the full list lives in Activity). Mirrors the Tauri
    /// `recentChanges(jobs)` contract (`RecentChanges.swift`).
    var recentChangesPreview: [RecentChange] {
        Array(RecentChanges.recentChanges(jobs).prefix(6))
    }

    /// Open Library filtered to packages with known vulnerabilities. Used by the
    /// Dashboard Exposure card's "View vulnerable packages" link and the sidebar
    /// vuln badge. Mirrors the Tauri `viewVulnerablePackages` (setSection then
    /// setFilter("vulnerable")).
    func openVulnerableInLibrary() {
        globalQuery = ""
        libraryFilter = .vulnerable
        selection = .library
    }

    // MARK: - Keyboard commands (⌘ menu shortcuts)

    /// Navigate to a section by its ⌘0–6 number. Mirrors the Tauri `+page.svelte`
    /// map (0 = dashboard … 6 = activity); see `Sidebar.svelte:35-43`.
    public func go(toSectionNumber n: Int) {
        let map: [Int: Section] = [
            0: .dashboard, 1: .library, 2: .discover,
            3: .trending, 4: .snapshots, 5: .services, 6: .activity,
            7: .bundles,
        ]
        if let s = map[n] { selection = s }
    }

    /// ⌘L — toggle the bottom Activity drawer. When opening with no active job,
    /// point it at the newest job so the console isn't blank.
    public func toggleDrawer() {
        drawerOpen.toggle()
        if drawerOpen, activeJobId == nil { activeJobId = jobs.first?.id }
    }

    /// ⌘R — refresh whichever surface is showing (matches the Tauri ⌘R switch in
    /// `+page.svelte:97-108`). Trending/Snapshots/Services reload their own data;
    /// every other section falls back to the global Library/Dashboard refresh.
    public func refreshCurrent() async {
        switch selection {
        case .trending:  await refreshTrending()
        case .snapshots: await loadSnapshots()
        case .services:  await loadServices()
        default:         await refresh()
        }
    }

    /// ⌘⇧L — cycle the appearance theme Light → Dark → System and apply it.
    /// Mirrors the Tauri theme cycle (`+page.svelte:63-71`).
    public func cycleTheme() {
        let prefs = LocalPrefs.shared
        let order: [AppTheme] = [.light, .dark, .system]
        let next = order[(order.firstIndex(of: prefs.theme).map { $0 + 1 } ?? 0) % order.count]
        prefs.theme = next
        prefs.applyTheme()
    }

    /// Esc — close the open detail inspector, if any. The palette closes itself
    /// (it owns the sheet's own Esc). Returns true if it consumed the Esc.
    @discardableResult
    func closeTopmostOverlay() -> Bool {
        if showDetail { closeDetail(); return true }
        return false
    }

    // MARK: - Command palette search (⌘K)

    /// Top installed matches for the palette (mirrors `CommandPalette.svelte`
    /// `installedHits` — name substring, cap 8). Distinct from `suggestions`,
    /// which is driven by the toolbar `globalQuery`; the palette has its own query.
    func paletteInstalled(_ query: String) -> [InstalledPackage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return Array(
            installed
                .filter { $0.name.lowercased().contains(q) }
                .prefix(8)
        )
    }

    /// Catalog ("index") matches for the palette, de-duped against the installed
    /// hits (mirrors `CommandPalette.svelte` `indexHits`, cap 10). The Tauri
    /// palette calls `local_search` — an in-process scan over the bundled catalog
    /// + enrichment, NOT `brew search` (which was dropped in v0.3.1). The native
    /// catalog is already in memory (`catalog`), so this reuses it directly: no
    /// subprocess, instant results. Matches token + display name.
    func paletteCatalog(_ query: String) -> [CatalogPackage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, !catalog.isEmpty else { return [] }
        let installedNames = Set(paletteInstalled(query).map { $0.name.lowercased() })
        return Array(
            catalog
                .lazy
                .filter { self.catalogPackageMatches($0, query: q, entry: self.enrichmentEntry(for: $0.token)) }
                .filter { !installedNames.contains($0.token.lowercased()) }
                .prefix(10)
        )
    }

    // ---- Dashboard stats (all from real brew data) ----
    var formulaCount = 0
    var caskCount = 0
    var leavesCount = 0
    var onRequestCount = 0
    var pinnedCount = 0
    var outdatedCount = 0
    var outdated: [OutdatedPackage] = []
    var storage: [StorageItem] = []
    var brewVersion = "—"
    var brewPrefix = "/opt/homebrew"
    var categories: [CategoryBreakdown] = []
    /// Curated Bundles catalog (M2), parsed from the bundled `bundles.json` by
    /// `loadBundledData()`. Per-bundle readiness (M3) is computed at render time
    /// via `readiness(for:)` against `systemProfile`.
    var bundles: [BrewBundle] = []

    /// Host capability snapshot (M1), read once at construction. Feeds
    /// `readiness(for:)` so the Bundles UI can gate recipes against this machine.
    /// `SystemProfile.detect()` honors `BREWBROWSER_FAKE_RAM_GB`, so a debug run
    /// can force Marginal/Blocked states on a high-RAM dev Mac.
    var systemProfile = SystemProfile.detect()

    /// Capability verdict for a bundle on this host (M3). Pure — just routes the
    /// bundle's `requires`/`capabilityNotes` and the cached profile through the
    /// M1 readiness function.
    func readiness(for b: BrewBundle) -> Readiness {
        BundleReadiness.readiness(b.requires, b.capabilityNotes, systemProfile)
    }
    var runningServices = 0
    var dashboardLoaded = false
    /// `brew outdated --json=v2` is slow (~4s) and `du -sk` can lag, so they no
    /// longer gate first paint — they stream into their cards. These flags drive
    /// the per-card placeholders while they're in flight.
    var outdatedLoading = false
    var storageLoading = false

    // Issue #80 — cache maintenance (brew doctor / cleanup) on the Storage card.
    /// Best-effort estimate of what `brew cleanup --prune=all` would free; nil
    /// hides the hint. Loaded alongside the storage breakdown.
    var cleanupReclaimableBytes: Int64?
    var doctorRunning = false
    var cleanupRunning = false
    var maintenanceBusy: Bool { doctorRunning || cleanupRunning }

    // ---- Services panel ----
    var services: [Service] = []
    var servicesLoading = false
    var servicesError: String?
    var servicesLoaded = false
    /// Service names with an in-flight start/stop/restart — drives the per-row
    /// spinner and disables that row's buttons.
    var servicePending: Set<String> = []

    /// Services sorted for display: running first (status rank), then name.
    var sortedServices: [Service] {
        services.sorted {
            $0.status.sortRank != $1.status.sortRank
                ? $0.status.sortRank < $1.status.sortRank
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The service record for an installed formula, if any (PackageDetail card).
    func service(for name: String) -> Service? {
        services.first { $0.name == name }
    }

    // ---- Package detail (inspector) ----
    /// The package whose detail is loaded. This is the DATA, decoupled from
    /// presentation: it's only set by `openDetail` and only cleared by
    /// `closeDetail` (the ⊗ close box). A drag-collapse of the inspector must
    /// NOT clear it, or re-expanding within the same gesture shows an empty pane.
    var detailPackage: InstalledPackage?
    /// The bundle whose detail is loaded in the shared inspector. Mutually
    /// exclusive with `detailPackage`: Bundles reuses the same `.inspector` slot,
    /// so exactly one of the two is non-nil while `showDetail` is true. Set only
    /// by `openBundleDetail`, cleared by `closeDetail` (the ⊗ close box).
    var detailBundle: BrewBundle?
    /// The section the inspector was opened from. When the user navigates to a
    /// different section, the detail closes (it belongs to where it was opened).
    var detailSection: Section?
    /// Inspector PRESENTATION flag — what the `.inspector(isPresented:)` binding
    /// reads/writes. A divider drag past `min` flips this to false (collapse)
    /// while `detailPackage` survives, so the panel can re-expand with content.
    var showDetail = false
    var detailInfo: PackageInfo?
    var detailEnrichment: EnrichmentEntry?
    var detailCategories: [String] = []        // category labels for this package
    var detailDependents: [ReverseDependent] = []  // catalog packages that depend on this one
    var detailLoading = false
    var detailError: String?
    /// True while any package action (install/upgrade/uninstall) is running —
    /// the footer disables its buttons. Live output goes to the Activity drawer.
    var actionRunning: Bool { jobs.contains { $0.status == .running } }

    // ---- Activity (streaming jobs + bottom drawer) ----
    /// All jobs, newest first; running + completed. Persisted (cap 50).
    var jobs: [ActivityJob] = []
    /// The job shown in the drawer console.
    var activeJobId: UUID?
    /// Whether the bottom Activity drawer is expanded.
    public var drawerOpen = false

    // ---- Command palette (⌘K) ----
    /// Whether the ⌘K command palette sheet is presented. Mirrors the Tauri
    /// `ui.paletteOpen` flag (CommandPalette.svelte) — toggled by the ⌘K menu
    /// command and the palette's own close/activate paths.
    public var paletteOpen = false

    /// Custom About box (`AboutView`) — toggled by the app menu's "About
    /// brew-browser". Mirrors the Tauri `ui.aboutOpen` modal.
    public var aboutOpen = false

    // ---- In-window toasts (transient overlay; see Toast.swift) ----
    /// The live toast queue, newest last. Rendered top-trailing by `ToastOverlay`
    /// so it never overlaps the bottom Activity drawer. Mirrors the Tauri toast
    /// store (`toast.svelte.ts`): success/info auto-dismiss after 4s, warning 7s,
    /// errors persist until dismissed. The native build uses these for in-window
    /// feedback (e.g. the GitHub scope/sign-in CTA); background job completion
    /// still goes through `NotificationService` (system notifications).
    var toasts: [ToastItem] = []

    /// Push a toast onto the queue. Success/info/warning auto-dismiss on a timer;
    /// errors stay until the user dismisses them (matching the Tauri timing).
    func pushToast(_ kind: ToastKind, _ title: String, _ body: String? = nil, action: ToastAction? = nil) {
        let item = ToastItem(kind: kind, title: title, body: body, action: action)
        toasts.append(item)
        guard let ms = kind.autoDismissMs else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(ms))
            dismissToast(item.id)
        }
    }

    /// Remove a toast by id (manual dismiss, or the auto-dismiss timer firing).
    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// Run a toast action's handler, then dismiss the toast — clicking the action
    /// implies acknowledgement (mirrors the Tauri `invokeAction`).
    func invokeToastAction(_ id: UUID) {
        guard let action = toasts.first(where: { $0.id == id })?.action else { return }
        dismissToast(id)
        action.handler()
    }

    // ---- Vulnerabilities (Security card) ----
    var detailVulns: [VulnFinding] = []
    var detailVulnsScanned = false
    var detailVulnsLoading = false
    var brewVulnsInstalled = false

    // ---- Vulnerabilities (install-wide / Exposure) ----
    /// name → per-package severity rollup, built by `scanAllVulns`. Drives the
    /// Library Vulnerable filter + per-row dot, the sidebar badge, and the
    /// Dashboard Exposure card. The native analogue of the Tauri
    /// `vulnerabilities.records` Map (keyed by name here — the only installed
    /// package with a given name is unambiguous in our flat list). Entries with
    /// `total == 0` are scanned-but-clean; absence means not-yet-scanned.
    var vulnIndex: [String: VulnSummary] = [:]
    /// name → full findings from the last install-wide scan. The Security card
    /// in the detail inspector reads THIS cache (instant) instead of re-running a
    /// scan per package — `brew vulns` can only scan the whole install, so a
    /// per-package re-check is really a full re-scan. Persisted with the index.
    var vulnFindings: [String: [VulnFinding]] = [:]
    /// True while a full install-wide scan is in flight (Exposure "Scan now").
    var vulnScanAllLoading = false
    /// Timestamp of the most recent successful install-wide scan, or nil before
    /// the first one (drives the Exposure card's never-scanned vs scanned state).
    var vulnLastScannedAt: Date?
    /// True only after a scan completed IN THIS SESSION (NOT set by loadVulns from
    /// the persisted cache). A green "no vulnerabilities / all clean" claim is only
    /// honest when freshly scanned — on launch we show the persisted result but
    /// frame it as stale ("re-scan to confirm"), never a confident all-clear.
    var vulnScannedThisSession = false

    /// Whether the displayed scan is a fresh run this session (`.live`) or the
    /// persisted result restored from a previous launch (`.cache`). nil before
    /// any scan has ever run. Mirrors the Tauri `vulnerabilities.source`
    /// (`vulnerabilities.svelte.ts:152-155`); drives the Exposure card's
    /// "· source:" label so a stale cached scan is visibly distinct from a
    /// fresh one (the gap that made native vs Tauri counts look discrepant).
    enum VulnSource: String, Sendable { case live, cache }
    var vulnSource: VulnSource?

    /// Aggregate severity rollup across every package in `vulnIndex`. Mirrors
    /// the Tauri `vulnerabilities.severityCounts` derived value: per-severity
    /// finding counts + the count of packages with ≥1 finding.
    var vulnExposure: VulnExposure {
        var exp = VulnExposure()
        for summary in vulnIndex.values {
            exp.critical += summary.critical
            exp.high += summary.high
            exp.medium += summary.medium
            exp.low += summary.low
            exp.unknown += summary.unknown
            if summary.total > 0 { exp.vulnerablePackages += 1 }
        }
        return exp
    }

    /// Count of installed packages with at least one known finding. Backs the
    /// Library Vulnerable pill count + the sidebar footer badge.
    var vulnerableCount: Int { vulnExposure.vulnerablePackages }

    /// Per-package severity rollup for `name`, but only when there's an actual
    /// finding AND scanning is enabled — otherwise nil so the per-row dot no-ops
    /// cleanly (off / unscanned packages render no dot). Used by views that look
    /// up by name (Services rows, Dashboard updates preview).
    func vulnSummary(for name: String) -> VulnSummary? {
        guard settings.vulnerabilityScanningAllowed else { return nil }
        guard let summary = vulnIndex[name], summary.total > 0 else { return nil }
        return summary
    }

    // ---- Install trend ----
    var detailTrend: TrendingHistorySeries?

    // ---- GitHub ----
    var detailRepoStats: RepoStats?
    var detailStarred: Bool?
    var detailWatching: Bool?
    var githubStatus: GithubStatus?

    // Parsed lazily off the main thread by `loadBundledData()` — NOT at init.
    // categories.json (~800K) + enrichment.json (~2.7M, 15.7k entries) used to
    // be synchronous stored-property inits that blocked first paint by seconds
    // in debug. `var` so a live-fetched categories file can replace the bundle.
    private var categoryCatalog: CategoryCatalog?
    private var enrichment: EnrichmentCatalog?
    /// True once the bundled catalogs finish parsing in the background.
    private var bundledDataLoaded = false
    private let catalogService = CatalogService()
    private let iconService = IconService()

    // Opt-in live enrichment overlay (mirrors the Tauri store overlay).
    private let enrichmentLive = EnrichmentLiveService()
    // Opt-in live Bundles-catalog refresh (M5), gated on settings.liveBundlesAllowed.
    private let bundleLive = BundleLiveService()
    private var liveEnrichment: [String: EnrichmentEntry] = [:]
    private var liveEnrichmentAttempted: Set<String> = []
    private var liveCategoriesVersion: String = ""
    /// token → resolved on-disk icon file (cached in-model so SwiftUI rows don't
    /// re-fetch on every redraw). nil value = resolved-but-no-icon.
    var iconCache: [String: URL] = [:]
    let settings = AppSettings.shared
    private let vulns = VulnsService()
    private let trendingHistory = TrendingHistoryService()
    private let trendingService = TrendingService()
    private let githubService = GitHubService()

    public init() {
        // Launch gate: a missing brew binary routes the whole window into the
        // onboarding pane (ContentView) instead of the normal initial loads.
        // Synchronous + cheap (two FileManager stats), so the very first body
        // evaluation already knows which root to build — no flash of the
        // normal UI before the gate kicks in.
        brewMissing = BrewService.resolveBrewPath() == nil
    }

    // MARK: - Missing-Homebrew onboarding

    /// True while no brew binary resolves — ContentView swaps the whole window
    /// for `OnboardingView` and `pollForBrew()` re-checks until one appears.
    /// Set synchronously at init (the launch gate) and cleared by the poll.
    var brewMissing = false

    /// Whether the Xcode Command Line Tools are installed (`xcode-select -p`
    /// exits 0). Drives the onboarding step list: the CLT step is shown first
    /// when they're missing, since the Homebrew installer needs them. Probed
    /// by `pollForBrew()` each pass; meaningful only while onboarding shows.
    var cltInstalled = false

    /// One onboarding poll step, split from the loop so tests can drive the
    /// transitions without a real install: records the CLT probe, exits the
    /// onboarding state when brew resolved. Returns true when onboarding is
    /// over (brew found) so the caller can stop polling.
    @discardableResult
    func updateOnboarding(brewFound: Bool, cltFound: Bool) -> Bool {
        cltInstalled = cltFound
        if brewFound { brewMissing = false }
        return !brewMissing
    }

    /// Re-check every 2s while the onboarding pane is up: does a brew binary
    /// resolve yet, and are the CLT installed? When brew appears the flag
    /// flips and the normal root view (whose `.task`s fire the standard
    /// initial load sequence) replaces the onboarding pane. Runs from
    /// OnboardingView's `.task`, so SwiftUI cancels it with the view.
    func pollForBrew() async {
        while brewMissing, !Task.isCancelled {
            // Probe off the main actor — both checks shell out / stat files.
            let (brewFound, cltFound) = await Task.detached(priority: .utility) {
                (BrewService.resolveBrewPath() != nil, Self.commandLineToolsInstalled())
            }.value
            if updateOnboarding(brewFound: brewFound, cltFound: cltFound) { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// `xcode-select -p` exit 0 = the Command Line Tools (or full Xcode) are
    /// installed. Fixed executable + args, no interpolation; any spawn failure
    /// reads as not-installed.
    nonisolated static func commandLineToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

#if DEBUG
    /// A model pre-populated with representative data for SwiftUI `#Preview`s
    /// and Xcode's `RenderPreview`. No `brew` subprocess, no network — pure
    /// fixtures, so previews render the layout/chrome without a live install.
    /// Data-driven behavior against the real install is still verified by
    /// launching the app; previews are for layout iteration only.
    static func preview() -> AppModel {
        let m = AppModel()
        m.installed = [
            InstalledPackage(name: "wget", version: "1.24.5", kind: .formula),
            InstalledPackage(name: "ripgrep", version: "14.1.0", kind: .formula),
            InstalledPackage(name: "fd", version: "10.2.0", kind: .formula),
            InstalledPackage(name: "jq", version: "1.7.1", kind: .formula),
            InstalledPackage(name: "git", version: "2.45.2", kind: .formula),
            InstalledPackage(name: "node", version: "22.3.0", kind: .formula),
            InstalledPackage(name: "visual-studio-code", version: "1.90.0", kind: .cask),
            InstalledPackage(name: "rectangle", version: "0.84", kind: .cask),
            InstalledPackage(name: "iterm2", version: "3.5.2", kind: .cask),
        ]
        m.outdated = [
            OutdatedPackage(name: "ripgrep", installedVersion: "14.1.0", currentVersion: "14.1.1", kind: .formula),
            OutdatedPackage(name: "node", installedVersion: "22.3.0", currentVersion: "22.4.0", kind: .formula),
            OutdatedPackage(name: "visual-studio-code", installedVersion: "1.90.0", currentVersion: "1.91.0", kind: .cask),
        ]
        m.formulaCount = m.installed.lazy.filter { $0.kind == .formula }.count
        m.caskCount = m.installed.lazy.filter { $0.kind == .cask }.count
        m.outdatedCount = m.outdated.count
        m.leavesCount = 4
        m.onRequestCount = 5
        m.pinnedCount = 1
        m.runningServices = 2
        m.brewVersion = "5.1.14"
        m.brewPrefix = "/opt/homebrew"
        m.categories = [
            CategoryBreakdown(slug: "developer-tools", label: "Developer Tools", count: 5, fraction: 0.56,
                              icon: "chevron.left.forwardslash.chevron.right"),
            CategoryBreakdown(slug: "productivity", label: "Productivity", count: 2, fraction: 0.22,
                              icon: "briefcase"),
            CategoryBreakdown(slug: "terminal", label: "Terminal", count: 2, fraction: 0.22,
                              icon: "terminal"),
        ]
        m.storage = [
            StorageItem(label: "Formulae (Cellar)", path: "/opt/homebrew/Cellar", bytes: 11_180_000_000),
            StorageItem(label: "Casks (Caskroom)", path: "/opt/homebrew/Caskroom", bytes: 7_350_000_000),
            StorageItem(label: "Logs (var/log)", path: "/opt/homebrew/var/log", bytes: 5_870_000_000),
            StorageItem(label: "Download cache", path: "~/Library/Caches/Homebrew", bytes: 17_700_000_000),
        ]
        m.dashboardLoaded = true
        m.catalog = [
            CatalogPackage(token: "wget", displayName: "wget", desc: "Retrieve files over HTTP/FTP", homepage: "https://www.gnu.org/software/wget/", version: "1.24.5", kind: .formula),
            CatalogPackage(token: "ripgrep", displayName: "ripgrep", desc: "Fast recursive grep", homepage: "https://github.com/BurntSushi/ripgrep", version: "14.1.0", kind: .formula),
            CatalogPackage(token: "neovim", displayName: "neovim", desc: "Hyperextensible Vim-based editor", homepage: "https://neovim.io/", version: "0.10.0", kind: .formula),
            CatalogPackage(token: "iterm2", displayName: "iTerm2", desc: "Terminal emulator", homepage: "https://iterm2.com/", version: "3.5.2", kind: .cask),
            CatalogPackage(token: "slack", displayName: "Slack", desc: "Team communication and collaboration", homepage: "https://slack.com/", version: "4.39.0", kind: .cask),
            CatalogPackage(token: "visual-studio-code", displayName: "Visual Studio Code", desc: "Code editor", homepage: "https://code.visualstudio.com/", version: "1.90.0", kind: .cask),
        ]
        m.trendingEntries = [
            TrendingEntry(rank: 1, token: "wget", kind: .formula, installCount: 511_288, velocity: 1.02),
            TrendingEntry(rank: 2, token: "ripgrep", kind: .formula, installCount: 402_113, velocity: 1.41),
            TrendingEntry(rank: 3, token: "visual-studio-code", kind: .cask, installCount: 221_669, velocity: 0.88),
            TrendingEntry(rank: 4, token: "neovim", kind: .formula, installCount: 188_402, velocity: 2.10),
            TrendingEntry(rank: 5, token: "slack", kind: .cask, installCount: 96_770, velocity: nil),
        ]
        return m
    }
#endif

    /// Count badge for a sidebar section (nil = no badge). Library shows the
    /// outdated count; Services shows running services; Activity shows running
    /// jobs. The vulnerable-package count is NOT a nav badge — a bare number on
    /// the Dashboard row reads as confusing (and climbs distractingly during a
    /// live sweep). It lives in the sidebar FOOTER instead ("● N vulnerable"),
    /// mirroring the Tauri sidebar footer badge.
    func badge(for section: Section) -> Int? {
        switch section {
        case .dashboard:
            return nil
        case .library:  return outdatedCount > 0 ? outdatedCount : nil
        case .services: return runningServices > 0 ? runningServices : nil
        case .activity:
            let running = jobs.filter { $0.status == .running }.count
            return running > 0 ? running : nil
        default:        return nil
        }
    }

    // MARK: - Brew health (sidebar footer status row)

    /// Health of the Homebrew environment, for the sidebar footer status dot.
    /// Mirrors the Tauri `statusKind` derived value (`Sidebar.svelte:145-150`):
    /// unknown until the first probe, then missing/running/ready.
    enum BrewHealth { case ready, running, missing, unknown }

    /// Derived brew-environment health. A library/detail command can fail while
    /// Homebrew itself is present (for example a cask that requires sudo), so do
    /// not collapse every `loadError` into "brew not found". The missing state is
    /// reserved for the launch resolver or a placeholder version with a load
    /// error; a known version/prefix stays ready.
    var brewHealth: BrewHealth {
        if jobs.contains(where: { $0.status == .running }) { return .running }
        if !dashboardLoaded && brewVersion == "—" { return .unknown }
        if brewMissing { return .missing }
        if brewVersion == "—", loadError != nil { return .missing }
        return brewVersion == "—" ? .missing : .ready
    }

    /// Short footer label — "brew 5.1.14" / "brew not found" / "brew". Mirrors
    /// the Tauri `env.shortLabel` (`env.svelte.ts:37-42`).
    var brewShortLabel: String {
        switch brewHealth {
        case .missing: return L10n.string("brew.status.notFound")
        case .unknown: return "brew"
        default:       return brewVersion == "—" ? "brew" : "brew \(brewVersion)"
        }
    }

    /// Tooltip for the footer status row — version + prefix, plus a running-jobs
    /// note. Mirrors the Tauri `env.summary` + `statusTooltip`.
    var brewStatusTooltip: String {
        var base: String
        switch brewHealth {
        case .unknown: base = L10n.string("brew.status.checking")
        case .missing: base = L10n.string("brew.status.notFoundOnPath")
        default:       base = String(format: L10n.string("brew.status.ready.format"), brewVersion, brewPrefix)
        }
        let running = jobs.filter { $0.status == .running }.count
        if running > 0 {
            base += "\n\(L10n.brewOperationsRunning(running))"
        }
        return base
    }

    /// Re-probe the brew environment (footer status-dot click). Re-runs the
    /// dashboard load, which re-resolves version/prefix and clears/sets
    /// `loadError`. Mirrors the Tauri footer's `env.refresh()`.
    func reprobeBrew() async {
        dashboardLoaded = false
        await loadDashboard()
    }

    /// Dependencies = installed formulae that weren't explicitly requested.
    var dependencyCount: Int { max(0, formulaCount - leavesCount) }
    var totalPackages: Int { formulaCount + caskCount }

    /// First 5 outdated packages for the Dashboard preview list.
    var outdatedPreview: [OutdatedPackage] { Array(outdated.lazy.filter { !$0.pinned }.prefix(5)) }

    /// Total bytes across all storage categories.
    var storageTotalBytes: Int64 { storage.reduce(0) { $0 + $1.bytes } }

    private let brew = BrewService()
    private let snapshotStore = SnapshotStore()

    func loadLibrary() async {
        isLoading = true
        loadError = nil
        do {
            // Library lists BOTH formulae and casks from the same source Tauri
            // uses: `brew info --installed --json=v2`. That payload carries
            // formula `installed_on_request`; casks are tagged on-request by
            // the parser, matching Tauri's cask rule.
            installed = try await brew.listInstalledAll()
            formulaCount = installed.lazy.filter { $0.kind == .formula }.count
            caskCount = installed.lazy.filter { $0.kind == .cask }.count
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Load all Dashboard stats. Reuses the Library load for the formula count
    /// (and triggers it if it hasn't run), then fans out the cheap counts.
    func loadDashboard() async {
        // Fast path — installed list + cheap (sub-second) counts. caskCount /
        // formulaCount come from the installed list itself (loadLibrary already
        // derives them), so no extra `brew list --cask` spawn.
        if installed.isEmpty {
            await loadLibrary()
        } else {
            formulaCount = installed.lazy.filter { $0.kind == .formula }.count
            caskCount = installed.lazy.filter { $0.kind == .cask }.count
        }
        async let leaves = try? brew.countLeaves()
        async let onRequest = try? brew.countOnRequest()
        async let ver = brew.version()
        async let pfx = brew.prefix()
        async let services = brew.countRunningServices()

        leavesCount = await leaves ?? 0
        onRequestCount = await onRequest ?? 0
        // Count pins from the installed list (its top-level `pinned` covers
        // formulae AND casks) rather than `brew list --pinned`, which only
        // reports pinned formulae and would undercount pinned casks (#90).
        pinnedCount = installed.lazy.filter { $0.pinned }.count
        brewVersion = await ver
        brewPrefix = await pfx
        runningServices = await services
        categories = categoryCatalog?.breakdown(installed: installed) ?? []
        dashboardLoaded = true   // paint NOW — don't wait on the slow ops below

        // Slow ops stream into their cards (gated by `outdatedLoading` /
        // `storageLoading`) instead of blocking the whole dashboard.
        Task { await loadOutdated() }
        Task { await loadStorage() }
    }

    /// `brew outdated --json=v2` (~4s) — runs after first paint; the Updates
    /// tile/card show a "checking" state until it resolves.
    func loadOutdated() async {
        outdatedLoading = true
        outdated = (try? await brew.outdatedPackages()) ?? []
        // `brew outdated --json` still lists pinned packages (flagged
        // `pinned: true`), but they're intentionally held back (#90) and brew
        // upgrade skips them — so the nag count (sidebar badge, Dashboard
        // "updates available", "Upgrade all (N)") counts only upgradable ones.
        // The Library's Outdated filter still shows pinned rows (badged).
        outdatedCount = outdated.lazy.filter { !$0.pinned }.count
        outdatedLoading = false
    }

    /// `du -sk` storage breakdown — runs after first paint; the Storage card
    /// shows a measuring placeholder until it resolves.
    func loadStorage() async {
        storageLoading = true
        storage = await brew.storageBreakdown()
        storageLoading = false
        // Best-effort cleanup estimate for the maintenance hint (#80). Detached
        // so it never delays the storage breakdown; a nil result hides the hint.
        Task { cleanupReclaimableBytes = await brew.cleanupReclaimableBytes() }
    }

    // MARK: - Cache maintenance (Issue #80)

    /// `brew doctor` as a streaming Activity job. Read-only diagnostics; a
    /// non-zero exit (advisories) is treated as success by `startJob` via
    /// `BrewErrorPatterns.doctorAdvisoryExit`, so the advisory text simply shows
    /// in the Activity log. Mirrors the Tauri Storage-card "Run brew doctor".
    func runDoctor() async {
        guard !maintenanceBusy else { return }
        doctorRunning = true
        await startJob("Running brew doctor", args: ["doctor"], startedAt: Date().timeIntervalSince1970)
        doctorRunning = false
    }

    /// `brew cleanup --prune=all [--scrub] [--verbose]` as a streaming Activity
    /// job (#80). Destructive of cached downloads only — the UI confirm-gates it.
    /// `scrub` is opt-in (default off in the UI): it also removes the latest
    /// versions' downloads, so it's a deliberate toggle. On success, re-measures
    /// the Storage card so the smaller cache is shown.
    func runCleanup(scrub: Bool, verbose: Bool) async {
        guard !maintenanceBusy else { return }
        cleanupRunning = true
        var args = ["cleanup", "--prune=all"]
        if scrub { args.append("--scrub") }
        if verbose { args.append("--verbose") }
        _ = await startJob("Cleaning up Homebrew cache", args: args, startedAt: Date().timeIntervalSince1970)
        cleanupRunning = false
        // Re-measure storage + refresh the "frees ~X" estimate regardless of exit
        // status: `brew cleanup` can free space yet exit non-zero (a file it
        // couldn't remove), and even a partial cleanup changes what's
        // reclaimable. loadStorage re-fetches cleanupReclaimableBytes
        // independently, so a stale estimate can't survive. (Mirrors Tauri.)
        await loadStorage()
    }

    /// Toolbar Refresh — reload whichever surface is showing.
    func refresh() async {
        await loadLibrary()
        dashboardLoaded = false
        await loadDashboard()
        // Opt-in live updates: drop the per-token overlay (served data may have
        // changed) and pull newer categories. Both no-op unless opted in.
        resetLiveEnrichment()
        await refreshLiveCategoriesIfNewer()
    }

    /// Deprecation status for the OPEN detail package: prefer the brew-info
    /// status (the only source with the "use X instead" replacement), falling
    /// back to the offline catalog baseline while `brew info` is still loading or
    /// when the package wasn't found there. Mirrors the Tauri PackageDetail,
    /// where the row baseline shows immediately and the replacement appears once
    /// brew info resolves. Clean (no notice) when neither source flags it.
    var detailDeprecation: DeprecationStatus {
        if let info = detailInfo, !info.deprecation.isClean { return info.deprecation }
        guard let pkg = detailPackage else { return DeprecationStatus() }
        return deprecationStatus(pkg.name, pkg.kind)
    }

    // MARK: - Package detail

    /// Open the inspector for a package and load its full detail.
    func openDetail(_ pkg: InstalledPackage) {
        let detailPkg = packageForDetail(pkg)
        detailPackage = detailPkg
        // Package and bundle detail share one inspector slot — clear the bundle
        // so the two stay mutually exclusive.
        detailBundle = nil
        detailSection = selection
        showDetail = true
        Task { await loadDetail(detailPkg) }
    }

    /// Open the shared inspector for a bundle (Bundles reuses the package-detail
    /// inspector slot). Clears `detailPackage` so exactly one detail is loaded.
    /// No async load — the bundle's data is already resident in `bundles`; its
    /// live per-package installed state is read straight from `installed`.
    func openBundleDetail(_ bundle: BrewBundle) {
        detailBundle = bundle
        detailPackage = nil
        detailSection = .bundles
        showDetail = true
    }

    func packageForDetail(_ pkg: InstalledPackage) -> InstalledPackage {
        guard let installed = installedPackageMatching(token: pkg.name, kind: pkg.kind) else {
            return pkg
        }
        return InstalledPackage(
            name: pkg.name,
            version: installed.version,
            kind: pkg.kind,
            installedOnRequest: installed.installedOnRequest
        )
    }

    /// Close the inspector if it was opened from a different section than the one
    /// now selected — navigating away dismisses the detail.
    func closeDetailIfSectionChanged() {
        if showDetail, detailSection != selection { closeDetail() }
    }

    func closeDetail() {
        showDetail = false
        detailPackage = nil
        detailBundle = nil
        detailSection = nil
        detailInfo = nil
        detailEnrichment = nil
        detailCategories = []
        detailDependents = []
        detailVulns = []
        detailVulnsScanned = false
        detailTrend = nil
        detailRepoStats = nil
        detailStarred = nil
        detailWatching = nil
        detailError = nil
    }

    /// Load `brew info` + bundled enrichment/categories for the package, then
    /// kick off the opt-in network sections (trend, github) per settings gates.
    func loadDetail(_ pkg: InstalledPackage) async {
        detailLoading = true
        detailError = nil
        detailInfo = nil
        // Show this package's vulns straight from the cached install-wide scan
        // (instant, no per-package subprocess).
        loadDetailVulnsFromCache()
        detailTrend = nil
        detailRepoStats = nil
        detailStarred = nil
        detailWatching = nil

        // Bundled, synchronous-ish lookups first (instant).
        detailEnrichment = settings.aiFeaturesVisible ? enrichmentEntry(for: pkg.name) : nil
        detailCategories = categoryCatalog?.categoryLabels(for: pkg.name, kind: pkg.kind) ?? []

        // Reverse dependents — packages in the bundled catalog that depend on
        // this one (pure catalog-graph inversion, no subprocess). Casks are
        // never depended-on, so a cask's reverse set is always empty.
        detailDependents = []
        let dependents = await catalogService.reverseDependents(of: pkg.name)
        guard detailPackage?.id == pkg.id else { return }
        detailDependents = dependents

        do {
            let info: PackageInfo
            do {
                info = try await brew.info(name: pkg.name, kind: pkg.kind)
            } catch {
                // A tap-qualified name (`user/tap/name`) that isn't tapped
                // locally makes `brew info` fail. Retry the bare name — the core
                // formula the list's catalog/enrichment data already resolved to.
                let bare = Self.bareToken(pkg.name)
                guard bare != pkg.name else { throw error }
                info = try await brew.info(name: bare, kind: pkg.kind)
            }
            // Guard against a stale load if the user clicked another package.
            guard detailPackage?.id == pkg.id else { return }
            detailInfo = info
        } catch {
            guard detailPackage?.id == pkg.id else { return }
            detailError = error.localizedDescription
        }
        detailLoading = false

        // Services: a formula may have a background service. Load the list once
        // (local, no network) so the detail's Service card can resolve it.
        if pkg.kind == .formula, !servicesLoaded {
            Task { await loadServices() }
        }

        // Opt-in network sections — fire-and-forget, gated by settings.
        if settings.enhancedTrendingAllowed {
            Task { await loadTrend(pkg) }
        }
        // Opt-in live enrichment: fetch fresher friendly-name/summary/etc. for
        // the viewed package and overlay it. No-ops unless opted in; soft-fails.
        if settings.liveEnrichmentAllowed {
            Task { await ensureLiveEnrichment(pkg.name) }
        }
        if settings.githubAllowed, let hp = detailInfo?.githubHomepage {
            Task { await loadGitHub(homepage: hp, pkgId: pkg.id) }
        }
        // Probe brew-vulns availability so the Security card shows the right CTA.
        if settings.vulnerabilityScanningAllowed {
            let installed = await vulns.isBrewVulnsInstalled()
            guard detailPackage?.id == pkg.id else { return }
            brewVulnsInstalled = installed
        }
    }

    // MARK: - One-line description lookup (Bundles inline expand)

    /// Resolve a package's short description, preferring data already resident in
    /// the app over a subprocess. Used by `BundleDetailView`'s inline package
    /// accordion so a bundle row can reveal what "orbstack", "caddy", etc. are.
    ///
    /// Order: (1) the bundled Discover/Library catalog, which carries `desc` for
    /// every formula/cask (instant, no subprocess); (2) `brew info` — the same
    /// path `loadDetail` uses to fill `PackageInfo.desc` — for tokens not resident
    /// in the catalog (common for not-installed bundle packages). Both steps retry
    /// under the bare token so a tap-qualified `user/tap/name` still resolves.
    /// Returns nil when nothing yields a non-empty description.
    func packageDescription(name: String, kind: InstalledPackage.Kind) async -> String? {
        if let resident = catalogDescription(for: name, kind: kind) { return resident }

        if let info = try? await brew.info(name: name, kind: kind),
           let desc = info.desc, !desc.isEmpty {
            return desc
        }
        let bare = Self.bareToken(name)
        if bare != name,
           let info = try? await brew.info(name: bare, kind: kind),
           let desc = info.desc, !desc.isEmpty {
            return desc
        }
        return nil
    }

    /// Description straight from the bundled catalog (Discover/Library metadata),
    /// matched on token+kind with a bare-token fallback. nil when absent/empty.
    private func catalogDescription(for token: String, kind: InstalledPackage.Kind) -> String? {
        let bare = Self.bareToken(token)
        let match = catalog.first { $0.token == token && $0.kind == kind }
            ?? catalog.first { $0.token == bare && $0.kind == kind }
        if let desc = match?.desc, !desc.isEmpty { return desc }
        return nil
    }

    // MARK: - Live enrichment overlay (opt-in)

    /// Enrichment for a token. In English, live enrichment wins over bundled
    /// data. In localized UI, localized bundled prose wins while live data can
    /// still fill technical fallback fields (mirrors the Tauri store).
    func enrichmentEntry(for token: String) -> EnrichmentEntry? {
        if let hit = preferredEnrichment(
            live: liveEnrichment[token],
            bundled: enrichment?.entry(for: token)
        ) { return hit }
        // Tap-qualified token (`user/tap/name`) → retry under the bare name the
        // enrichment is keyed by.
        let bare = Self.bareToken(token)
        guard bare != token else { return nil }
        return preferredEnrichment(
            live: liveEnrichment[bare],
            bundled: enrichment?.entry(for: bare)
        )
    }

    private func preferredEnrichment(
        live: EnrichmentEntry?,
        bundled: EnrichmentEntry?
    ) -> EnrichmentEntry? {
        guard L10n.isRussian, let bundled else { return live ?? bundled }
        guard let live else { return bundled }
        return bundled.localized(over: live)
    }

    private func catalogPackageMatches(
        _ pkg: CatalogPackage,
        query: String,
        entry: EnrichmentEntry?
    ) -> Bool {
        let fields: [String?] = [
            pkg.token,
            pkg.displayName,
            pkg.desc,
            entry?.friendlyName,
            entry?.summary,
        ]
        if fields.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        if entry?.searchTerms.contains(where: { $0.localizedCaseInsensitiveContains(query) }) == true {
            return true
        }
        if entry?.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) == true {
            return true
        }
        let labels = categoryCatalog?.categoryLabels(for: pkg.token, kind: pkg.kind) ?? []
        return labels.contains {
            $0.localizedCaseInsensitiveContains(query)
                || L10n.display($0).localizedCaseInsensitiveContains(query)
        }
    }

    /// Fetch a token's live enrichment on demand and overlay it. Deduped +
    /// soft-fail; refreshes the open detail panel if it's the same package.
    func ensureLiveEnrichment(_ token: String) async {
        // Fetch + key by the bare name: tap-qualified tokens carry a `/`, which
        // the served path + the token allowlist (EnrichmentLiveService) reject.
        let bare = Self.bareToken(token)
        guard settings.liveEnrichmentAllowed, !liveEnrichmentAttempted.contains(bare) else { return }
        liveEnrichmentAttempted.insert(bare)
        if let entry = await enrichmentLive.entry(token: bare) {
            liveEnrichment[bare] = entry
            if let dp = detailPackage, Self.bareToken(dp.name) == bare {
                detailEnrichment = enrichmentEntry(for: dp.name)
            }
        }
    }

    /// Drop the live overlay so the next `ensureLiveEnrichment` re-fetches.
    private func resetLiveEnrichment() {
        liveEnrichmentAttempted.removeAll()
        liveEnrichment.removeAll()
    }

    /// Pull the live categories file when the served version is newer than the
    /// last one pulled, replacing the catalog + rebuilding the dashboard
    /// breakdown. Soft-fail; opt-in. Called on refresh.
    func refreshLiveCategoriesIfNewer() async {
        guard settings.liveEnrichmentAllowed,
              let v = await enrichmentLive.version(),
              v.categoriesVersion > liveCategoriesVersion,
              let data = await enrichmentLive.categoriesData(),
              let cat = CategoryCatalog.parse(data: data)
        else { return }
        liveCategoriesVersion = v.categoriesVersion
        categoryCatalog = cat
        categories = cat.breakdown(installed: installed)
    }

    func loadTrend(_ pkg: InstalledPackage) async {
        let series = await trendingHistory.series(name: pkg.name, isCask: pkg.kind == .cask)
        guard detailPackage?.id == pkg.id else { return }
        detailTrend = series
    }

    func loadGitHub(homepage: String, pkgId: String) async {
        let stats = try? await githubService.repoStats(homepage: homepage)
        guard detailPackage?.id == pkgId else { return }
        detailRepoStats = stats
        let status = githubService.status()
        let wasSignedIn = githubSignedIn
        githubStatus = status
        if status.signedIn {
            let starred = try? await githubService.isStarred(homepage: homepage)
            guard detailPackage?.id == pkgId else { return }
            detailStarred = starred
        }
        // Creds are lazy — the user may have just become signed-in (keychain ACL
        // allowed on this read, or a prior action signed them in). Populate the
        // dashboard GitHub card + toolbar chip now that we know.
        if status.signedIn && (!wasSignedIn || !githubStatsLoaded) {
            await loadGithubStats()
        }
    }

    // MARK: - GitHub actions (star / watch / file issue) + sign-in

    var githubSignedIn: Bool { githubStatus?.signedIn ?? false }
    /// True when signed in AND the `public_repo` scope is present (authed actions
    /// work). Drives the toolbar chip's green-vs-amber tint.
    var githubScopeComplete: Bool { githubStatus?.scopes.contains("public_repo") ?? false }

    // ---- Dashboard GitHub card (personal "starred N of M" stat) ----
    var githubStarredCount = 0
    var githubHomepageTotal = 0
    var githubStatsLoading = false
    var githubStatsLoaded = false
    /// Card is shown only when signed in + GitHub allowed (toggle on, not paranoid).
    var githubStatsEligible: Bool { githubSignedIn && settings.githubAllowed }

    /// Active device-flow prompt — drives the sign-in sheet. nil = not signing in.
    var deviceFlow: DeviceFlowStart?
    var githubSignInError: String?

    /// Star/unstar the detail repo. If signed out, kicks off sign-in first
    /// (the action re-runs after auth completes — mirrors Tauri's intercept).
    /// A missing `public_repo` scope surfaces a "Re-authorize" toast rather than
    /// silently failing, matching the Tauri scope-required CTA.
    func toggleStar() async {
        guard let hp = detailInfo?.githubHomepage else { return }
        guard await ensureGitHubSignIn() else { return }
        guard requireScope("public_repo", action: "Star") else { return }
        let target = !(detailStarred ?? false)
        try? await githubService.setStar(homepage: hp, starred: target)
        detailStarred = target
    }

    func toggleWatch() async {
        guard let hp = detailInfo?.githubHomepage else { return }
        guard await ensureGitHubSignIn() else { return }
        guard requireScope("public_repo", action: "Watch") else { return }
        let target = !(detailWatching ?? false)
        try? await githubService.setWatch(homepage: hp, watching: target)
        detailWatching = target
    }

    /// Guard an authed GitHub action on a required token scope. When the scope is
    /// missing, surfaces an error toast with a "Re-authorize" action that re-runs
    /// the device flow (which requests the full scope set — GitHub's consent only
    /// shows the missing scopes) and returns false so the caller bails. Mirrors
    /// the Tauri scope-required toast (`PackageDetail.svelte:528-540`).
    private func requireScope(_ scope: String, action: String) -> Bool {
        if githubStatus?.scopes.contains(scope) ?? false { return true }
        pushToast(.error, String(format: L10n.string("github.scopeRequired.title.format"), L10n.githubAction(action)),
                  String(format: L10n.string("github.scopeRequired.body.format"), scope),
                  action: ToastAction(label: L10n.string("Re-authorize")) { [weak self] in
                      Task { await self?.reauthorizeGitHub() }
                  })
        return false
    }

    /// Re-run the device flow to grant any missing scopes (the "Re-authorize"
    /// toast action). Forces a fresh sign-in even though a token already exists,
    /// so GitHub re-prompts for the full scope set.
    func reauthorizeGitHub() async {
        githubStatus = nil   // force ensureGitHubSignIn to re-run the device flow
        _ = await ensureGitHubSignIn()
    }

    func fileIssue(title: String, body: String) async -> String? {
        guard let hp = detailInfo?.githubHomepage else { return nil }
        guard await ensureGitHubSignIn() else { return nil }
        let result = try? await githubService.createIssue(homepage: hp, title: title, body: body, labels: [])
        return result?.url
    }

    /// True if signed in (already, or after completing the device flow). When
    /// signed out, surfaces `deviceFlow` for the sign-in sheet and polls to
    /// completion. The caller's action proceeds only on a true return.
    private func ensureGitHubSignIn() async -> Bool {
        if githubSignedIn { return true }
        githubSignInError = nil
        do {
            let flow = try await githubService.startDeviceFlow()
            deviceFlow = flow
            // Open GitHub's verification page + copy the code (Tauri parity).
            if let url = URL(string: flow.verificationUri) { NSWorkspace.shared.open(url) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(flow.userCode, forType: .string)
            let status = try await githubService.pollDeviceFlow(deviceCode: flow.deviceCode, interval: flow.interval)
            deviceFlow = nil
            githubStatus = status
            // Now signed in — light up the dashboard card + toolbar chip.
            if status.signedIn { await loadGithubStats() }
            return status.signedIn
        } catch {
            githubSignInError = error.localizedDescription
            deviceFlow = nil
            return false
        }
    }

    func cancelGitHubSignIn() { deviceFlow = nil }

    /// Run a `brew vulns` scan for the detail package (Security card "Check now").
    /// Populate the detail Security card from the cached install-wide scan —
    /// instant, no subprocess. Called when the inspector opens. Leaves the card
    /// in its "not scanned" state if no scan has run yet.
    func loadDetailVulnsFromCache() {
        guard let pkg = detailPackage else { return }
        if vulnLastScannedAt != nil {
            detailVulns = vulnFindings[pkg.name] ?? []
            detailVulnsScanned = true
        } else {
            detailVulns = []
            detailVulnsScanned = false
        }
    }

    /// The Security card's scan action. There's no single-package scan —
    /// `brew vulns` only scans the whole install — so this runs the full
    /// system scan (and the card's copy says so), then reads this package's
    /// findings back out of the refreshed cache.
    func scanDetailVulns() async {
        guard let pkg = detailPackage else { return }
        detailVulnsLoading = true
        await scanAllVulns()
        guard detailPackage?.id == pkg.id else { return }
        detailVulns = vulnFindings[pkg.name] ?? []
        detailVulnsScanned = vulnLastScannedAt != nil
        detailVulnsLoading = false
    }

    /// Lazy first scan on first interest — called when a vuln-surfacing view
    /// appears (Exposure card `.task`, Library `.vulnerable` filter). No-ops
    /// when scanning is disabled, already scanned, or a scan is in flight.
    /// Mirrors the Tauri store's `scanIfNeeded`.
    func scanVulnsIfNeeded() async {
        guard settings.vulnerabilityScanningAllowed else { return }
        guard vulnLastScannedAt == nil, !vulnScanAllLoading else { return }
        await scanAllVulns()
    }

    /// Scan every installed formula for known vulnerabilities and build the
    /// `vulnIndex` severity rollup. The install-wide analogue of
    /// `scanDetailVulns` — the native parallel to the Tauri
    /// `vulnerabilities.scanAll`. Casks are skipped (brew-vulns is
    /// formula-only; `scanOne` short-circuits them to empty anyway).
    ///
    /// Gated on `vulnerabilityScanningAllowed` (Offline Mode off + toggle on),
    /// matching the detail scan and the Tauri store's `enabled` predicate.
    /// Runs the per-formula `scanOne` calls CONCURRENTLY (bounded) off the main
    /// actor — `VulnsService` is a plain `Sendable` struct, so the subprocesses
    /// no longer serialize on a single actor (the trap that made a ~331-formula
    /// sweep crawl one `brew vulns` at a time). Results fold in incrementally so
    /// the Exposure card / Library dots fill in progressively as the sweep runs.
    /// Whether the install-wide sweep may keep scheduling work. Re-read each
    /// iteration so flipping Offline Mode on mid-sweep stops it.
    func scanAllVulns() async {
        guard settings.vulnerabilityScanningAllowed else { return }
        guard !vulnScanAllLoading else { return }
        vulnScanAllLoading = true
        defer { vulnScanAllLoading = false }

        // Ensure the helper is present so the sweep doesn't silently no-op into
        // an all-clean state (which would be a fake "no vulnerabilities" signal).
        // If it's missing we do NOT mark the scan as done — the card stays in its
        // "never scanned / Scan now" CTA rather than a false "clean" result.
        let installedHelper = await vulns.isBrewVulnsInstalled()
        brewVulnsInstalled = installedHelper
        guard installedHelper else { return }

        // ONE `brew vulns --json` call over the install set — exactly like the
        // Tauri scan_all. The old per-formula sweep over EVERY installed formula
        // (deps included) both over-reported (Tauri's single call scans a much
        // smaller set) and was ~331× slower. Run off the main actor so the
        // blocking subprocess I/O doesn't freeze the UI.
        let service = vulns
        guard let rawFindings = try? await Task.detached(priority: .utility, operation: {
            try await service.scanAll()
        }).value else { return }
        // Best-effort GHSA enrichment — same posture + position as Tauri's
        // scan_all (commands/vulns.rs:218): fills richer advisory text for
        // GHSA findings from api.github.com, gated on the GitHub master toggle.
        // Does NOT change severity or counts. Token read once (anonymous if
        // signed out); skipped entirely when GitHub is off/Offline Mode on.
        let token = settings.githubAllowed ? GitHubService.storedToken() : nil
        let findings = await VulnsEnrich.enrich(
            rawFindings, githubEnabled: settings.githubAllowed, token: token)
        // Replace wholesale so an uninstalled package drops out of the caches.
        vulnFindings = findings
        vulnIndex = findings.mapValues { VulnSummary.from($0) }
        vulnLastScannedAt = Date()
        vulnScannedThisSession = true
        vulnSource = .live
        // Persist so the result survives relaunch — the Exposure card shows the
        // last scan instantly instead of re-scanning at every launch.
        persistVulns()
    }

    // MARK: - Vulnerability persistence (UserDefaults)

    private static let vulnFindingsKey = "vuln.findings.v1"
    private static let vulnScannedAtKey = "vuln.scannedAt.v1"

    /// Persist the full per-package findings + timestamp. Best-effort. The detail
    /// card reads these back after relaunch with no re-scan; the summary index is
    /// derived from them on load.
    private func persistVulns() {
        if let data = try? JSONEncoder().encode(vulnFindings) {
            UserDefaults.standard.set(data, forKey: Self.vulnFindingsKey)
        }
        if let at = vulnLastScannedAt {
            UserDefaults.standard.set(at.timeIntervalSince1970, forKey: Self.vulnScannedAtKey)
        }
    }

    /// Load the last persisted scan at launch so the Exposure card + Library
    /// dots + detail Security card show immediately without re-scanning.
    /// `scanVulnsIfNeeded` then no-ops (lastScannedAt is set); a fresh scan only
    /// happens on explicit "Scan now".
    func loadVulns() {
        if let data = UserDefaults.standard.data(forKey: Self.vulnFindingsKey),
           let findings = try? JSONDecoder().decode([String: [VulnFinding]].self, from: data) {
            vulnFindings = findings
            vulnIndex = findings.mapValues { VulnSummary.from($0) }
            // Restored from disk → a previous session's scan, not a fresh run.
            vulnSource = .cache
        }
        let ts = UserDefaults.standard.double(forKey: Self.vulnScannedAtKey)
        if ts > 0 { vulnLastScannedAt = Date(timeIntervalSince1970: ts) }
    }

    /// Canonical advisory URL for a finding — the first HTTPS reference if the
    /// entry carries one, else the canonical detail page derived from the id
    /// prefix (CVE→NVD, OSV→osv.dev, GHSA→GitHub advisories). Mirrors the Tauri
    /// `vulnPrimaryLink` + `canonicalVulnUrl`. Returns nil for an id-less /
    /// unrecognized entry so the UI can render a plain, non-clickable id.
    func advisoryURL(for finding: VulnFinding) -> URL? {
        for ref in finding.references where ref.hasPrefix("https://") {
            if let url = URL(string: ref) { return url }
        }
        return Self.canonicalAdvisoryURL(id: finding.rawId)
    }

    /// Map a vulnerability id to its canonical detail page. Mirrors the Tauri
    /// `canonicalVulnUrl`.
    static func canonicalAdvisoryURL(id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        if id.hasPrefix("CVE-") { return URL(string: "https://nvd.nist.gov/vuln/detail/\(id)") }
        if id.hasPrefix("OSV-") { return URL(string: "https://osv.dev/vulnerability/\(id)") }
        if id.hasPrefix("GHSA-") { return URL(string: "https://github.com/advisories/\(id)") }
        return nil
    }

    /// Naïve dot/dash-segment version compare — true when `a` is strictly older
    /// than `b`. Good enough for brew's mostly-semver tags; degrades to "show
    /// the upgrade button" (false-positive bias) on odd suffixes. Mirrors the
    /// Tauri `versionLessThan`.
    static func versionLessThan(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        func norm(_ v: String) -> [String] {
            var s = v
            if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
            return s.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        }
        let aa = norm(a), bb = norm(b)
        for i in 0..<max(aa.count, bb.count) {
            let as_ = i < aa.count ? aa[i] : "0"
            let bs = i < bb.count ? bb[i] : "0"
            if let an = Int(as_), let bn = Int(bs) {
                if an != bn { return an < bn }
            } else {
                if as_ != bs { return as_ < bs }
            }
        }
        return false
    }

    // MARK: - Detail actions

    func upgradeDetail(greedy: Bool = false) async {
        guard let pkg = detailPackage else { return }
        var args = ["upgrade"]
        if pkg.kind == .cask { args.append("--cask") }
        args.append(pkg.name)
        if greedy { args.append("--greedy") }
        let ok = await startJob("Upgrading \(pkg.name)", args: args, startedAt: Date().timeIntervalSince1970)
        if ok, let pkg = detailPackage { await loadDetail(pkg) }
    }

    /// Pin/unpin the detail package via `brew pin`/`unpin` (#90). Quiet and
    /// non-streaming — an instant flag flip, so it toasts success/failure
    /// rather than spawning an Activity job. On success `refresh()` reloads the
    /// installed + outdated lists (so the honest update count and Library badge
    /// re-derive) and the detail reloads so the footer button flips.
    func setPinnedDetail(_ pinned: Bool) async {
        guard let pkg = detailPackage else { return }
        do {
            try await brew.setPinned(pkg.name, kind: pkg.kind, pinned: pinned)
            pushToast(.success, L10n.pinToast(pkg.name, pinned: pinned))
            await refresh()
            if let pkg = detailPackage { await loadDetail(pkg) }
        } catch {
            pushToast(.error, L10n.pinFailedTitle(pinned: pinned), error.localizedDescription)
        }
    }

    /// Uninstall the detail package. `ignoreDependencies` adds
    /// `--ignore-dependencies` to force removal when another installed package
    /// still requires it ("Force remove", #100).
    func uninstallDetail(ignoreDependencies: Bool = false) async {
        guard let pkg = detailPackage else { return }
        let args = BrewArgs.uninstall(pkg.name, kind: pkg.kind, ignoreDependencies: ignoreDependencies)
        let ok = await startJob("Uninstalling \(pkg.name)", args: args, startedAt: Date().timeIntervalSince1970)
        if ok { closeDetail() }
    }

    /// Install the detail package (Discover → uninstalled packages). Reloads
    /// detail afterward so the footer flips Install → Uninstall + the meta table
    /// shows the now-installed version. Output streams into the Activity drawer;
    /// on failure the job shows `failed` with brew's actual error lines.
    /// Install the detail package. `adopt` adds `--adopt` (cask-only) to take
    /// over a matching app already on disk instead of erroring "already an
    /// App" (#13/#102); `force` overwrites it.
    func installDetail(force: Bool = false, adopt: Bool = false) async {
        guard let pkg = detailPackage else { return }
        let args = BrewArgs.install(pkg.name, kind: pkg.kind, force: force, adopt: adopt)
        let ok = await startJob("Installing \(pkg.name)", args: args, startedAt: Date().timeIntervalSince1970)
        if ok, let pkg = detailPackage { await loadDetail(pkg) }
    }

    // MARK: - Bundles (M3)

    /// Install every not-yet-installed package in a bundle (M3 "Install all").
    /// brew rejects a single interleaved `--formula … --cask …` invocation
    /// ("Options --cask and --formulae are mutually exclusive"), so
    /// `BrewArgs.installBundle` splits the set into at most two per-kind groups
    /// (formulae, then casks); each is ONE streamed Activity job — not N.
    /// Already-installed packages are filtered out first (install is idempotent,
    /// but this keeps the job to just the missing pieces). `startJob` refreshes
    /// the library on success, so per-package installed state flips afterward.
    func installBundle(_ b: BrewBundle) async {
        let pending = b.packages.filter {
            let kind = InstalledPackage.Kind(rawValue: $0.kind) ?? .formula
            return !isPackageInstalled(token: $0.name, kind: kind)
        }
        let groups = BrewArgs.installBundle(pending)
        guard !groups.isEmpty else { return }
        let label = "Installing \(b.name)"
        for args in groups {
            let ok = await startJob(label, args: args, startedAt: Date().timeIntervalSince1970)
            // Stop before the second (cask) job if the formula job failed — the
            // failure is already surfaced in Activity; don't pile a second error on.
            if !ok { break }
        }
    }

    /// Install a SINGLE bundle package — the per-row "Install" affordance in
    /// `BundleDetailView`. Reuses the exact streamed machinery `installBundle(_:)`
    /// drives: `BrewArgs.installBundle` scoped to one package (which yields a
    /// single install group) run through `startJob`, whose completion calls
    /// `refresh()` so the row's `isInstalled` check flips to "Installed" on its
    /// own. No brew-exec logic is duplicated. Unlike a full-bundle install the
    /// caller keeps the inspector open — the user stays in the bundle.
    func installPackage(_ pkg: BundlePackage) async {
        guard let args = BrewArgs.installBundle([pkg]).first else { return }
        await startJob("Installing \(pkg.name)", args: args, startedAt: Date().timeIntervalSince1970)
    }

    // MARK: - Bulk actions (Dashboard Updates card)

    /// `brew upgrade` — upgrade every outdated formula and cask, as a streaming
    /// Activity job. Mirrors Tauri's Dashboard "Upgrade all". `startJob` calls
    /// `refresh()` on completion, so the outdated count updates itself.
    func upgradeAll(greedy: Bool = false) async {
        guard outdatedCount > 0 else { return }
        var args = ["upgrade"]
        if greedy { args.append("--greedy") }
        await startJob("Upgrading all packages", args: args, startedAt: Date().timeIntervalSince1970)
    }

    /// Curated upgrade — run ONE `brew upgrade <name1> <name2> …` for the
    /// user-selected outdated packages. Drives the Dashboard "Choose…" sheet.
    /// Mirrors the Tauri `brew_upgrade_many` flow (`UpgradeModal.svelte`): a
    /// single streaming Activity job rather than N sequential ones. `startJob`
    /// calls `refresh()` on completion, so the outdated count self-updates.
    func upgradeMany(_ names: [String], greedy: Bool = false) async {
        guard !names.isEmpty else { return }
        let label = names.count == 1 ? "Upgrading \(names[0])" : "Upgrading \(names.count) packages"
        var args = ["upgrade"] + names
        if greedy { args.append("--greedy") }
        await startJob(label, args: args, startedAt: Date().timeIntervalSince1970)
    }

    /// `brew autoremove` — remove formulae installed only as now-unneeded
    /// dependencies (#47). Confirm-gated in the UI; streams into Activity.
    /// Mirrors Tauri `brew_autoremove`; `startJob` refreshes on completion.
    func autoremove() async {
        await startJob("Removing unused dependencies", args: ["autoremove"], startedAt: Date().timeIntervalSince1970)
    }

    /// Re-run a failed command with the flag a recovery choice implies
    /// (#13/#102/#100). Streams a fresh Activity job, exactly like the first
    /// attempt. Mirrors the Tauri `runRecovery` in `util/recovery.ts`.
    func runRecovery(_ option: BrewRecovery.Option, choice: BrewRecovery.Choice) async {
        let args: [String]
        let label: String
        switch choice {
        case .adopt:
            args = BrewArgs.install(option.name, kind: option.kind, adopt: true)
            label = "Adopting \(option.name)"
        case .overwrite:
            args = BrewArgs.install(option.name, kind: option.kind, force: true)
            label = "Reinstalling \(option.name)"
        case .forceRemove:
            args = BrewArgs.uninstall(option.name, kind: option.kind, ignoreDependencies: true)
            label = "Force-removing \(option.name)"
        }
        await startJob(label, args: args, startedAt: Date().timeIntervalSince1970)
    }

    // MARK: - Snapshots (Brewfile)

    /// Load the saved Brewfile snapshots from disk (newest first).
    func loadSnapshots() async {
        snapshotsLoading = true
        snapshots = await snapshotStore.list()
        snapshotsLoading = false
    }

    /// `brew bundle dump --file=<dir>/<id>.Brewfile --force` as a streaming
    /// Activity job, then reload the list. Mirrors Tauri `brewfile_dump`.
    func dumpSnapshot(label: String) async {
        try? await snapshotStore.ensureDir()
        // dumpTarget validates the (sanitized) id; it can't realistically throw,
        // but guard rather than force-unwrap.
        guard let target = try? await snapshotStore.dumpTarget(forLabel: label) else { return }
        let args = ["bundle", "dump", "--file=\(target.url.path)", "--force"]
        await startJob("Dumping Brewfile: \(label)", args: args, startedAt: Date().timeIntervalSince1970)
        await loadSnapshots()
    }

    /// `brew bundle install --file=<path>` as a streaming Activity job.
    /// Mirrors Tauri `brewfile_install`.
    func restoreSnapshot(_ snap: Snapshot) async {
        let args = ["bundle", "install", "--file=\(snap.path)"]
        await startJob("Restoring \(snap.label)", args: args, startedAt: Date().timeIntervalSince1970)
    }

    func deleteSnapshot(_ snap: Snapshot) async {
        try? await snapshotStore.delete(id: snap.id)
        await loadSnapshots()
    }

    /// Copy a snapshot to a user-picked destination (throws so the view can toast).
    func exportSnapshot(_ snap: Snapshot, to dest: URL) async throws {
        try await snapshotStore.export(id: snap.id, to: dest)
    }

    /// Import an external Brewfile (filename → label), then reload.
    func importSnapshot(from src: URL) async throws {
        let label = src.deletingPathExtension().lastPathComponent
        try await snapshotStore.importFile(from: src, label: label.isEmpty ? "imported" : label)
        await loadSnapshots()
    }

    /// Eagerly read GitHub sign-in status (Keychain) at launch so the toolbar's
    /// Octocat chip can render. Signed-out users have no token → no Keychain ACL
    /// prompt; only previously-signed-in users see the one-time prompt.
    func loadGithubStatus() async {
        githubStatus = githubService.status()
        if !(githubStatus?.signedIn ?? false) {
            // Signed out (or not yet) — reset card state so a later sign-in
            // reloads fresh (the idempotent loadGithubStats keys off this).
            githubStatsLoaded = false
            githubStarredCount = 0
            githubHomepageTotal = 0
        }
        await loadGithubStats()
    }

    /// Dashboard GitHub card: how many installed packages with a GitHub homepage
    /// the signed-in user has starred. Mirrors the Tauri personal-stats card.
    /// Homepages come from the bundled catalog's `homepage` field (native catalog
    /// carries only the homepage, so this counts packages whose *homepage* is on
    /// GitHub — a subset of Tauri's url-resolved set, but no extra brew calls).
    func loadGithubStats() async {
        guard githubStatsEligible, !githubStatsLoading, !githubStatsLoaded else { return }
        if installed.isEmpty { await loadLibrary() }
        if catalog.isEmpty { await loadCatalog() }
        // Resolve each installed package to its canonical GitHub URL (homepage
        // OR source URL), de-duplicated. Mirrors Tauri's githubHomepage set.
        var seen = Set<String>()
        let homepages: [String] = installed.compactMap { pkg in
            guard let gh = catalogLookup(pkg.name, pkg.kind)?.githubHomepage,
                  seen.insert(gh).inserted else { return nil }
            return gh
        }
        githubHomepageTotal = homepages.count
        guard !homepages.isEmpty else { githubStatsLoaded = true; return }
        githubStatsLoading = true
        let results = await githubService.batchIsStarred(homepages)
        githubStarredCount = results.values.filter { $0 }.count
        githubStatsLoading = false
        githubStatsLoaded = true
    }

    // MARK: - Services

    /// Load the full background-service list (`brew services list --json`).
    /// Soft-fails into `servicesError`; never throws.
    func loadServices() async {
        if servicesLoading { return }
        servicesLoading = true
        servicesError = nil
        do {
            services = try await brew.servicesList()
        } catch {
            servicesError = error.localizedDescription
        }
        servicesLoading = false
        servicesLoaded = true
        runningServices = services.filter { $0.status.isRunning }.count
    }

    /// Start/stop/restart a service. Hybrid UX: a per-row spinner during the
    /// quiet run; on failure the error is surfaced as a failed Activity job +
    /// the drawer opens. Always reloads the list afterward.
    func performServiceAction(_ verb: ServiceVerb, name: String) async {
        guard !servicePending.contains(name) else { return }
        servicePending.insert(name)
        do {
            try await brew.serviceAction(verb, name: name)
        } catch {
            recordFailedServiceJob(verb, name: name, error: error)
        }
        servicePending.remove(name)
        await loadServices()
    }

    /// Surface a failed service action in the Activity drawer (the "errors go to
    /// the drawer" half of the hybrid action UX).
    private func recordFailedServiceJob(_ verb: ServiceVerb, name: String, error: Error) {
        let job = ActivityJob(
            id: UUID(),
            label: "\(verb.verbLabel) \(name)",
            command: "brew services \(verb.rawValue) \(name)",
            startedAt: Date().timeIntervalSince1970,
            status: .failed,
            lines: [ActivityLine(stream: .stderr, text: error.localizedDescription)],
            exitCode: nil,
            durationMs: nil,
            friendlyFailureMessage: BrewErrorPatterns.friendlify(
                stderr: error.localizedDescription,
                command: "brew services \(verb.rawValue) \(name)"
            ),
            progress: nil
        )
        jobs.insert(job, at: 0)
        if jobs.count > Self.maxJobs { jobs.removeLast(jobs.count - Self.maxJobs) }
        activeJobId = job.id
        drawerOpen = true
        persistJobs()
    }

    /// Run a mutating brew command as an Activity job: creates a running job,
    /// opens the drawer, streams output into the job's lines live, then sets the
    /// terminal status + exit. Returns true on success. stdin is /dev/null in
    /// the service, so a sudo/.pkg prompt fails fast (visible in the drawer)
    /// instead of hanging. `label` actually drives display label too.
    @discardableResult
    private func startJob(_ label: String, args: [String], startedAt: Double) async -> Bool {
        let jobId = UUID()
        let job = ActivityJob(
            id: jobId, label: label,
            command: "brew " + args.joined(separator: " "),
            startedAt: startedAt, status: .running, lines: [],
            exitCode: nil, durationMs: nil,
            friendlyFailureMessage: nil,
            progress: nil
        )
        // Don't yank the drawer away from a job the user is actively watching:
        // only auto-focus the new job if nothing is shown or the shown job has
        // already finished. Either way the new job appears as a switcher segment.
        let activeRunning = activeJobId.flatMap { id in jobs.first { $0.id == id } }?.status == .running
        jobs.insert(job, at: 0)
        if jobs.count > Self.maxJobs { jobs.removeLast(jobs.count - Self.maxJobs) }
        if !activeRunning {
            activeJobId = jobId
            drawerOpen = true
        }

        var exit: Int32 = 0
        var progressParser = BrewProgressParser()
        let stream = brew.runStreaming(jobId: jobId, args)
        for await event in stream {
            guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { continue }
            switch event {
            case .line(let l, let isStderr):
                jobs[idx].lines.append(ActivityLine(stream: isStderr ? .stderr : .stdout, text: l))
                if jobs[idx].lines.count > Self.maxLinesPerJob {
                    jobs[idx].lines.removeFirst(jobs[idx].lines.count - Self.maxLinesPerJob)
                }
                // Best-effort live progress from brew's `==>` markers (#57).
                if !isStderr, let p = progressParser.observe(l) {
                    jobs[idx].progress = p
                }
            case .finished(let code):
                exit = code
            }
        }

        let canceled = exit == 130 || exit == 143
        // brew exits 1 on non-fatal upgrade/install warnings (post-install
        // warnings, link conflicts, already-linked kegs) even though the work
        // completed — treat those as success so we don't show a scary "failed"
        // job + report button. This was the dominant source of bogus
        // "Upgrade-all failed" reports. See BrewErrorPatterns.upgradeWarningsOnly.
        var ok = exit == 0
        if !ok, !canceled {
            let command = "brew " + args.joined(separator: " ")
            let stderrText = jobs.first(where: { $0.id == jobId })?
                .lines.filter { $0.stream == .stderr }.map(\.text).joined(separator: "\n") ?? ""
            // brew doctor exits 1 on advisories — diagnostics, not a failure (#80).
            if BrewErrorPatterns.upgradeWarningsOnly(stderr: stderrText, command: command)
                || BrewErrorPatterns.doctorAdvisoryExit(command: command)
            {
                ok = true
            }
        }
        var finishedJob: ActivityJob?
        if let idx = jobs.firstIndex(where: { $0.id == jobId }) {
            let stderrText = jobs[idx].lines
                .filter { $0.stream == .stderr }
                .map(\.text)
                .joined(separator: "\n")
            let command = "brew " + args.joined(separator: " ")
            // exit 130/143 = SIGINT/SIGTERM → treat as canceled.
            jobs[idx].status = ok ? .succeeded : (canceled ? .canceled : .failed)
            jobs[idx].exitCode = exit
            jobs[idx].durationMs = Int((Date().timeIntervalSince1970 - startedAt) * 1000)
            jobs[idx].friendlyFailureMessage = (!ok && !canceled)
                ? BrewErrorPatterns.friendlify(stderr: stderrText, command: command)
                : nil
            jobs[idx].progress = nil   // clear live progress once finished
            finishedJob = jobs[idx]
        }
        // Background completion → macOS notification (opt-in; foreground uses
        // the Activity drawer). No-op unless enabled + app not frontmost.
        NotificationService.notifyTaskFinished(label: label, succeeded: ok, canceled: canceled)
        persistJobs()
        if let finishedJob, finishedJob.status == .failed {
            focusFailedJobInDrawer(finishedJob.id)
        }
        if Self.shouldRefreshAfterJob(succeeded: ok, canceled: canceled) {
            await refresh()
        }
        return ok
    }

    static func shouldRefreshAfterJob(succeeded: Bool, canceled: Bool) -> Bool {
        succeeded && !canceled
    }

    static func failureNoticeTitle(for label: String) -> String {
        L10n.activityFailureTitle(for: label)
    }

    /// True when a failed job is a genuine brew-browser problem (worth a
    /// "Report to brew-browser") rather than a brew-command failure. A non-zero
    /// brew exit means the command RAN and failed = a Homebrew/formula problem,
    /// not our bug — so it is NOT reportable. Only a failure without a real brew
    /// exit code (the app couldn't run the command) is. Mirrors the Tauri
    /// drawer's `exitCode == null` check.
    static func isAppError(_ job: ActivityJob) -> Bool {
        (job.exitCode ?? 0) == 0
    }

    private func focusFailedJobInDrawer(_ jobId: UUID) {
        activeJobId = jobId
        drawerOpen = true
    }

    /// Cancel a running job (SIGTERM its brew process).
    func cancelJob(_ jobId: UUID) {
        Task { await brew.cancel(jobId: jobId) }
    }

    /// Close the drawer — clears the active job so the bottom bar hides. The job
    /// stays in Activity history; selecting it there reopens the drawer.
    func dismissDrawer() {
        activeJobId = nil
        drawerOpen = false
    }

    /// Clear completed jobs from the history (keeps running ones).
    func clearFinishedJobs() {
        jobs.removeAll { $0.status != .running }
        persistJobs()
        if let active = activeJobId, !jobs.contains(where: { $0.id == active }) {
            activeJobId = jobs.first?.id
        }
    }

    /// Remove a single job from the history. If it's still running it's canceled
    /// first (we don't leave an orphaned brew process tracked nowhere). Drawer
    /// re-points to the next job, or hides if none remain.
    func removeJob(_ id: UUID) {
        if jobs.first(where: { $0.id == id })?.status == .running {
            cancelJob(id)
        }
        jobs.removeAll { $0.id == id }
        persistJobs()
        if activeJobId == id {
            activeJobId = jobs.first?.id
            if jobs.isEmpty { drawerOpen = false }
        }
    }

    // MARK: - Activity persistence (UserDefaults; mirrors Tauri's localStorage)

    private static let maxJobs = 50
    private static let maxLinesPerJob = 500
    private static let jobsKey = "activity.jobs.v1"

    /// Persist completed jobs (running ones are dropped on next launch). Best-
    /// effort; failure just means history doesn't survive restart.
    private func persistJobs() {
        let finished = jobs.filter { $0.status != .running }.prefix(Self.maxJobs)
        guard let data = try? JSONEncoder().encode(Array(finished)) else { return }
        UserDefaults.standard.set(data, forKey: Self.jobsKey)
    }

    /// Load persisted job history at launch. Any "running" survivor (app quit
    /// mid-job) is marked canceled — we can't reattach to a dead process.
    func loadJobs() {
        guard let data = UserDefaults.standard.data(forKey: Self.jobsKey),
              let saved = try? JSONDecoder().decode([ActivityJob].self, from: data) else { return }
        jobs = saved.map { j in
            var j = j
            if j.status == .running { j.status = .canceled }
            return j
        }
    }
}
