import Foundation
import Compression

/// One package from the full Homebrew catalog (available, not necessarily
/// installed) — the data behind the Discover panel. Sourced from the bundled
/// gzipped `catalog/{formula,cask}.json.gz` (same data the Tauri app ships at
/// `src-tauri/data/catalog/`). Only the fields Discover renders are kept.
struct CatalogPackage: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(token)" }
    /// Homebrew token (formula name / cask token) — the install identifier.
    let token: String
    /// Human display name (cask `name[0]`; formula uses the token).
    let displayName: String
    let desc: String
    let homepage: String
    let version: String
    let kind: InstalledPackage.Kind
    /// Canonical `https://github.com/<owner>/<repo>` resolved from the homepage
    /// OR the source URL (`urls.stable.url` / cask `url`) — many GitHub-hosted
    /// packages have a non-GitHub marketing homepage. nil when neither is GitHub.
    /// Mirrors the Tauri `githubHomepage` resolution. Default nil for previews.
    var githubHomepage: String? = nil
    /// Offline deprecation/disabled baseline from the catalog (flags + reason +
    /// date; NO replacement — the catalog never carries one). Drives the Discover
    /// row badge + the AppModel token→status index that enriches Library rows.
    /// Default clean for previews. Mirrors the Tauri `CatalogEntrySummary` flags.
    var deprecation: DeprecationStatus = DeprecationStatus()
}

/// One package that depends on a queried target — a single reverse edge in the
/// catalog dependency graph. The native mirror of the Tauri
/// `catalog_reverse_dependents` row (parity charter: same bundled JSON, same
/// inversion rules, same data contract). `name`+`kind` identify the dependent;
/// `edge` classifies *how* it depends on the target.
struct ReverseDependent: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(name)" }
    /// Homebrew token of the dependent (the package that lists the target).
    let name: String
    /// formula vs cask — a cask depends on a formula via `depends_on.formula`.
    let kind: InstalledPackage.Kind
    /// How the dependent references the target.
    let edge: Edge

    /// Classification of a reverse edge, by the catalog array it came from.
    /// Precedence (strongest → weakest) for deduping a source that lists the
    /// target in several arrays: required > recommended > build > optional.
    /// Matches the Tauri edge contract exactly.
    enum Edge: String, Sendable, CaseIterable {
        case required, recommended, build, optional

        /// Lower rank = stronger edge (kept when deduping).
        var rank: Int {
            switch self {
            case .required: return 0
            case .recommended: return 1
            case .build: return 2
            case .optional: return 3
            }
        }
    }
}

