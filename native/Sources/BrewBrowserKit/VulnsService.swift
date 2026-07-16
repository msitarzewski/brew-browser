import Foundation

// MARK: - Severity

/// Vulnerability severity, ordered by *risk* (Comparable): a higher
/// `<` ordering means more dangerous, so `findings.max()` yields the
/// worst finding and `.critical > .low`.
///
/// The raw values are the lowercase, in-app canonical form. They are
/// deliberately NOT used to decode the wire format — `brew vulns`
/// ships UPPERCASE strings (`"CRITICAL"`, `"MODERATE"`, …). See
/// ``init(wire:)`` for the case-folding mapper (GOTCHA #2).
enum VulnSeverity: String, Sendable, Comparable, Codable {
    case critical
    case high
    case medium
    case low
    case unknown

    /// Risk rank — higher is worse. Drives `Comparable` so `max()` /
    /// sorting surface the most dangerous finding first. `unknown` is
    /// the floor so an unrecognized level never masquerades as severe.
    private var risk: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .unknown: return 0
        }
    }

    static func < (lhs: VulnSeverity, rhs: VulnSeverity) -> Bool {
        lhs.risk < rhs.risk
    }

    /// GOTCHA #2 — wire severity is UPPERCASE (`"CRITICAL"`, `"HIGH"`,
    /// `"MEDIUM"`, `"LOW"`, `"UNKNOWN"`) and GHSA uses `"MODERATE"`
    /// where OSV uses `"MEDIUM"`. `rawValue` alone can't decode this
    /// (Swift's raw-value init is case-sensitive), so we case-fold once
    /// at the boundary and map `moderate → medium`. Anything we don't
    /// recognize (or `nil`) becomes `.unknown` rather than failing the
    /// whole scan — mirrors the Rust `#[serde(other)]` catch-all in
    /// `src-tauri/src/vulns/client.rs::Severity`.
    init(wire: String?) {
        switch wire?.lowercased() {
        case "critical": self = .critical
        case "high": self = .high
        case "medium", "moderate": self = .medium
        case "low": self = .low
        default: self = .unknown
        }
    }
}

// MARK: - Public finding

/// One canonical vulnerability finding for a package. This is the
/// in-app shape the UI consumes — the noisy/uppercase/array-shaped
/// wire format is normalized into this at the parse boundary (see
/// ``VulnsService`` decoding). Mirrors the Rust `RawVuln` post-mapping
/// shape (camelCase, scalar `fixedIn`, lowercased severity).
struct VulnFinding: Identifiable, Sendable, Hashable, Codable {
    /// Stable identity for SwiftUI lists. The CVE/GHSA/OSV id when the
    /// upstream entry has one; otherwise a synthesized fallback so a
    /// rare id-less entry still renders distinctly instead of colliding.
    var id: String
    /// The id exactly as it arrived on the wire (may be empty).
    let rawId: String
    let severity: VulnSeverity
    let summary: String
    let details: String
    /// First patched version/commit (GOTCHA #3 — wire sends an array).
    let fixedIn: String?
    let references: [String]
    let published: String?
}

// MARK: - Severity rollup

/// Per-severity counts plus the worst severity present, derived from a
/// list of findings. Useful for the sidebar badge tone, dashboard
/// exposure bar, and per-row dot — the native analogues of the
/// frontend `SeverityCounts` rollup.
struct VulnSummary: Sendable, Hashable, Codable {
    var critical = 0
    var high = 0
    var medium = 0
    var low = 0
    var unknown = 0

    /// Total findings across all severities.
    var total: Int { critical + high + medium + low + unknown }

    /// The most dangerous severity present, or `nil` when there are no
    /// findings (a positive "clean" signal, distinct from "not scanned").
    var maxSeverity: VulnSeverity?

    /// Derive counts + max severity from a finding list. `max()` uses
    /// `VulnSeverity`'s risk-ordered `Comparable`.
    static func from(_ findings: [VulnFinding]) -> VulnSummary {
        var summary = VulnSummary()
        for finding in findings {
            switch finding.severity {
            case .critical: summary.critical += 1
            case .high: summary.high += 1
            case .medium: summary.medium += 1
            case .low: summary.low += 1
            case .unknown: summary.unknown += 1
            }
        }
        summary.maxSeverity = findings.map(\.severity).max()
        return summary
    }
}

// MARK: - Install-wide exposure rollup

