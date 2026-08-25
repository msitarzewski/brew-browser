import Foundation

/// Thin async wrapper over the `brew` CLI — the Swift equivalent of the Rust
/// `brew::exec` module. Every action shells out to `brew`; we never parse
/// formula files or touch the prefix ourselves. brew owns all of that.
///
/// Spike scope: just `list --versions`. The streaming-line design generalizes
/// to install/upgrade/search (the long-running, live-output commands) without
/// changing shape — the same `runStreaming` powers them in the full port.
struct InstalledPackage: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let version: String
    let kind: Kind
    /// Whether brew records this package as installed *on request* (the user ran
    /// `brew install foo`), vs pulled in only as a dependency. Tagged at load
    /// time from the `brew list --installed-on-request --formula` set (formulae)
    /// + the cask rule (all installed casks count as on-request). Drives the
    /// Manual vs Dependency Library filters. Defaults to `false` so the
    /// `list --versions` constructors stay valid before tagging. Feature #3.
    var installedOnRequest: Bool = false

    /// Whether brew has this package pinned (`brew pin`) — held back from
    /// `brew upgrade` (including `--greedy`). Read from the top-level `pinned`
    /// flag in `brew info --installed --json=v2` (both formulae and casks carry
    /// it in current Homebrew). Drives the Library "Pinned" badge and keeps a
    /// pinned package out of the honest "updates available" count (#90).
    /// Defaults `false` so the lightweight nav constructors stay valid.
    var pinned: Bool = false

    enum Kind: String, Sendable { case formula, cask }
}

/// An outdated package with its installed → current version transition,
/// mirroring the Tauri Dashboard's "Updates available" rows.
struct OutdatedPackage: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let installedVersion: String
    let currentVersion: String
    /// formula vs cask — taken from the `brew outdated --json=v2` array the row
    /// came from, so the Dashboard pill + detail open use the right kind.
    let kind: InstalledPackage.Kind
    /// `pinned` from `brew outdated --json=v2` (both formulae and casks in
    /// current Homebrew). `brew outdated --json` still *lists* pinned packages
    /// with `pinned: true`, so they're excluded from the curated upgrade sheet
    /// and the honest update count (#90). Mirrors the Tauri `Package.pinned`.
    var pinned: Bool = false
}

/// One Homebrew background service from `brew services list --json`, mirroring
/// the Tauri `Service` shape (`commands/services.rs`).
struct Service: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let status: Status
    let user: String?
    let file: String?
    let exitCode: Int?

    /// `none` (formula installed but not loaded for the user) is mapped to
    /// `.notLoaded` to avoid colliding with `Optional.none`.
    enum Status: String, Sendable {
        case started, stopped, error, scheduled, unknown
        case notLoaded = "none"
        init(raw: String) { self = Status(rawValue: raw) ?? .unknown }

        /// Display order on the Services list: running first, dead last (matches
        /// Tauri's sort — started → scheduled → error → stopped → none → unknown).
        var sortRank: Int {
            switch self {
            case .started: return 0
            case .scheduled: return 1
            case .error: return 2
            case .stopped: return 3
            case .notLoaded: return 4
            case .unknown: return 5
            }
        }

        /// True for states that count as "running" (badge + header tally).
        var isRunning: Bool { self == .started || self == .scheduled }
    }
}

/// The three service mutations, matching `brew services <verb> <name>`.
enum ServiceVerb: String, Sendable, CaseIterable {
    case start, stop, restart
    var verbLabel: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        }
    }
}

enum BrewError: Error, LocalizedError {
    case brewNotFound
    case nonZeroExit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Couldn't find the brew executable. Is Homebrew installed?"
        case let .nonZeroExit(code, stderr):
            return "brew exited with code \(code): \(stderr)"
        }
    }
}

/// Tracks live brew processes for cancellation. Its own actor so the registry
/// stays correct under concurrent runs — while `BrewService` itself is a plain
/// `Sendable` struct, so its read-only subprocess calls run in PARALLEL instead
/// of serializing on a single actor (that serialization made the dashboard's
/// ~8 brew calls run back-to-back, ~4s, gating first paint).
private actor ProcessRegistry {
    private var live: [UUID: Process] = [:]
    func register(_ p: Process, for id: UUID) { live[id] = p }
    func unregister(_ id: UUID) { live[id] = nil }
    func cancel(_ id: UUID) { live[id]?.terminate() }
}

