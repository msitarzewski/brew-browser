import Foundation

/// A saved Brewfile snapshot. Mirrors the Tauri `BrewfileSummary` so the same
/// on-disk snapshots are interoperable between the two apps (both store under
/// `~/Library/Application Support/brew-browser/brewfiles/<id>.Brewfile`).
struct Snapshot: Identifiable, Hashable, Sendable {
    /// Sanitized filename stem — also the stable id.
    let id: String
    let label: String
    let path: String
    let createdAt: Date
    let sizeBytes: Int64
    let counts: SnapshotCounts
}

/// Per-snapshot entry tallies, parsed from the Brewfile text.
struct SnapshotCounts: Hashable, Sendable {
    var taps = 0
    var formulae = 0
    var casks = 0
    var masApps = 0
    var vscodeExtensions = 0
}

/// Disk layer for Brewfile snapshots — list / delete / export / import / parse.
/// The brew `dump`/`install` runs stream through `AppModel.startJob` (Activity
/// drawer); this actor only owns the filesystem side. Verbatim port of
/// `src-tauri/src/commands/brewfile.rs` (storage layout, label sanitization,
/// Brewfile parsing, import/export safety gates).
actor SnapshotStore {
    /// `~/Library/Application Support/brew-browser/brewfiles/`
    let dir: URL

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        dir = base
            .appendingPathComponent("brew-browser", isDirectory: true)
            .appendingPathComponent("brewfiles", isDirectory: true)
    }

    /// Create the snapshots dir if missing (brew bundle dump needs it to exist).
    func ensureDir() throws {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Validate a snapshot id before it becomes a filesystem path. Ids only ever
    /// originate from `sanitizeLabel` or a directory scan, so this is defense in
    /// depth (parity with the Tauri `validate_brewfile_id` chokepoint from
    /// PR #46) — it rejects `/`, `.`, `..`, NUL, and any separator/metacharacter
    /// that could escape the snapshots dir.
    static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 64 else {
            throw SnapshotError.invalidID("Snapshot id must be 1–64 characters.")
        }
        let ok = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        guard ok else {
            throw SnapshotError.invalidID("Snapshot id contains an illegal character: \(id)")
        }
    }

    /// File URL for a snapshot id (`<dir>/<id>.Brewfile`). Throwing so the
    /// allowlist runs at the single point an id becomes a path — the compiler
    /// then routes every caller through validation.
    func path(forID id: String) throws -> URL {
        try Self.validateID(id)
        return dir.appendingPathComponent("\(id).Brewfile")
    }

    /// Sanitize a label into a safe id and its `.Brewfile` URL — used by the
    /// caller to build the `--file=` arg for `brew bundle dump`.
    func dumpTarget(forLabel label: String) throws -> (id: String, url: URL) {
        let id = Self.sanitizeLabel(label)
        return (id, try path(forID: id))
    }

    /// All snapshots, newest first. Returns [] if the dir doesn't exist yet.
    func list() -> [Snapshot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var out: [Snapshot] = []
        for url in entries where url.pathExtension == "Brewfile" {
            let id = url.deletingPathExtension().lastPathComponent
            if id.isEmpty { continue }
            if let snap = summary(for: url, id: id, label: id) {
                out.append(snap)
            }
        }
        out.sort { $0.createdAt > $1.createdAt }
        return out
    }

    func delete(id: String) throws {
        let target = try path(forID: id)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw SnapshotError.notFound(id)
        }
        try FileManager.default.removeItem(at: target)
    }

    /// Copy a snapshot out to a user-chosen path (NSSavePanel-picked).
    func export(id: String, to dest: URL) throws {
        let src = try path(forID: id)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw SnapshotError.notFound(id)
        }
        try Self.checkExportTarget(dest)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Import an external Brewfile, copying it into the snapshots dir.
    @discardableResult
    func importFile(from src: URL, label: String) throws -> Snapshot {
        try Self.checkImportSource(src)
        try ensureDir()
        let id = Self.sanitizeLabel(label)
        let dest = try path(forID: id)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        guard let snap = summary(for: dest, id: id, label: label) else {
            throw SnapshotError.notFound(id)
        }
        return snap
    }

    // MARK: - Summary + parse

    private func summary(for url: URL, id: String, label: String) -> Snapshot? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let created = (attrs[.creationDate] as? Date)
            ?? (attrs[.modificationDate] as? Date)
            ?? Date()
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Snapshot(id: id, label: label, path: url.path,
                        createdAt: created, sizeBytes: size,
                        counts: Self.parseCounts(raw))
    }

    /// Tally Brewfile entries. Recognizes the canonical Ruby-DSL forms:
    /// `tap "x"`, `brew "x"`, `cask "x"`, `mas "x", id: N`, `vscode "x"`.
    /// Verbatim logic of `brewfile.rs::parse_brewfile_text` (counts only).
    static func parseCounts(_ raw: String) -> SnapshotCounts {
        var c = SnapshotCounts()
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sp = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let kind = String(line[line.startIndex..<sp])
            switch kind {
            case "tap": c.taps += 1
            case "brew": c.formulae += 1
            case "cask": c.casks += 1
            case "mas": c.masApps += 1
            case "vscode": c.vscodeExtensions += 1
            default: break
            }
        }
        return c
    }

    /// Keep `[A-Za-z0-9_-]`, collapse everything else to `_`, trim edge `_`,
    /// cap at 64, empty → `snapshot_<timestamp>`. Matches `brewfile.rs`.
    static func sanitizeLabel(_ label: String) -> String {
        let mapped = label.trimmingCharacters(in: .whitespaces).map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") { return ch }
            return "_"
        }
        var cleaned = String(mapped)
        while cleaned.hasPrefix("_") { cleaned.removeFirst() }
        while cleaned.hasSuffix("_") { cleaned.removeLast() }
        if cleaned.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            return "snapshot_\(fmt.string(from: Date()))"
        }
        return cleaned.count > 64 ? String(cleaned.prefix(64)) : cleaned
    }

    // MARK: - Safety gates (port of brewfile.rs H2 checks)

    private static let maxImportBytes: Int64 = 1024 * 1024
    private static let importHeadSampleBytes = 4096
    private static let forbiddenExportPrefixes = [
        "/etc", "/System", "/Library", "/usr", "/bin", "/sbin",
        "/var", "/private/etc", "/private/var", "/dev", "/Volumes/",
    ]

    /// Refuse exports into system-owned locations (the save panel is
    /// user-driven, but we gate defensively, like the Tauri IPC boundary).
    static func checkExportTarget(_ dest: URL) throws {
        let p = dest.path
        for prefix in forbiddenExportPrefixes where p == prefix || p.hasPrefix(prefix + "/") {
            throw SnapshotError.unsafePath("refusing to write inside \(prefix)")
        }
    }

    /// Refuse symlinks, oversize files, and binary payloads on import.
    static func checkImportSource(_ src: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: src.path)
        if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw SnapshotError.unsafePath("refusing to import a symlink")
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxImportBytes {
            throw SnapshotError.unsafePath("file larger than 1 MiB")
        }
        if let fh = try? FileHandle(forReadingFrom: src) {
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: importHeadSampleBytes)) ?? Data()
            if head.contains(0) {
                throw SnapshotError.unsafePath("refusing to import binary content")
            }
        }
    }
}

enum SnapshotError: LocalizedError {
    case notFound(String)
    case unsafePath(String)
    case invalidID(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return L10n.isRussian ? "Снимок «\(id)» не найден." : "Snapshot \"\(id)\" not found."
        case .unsafePath(let why):
            if !L10n.isRussian { return why }
            switch why {
            case "refusing to import a symlink":
                return "Нельзя импортировать символическую ссылку."
            case "file larger than 1 MiB":
                return "Файл больше 1 МиБ."
            case "refusing to import binary content":
                return "Нельзя импортировать бинарный файл."
            default:
                if why.hasPrefix("refusing to write inside ") {
                    let path = String(why.dropFirst("refusing to write inside ".count))
                    return "Нельзя записывать снимок внутрь \(path)."
                }
                return why
            }
        case .invalidID(let why):
            if !L10n.isRussian { return why }
            if why == "Snapshot id must be 1–64 characters." {
                return "Идентификатор снимка должен содержать от 1 до 64 символов."
            }
            if why.hasPrefix("Snapshot id contains an illegal character: ") {
                let id = String(why.dropFirst("Snapshot id contains an illegal character: ".count))
                return "Идентификатор снимка содержит недопустимый символ: \(id)."
            }
            return why
        }
    }
}