/// Aggregate severity counts across an entire install, plus the count of
/// packages with at least one finding. The native analogue of the frontend
/// `SeverityCounts` rollup (`vulnerabilities.svelte.ts`) — distinct from
/// ``VulnSummary`` (one package) in carrying `vulnerablePackages` (a
/// per-package, not per-finding, count). Backs the Dashboard Exposure card.
struct VulnExposure: Sendable, Hashable {
    var critical = 0
    var high = 0
    var medium = 0
    var low = 0
    var unknown = 0
    /// Count of packages with ≥1 finding (NOT a finding total). Mirrors the
    /// Tauri `SeverityCounts.vulnerablePackages`.
    var vulnerablePackages = 0

    /// Total findings across all severities.
    var total: Int { critical + high + medium + low + unknown }
}

// MARK: - Errors

/// Errors surfaced by ``VulnsService``. Its own type (not `BrewService`'s
/// `BrewError`) so a vulns failure is distinguishable at the call site —
/// `.brewNotFound` here is the honest "no Homebrew" signal where the old
/// code fabricated a default brew path and mis-probed instead.
enum VulnsServiceError: Error, LocalizedError {
    case brewNotFound
    /// Real scan failure — exit code ≥ 2 (exit 0/1 are NOT failures, see
    /// GOTCHA #1).
    case scanFailed(code: Int32, stderr: String)
    case installFailed(code: Int32, stderr: String)
    case decodeFailed(String)
    case invalidFormulaName(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            if L10n.isRussian {
                return "Не удалось найти исполняемый файл brew. Установлен ли Homebrew?"
            }
            return "Couldn't find the brew executable. Is Homebrew installed?"
        case let .scanFailed(code, stderr):
            if L10n.isRussian {
                return "brew vulns завершился с кодом \(code): \(stderr)"
            }
            return "brew vulns failed (exit \(code)): \(stderr)"
        case let .installFailed(code, stderr):
            if L10n.isRussian {
                return "brew install brew-vulns завершился с кодом \(code): \(stderr)"
            }
            return "brew install brew-vulns failed (exit \(code)): \(stderr)"
        case let .decodeFailed(message):
            if L10n.isRussian {
                return "Не удалось разобрать вывод brew vulns: \(message)"
            }
            return "Couldn't parse brew vulns output: \(message)"
        case let .invalidFormulaName(name):
            if L10n.isRussian {
                return "Некорректное имя формулы: \(name)"
            }
            return "Invalid formula name: \(name)"
        case let .spawnFailed(message):
            if L10n.isRussian {
                return "Не удалось запустить brew: \(message)"
            }
            return "Couldn't launch brew: \(message)"
        }
    }
}

// MARK: - Service

/// Subprocess wrapper around the official `brew vulns` subcommand —
/// the native analogue of `src-tauri/src/vulns/client.rs`. Shells out
/// to brew-vulns (by Andrew Nesbitt, `Homebrew/homebrew-brew-vulns`)
/// rather than re-implementing the OSV query layer, so we inherit
/// upstream fixes automatically.
///
/// A plain `Sendable` struct (not an `actor`): it holds no mutable state —
/// just the resolved brew path plus read-only scan/parse methods. As an
/// actor, every `scanOne` SERIALIZED on the single actor instance, so the
/// install-wide sweep ran `brew vulns` one formula at a time (~331 calls
/// back-to-back). As a struct, those subprocess calls run in PARALLEL, the
/// same fix already applied to `BrewService`/`GitHubService`.
struct VulnsService: Sendable {
    /// Canonical install command for `brew vulns`, surfaced verbatim by
    /// the install affordance. Pinned (matches the Rust
    /// `BREW_VULNS_INSTALL_CMD`).
    static let installCommand = "brew install homebrew/brew-vulns/brew-vulns"

    /// Resolved path to the brew binary, or nil when no Homebrew install was
    /// found. Internal (not private) so tests can assert it mirrors the shared
    /// resolver exactly — a nil resolution must stay nil, never be papered
    /// over with a fabricated default path (the old `/opt/homebrew/bin/brew`
    /// fallback silently mis-probed Intel/brew-less machines).
    let brewPath: String?

    /// Inject a resolved brew path (testing / explicit configuration).
    /// nil = "no brew" — every scan/probe call then surfaces `.brewNotFound`.
    init(brewPath: String?) {
        self.brewPath = brewPath
    }

    /// Resolve via the shared `BrewService.resolveBrewPath()` (Apple-Silicon
    /// prefix, then Intel). Non-throwing so it can be a stored property; a nil
    /// resolution is kept as-is and surfaces as `.brewNotFound` at call time.
    init() {
        self.brewPath = BrewService.resolveBrewPath()
    }