/// Pure inversion of the catalog forward-dependency graph into a
/// target → [dependent] map. Free function so both the live loader and the
/// unit tests feed it the same raw decoded JSON dicts (the very shape
/// `formulae(from:)` / `casks(from:)` already receive). No I/O, no subprocess —
/// arch-independent catalog-graph inversion.
///
/// Inversion rules (must match the Tauri `invert_dependents`):
///   source S is a dependent of target T iff T appears in
///     S.dependencies              → .required
///     S.build_dependencies        → .build
///     S.recommended_dependencies  → .recommended
///     S.optional_dependencies     → .optional
///   or S is a cask and T ∈ S.depends_on.formula → .required (kind .cask)
/// Self-loops are excluded. Edges are keyed on the exact (bare) token present.
/// Per (target) the dependents are deduped by (name,kind) keeping the strongest
/// edge, then sorted ascending by name (stable for the UI).
func buildReverseDependentsIndex(
    formulae: [[String: Any]],
    casks: [[String: Any]]
) -> [String: [ReverseDependent]] {
    // Accumulate raw edges per target; dedupe + sort at the end.
    var raw: [String: [ReverseDependent]] = [:]

    func add(target: String, dependent: ReverseDependent) {
        guard !target.isEmpty, target != dependent.name || dependent.kind != .formula else { return }
        raw[target, default: []].append(dependent)
    }

    for obj in formulae {
        guard let source = obj["name"] as? String else { continue }
        let edges: [(String, ReverseDependent.Edge)] = [
            ("dependencies", .required),
            ("build_dependencies", .build),
            ("recommended_dependencies", .recommended),
            ("optional_dependencies", .optional),
        ]
        for (key, edge) in edges {
            guard let targets = obj[key] as? [String] else { continue }
            for target in targets {
                add(target: target,
                    dependent: ReverseDependent(name: source, kind: .formula, edge: edge))
            }
        }
    }

    for obj in casks {
        guard let source = obj["token"] as? String,
              let dependsOn = obj["depends_on"] as? [String: Any] else { continue }
        // `depends_on.formula` is sometimes a string, sometimes an array.
        let targets: [String]
        if let arr = dependsOn["formula"] as? [String] {
            targets = arr
        } else if let one = dependsOn["formula"] as? String {
            targets = [one]
        } else {
            continue
        }
        for target in targets {
            // A cask depending on a formula is a required edge for that formula.
            add(target: target,
                dependent: ReverseDependent(name: source, kind: .cask, edge: .required))
        }
    }

    // Dedupe by (name,kind) keeping the strongest edge, then sort by name.
    var out: [String: [ReverseDependent]] = [:]
    out.reserveCapacity(raw.count)
    for (target, deps) in raw {
        var best: [String: ReverseDependent] = [:]
        for d in deps {
            if let prev = best[d.id], prev.edge.rank <= d.edge.rank { continue }
            best[d.id] = d
        }
        out[target] = best.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    return out
}

/// Canonicalize any URL containing `github.com/<owner>/<repo>` to
/// `https://github.com/<owner>/<repo>`, or nil. Free function so both loaders
/// and tests can use it.
func resolveGithubHomepage(homepage: String, source: String?) -> String? {
    if let g = canonicalGithubURL(homepage) { return g }
    if let source, let g = canonicalGithubURL(source) { return g }
    return nil
}

private func canonicalGithubURL(_ url: String) -> String? {
    guard let r = url.range(of: "github.com/") else { return nil }
    let parts = url[r.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let owner = parts[0].prefix { $0 != "?" && $0 != "#" }
    var repo = parts[1].prefix { $0 != "?" && $0 != "#" }
    if repo.hasSuffix(".git") { repo = repo.dropLast(4) }
    guard !owner.isEmpty, !repo.isEmpty else { return nil }
    return "https://github.com/\(owner)/\(repo)"
}

/// Catalog freshness summary — the native mirror of the Tauri `CatalogSummary`
/// (`src/lib/types.ts:228`, Rust `catalog::CatalogSummary`). Drives the Dashboard
/// freshness strip + the Discover stale banner. `daysOld` is clamped to 0 on
/// clock skew, like the Rust `summarize`.
struct CatalogSummary: Sendable, Equatable {
    /// ISO 8601 UTC timestamp from the active catalog's `as_of` manifest field.
    let asOf: String
    /// Which copy is active — the shipped catalog vs. a user "Refresh from
    /// brew.sh" copy persisted in Application Support.
    enum Source: String, Sendable { case bundled, userRefreshed = "user-refreshed" }
    let source: Source
    let formulaCount: Int
    let caskCount: Int
    /// Whole days between `asOf` and now (UTC), clamped to ≥ 0.
    let daysOld: Int
}

/// Loads + decompresses the bundled catalog once, off the main actor, and
/// exposes the parsed package list. ~16k entries: parse a single time, hold in
/// memory. Mirrors the Tauri catalog loader (`src-tauri/src/catalog/`) at the
/// data level (parity charter: same bundled JSON, same shapes).
actor CatalogService {
    private var cache: [CatalogPackage]?
    /// Cached active-catalog summary (bundled OR the user-refreshed copy).
    private var summaryCache: CatalogSummary?
    /// Cached reverse-dependents index (target token → sorted dependents).
    /// Built once on first ``reverseDependents(of:)`` from the same raw JSON
    /// dicts the package loaders read (prefers the user-refreshed copy).
    private var reverseIndexCache: [String: [ReverseDependent]]?

    init() {}

    /// The full catalog (formulae + casks), name-sorted. Loads + decompresses on
    /// first call, then serves from memory. Prefers a user-refreshed copy in
    /// Application Support (written by ``refresh()``) over the bundled gzip, so
    /// "Refresh from brew.sh" survives relaunch. Returns [] if both are missing
    /// or malformed (Discover then shows an empty state rather than crashing).
    func all() async -> [CatalogPackage] {
        if let cache { return cache }
        var out: [CatalogPackage] = []
        // Prefer user-refreshed gzip → fall back to the bundled gzip.
        if let dir = Self.userCatalogDir,
           let f = Self.loadGzippedJSONArray(at: dir.appendingPathComponent("formula.json.gz")),
           let c = Self.loadGzippedJSONArray(at: dir.appendingPathComponent("cask.json.gz")) {
            out.append(contentsOf: Self.formulae(from: f))
            out.append(contentsOf: Self.casks(from: c))
        } else {
            out.append(contentsOf: Self.loadFormulae())
            out.append(contentsOf: Self.loadCasks())
        }
        out.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        cache = out
        return out
    }

    // MARK: - Freshness summary

    /// Active-catalog summary (user-refreshed copy if present, else bundled).
    /// Cached after first read; reset by ``refresh()``.
    func summary() async -> CatalogSummary? {
        if let summaryCache { return summaryCache }
        // User manifest wins (it's what `all()` is serving when present).
        if let dir = Self.userCatalogDir,
           let m = Self.readManifest(at: dir.appendingPathComponent("manifest.json")),
           Self.userCatalogDir.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("formula.json.gz").path) }) == true {
            let s = Self.summarize(m, source: .userRefreshed)
            summaryCache = s
            return s
        }
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "catalog")
                ?? Bundle.module.url(forResource: "manifest", withExtension: "json"),
              let m = Self.readManifest(at: url)
        else { return nil }
        let s = Self.summarize(m, source: .bundled)
        summaryCache = s
        return s
    }

    /// Refresh the catalog from `formulae.brew.sh`, mirroring the Tauri
    /// `refresh_catalog_inner` (`src-tauri/src/commands/catalog.rs:131`): fetch
    /// both JSON dumps, gzip them, write the user copy + manifest to Application
    /// Support, then reload from that copy so the in-memory list + summary go
    /// fresh. Throws on network / parse failure; the caller surfaces the error.
    /// The caller is responsible for the network gate (Offline Mode) before
    /// invoking, matching every other network-touching path in the app.
    func refresh() async throws -> CatalogSummary {
        guard let dir = Self.userCatalogDir else {
            throw CatalogRefreshError.noWritableDir
        }
        let session = Self.refreshSession()
        let formulaRaw = try await Self.fetch(Self.formulaURL, session: session)
        let caskRaw = try await Self.fetch(Self.caskURL, session: session)

        // Structural sanity — both endpoints must decode to a top-level array.
        guard let formulaArr = try? JSONSerialization.jsonObject(with: formulaRaw) as? [[String: Any]],
              let caskArr = try? JSONSerialization.jsonObject(with: caskRaw) as? [[String: Any]] else {
            throw CatalogRefreshError.malformedResponse
        }

        // Reject an empty response: formulae.brew.sh always returns thousands of
        // entries. A zero count means the body parsed as a JSON array but is
        // empty (a hostile mirror, a partial response, or a CDN error page that
        // happens to be a JSON array). Persisting it would silently zero out the
        // user's catalog on next launch, so throw before any write and let the
        // caller keep the previous good catalog. Parity with the Tauri guard in
        // `src-tauri/src/commands/catalog.rs` (refresh_catalog_inner). Safe on
        // every OS: cask.json comes from the brew.sh API, not the OS-gated local
        // brew layer, so it is non-empty regardless of platform.
        if formulaArr.isEmpty || caskArr.isEmpty {
            throw CatalogRefreshError.emptyResponse(formulaCount: formulaArr.count, caskCount: caskArr.count)
        }

        let formulaGz = try Self.gzip(formulaRaw)
        let caskGz = try Self.gzip(caskRaw)

        // Persist user copy + manifest atomically-ish (write into the dir).
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try formulaGz.write(to: dir.appendingPathComponent("formula.json.gz"))
        try caskGz.write(to: dir.appendingPathComponent("cask.json.gz"))
        let asOf = ISO8601DateFormatter().string(from: Date())
        let manifest: [String: Any] = [
            "as_of": asOf,
            "formula_count": formulaArr.count,
            "cask_count": caskArr.count,
            "fetched_from": Self.apiBase,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))

        // Reparse the freshly-written copy into the in-memory caches.
        var out: [CatalogPackage] = []
        out.append(contentsOf: Self.formulae(from: formulaArr))
        out.append(contentsOf: Self.casks(from: caskArr))
        out.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        cache = out

        let summary = CatalogSummary(
            asOf: asOf,
            source: .userRefreshed,
            formulaCount: formulaArr.count,
            caskCount: caskArr.count,
            daysOld: 0
        )
        summaryCache = summary
        reverseIndexCache = buildReverseDependentsIndex(formulae: formulaArr, casks: caskArr)
        return summary
    }

    // MARK: - Reverse dependents

    /// Packages in the catalog that depend on `token` (the reverse edges of the
    /// dependency graph), deduped + sorted by name. Builds the inverted index on
    /// first call from the same raw JSON dicts the loaders read (user-refreshed
    /// copy preferred over bundled), then serves from memory. Returns [] for a
    /// leaf, an unknown token, or a corrupt/empty catalog — never throws. The
    /// queried token is matched on its bare form (`user/tap/name` → `name`),
    /// since the catalog keys forward edges by bare token.
    func reverseDependents(of token: String) async -> [ReverseDependent] {
        let index = ensureReverseIndex()
        if let hit = index[token] { return hit }
        let bare = token.split(separator: "/").last.map(String.init) ?? token
        return bare != token ? (index[bare] ?? []) : []
    }

    /// Build (or return cached) the reverse-dependents index from the raw catalog
    /// JSON. Prefers the user-refreshed gzip pair, falls back to the bundled pair.
    /// On any load failure the index is an empty map (honest empty state).
    private func ensureReverseIndex() -> [String: [ReverseDependent]] {
        if let reverseIndexCache { return reverseIndexCache }
        var formulaArr: [[String: Any]] = []
        var caskArr: [[String: Any]] = []
        if let dir = Self.userCatalogDir,
           let f = Self.loadGzippedJSONArray(at: dir.appendingPathComponent("formula.json.gz")),
           let c = Self.loadGzippedJSONArray(at: dir.appendingPathComponent("cask.json.gz")) {
            formulaArr = f
            caskArr = c
        } else {
            formulaArr = Self.loadGzippedJSONArray("formula") ?? []
            caskArr = Self.loadGzippedJSONArray("cask") ?? []
        }
        let index = buildReverseDependentsIndex(formulae: formulaArr, casks: caskArr)
        reverseIndexCache = index
        return index
    }

    // MARK: - Decode

    private static func loadFormulae() -> [CatalogPackage] {
        guard let arr = loadGzippedJSONArray("formula") else { return [] }
        return formulae(from: arr)
    }

    private static func loadCasks() -> [CatalogPackage] {
        guard let arr = loadGzippedJSONArray("cask") else { return [] }
        return casks(from: arr)
    }

    /// Map a decoded formula JSON array → `CatalogPackage`s. Shared by the
    /// bundled loader and the refresh path (both feed the same parser).
    private static func formulae(from arr: [[String: Any]]) -> [CatalogPackage] {
        arr.compactMap { obj in
            guard let name = obj["name"] as? String else { return nil }
            let version = ((obj["versions"] as? [String: Any])?["stable"] as? String) ?? "—"
            let homepage = obj["homepage"] as? String ?? ""
            let source = ((obj["urls"] as? [String: Any])?["stable"] as? [String: Any])?["url"] as? String
            return CatalogPackage(
                token: name,
                displayName: name,                       // formulae have no separate display name
                desc: obj["desc"] as? String ?? "",
                homepage: homepage,
                version: version,
                kind: .formula,
                githubHomepage: resolveGithubHomepage(homepage: homepage, source: source),
                deprecation: parseDeprecationStatus(obj, includeReplacement: false)
            )
        }
    }

    /// Map a decoded cask JSON array → `CatalogPackage`s.
    private static func casks(from arr: [[String: Any]]) -> [CatalogPackage] {
        arr.compactMap { obj in
            guard let token = obj["token"] as? String else { return nil }
            // cask `name` is an array of human names; first is the primary.
            let display = (obj["name"] as? [String])?.first ?? token
            let homepage = obj["homepage"] as? String ?? ""
            let source = obj["url"] as? String
            return CatalogPackage(
                token: token,
                displayName: display,
                desc: obj["desc"] as? String ?? "",
                homepage: homepage,
                version: obj["version"] as? String ?? "—",
                kind: .cask,
                githubHomepage: resolveGithubHomepage(homepage: homepage, source: source),
                deprecation: parseDeprecationStatus(obj, includeReplacement: false)
            )
        }
    }

    /// Read `catalog/<name>.json.gz` from the module bundle, gunzip, parse as a
    /// JSON array of objects. Returns nil on any failure.
    private static func loadGzippedJSONArray(_ name: String) -> [[String: Any]]? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json.gz", subdirectory: "catalog")
                ?? Bundle.module.url(forResource: name, withExtension: "json.gz")
        else { return nil }
        return loadGzippedJSONArray(at: url)
    }

    /// Gunzip + parse a `.json.gz` file at an arbitrary URL (used for the
    /// user-refreshed copy in Application Support). Returns nil on any failure.
    private static func loadGzippedJSONArray(at url: URL) -> [[String: Any]]? {
        guard let gz = try? Data(contentsOf: url),
              let raw = gunzip(gz),
              let arr = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        else { return nil }
        return arr
    }

    // MARK: - Manifest / freshness

    /// Application-Support directory for the user-refreshed catalog copy
    /// (`…/Application Support/brew-browser/catalog/`). Mirrors the Tauri
    /// `app_data_dir/catalog` user-data location.
    private static var userCatalogDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("brew-browser", isDirectory: true)
            .appendingPathComponent("catalog", isDirectory: true)
    }

    /// Decode a `manifest.json` (bundled or user-refreshed). Only the fields the
    /// summary needs are read; matches the shape written by `tools/catalog/fetch.py`.
    private static func readManifest(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Build a `CatalogSummary` from a manifest dict + its source. `daysOld` is
    /// whole days from `as_of` to now (UTC), clamped to ≥ 0 (clock-skew safe),
    /// matching the Rust `summarize`.
    private static func summarize(_ manifest: [String: Any], source: CatalogSummary.Source) -> CatalogSummary {
        let asOf = manifest["as_of"] as? String ?? ""
        let days: Int
        if let date = ISO8601DateFormatter().date(from: asOf) {
            let secs = Date().timeIntervalSince(date)
            days = max(0, Int(secs / 86_400))
        } else {
            days = 0
        }
        return CatalogSummary(
            asOf: asOf,
            source: source,
            formulaCount: manifest["formula_count"] as? Int ?? 0,
            caskCount: manifest["cask_count"] as? Int ?? 0,
            daysOld: days
        )
    }

    // MARK: - Refresh transport (formulae.brew.sh)

    /// Errors surfaced by ``refresh()`` so the UI can show a typed message.
    enum CatalogRefreshError: Error, LocalizedError {
        case noWritableDir
        case network(String)
        case malformedResponse
        case emptyResponse(formulaCount: Int, caskCount: Int)
        case compression

        var errorDescription: String? {
            switch self {
            case .noWritableDir: return L10n.string("catalog.refresh.noWritableDir")
            case .network(let m): return String(format: L10n.string("catalog.refresh.failed.format"), m)
            case .malformedResponse: return L10n.string("catalog.refresh.malformedResponse")
            case .emptyResponse(let f, let c):
                return String(format: L10n.string("catalog.refresh.emptyResponse.format"), f, c)
            case .compression: return L10n.string("catalog.refresh.compression")
            }
        }
    }

    private static let apiBase = "https://formulae.brew.sh/api/"
    private static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula.json")!
    private static let caskURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    private static func refreshSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "User-Agent": "brew-browser/0.1 (+https://github.com/msitarzewski/brew-browser)"
        ]
        return URLSession(configuration: config)
    }

    /// GET a URL, returning the body or throwing a typed network error on a
    /// transport failure / non-2xx response.
    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CatalogRefreshError.network("HTTP \(http.statusCode) from \(url.host ?? "brew.sh")")
            }
            return data
        } catch let e as CatalogRefreshError {
            throw e
        } catch {
            throw CatalogRefreshError.network(error.localizedDescription)
        }
    }

    /// gzip-compress raw JSON bytes for the persisted user copy — writes the same
    /// 10-byte header + raw DEFLATE + 8-byte trailer layout that ``gunzip``
    /// expects (the catalog files use no extra-field/name flags).
    private static func gzip(_ data: Data) throws -> Data {
        let srcCapacity = data.count
        let dstCapacity = srcCapacity + 64 * 1024  // DEFLATE rarely expands; pad for tiny inputs.
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let written = data.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, dstCapacity, base, srcCapacity, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CatalogRefreshError.compression }

        // Frame the raw DEFLATE body in a minimal gzip container: fixed 10-byte
        // header (no flags), the body, then CRC32 + ISIZE little-endian trailer.
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(Data(bytes: dst, count: written))
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    /// Standard CRC-32 (gzip trailer). Small table-free implementation — the
    /// catalog is written once per refresh, so speed isn't critical here.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    /// Decompress a gzip blob via Apple's Compression framework. `.gz` is a
    /// 10-byte header + raw DEFLATE + 8-byte trailer; COMPRESSION_ZLIB wants the
    /// raw DEFLATE body, so strip the fixed header and trailer. Our catalog
    /// files have no extra-field/name flags, so the header is exactly 10 bytes.
    /// (Verified against the real bundled files before adopting.)
    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let body = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        let dstCapacity = 64 * 1024 * 1024  // 64 MiB ceiling (raw catalog ~44 MiB)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let written = body.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, dstCapacity, base, body.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }
}
