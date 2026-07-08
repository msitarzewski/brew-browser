import Foundation

/// Time window for the install leaderboard. Raw value is the API path segment.
enum TrendingWindow: String, CaseIterable, Identifiable, Sendable {
    case d30 = "30d"
    case d90 = "90d"
    case d365 = "365d"
    var id: String { rawValue }
    var label: String {
        guard L10n.isRussian else { return rawValue }
        switch self {
        case .d30: return "30 дн."
        case .d90: return "90 дн."
        case .d365: return "365 дн."
        }
    }
}

/// One entry from the always-on Homebrew install analytics — token + install
/// count for the displayed window, plus a locally-computed velocity index
/// (this month vs prior-11-month average, from the 30/90/365 windows). The
/// leaderboard behind the Trending panel. Mirrors the Tauri model: install-
/// ranked leaderboard with velocity back-filled as a column.
struct TrendingEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(token)" }
    let rank: Int
    let token: String
    let kind: InstalledPackage.Kind
    let installCount: Int
    /// Velocity index (nil when the package's counts can't form a stable ratio).
    let velocity: Double?
}

/// Fetches Homebrew's published install analytics (always-on, no auth):
///   formulae: formulae.brew.sh/api/analytics/install/{window}.json
///   casks:    formulae.brew.sh/api/analytics/cask-install/{window}.json
/// Same data source + decision as the Tauri app (decisions.md 2026-05-23).
/// The opt-in velocity/sparkline layer is separate (`TrendingHistoryService`).
actor TrendingService {
    /// In-memory cache per window (~60min TTL, polite client; matches Tauri).
    private var cache: [TrendingWindow: (at: Double, entries: [TrendingEntry])] = [:]
    private static let ttl: Double = 60 * 60

    private let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    /// Merged formula + cask leaderboard for a window, install-count desc, with
    /// a locally-computed velocity per package (from the 30/90/365 windows of
    /// the SAME analytics — matching Tauri's `build_velocity_map`). `now` is the
    /// caller's timestamp for TTL. Returns [] on failure.
    func leaderboard(window: TrendingWindow, now: Double, force: Bool = false) async -> [TrendingEntry] {
        if !force, let c = cache[window], now - c.at < Self.ttl { return c.entries }

        // Fetch all three windows once — needed for velocity regardless of which
        // window is displayed. Each is (token,kind)->count.
        async let c30 = counts(window: .d30)
        async let c90 = counts(window: .d90)
        async let c365 = counts(window: .d365)
        let counts30 = await c30, counts90 = await c90, counts365 = await c365

        // The displayed leaderboard uses the requested window's counts.
        let display = window == .d30 ? counts30 : (window == .d90 ? counts90 : counts365)

        // Sort by install count desc, then cap to the top N — matching Tauri's
        // `MAX_ENTRIES = 100`. Building/sorting all ~28k rows (and handing them
        // to a SwiftUI Table) is what made sorting crawl; the leaderboard only
        // ever shows the top slice. Cap BEFORE the (more expensive) velocity
        // join so we compute velocity for 100 rows, not 28k.
        let ranked = display.values
            .sorted { $0.count > $1.count }
            .prefix(Self.maxEntries)

        let entries = ranked.enumerated().map { i, row -> TrendingEntry in
            let id = "\(row.kind.rawValue):\(row.token)"
            let vel = Self.velocityIndex(
                c30: counts30[id]?.count ?? 0,
                c90: counts90[id]?.count ?? 0,
                c365: counts365[id]?.count ?? 0
            )
            return TrendingEntry(rank: i + 1, token: row.token, kind: row.kind,
                                 installCount: row.count, velocity: vel)
        }
        cache[window] = (now, entries)
        return entries
    }

    /// Leaderboard cap — matches Tauri's `MAX_ENTRIES`.
    private static let maxEntries = 100

    /// id → (token, count) for one window. Formulae only — Tauri's trending
    /// leaderboard never fetches cask install counts (the two populations aren't
    /// comparable). Casks remain browsable in Discover.
    private func counts(window: TrendingWindow) async -> [String: CountRow] {
        await fetchCounts(path: "install", key: "formula", kind: .formula, window: window)
    }

    struct CountRow: Sendable {
        let token: String
        let kind: InstalledPackage.Kind
        let count: Int
        var idParts: (String, InstalledPackage.Kind) { (token, kind) }
    }

    private func fetchCounts(path: String, key: String, kind: InstalledPackage.Kind,
                             window: TrendingWindow) async -> [String: CountRow] {
        guard let url = URL(string: "https://formulae.brew.sh/api/analytics/\(path)/\(window.rawValue).json"),
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [:] }

        var out: [String: CountRow] = [:]
        for item in items {
            guard let token = item[key] as? String else { continue }
            let count = Self.parseCount(item["count"])
            out["\(kind.rawValue):\(token)"] = CountRow(token: token, kind: kind, count: count)
        }
        return out
    }

    /// Velocity index: this month vs prior-11-month average. Verbatim port of
    /// the Tauri `velocity_index(c30, c90, c365)` formula.
    static func velocityIndex(c30: Int, c90: Int, c365: Int) -> Double? {
        guard c365 != 0, c365 >= c90, c90 >= c30 else { return nil }
        let olderInstalls = c365 - c30
        guard olderInstalls != 0 else { return nil }
        let olderMonthlyAvg = Double(olderInstalls) / (335.0 / 30.0)
        guard olderMonthlyAvg >= 1.0 else { return nil }
        return Double(c30) / olderMonthlyAvg
    }

    /// Parse Homebrew's comma-grouped count ("511,288" → 511288). Tolerates
    /// Int or already-clean strings.
    static func parseCount(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        guard let s = raw as? String else { return 0 }
        return Int(s.filter { $0.isNumber }) ?? 0
    }
}