/// Pure builders for the brew argv of each write action, the native mirror of
/// the Tauri `commands::actions` arg-builders (parity charter: same flag logic,
/// same data contract). Free of I/O so they're unit-testable without spawning
/// brew. The `--cask`/no-`--formula` convention matches the existing native
/// commands (brew defaults to a formula); the new flags are the additions.
enum BrewArgs {
    /// `brew install [--cask] <name> [--adopt] [--force]`. `--adopt` is cask-only
    /// and takes over a matching app already on disk instead of erroring with
    /// "It seems there is already an App at…" (#13/#102). `--force` overwrites.
    static func install(_ name: String, kind: InstalledPackage.Kind,
                        force: Bool = false, adopt: Bool = false) -> [String] {
        var args = ["install"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        if adopt && kind == .cask { args.append("--adopt") }
        if force { args.append("--force") }
        return args
    }

    /// `brew uninstall [--cask] <name> [--zap] [--ignore-dependencies]`.
    /// `--ignore-dependencies` forces removal even when another installed
    /// package still requires it — the in-app escape for "Refusing to
    /// uninstall … because it is required by…" (#100).
    static func uninstall(_ name: String, kind: InstalledPackage.Kind,
                          zap: Bool = false, ignoreDependencies: Bool = false) -> [String] {
        var args = ["uninstall"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        if zap && kind == .cask { args.append("--zap") }
        if ignoreDependencies { args.append("--ignore-dependencies") }
        return args
    }

    /// `brew pin [--cask] <name>` / `brew unpin [--cask] <name>`. Pinning holds
    /// a package back from `brew upgrade` (including `--greedy`) — the in-app
    /// "stop nagging me about this one" hold for #90/#134. Current Homebrew
    /// pins both formulae and casks, so the `--cask` flag disambiguates a name
    /// that exists as both. `pinned == true` pins; `false` unpins.
    static func setPinned(_ name: String, kind: InstalledPackage.Kind, pinned: Bool) -> [String] {
        var args = [pinned ? "pin" : "unpin"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        return args
    }

    /// Argv groups for a bundle "Install all" (M3). brew rejects mixing
    /// `--formula` and `--cask` in one invocation ("Options --cask and
    /// --formulae are mutually exclusive"), but takes many same-kind names at
    /// once — so we emit at most two groups: `["install","--formula",f1,f2,…]`
    /// then `["install","--cask",c1,c2,…]`. A group is omitted when it has no
    /// members (formulae-only bundles → one group; empty input → no groups).
    /// Each group is run as its own streaming Activity job by
    /// `AppModel.installBundle(_:)`. Input order is preserved within each kind.
    static func installBundle(_ packages: [BundlePackage]) -> [[String]] {
        let formulae = packages.filter { $0.kind != "cask" }.map(\.name)
        let casks    = packages.filter { $0.kind == "cask" }.map(\.name)
        var groups: [[String]] = []
        if !formulae.isEmpty { groups.append(["install", "--formula"] + formulae) }
        if !casks.isEmpty    { groups.append(["install", "--cask"] + casks) }
        return groups
    }
}

struct BrewService: Sendable {
    private let registry = ProcessRegistry()

    /// Resolve the brew binary the same way the Rust backend does: prefer the
    /// Apple-Silicon prefix, fall back to the Intel path, then bare PATH lookup.
    /// Internal (not private) — the single source of truth for "is Homebrew
    /// installed?": `VulnsService` resolves through it, and `AppModel`'s
    /// missing-Homebrew onboarding gate polls it. Returns nil when no install
    /// is found; callers must surface that, never substitute a fake path.
    static func resolveBrewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// Run a brew subcommand to completion and return captured stdout.
    /// `current_dir` is pinned to "/" to dodge the "cwd must be readable"
    /// failure the Linux build hit — harmless on macOS, future-proof.
    /// Environment for every `brew` subprocess this app spawns.
    ///
    /// `HOMEBREW_NO_ANALYTICS=1` disables Homebrew's own analytics so our
    /// automated brew calls never trigger its ping to Homebrew's InfluxDB
    /// endpoint (`*.influxdata.com`). Brew Browser sends no telemetry, and must
    /// not cause `brew` to send any on the user's behalf either — a user
    /// reported the startup `*.influxdata.com` connection, which was Homebrew's,
    /// fired because we shell out to `brew`. The user's OWN global brew-analytics
    /// preference (for manual CLI use) is untouched. `NO_COLOR`/`NO_ENV_HINTS`
    /// keep brew's terminal chatter out of captured/streamed output.
    /// See https://docs.brew.sh/Analytics.
    static func brewEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    /// Build the (executable, arguments) pair for a `brew` spawn, routing
    /// through `/usr/bin/arch -arm64` when this process runs under Rosetta 2
    /// against an arm-native Homebrew (`/opt/homebrew`). Without this, a
    /// translated (x86_64) process spawning arm `brew` fails with "Cannot
    /// install under Rosetta 2 in ARM default prefix" (issue #158). An Intel
    /// brew at `/usr/local` already matches the translated process, so it's
    /// left alone. Every brew spawn site goes through this.
    static func brewInvocation(brew: String, args: [String])
        -> (executable: URL, arguments: [String])
    {
        if SystemProfile.isTranslated() && brew.hasPrefix("/opt/homebrew") {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-arm64", brew] + args)
        }
        return (URL(fileURLWithPath: brew), args)
    }

    private func runCapture(_ args: [String]) async throws -> String {
        guard let brew = Self.resolveBrewPath() else { throw BrewError.brewNotFound }

        let process = Process()
        let invocation = Self.brewInvocation(brew: brew, args: args)
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = Self.brewEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Read pipes off the main actor; Process.run is synchronous-launch but
        // we await its termination without blocking the UI.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(decoding: errData, as: UTF8.self)
            throw BrewError.nonZeroExit(code: process.terminationStatus, stderr: err)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// One event from a streaming brew run — a line of output, or the terminal
    /// result. Lets the UI show live progress and surface failures instead of a
    /// dead spinner.
    enum StreamEvent: Sendable {
        /// A line of output. `isStderr` distinguishes the stream so the UI can
        /// style stderr (and the issue reporter can excerpt just stderr).
        case line(String, isStderr: Bool)
        case finished(exitCode: Int32)
    }

    /// Thread-safe newline splitter for the pipe read handler. The read +
    /// termination closures run on arbitrary queues, so the byte buffer lives
    /// in this locked reference type rather than a captured `var` (Swift 6
    /// Sendable-capture rules forbid the latter).
    private final class LineAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        /// Append a chunk, return any complete lines it produced.
        func append(_ chunk: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                out.append(String(decoding: lineData, as: UTF8.self))
            }
            return out
        }

        /// Final partial line (if any) at termination.
        func flush() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !buffer.isEmpty else { return nil }
            let s = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return s
        }
    }

    /// Live processes keyed by job id, so a running job can be cancelled
    /// Terminate a running job's brew process (SIGTERM). No-op if already gone.
    func cancel(jobId: UUID) async {
        await registry.cancel(jobId)
    }

    /// Run a brew subcommand and stream stdout+stderr line-by-line, finishing
    /// with the exit code. Critically, **stdin is /dev/null** — so if brew tries
    /// to prompt (e.g. a sudo password for a `.pkg` cask) it gets EOF and fails
    /// fast with a visible error rather than hanging forever on a TTY-less pipe.
    /// The process is registered under `jobId` so `cancel(jobId:)` can kill it.
    func runStreaming(jobId: UUID, _ args: [String]) -> AsyncStream<StreamEvent> {
        let registry = self.registry
        return AsyncStream { continuation in
            guard let brew = Self.resolveBrewPath() else {
                continuation.yield(.line("Error: couldn't find the brew executable.", isStderr: true))
                continuation.yield(.finished(exitCode: 127))
                continuation.finish()
                return
            }
            let process = Process()
            let invocation = Self.brewInvocation(brew: brew, args: args)
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            // No TTY/stdin: a sudo/interactive prompt gets EOF → brew errors out
            // visibly instead of blocking on a read that never returns.
            process.standardInput = FileHandle.nullDevice
            // Separate pipes so each line is tagged with its real stream. Each
            // pipe has its own readabilityHandler that continuously drains it, so
            // there's no deadlock from one buffer filling while we read the other
            // (ordering is by arrival, interleaved, the same as the Tauri engine).
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Tell brew not to expect a terminal (disables spinners/color that
            // would otherwise garble the streamed lines) and disable Homebrew's
            // own analytics ping (see brewEnvironment()).
            process.environment = Self.brewEnvironment()

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            // One accumulator per stream. Reference types with their own lock
            // satisfy Swift 6 Sendable capture rules (a captured `var Data`
            // can't cross the read + termination closures).
            let outAcc = LineAccumulator()
            let errAcc = LineAccumulator()
            outHandle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                for line in outAcc.append(chunk) {
                    continuation.yield(.line(line, isStderr: false))
                }
            }
            errHandle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                for line in errAcc.append(chunk) {
                    continuation.yield(.line(line, isStderr: true))
                }
            }
            process.terminationHandler = { proc in
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                if let tail = outAcc.flush() {
                    continuation.yield(.line(tail, isStderr: false))
                }
                if let tail = errAcc.flush() {
                    continuation.yield(.line(tail, isStderr: true))
                }
                continuation.yield(.finished(exitCode: proc.terminationStatus))
                continuation.finish()
                Task { await registry.unregister(jobId) }
            }
            do {
                try process.run()
                Task { await registry.register(process, for: jobId) }
            } catch {
                continuation.yield(.line("Error launching brew: \(error.localizedDescription)", isStderr: true))
                continuation.yield(.finished(exitCode: -1))
                continuation.finish()
            }
        }
    }