    // MARK: Install detection

    /// GOTCHA #4 — probe install via `brew --prefix brew-vulns`, NOT
    /// `brew commands`. brew-vulns ships as a *formula* whose
    /// `bin/brew-vulns` shim becomes a `brew vulns` external subcommand
    /// via PATH dispatch; `brew commands` enumerates built-in and
    /// tap-resident subcommands but NOT external `brew-FOO` formula
    /// binaries, so it reports a correctly-installed brew-vulns as
    /// missing. `brew --prefix brew-vulns` is a clean status-code probe:
    /// exit 0 = installed, any non-zero (e.g. "No available formula") =
    /// not installed — matches the Rust `output.status.success()` check.
    func isBrewVulnsInstalled() async -> Bool {
        guard let result = try? run(["--prefix", "brew-vulns"]) else {
            return false
        }
        return result.exitCode == 0
    }

    // MARK: Scanning

    /// Scan a single package for known vulnerabilities.
    ///
    /// `isCask` is intentionally a plain `Bool` (self-contained — no
    /// dependency on the app's package-kind type). brew-vulns is
    /// formula-only (it queries OSV via source-repo URLs, which casks
    /// lack), so a cask scan short-circuits to an empty result — the
    /// honest "no coverage" signal, never a fake clean state.
    func scanOne(name: String, isCask: Bool) async throws -> [VulnFinding] {
        guard !isCask else { return [] }
        try Self.validateFormulaName(name)

        // GOTCHA #5 — modern brew is noisy without `--quiet`; pass it so
        // progress chatter on stderr doesn't interfere.
        let result = try run(["vulns", "--quiet", "--json", "--formula", name])

        // GOTCHA #1 — `brew vulns --json` exits 1 when findings ARE
        // present (CI-scanner convention: 0 = clean, 1 = findings,
        // ≥2 = real error). Accept exit 0 OR 1 and keep stdout; only
        // exit ≥2 is a genuine failure. Without this we'd throw away the
        // JSON for every package that actually has vulnerabilities.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw VulnsServiceError.scanFailed(code: result.exitCode, stderr: result.stderr)
        }

