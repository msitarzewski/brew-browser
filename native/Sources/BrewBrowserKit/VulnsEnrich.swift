import Foundation

/// GHSA enrichment layer — the native Swift port of
/// `src-tauri/src/vulns/enrich.rs` (parity charter: same endpoint, same cache
/// shape, same merge semantics).
///
/// `brew vulns` gives the canonical CVE/GHSA id + a severity, but the
/// title/details/patched-version fields are often a one-line OSV stub when the
/// real advisory lives on GitHub. For any `GHSA-…` finding this fetches
/// `GET https://api.github.com/advisories/{id}` and merges the richer fields
/// back in. Like the Rust version it **never changes the finding's severity**
/// (severity stays whatever `brew vulns` reported) and never adds or removes
/// findings — so it has no effect on the Exposure card counts; it enriches the
/// PackageDetail advisory text.
///
/// Gated on the same independent GitHub master toggle as the Tauri layer
/// (`AppSettings.githubAllowed`). Best-effort throughout: a 404/429/parse
/// failure leaves the finding untouched and moves on. Results are cached to
/// `<App Support>/brew-browser/ghsa_cache.json` (the same file Tauri writes),
/// 7-day TTL, 500-entry LRU, fail-soft on a corrupt/foreign entry.
enum VulnsEnrich {
    static let apiBase = "https://api.github.com"
    static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
    static let cacheMaxEntries = 500
    static let schemaVersion = 1
    static let maxResponseBytes = 256 * 1024
    static let httpTimeout: TimeInterval = 10

    // MARK: - Public entry point

    /// Enrich every GHSA finding across the install-wide scan result. No-op
    /// (returns the input unchanged) when GitHub is disabled or there are no
    /// GHSA ids to enrich. `token` is read once by the caller (a Keychain miss
    /// just means anonymous rate limit). The cache dedups fetches across
    /// packages that share an advisory.
    static func enrich(
        _ findingsByPackage: [String: [VulnFinding]],
        githubEnabled: Bool,
        token: String?,
        session: URLSession = .shared,
        apiBase: String = VulnsEnrich.apiBase,
        cacheDir: URL? = VulnsEnrich.defaultCacheDir()
    ) async -> [String: [VulnFinding]] {
        guard githubEnabled else { return findingsByPackage }
        // Early-exit before touching the cache file when nothing is enrichable.
        let hasGhsa = findingsByPackage.values.contains { findings in
            findings.contains { isValidGhsaId($0.rawId) }
        }
        guard hasGhsa else { return findingsByPackage }

        var cache = GhsaCache.load(dir: cacheDir)
        var out: [String: [VulnFinding]] = [:]
        out.reserveCapacity(findingsByPackage.count)

        for (name, findings) in findingsByPackage {
            var merged: [VulnFinding] = []
            merged.reserveCapacity(findings.count)
            for finding in findings {
                guard isValidGhsaId(finding.rawId) else { merged.append(finding); continue }
                if let adv = cache.getFresh(finding.rawId) {
                    merged.append(mergeInto(finding, adv))
                    continue
                }
                if let adv = await fetchAdvisory(finding.rawId, token: token,
                                                 session: session, apiBase: apiBase) {
                    cache.put(finding.rawId, adv)
                    merged.append(mergeInto(finding, adv))
                } else {
                    merged.append(finding) // 404 / rate-limit / parse-fail → unchanged
                }
            }
            out[name] = merged
        }

        cache.saveIfDirty(dir: cacheDir)
        return out
    }

    // MARK: - Merge (mirrors enrich.rs `merge_into`)

    /// Fold richer advisory fields into a finding. Only non-empty fields
    /// overwrite (a sparse advisory must not clobber a populated OSV record);
    /// `fixedIn` is only set when the finding had none; references are deduped.
    /// **Severity is never changed.**
    static func mergeInto(_ finding: VulnFinding, _ adv: GhsaAdvisory) -> VulnFinding {
        var refs = finding.references
        for r in adv.references where !r.isEmpty && !refs.contains(r) { refs.append(r) }
        return VulnFinding(
            id: finding.id,
            rawId: finding.rawId,
            severity: finding.severity, // unchanged — parity with merge_into
            summary: adv.summary.isEmpty ? finding.summary : adv.summary,
            details: adv.description.isEmpty ? finding.details : adv.description,
            fixedIn: finding.fixedIn ?? (adv.firstPatchedVersion?.isEmpty == false ? adv.firstPatchedVersion : nil),
            references: refs,
            published: finding.published
        )
    }

