import Foundation
import Testing
@testable import BrewBrowserKit

/// Parity tests for the Swift GHSA enrichment layer, mirroring the Rust
/// `src-tauri/src/vulns/enrich.rs` test suite (id validation, merge semantics,
/// advisory parsing, cache round-trip + fail-soft + LRU, and the gating
/// no-ops). The live HTTP fetch is exercised via `parseAdvisory` on captured
/// bodies rather than a mocked URLSession.
@Suite("VulnsEnrich")
struct VulnsEnrichTests {

    private func finding(_ rawId: String,
                         severity: VulnSeverity = .high,
                         summary: String = "stub",
                         details: String = "stub details",
                         fixedIn: String? = nil,
                         references: [String] = []) -> VulnFinding {
        VulnFinding(id: rawId, rawId: rawId, severity: severity, summary: summary,
                    details: details, fixedIn: fixedIn, references: references, published: nil)
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghsa-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // ---------- GHSA id validation ----------

    @Test func ghsaIdAcceptsCanonicalForm() {
        #expect(VulnsEnrich.isValidGhsaId("GHSA-abcd-1234-wxyz"))
        #expect(VulnsEnrich.isValidGhsaId("GHSA-0000-0000-0000"))
        #expect(VulnsEnrich.isValidGhsaId("GHSA-AAAA-bbbb-CCCC"))
    }

    @Test func ghsaIdRejectsMalformed() {
        for bad in ["", "GHSA-", "GHSA-abc-1234-wxyz", "GHSA-abcd-1234",
                    "ghsa-abcd-1234-wxyz", "GHSA-abcd-1234-wxyz-extra",
                    "GHSA-ab/d-1234-wxyz", "GHSA-ab.d-1234-wxyz",
                    "CVE-2024-1", "GHSA-abcd-1234-wxy", "../etc/passwd"] {
            #expect(!VulnsEnrich.isValidGhsaId(bad), "must reject: \(bad)")
        }
    }

    // ---------- merge semantics (mirrors merge_into) ----------

    @Test func mergeOnlyOverwritesNonEmptyAndNeverSeverity() {
        let v = finding("GHSA-abcd-1234-wxyz", severity: .high,
                        summary: "OSV summary", details: "OSV details",
                        fixedIn: "2.0.0", references: ["https://osv.example/x"])
        let sparse = GhsaAdvisory() // all empty
        let out = VulnsEnrich.mergeInto(v, sparse)
        #expect(out.summary == "OSV summary")
        #expect(out.details == "OSV details")
        #expect(out.fixedIn == "2.0.0")
        #expect(out.references == ["https://osv.example/x"])
        #expect(out.severity == .high) // severity NEVER changes
    }

    @Test func mergeDedupesReferences() {
        let v = finding("GHSA-abcd-1234-wxyz", references: ["https://example.com/a"])
        let adv = GhsaAdvisory(references: ["https://example.com/a", "https://example.com/b"])
        let out = VulnsEnrich.mergeInto(v, adv)
        #expect(out.references == ["https://example.com/a", "https://example.com/b"])
    }

    @Test func mergePreservesExistingFixedIn() {
        let v = finding("GHSA-abcd-1234-wxyz", fixedIn: "2.0.0")
        let adv = GhsaAdvisory(firstPatchedVersion: "3.0.0")
        #expect(VulnsEnrich.mergeInto(v, adv).fixedIn == "2.0.0")
    }

    @Test func mergeFillsFixedInWhenMissing() {
        let v = finding("GHSA-abcd-1234-wxyz", fixedIn: nil)
        let adv = GhsaAdvisory(firstPatchedVersion: "3.0.0")
        #expect(VulnsEnrich.mergeInto(v, adv).fixedIn == "3.0.0")
    }

    // ---------- advisory parsing ----------

    @Test func parseAdvisoryDefaults() {
        let adv = VulnsEnrich.parseAdvisory(Data("{}".utf8))
        #expect(adv?.summary == "")
        #expect(adv?.references.isEmpty == true)
        #expect(adv?.firstPatchedVersion == nil)
    }

    @Test func parseAdvisoryIgnoresUnknownFieldsAndMaps() {
        // Fixture matches the REAL `GET /advisories/{id}` shape from
        // api.github.com: `references` is an array of plain STRINGS, and
        // `vulnerabilities[]` carries extra keys we ignore.
        let json = """
        {"summary":"boom","description":"details","severity":"high",
         "references":["https://example.com/x","https://example.com/y"],
         "vulnerabilities":[{"first_patched_version":"1.0.0","package":{"name":"p"},"vulnerable_version_range":"< 1.0.0"}],
         "new_field_2027":{"nested":true}}
        """
        let adv = VulnsEnrich.parseAdvisory(Data(json.utf8))
        #expect(adv?.summary == "boom")
        #expect(adv?.description == "details")
        #expect(adv?.references == ["https://example.com/x", "https://example.com/y"])
        #expect(adv?.firstPatchedVersion == "1.0.0")
    }

    @Test func parseAdvisoryReferencesAcceptStringAndObjectShapes() {
        // Tolerate BOTH the real string-array shape and the object-array
        // (`[{url}]`) shape so neither variant silently drops references.
        let strings = VulnsEnrich.parseAdvisory(Data(#"{"references":["https://a/1"]}"#.utf8))
        #expect(strings?.references == ["https://a/1"])
        let objects = VulnsEnrich.parseAdvisory(Data(#"{"references":[{"url":"https://b/2"}]}"#.utf8))
        #expect(objects?.references == ["https://b/2"])
    }

    @Test func parseAdvisoryPicksFirstNonEmptyPatchedVersion() {
        let json = """
        {"vulnerabilities":[{"first_patched_version":null},
         {"first_patched_version":""},{"first_patched_version":"2.0.0"},
         {"first_patched_version":"3.0.0"}]}
        """
        #expect(VulnsEnrich.parseAdvisory(Data(json.utf8))?.firstPatchedVersion == "2.0.0")
    }

    // ---------- cache ----------

    @Test func cacheRoundTrips() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var c = GhsaCache.newEmpty()
        let adv = GhsaAdvisory(summary: "Buffer overflow", description: "details",
                               severity: "high", references: ["https://example.com/adv"],
                               firstPatchedVersion: "3.2.1")
        c.put("GHSA-abcd-1234-wxyz", adv)
        c.saveIfDirty(dir: dir)
        #expect(FileManager.default.fileExists(atPath: GhsaCache.path(dir: dir).path))

        let loaded = GhsaCache.load(dir: dir)
        #expect(loaded.getFresh("GHSA-abcd-1234-wxyz") == adv)
        #expect(loaded.file.fetchCount == 1)
    }

    @Test func cacheLoadHandlesCorruptFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try? Data("{not json".utf8).write(to: GhsaCache.path(dir: dir))
        let c = GhsaCache.load(dir: dir)
        #expect(c.file.entries.isEmpty)
        #expect(c.file.schemaVersion == VulnsEnrich.schemaVersion)
    }

    @Test func cacheLoadHandlesFutureSchema() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let future = GhsaCacheFile(schemaVersion: VulnsEnrich.schemaVersion + 1, entries: [:], fetchCount: 99)
        try? JSONEncoder().encode(future).write(to: GhsaCache.path(dir: dir))
        let c = GhsaCache.load(dir: dir)
        #expect(c.file.entries.isEmpty)
        #expect(c.file.fetchCount == 0)
    }

    @Test func cacheEvictsOldestAtCap() {
        var c = GhsaCache.newEmpty()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<VulnsEnrich.cacheMaxEntries {
            let id = String(format: "GHSA-pkg%04d-0000-0000", i)
            c.file.entries[id] = GhsaCacheEntry(fetchedAt: base.addingTimeInterval(Double(i)),
                                                advisory: GhsaAdvisory())
        }
        #expect(c.file.entries.count == VulnsEnrich.cacheMaxEntries)
        c.put("GHSA-newr-comr-1234", GhsaAdvisory())
        #expect(c.file.entries.count == VulnsEnrich.cacheMaxEntries)
        #expect(c.file.entries["GHSA-pkg0000-0000-0000"] == nil) // oldest evicted
        #expect(c.file.entries["GHSA-newr-comr-1234"] != nil)
    }

    @Test func cacheGetFreshRejectsStale() {
        var c = GhsaCache.newEmpty()
        c.file.entries["GHSA-abcd-1234-wxyz"] = GhsaCacheEntry(
            fetchedAt: Date().addingTimeInterval(-(VulnsEnrich.cacheTTL + 60)),
            advisory: GhsaAdvisory(summary: "old"))
        #expect(c.getFresh("GHSA-abcd-1234-wxyz") == nil) // past TTL
    }

    // ---------- enrich gating (no-op paths, no network) ----------

    @Test func enrichNoOpWhenGithubDisabled() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = ["wget": [finding("GHSA-abcd-1234-wxyz")]]
        let out = await VulnsEnrich.enrich(input, githubEnabled: false, token: nil, cacheDir: dir)
        #expect(out == input)
        #expect(!FileManager.default.fileExists(atPath: GhsaCache.path(dir: dir).path))
    }

    @Test func enrichNoOpWhenNoGhsaIds() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = ["wget": [finding("CVE-2024-1"), finding("CVE-2024-99999")]]
        let out = await VulnsEnrich.enrich(input, githubEnabled: true, token: nil, cacheDir: dir)
        #expect(out == input) // CVE-only → untouched, early-exit before cache
        #expect(!FileManager.default.fileExists(atPath: GhsaCache.path(dir: dir).path))
    }
}