        let records = try Self.parseScanOutput(result.stdout)
        // brew vulns IGNORES --formula and returns the whole install set, so we
        // must keep only the requested formula's record — otherwise the detail
        // card shows every other package's CVEs (boost/icu/jxl/…) under this one.
        // brew vulns may echo a tap-qualified name under its bare form (or
        // vice-versa), so match the exact name OR the last `/`-segment (#92).
        let wantTail = name.split(separator: "/").last.map(String.init) ?? name
        return records.first(where: {
            $0.formula == name
                || $0.formula.split(separator: "/").last.map(String.init) == wantTail
        })?.findings ?? []
    }

    /// Scan the WHOLE install set in ONE `brew vulns --json` call (no
    /// `--formula`), exactly like the Tauri `scan_all`. This matches Tauri's
    /// result set — letting brew-vulns pick which packages to scan — instead of
    /// force-scanning every installed formula (deps included) one at a time,
    /// which both over-reports and is ~331× slower. Returns name → per-package
    /// rollup for packages brew-vulns reported on.
    func scanAll() async throws -> [String: [VulnFinding]] {
        let result = try run(["vulns", "--quiet", "--json"])
        // Same exit-1-is-findings convention as scanOne (GOTCHA #1).
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw VulnsServiceError.scanFailed(code: result.exitCode, stderr: result.stderr)
        }
        // Per-package findings — the detail card reads this cache so it never has
        // to re-run a (whole-install) scan just to show one package.
        return try Self.parseScanOutputKeyed(result.stdout)
    }

    /// Parse a `brew vulns --json` payload and key findings by `formula` — the
    /// exact transform `scanAll` performs. Exposed (internal) for tests: this
    /// is where the "attribute each finding to the right package, never smear
    /// the whole set onto every formula" contract lives — the bug behind the
    /// 1500-CVE over-report. Mirrors the Rust keying in `vulns::client`.
    static func parseScanOutputKeyed(_ raw: String) throws -> [String: [VulnFinding]] {
        var out: [String: [VulnFinding]] = [:]
        for record in try parseScanOutput(raw) where !record.formula.isEmpty {
            out[record.formula] = record.findings
        }
        return out
    }

    /// Install the `brew vulns` subcommand via
    /// `brew install homebrew/brew-vulns/brew-vulns`. Returns captured
    /// stdout (install progress) for surfacing in an activity view.
    ///
    /// GOTCHA #5 — `--quiet` keeps modern brew's install chatter down.
    /// Plain `brew install` is NOT exit-1-tolerant: a non-zero here is a
    /// genuine install failure that should surface.
    func installHelper() async throws -> String {
        let result = try run(["install", "--quiet", "homebrew/brew-vulns/brew-vulns"])
        guard result.exitCode == 0 else {
            throw VulnsServiceError.installFailed(code: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }

    // NOTE: on-disk cache would slot here — a `scanAll` + an install-set
    // fingerprint (SHA-256 over sorted `kind:name:version`) gating a
    // disk-backed `[VulnKey: [VulnFinding]]`, mirroring the Rust
    // `vulns::cache`. Intentionally omitted for now; every `scanOne`
    // currently re-shells `brew vulns`.

    // MARK: - Subprocess

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run brew with the given args and capture exit code + stdout +
    /// stderr. `currentDirectoryURL` is pinned to "/" (the cwd must be
    /// readable — pinning a guaranteed-readable directory dodges a spawn
    /// failure when the launching process's cwd is gone/unreadable).
    ///
    /// Returns the exit code rather than throwing on non-zero so callers
    /// can apply the right exit-code policy per command (GOTCHA #1: scans
    /// treat exit 1 as success; install does not).
    private func run(_ args: [String]) throws -> ProcessResult {
        guard let brewPath else { throw VulnsServiceError.brewNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw VulnsServiceError.spawnFailed(error.localizedDescription)
        }

        // Drain before waiting so a large payload can't deadlock on a
        // full pipe buffer.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    // MARK: - Parsing

    /// One `brew vulns --json` scan record for a single formula. The
    /// `findings` array is empty when the formula was scanned and
    /// nothing was found (a "clean at this version" signal).
    private struct ScanRecord: Decodable {
        let formula: String
        let version: String
        let findings: [VulnFinding]

        private enum CodingKeys: String, CodingKey {
            case formula, version
            case vulnerabilities
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formula = (try? c.decode(String.self, forKey: .formula)) ?? ""
            version = (try? c.decode(String.self, forKey: .version)) ?? ""
            let raw = (try? c.decode([WireVuln].self, forKey: .vulnerabilities)) ?? []
            findings = raw.map(\.canonical)
        }
    }

    /// Wire shape of one entry under `vulnerabilities`. Decodes the raw
    /// brew-vulns JSON (uppercase severity, `fixed_versions` array,
    /// nullable `summary`) and maps it to the canonical ``VulnFinding``.
    private struct WireVuln: Decodable {
        let id: String
        let severity: VulnSeverity
        let summary: String
        let details: String
        let fixedIn: String?
        let references: [String]
        let published: String?

        private enum CodingKeys: String, CodingKey {
            case id, severity, summary, details, references, published
            case fixedVersions = "fixed_versions"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            id = (try? c.decode(String.self, forKey: .id)) ?? ""

            // GOTCHA #2 — decode severity as a raw string then case-fold
            // via `VulnSeverity(wire:)`; never rely on the rawValue init.
            let severityWire = try? c.decode(String.self, forKey: .severity)
            severity = VulnSeverity(wire: severityWire)

            // `summary` arrives as explicit `null` for un-summarized
            // entries → map to "" for ergonomic display.
            summary = (try? c.decodeIfPresent(String.self, forKey: .summary).flatMap { $0 }) ?? ""
            details = (try? c.decodeIfPresent(String.self, forKey: .details).flatMap { $0 }) ?? ""

            // GOTCHA #3 — wire field is `fixed_versions`, an ARRAY of
            // strings (often empty, sometimes commit hashes / tags).
            // Surface the FIRST element as a scalar `fixedIn` ("earliest
            // patch wins"). Defensive: also accept a bare string in case
            // a future brew-vulns release flips the shape back to scalar.
            // Empty array / missing / null → nil.
            fixedIn = Self.firstFixedVersion(c)

            references = (try? c.decode([String].self, forKey: .references)) ?? []
            published = (try? c.decodeIfPresent(String.self, forKey: .published).flatMap { $0 })
        }

        /// GOTCHA #3 helper — pull the first non-empty patched version
        /// out of the `fixed_versions` array, tolerating a scalar-string
        /// fallback for forward-compat.
        private static func firstFixedVersion(_ c: KeyedDecodingContainer<CodingKeys>) -> String? {
            if let arr = try? c.decode([String].self, forKey: .fixedVersions) {
                return arr.first { !$0.isEmpty }
            }
            if let scalar = try? c.decode(String.self, forKey: .fixedVersions), !scalar.isEmpty {
                return scalar
            }
            return nil
        }

        /// Map to the canonical public finding, synthesizing an `id`
        /// when the wire entry has none (rare) so SwiftUI list identity
        /// stays stable and non-colliding.
        var canonical: VulnFinding {
            let resolvedId = id.isEmpty
                ? "vuln-\(severity.rawValue)-\(abs(summary.hashValue))"
                : id
            return VulnFinding(
                id: resolvedId,
                rawId: id,
                severity: severity,
                summary: summary,
                details: details,
                fixedIn: fixedIn,
                references: references,
                published: published
            )
        }
    }

    /// Parse `brew vulns --json` output. Expected shape is an array of
    /// records; we also accept a single object (defensive, mirrors the
    /// Rust fallback) and treat empty/whitespace output as "no results".
    private static func parseScanOutput(_ raw: String) throws -> [ScanRecord] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Fast path: the whole stdout is the JSON document (the common case).
        if let records = decodeRecords(trimmed) {
            return records
        }
        // Salvage: older brew / brew-vulns can print a banner or notice on
        // stdout around the `--json` document (issue #62 — `whatcable` on brew
        // 5.1.15). Slice the JSON document out of the surrounding line-oriented
        // noise and retry. Mirrors the Rust `extract_json_document`.
        if let slice = extractJSONDocument(trimmed) {
            if let records = decodeRecords(slice) {
                return records
            }
            // A JSON-looking payload was present but malformed → surface it.
            throw VulnsServiceError.decodeFailed("output starts: \(String(trimmed.prefix(400)))")
        }
        // No JSON structure at all on a clean exit (already past the exit-≥2
        // gate in the caller). Treat as "nothing to report" rather than a
        // scary decode error — consistent with scanAll silently omitting
        // unsupported-forge formulae (issue #62).
        return []
    }

    /// Decode both documented shapes: an array (the norm) then a single object
    /// (defensive fallback). `nil` if the input isn't valid JSON in either shape.
    private static func decodeRecords(_ s: String) -> [ScanRecord]? {
        guard let data = s.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([ScanRecord].self, from: data) {
            return array
        }
        if let single = try? decoder.decode(ScanRecord.self, from: data) {
            return [single]
        }
        return nil
    }

    /// Extract the JSON document from line-oriented CLI noise: from the first
    /// line that (left-trimmed) starts with `[`/`{` to the last line that
    /// (right-trimmed) ends with `]`/`}`. Line-granular so a stray bracket in a
    /// mid-sentence warning doesn't derail extraction. `nil` when no such
    /// bracketed block exists. Mirrors the Rust `extract_json_document`.
    static func extractJSONDocument(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n")
        let ws = CharacterSet(charactersIn: " \t")
        guard
            let start = lines.firstIndex(where: {
                let t = $0.trimmingCharacters(in: ws)
                return t.first == "[" || t.first == "{"
            }),
            let end = lines.lastIndex(where: {
                let t = $0.trimmingCharacters(in: ws)
                return t.last == "]" || t.last == "}"
            }),
            start <= end
        else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    /// Validate a formula name before passing it to `brew vulns
    /// --formula`. Defense-in-depth against shell-meta injection even
    /// though `Process`/argv is already injection-safe — mirrors the
    /// Rust `validate_formula_name`.
    static func validateFormulaName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 128 else {
            throw VulnsServiceError.invalidFormulaName(name)
        }
        // Allow `/` so tap-qualified names (`user/repo/name`) pass — brew vulns
        // accepts them and users scan formulae from third-party taps (issue #92,
        // `anomalyco/tap/opencode`). Process/argv is injection-safe and the
        // vulns cache keys names into a map, NOT a path, so `/` adds no risk;
        // the structure guard below keeps it tight. Mirrors the Rust validator.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+@./")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw VulnsServiceError.invalidFormulaName(name)
        }
        // A tap-qualified name is exactly `user/repo/name` (2 slashes); a bare
        // name has none. Reject anything else — empty segments, leading/trailing
        // slash, `a//b`, `.`/`..` path segments, or deeper paths.
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        let wellFormed = (segments.count == 1 || segments.count == 3)
            && segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard wellFormed else {
            throw VulnsServiceError.invalidFormulaName(name)
        }
    }
}