    // MARK: - GHSA id validation (mirrors `is_valid_ghsa_id`)

    /// `GHSA-xxxx-xxxx-xxxx` where each group is exactly 4 ASCII alphanumerics.
    /// Defense in depth: keeps malformed ids out of the URL + cache keys.
    static func isValidGhsaId(_ id: String) -> Bool {
        guard id.hasPrefix("GHSA-") else { return false }
        let parts = id.dropFirst("GHSA-".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { p in
            p.count == 4 && p.allSatisfy { c in
                ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
            }
        }
    }

    // MARK: - HTTP (mirrors `fetch_advisory_with`)

    /// Fetch one advisory. Returns nil on 404/429/403/parse-fail (skip and
    /// continue) or any network error — every failure is best-effort.
    static func fetchAdvisory(
        _ ghsaId: String,
        token: String?,
        session: URLSession,
        apiBase: String
    ) async -> GhsaAdvisory? {
        guard let url = URL(string: "\(apiBase)/advisories/\(ghsaId)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: httpTimeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200: break
        case 404, 429, 403: return nil // withdrawn / rate limited → skip
        default: return nil
        }
        guard data.count <= maxResponseBytes else { return nil }
        return parseAdvisory(data)
    }

    /// Decode the api.github.com advisory body into our merge shape. Tolerant
    /// of missing/extra fields (forward-compat). nil on un-parseable JSON.
    static func parseAdvisory(_ data: Data) -> GhsaAdvisory? {
        guard let raw = try? JSONDecoder().decode(RawAdvisory.self, from: data) else { return nil }
        let refs = raw.references.map(\.url).filter { !$0.isEmpty }
        let firstPatched = raw.vulnerabilities
            .compactMap { $0.firstPatchedVersion }
            .first { !$0.isEmpty }
        return GhsaAdvisory(
            summary: raw.summary,
            description: raw.description,
            severity: raw.severity,
            references: refs,
            firstPatchedVersion: firstPatched
        )
    }

    static let userAgent = "brew-browser (+https://github.com/msitarzewski/brew-browser)"

    /// `<App Support>/brew-browser/ghsa_cache.json` — the same path the Tauri
    /// app uses (`dirs::data_dir()/brew-browser`), so the two share the cache.
    static func defaultCacheDir() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("brew-browser", isDirectory: true)
    }
}

// MARK: - Wire shapes (api.github.com advisory response)

/// Tolerant decode of the advisory response — every field optional-with-default
/// so a future api.github.com schema change can't break the scan.
struct RawAdvisory: Decodable {
    var summary = ""
    var description = ""
    var severity = ""
    var references: [RawReference] = []
    var vulnerabilities: [RawVulnerableProduct] = []

    enum CodingKeys: String, CodingKey { case summary, description, severity, references, vulnerabilities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        severity = (try? c.decode(String.self, forKey: .severity)) ?? ""
        references = (try? c.decode([RawReference].self, forKey: .references)) ?? []
        vulnerabilities = (try? c.decode([RawVulnerableProduct].self, forKey: .vulnerabilities)) ?? []
    }
    // Test/seam initializer.
    init(summary: String = "", description: String = "", severity: String = "",
         references: [RawReference] = [], vulnerabilities: [RawVulnerableProduct] = []) {
        self.summary = summary; self.description = description; self.severity = severity
        self.references = references; self.vulnerabilities = vulnerabilities
    }
}

/// A reference from the advisory API. The global advisories endpoint returns
/// `references` as an array of plain URL **strings** — not `[{ "url": … }]`
/// objects (an earlier assumption that silently dropped all references).
/// Decodes BOTH shapes so neither endpoint variant breaks enrichment.
struct RawReference: Decodable {
    let url: String
    enum CodingKeys: String, CodingKey { case url }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            url = s
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = (try? c.decode(String.self, forKey: .url)) ?? ""
        }
    }
}
struct RawVulnerableProduct: Decodable {
    var firstPatchedVersion: String?
    enum CodingKeys: String, CodingKey { case firstPatchedVersion = "first_patched_version" }
}