    /// `brew list --formula --versions` → [InstalledPackage].
    /// Output is one package per line: "name version1 version2 ...".
    /// We take the first version (the linked one) for display, matching the
    /// existing app's behavior.
    func listInstalledFormulae() async throws -> [InstalledPackage] {
        let raw = try await runCapture(["list", "--formula", "--versions"])
        return raw
            .split(separator: "\n")
            .compactMap { line -> InstalledPackage? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let version = parts.count > 1
                    ? String(parts[1].split(separator: " ").first ?? "")
                    : "—"
                return InstalledPackage(name: String(name), version: version, kind: .formula)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `brew list --cask --versions` → [InstalledPackage] of kind `.cask`.
    /// Same line shape as the formula lister: "name version1 version2 …".
    func listInstalledCasks() async throws -> [InstalledPackage] {
        let raw = try await runCapture(["list", "--cask", "--versions"])
        return raw
            .split(separator: "\n")
            .compactMap { line -> InstalledPackage? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let version = parts.count > 1
                    ? String(parts[1].split(separator: " ").first ?? "")
                    : "—"
                return InstalledPackage(name: String(name), version: version, kind: .cask)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All installed packages — formulae + casks — merged and name-sorted.
    /// Mirrors Tauri's `brew_list`: `brew info --installed --json=v2`.
    /// This survives Homebrew 6's untrusted-cask-tap guard better than
    /// `brew list --cask --versions`, and carries formula `installed_on_request`
    /// so the Manual/Dependency filters do not need a second brew call.
    func listInstalledAll() async throws -> [InstalledPackage] {
        let raw = try await runCapture(["info", "--installed", "--json=v2"])
        return try Self.parseInstalledInfoV2(raw)
    }

    static func parseInstalledInfoV2(_ raw: String) throws -> [InstalledPackage] {
        let data = Data(raw.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrewError.nonZeroExit(code: -1, stderr: "Unparseable brew info --installed JSON")
        }

        let formulae = (root["formulae"] as? [[String: Any]] ?? []).compactMap { o -> InstalledPackage? in
            guard let name = o["name"] as? String else { return nil }
            let installed = o["installed"] as? [[String: Any]]
            let first = installed?.first
            let version = first?["version"] as? String
                ?? ((o["versions"] as? [String: Any])?["stable"] as? String)
                ?? "—"
            let onRequest = first?["installed_on_request"] as? Bool ?? false
            let pinned = o["pinned"] as? Bool ?? false
            return InstalledPackage(name: name, version: version, kind: .formula,
                                    installedOnRequest: onRequest, pinned: pinned)
        }

        let casks = (root["casks"] as? [[String: Any]] ?? []).compactMap { o -> InstalledPackage? in
            guard let token = o["token"] as? String else { return nil }
            let installed = o["installed"] as? String
            let version = installed
                ?? o["version"] as? String
                ?? "—"
            let pinned = o["pinned"] as? Bool ?? false
            return InstalledPackage(name: token, version: version, kind: .cask,
                                    installedOnRequest: true, pinned: pinned)
        }

        return (formulae + casks)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Count of newline-delimited entries from a brew subcommand, ignoring
    /// blank lines. Used for the cheap "how many X" Dashboard stats.
    private func lineCount(_ args: [String]) async throws -> Int {
        let raw = try await runCapture(args)
        return raw.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    func countCasks() async throws -> Int { try await lineCount(["list", "--cask"]) }

    func countFormulae() async throws -> Int { try await lineCount(["list", "--formula"]) }

    /// Explicitly-installed formulae (not pulled in as dependencies).
    func countLeaves() async throws -> Int { try await lineCount(["leaves"]) }

    /// Formulae the user explicitly requested (`brew install foo`), vs pulled
    /// in as dependencies. Mirrors the Tauri "N on request" chip.
    func countOnRequest() async throws -> Int {
        try await lineCount(["list", "--installed-on-request", "--formula"])
    }

    /// Set of formula names the user explicitly requested, from
    /// `brew list --installed-on-request --formula`. Parallel to `countOnRequest`
    /// (same brew call), but returns the names so `loadLibrary` can tag each
    /// `InstalledPackage.installedOnRequest`. Drives the Manual/Dependency Library
    /// filters. Feature #3.
    func listOnRequestFormulae() async throws -> Set<String> {
        let raw = try await runCapture(["list", "--installed-on-request", "--formula"])
        return BrewService.parseNameSet(raw)
    }

    /// Parse newline-delimited brew output into a name `Set`, skipping blank
    /// lines — same line handling as `lineCount`. Static + pure so it can be
    /// unit-tested without shelling out (mirrors the Rust parse tests).
    static func parseNameSet(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty })
    }

    /// Tag each installed package with `installedOnRequest`, given the on-request
    /// formula name set from `listOnRequestFormulae`. Casks are always treated as
    /// on-request (matching Tauri parse.rs:393-394, which sets on_request=true for
    /// every installed cask); formulae are on-request only if present in the set.
    /// Static + pure for unit testing. Feature #3.
    static func taggingOnRequest(
        _ packages: [InstalledPackage],
        onRequest: Set<String>
    ) -> [InstalledPackage] {
        packages.map { pkg in
            var p = pkg
            p.installedOnRequest = pkg.kind == .cask || onRequest.contains(pkg.name)
            return p
        }
    }

    /// Count of running brew services (`brew services list`, status "started"/
    /// "scheduled"). Powers the Services sidebar badge. Best-effort: 0 on error.
    func countRunningServices() async -> Int {
        guard let raw = try? await runCapture(["services", "list"]) else { return 0 }
        // Skip the header line; a service is "running" if its 2nd column is
        // started or scheduled.
        return raw.split(separator: "\n").dropFirst().reduce(into: 0) { acc, line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2, cols[1] == "started" || cols[1] == "scheduled" { acc += 1 }
        }
    }

    /// Full background-service list via `brew services list --json` (mirrors the
    /// Tauri `services_list` command). Throws on a brew error or unparseable JSON.
    func servicesList() async throws -> [Service] {
        let raw = try await runCapture(["services", "list", "--json"])
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw BrewError.nonZeroExit(code: -1, stderr: "Unparseable brew services JSON") }
        return arr.compactMap { obj in
            guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
            return Service(
                name: name,
                status: Service.Status(raw: (obj["status"] as? String) ?? "unknown"),
                user: obj["user"] as? String,
                file: obj["file"] as? String,
                exitCode: obj["exit_code"] as? Int
            )
        }
    }

    /// Run `brew services <verb> <name>`. Quiet (no streaming); throws on a
    /// non-zero exit so the caller can surface the failure.
    func serviceAction(_ verb: ServiceVerb, name: String) async throws {
        _ = try await runCapture(["services", verb.rawValue, name])
    }

    /// brew version string, e.g. "5.1.14-112-g0d7d68d" (the build suffix kept).
    func version() async -> String {
        guard let raw = try? await runCapture(["--version"]) else { return "—" }
        // First line is "Homebrew 5.1.14-112-g0d7d68d"
        let first = raw.split(separator: "\n").first.map(String.init) ?? ""
        return first.replacingOccurrences(of: "Homebrew ", with: "")
    }

    /// The Homebrew prefix (e.g. /opt/homebrew).
    func prefix() async -> String {
        (try? await runCapture(["--prefix"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/opt/homebrew"
    }

    /// Outdated packages (formulae + casks). `brew outdated` prints one per line.
    func countOutdated() async throws -> Int { try await lineCount(["outdated"]) }

    /// Outdated formulae with installed → current versions, parsed from
    /// `brew outdated --json=v2`. Used for the Dashboard "Updates available"
    /// list. Best-effort decode: malformed JSON yields an empty list.
    func outdatedPackages() async throws -> [OutdatedPackage] {
        let raw = try await runCapture(["outdated", "--json=v2"])
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var out: [OutdatedPackage] = []
        for (key, kind): (String, InstalledPackage.Kind) in [("formulae", .formula), ("casks", .cask)] {
            guard let arr = root[key] as? [[String: Any]] else { continue }
            for item in arr {
                guard let name = item["name"] as? String else { continue }
                let installed = (item["installed_versions"] as? [String])?.first
                    ?? (item["installed_versions"] as? [Any])?.first as? String
                    ?? "?"
                let current = item["current_version"] as? String ?? "?"
                // `pinned` only appears on formulae; casks never carry it.
                let pinned = item["pinned"] as? Bool ?? false
                out.append(OutdatedPackage(name: name, installedVersion: installed, currentVersion: current, kind: kind, pinned: pinned))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bytes used by a directory, via `du -sk` (read-only, fast). Returns nil if
    /// the path is missing or du fails.
    private func dirSizeBytes(_ path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard let kb = text.split(separator: "\t").first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) })
            else { return nil }
            return kb * 1024
        } catch {
            return nil
        }
    }

    /// Full storage breakdown, mirroring the Tauri Storage card: Cellar,
    /// Caskroom, Logs, and the Homebrew download cache, each with its path.
    func storageBreakdown() async -> [StorageItem] {
        let prefix = await prefix()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries: [(String, String)] = [
            ("Formulae (Cellar)", "\(prefix)/Cellar"),
            ("Casks (Caskroom)", "\(prefix)/Caskroom"),
            ("Logs (var/log)", "\(prefix)/var/log"),
            ("Download cache", "\(home)/Library/Caches/Homebrew"),
        ]
        var items: [StorageItem] = []
        for (label, path) in entries {
            if let bytes = await dirSizeBytes(path) {
                items.append(StorageItem(label: label, path: path, bytes: bytes))
            }
        }
        return items
    }

    /// Dry-run `brew cleanup -n --prune=all` and parse the "would free
    /// approximately X" estimate. Best-effort: nil on any error or unparsable
    /// output — only feeds the cleanup-button hint (#80). Mirrors the Tauri
    /// `brew_cleanup_preview` command.
    func cleanupReclaimableBytes() async -> Int64? {
        guard let raw = try? await runCapture(["cleanup", "-n", "--prune=all"]) else { return nil }
        return BrewErrorPatterns.parseReclaimableBytes(raw)
    }
}

/// One row in the Storage breakdown.
struct StorageItem: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let path: String
    let bytes: Int64
}

/// Full single-package detail, mirroring the Tauri `PackageDetail` (types.rs:138)
/// as parsed from `brew info --json=v2`. Only the fields the native detail panel
/// renders are kept.
struct PackageInfo: Sendable, Hashable {
    let name: String
    let fullName: String
    let kind: InstalledPackage.Kind
    let installedVersion: String?
    let stableVersion: String?
    let desc: String?
    let homepage: String?
    /// The GitHub repo URL resolved from homepage → source URLs (not just the
    /// homepage field) — many packages have non-GitHub marketing homepages but
    /// GitHub-hosted source. nil when nothing resolves. Mirrors the Tauri
    /// `resolve_github_homepage` cascade (task #17). Drives the GitHub card.
    let githubHomepage: String?
    let license: String?
    let tap: String?
    let caveats: String?
    let outdated: Bool
    let pinned: Bool
    let dependencies: [String]
    let buildDependencies: [String]
    let conflictsWith: [String]
    /// Deprecation/disabled status from `brew info --json=v2` — the RICHER source
    /// that also carries the replacement token ("use X instead"), which the
    /// bundled catalog never has. Drives the detail panel's deprecation notice.
    /// Mirrors the Tauri `Package` deprecation fields. Default clean.
    var deprecation: DeprecationStatus = DeprecationStatus()
    /// On-disk size of the installed keg in bytes, from `du -sk` on
    /// `<prefix>/Cellar/<name>` (formula, all versions) or
    /// `<prefix>/Caskroom/<token>` (cask). nil when the package isn't installed
    /// or du fails — never fabricated. Computed lazily in `info()`, not by the
    /// static parsers. Mirrors the Tauri `installed_size_bytes` field (feature #4).
    var installedSizeBytes: Int64? = nil

    var isOutdated: Bool {
        guard let i = installedVersion, let s = stableVersion else { return outdated }
        return outdated || (i != s)
    }
}

extension BrewService {
    /// `brew info --json=v2 [--formula|--cask] <name>` → PackageInfo.
    /// Field names mirror `brew/parse.rs` / the Rust `to_detail` mapping.
    func info(name: String, kind: InstalledPackage.Kind) async throws -> PackageInfo {
        let kindFlag = kind == .cask ? "--cask" : "--formula"
        let raw = try await runCapture(["info", "--json=v2", kindFlag, name])
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BrewError.nonZeroExit(code: -1, stderr: "Unparseable brew info JSON") }

        // v2 nests under "formulae" / "casks".
        let arrayKey = kind == .cask ? "casks" : "formulae"
        guard let arr = root[arrayKey] as? [[String: Any]], let obj = arr.first else {
            throw BrewError.nonZeroExit(code: -1, stderr: "No \(arrayKey) entry for \(name)")
        }

        var parsed = kind == .cask ? Self.parseCask(obj) : Self.parseFormula(obj)

        // Lazily size the installed keg (feature #4). Only when the package is
        // actually installed — a non-installed package gets nil (no du, no
        // fabricated estimate). Reuses `dirSizeBytes` (the `du -sk` helper) on
        // the resolved keg dir. Formula: Cellar/<short-name> (all versions);
        // cask: Caskroom/<token>. Short name (not full tap path) per layout.
        if parsed.installedVersion != nil {
            let prefix = await prefix()
            let kegPath = Self.kegPath(prefix: prefix, name: parsed.name, kind: kind)
            parsed.installedSizeBytes = await dirSizeBytes(kegPath)
        }
        return parsed
    }

    /// Resolve the on-disk keg directory for a package. Formula kegs live at
    /// `<prefix>/Cellar/<short-name>` (a dir of per-version subdirs — sizing the
    /// parent sums all installed versions); cask kegs at
    /// `<prefix>/Caskroom/<token>`. Always uses the short name (the last path
    /// component) so tap-qualified names like `homebrew/core/wget` map to
    /// `Cellar/wget`, not the full tap path. Mirrors the Tauri keg-path logic.
    static func kegPath(prefix: String, name: String, kind: InstalledPackage.Kind) -> String {
        let short = name.split(separator: "/").last.map(String.init) ?? name
        let sub = kind == .cask ? "Caskroom" : "Cellar"
        return "\(prefix)/\(sub)/\(short)"
    }

    // Internal (not private) so `BrewOutputParsingTests` can feed these the same
    // decoded `brew info --json=v2` dicts the live `info(name:kind:)` path parses
    // — keeping the deprecation mapping in lock-step with the Rust `to_package`.
    static func parseFormula(_ o: [String: Any]) -> PackageInfo {
        let name = o["name"] as? String ?? o["full_name"] as? String ?? "?"
        let versions = o["versions"] as? [String: Any]
        let stable = versions?["stable"] as? String
        // installed: [{version, ...}] — take the linked/first.
        let installedArr = o["installed"] as? [[String: Any]]
        let installed = installedArr?.last?["version"] as? String
            ?? (o["linked_keg"] as? String)
        // GitHub resolution: homepage → urls.stable.url → urls.head.url.
        let urls = o["urls"] as? [String: Any]
        let stableURL = (urls?["stable"] as? [String: Any])?["url"] as? String
        let headURL = (urls?["head"] as? [String: Any])?["url"] as? String
        let github = GitHubService.resolveGithubURL([
            o["homepage"] as? String, stableURL, headURL,
        ])
        return PackageInfo(
            name: name,
            fullName: o["full_name"] as? String ?? name,
            kind: .formula,
            installedVersion: installed,
            stableVersion: stable,
            desc: o["desc"] as? String,
            homepage: o["homepage"] as? String,
            githubHomepage: github,
            license: o["license"] as? String,
            tap: o["tap"] as? String,
            caveats: o["caveats"] as? String,
            outdated: o["outdated"] as? Bool ?? false,
            pinned: o["pinned"] as? Bool ?? false,
            dependencies: o["dependencies"] as? [String] ?? [],
            buildDependencies: o["build_dependencies"] as? [String] ?? [],
            conflictsWith: o["conflicts_with"] as? [String] ?? [],
            deprecation: parseDeprecationStatus(o, includeReplacement: true)
        )
    }

    static func parseCask(_ o: [String: Any]) -> PackageInfo {
        // Casks: token, version (string), installed (string), name [array], desc.
        let token = o["token"] as? String ?? o["full_token"] as? String ?? "?"
        let nameArr = o["name"] as? [String]
        let display = nameArr?.first ?? token
        // GitHub resolution: homepage → top-level url (casks with GitHub-Releases
        // artifacts but marketing homepages are common).
        let github = GitHubService.resolveGithubURL([
            o["homepage"] as? String, o["url"] as? String,
        ])
        return PackageInfo(
            name: token,
            fullName: display,
            kind: .cask,
            installedVersion: o["installed"] as? String,
            stableVersion: o["version"] as? String,
            desc: o["desc"] as? String,
            homepage: o["homepage"] as? String,
            githubHomepage: github,
            license: nil,
            tap: o["tap"] as? String,
            caveats: o["caveats"] as? String,
            outdated: o["outdated"] as? Bool ?? false,
            // Casks pin too in current Homebrew — read the real flag rather
            // than hardcoding false, so the detail Pin/Unpin button reflects
            // actual state (#90).
            pinned: o["pinned"] as? Bool ?? false,
            dependencies: [],
            buildDependencies: [],
            conflictsWith: [],
            deprecation: parseDeprecationStatus(o, includeReplacement: true)
        )
    }

    /// `brew upgrade <name>` — runs to completion, throws on failure.
    func upgrade(_ name: String) async throws {
        _ = try await runCapture(["upgrade", name])
    }

    /// `brew uninstall [--cask] <name>` — runs to completion, throws on failure.
    func uninstall(_ name: String, kind: InstalledPackage.Kind) async throws {
        var args = ["uninstall"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        _ = try await runCapture(args)
    }

    /// `brew install [--cask] <name>` — runs to completion, throws on failure.
    func install(_ name: String, kind: InstalledPackage.Kind) async throws {
        var args = ["install"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        _ = try await runCapture(args)
    }

    /// `brew pin`/`unpin [--cask] <name>` — runs to completion, throws on
    /// failure. Instant metadata flip (no streaming), so it goes through
    /// `runCapture` like the other short write commands (#90).
    func setPinned(_ name: String, kind: InstalledPackage.Kind, pinned: Bool) async throws {
        _ = try await runCapture(BrewArgs.setPinned(name, kind: kind, pinned: pinned))
    }

    // MARK: - Homebrew analytics (Settings → Brew)

    /// Read Homebrew's own analytics setting (`brew analytics state`). Returns
    /// true when analytics are ON. nil if the state can't be determined.
    /// Mirrors the Tauri `brew_get_analytics` command.
    func getAnalytics() async -> Bool? {
        guard let raw = try? await runCapture(["analytics", "state"]) else { return nil }
        let lower = raw.lowercased()
        if lower.contains("enabled") || lower.contains("are on") { return true }
        if lower.contains("disabled") || lower.contains("are off") { return false }
        return nil
    }

    /// Flip Homebrew's analytics setting — same as `brew analytics on|off` at
    /// the terminal. Mirrors the Tauri `brew_set_analytics` command.
    func setAnalytics(_ enabled: Bool) async throws {
        _ = try await runCapture(["analytics", enabled ? "on" : "off"])
    }
}