// MARK: - Merge shape + cache (mirrors enrich.rs GhsaAdvisory / GhsaCache)

/// The advisory fields we actually merge. camelCase keys match the Tauri
/// on-disk shape so the shared `ghsa_cache.json` round-trips between apps.
struct GhsaAdvisory: Codable, Equatable, Sendable {
    var summary: String = ""
    var description: String = ""
    var severity: String = ""
    var references: [String] = []
    var firstPatchedVersion: String?
}

struct GhsaCacheEntry: Codable, Sendable {
    var fetchedAt: Date
    var advisory: GhsaAdvisory

    enum CodingKeys: String, CodingKey { case fetchedAt, advisory }
    init(fetchedAt: Date, advisory: GhsaAdvisory) {
        self.fetchedAt = fetchedAt; self.advisory = advisory
    }
    // fetchedAt is an RFC3339 string on disk (chrono `DateTime<Utc>` shape).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .fetchedAt)
        guard let date = GhsaCache.parseDate(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .fetchedAt, in: c,
                debugDescription: "unparseable fetchedAt: \(raw)")
        }
        fetchedAt = date
        advisory = try c.decode(GhsaAdvisory.self, forKey: .advisory)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(GhsaCache.formatDate(fetchedAt), forKey: .fetchedAt)
        try c.encode(advisory, forKey: .advisory)
    }
}

struct GhsaCacheFile: Codable, Sendable {
    var schemaVersion: Int = VulnsEnrich.schemaVersion
    var entries: [String: GhsaCacheEntry] = [:]
    var fetchCount: Int = 0
}

/// In-memory cache wrapper with a dirty flag so writes batch after a scan.
struct GhsaCache {
    var file: GhsaCacheFile
    var dirty: Bool

    static func newEmpty() -> GhsaCache {
        GhsaCache(file: GhsaCacheFile(schemaVersion: VulnsEnrich.schemaVersion), dirty: false)
    }

    static func path(dir: URL) -> URL { dir.appendingPathComponent("ghsa_cache.json") }

    /// Fail-soft load: missing/oversize/corrupt/future-schema → empty.
    static func load(dir: URL?) -> GhsaCache {
        guard let dir else { return newEmpty() }
        let url = path(dir: dir)
        guard let data = try? Data(contentsOf: url),
              data.count <= 2 * 1024 * 1024,
              let file = try? JSONDecoder().decode(GhsaCacheFile.self, from: data) else {
            return newEmpty()
        }
        if file.schemaVersion > VulnsEnrich.schemaVersion { return newEmpty() }
        return GhsaCache(file: file, dirty: false)
    }

    func saveIfDirty(dir: URL?) {
        guard dirty, let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file), data.count <= 2 * 1024 * 1024 else { return }
        try? data.write(to: Self.path(dir: dir), options: .atomic)
    }

    /// Fresh (within TTL) advisory for `ghsaId`, else nil.
    func getFresh(_ ghsaId: String) -> GhsaAdvisory? {
        guard let entry = file.entries[ghsaId] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < VulnsEnrich.cacheTTL else { return nil }
        return entry.advisory
    }

    /// Insert/replace, evicting the oldest entry by `fetchedAt` at the cap.
    mutating func put(_ ghsaId: String, _ advisory: GhsaAdvisory) {
        if file.entries[ghsaId] == nil, file.entries.count >= VulnsEnrich.cacheMaxEntries {
            if let oldest = file.entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                file.entries.removeValue(forKey: oldest)
            }
        }
        file.entries[ghsaId] = GhsaCacheEntry(fetchedAt: Date(), advisory: advisory)
        file.fetchCount += 1
        dirty = true
    }

    // RFC3339 helpers — match chrono's `DateTime<Utc>` JSON so the cache file
    // is shared with the Tauri app. Encode with fractional seconds; decode
    // tolerant of presence/absence of them. Formatters are built per-call:
    // ISO8601DateFormatter isn't Sendable, so it can't be a shared static
    // under Swift 6 strict concurrency, and the cost is negligible here.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
    static func formatDate(_ date: Date) -> String {
        makeFormatter(fractional: true).string(from: date)
    }
    static func parseDate(_ raw: String) -> Date? {
        makeFormatter(fractional: true).date(from: raw) ?? makeFormatter(fractional: false).date(from: raw)
    }
}
