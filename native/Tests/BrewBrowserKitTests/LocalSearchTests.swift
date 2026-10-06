import Foundation
import Testing
@testable import BrewBrowserKit

/// Parity tests for the native `local_search` port. The weights + AND semantics
/// + ordering + fair-split cap must match the Rust `local_search`
/// (`src-tauri/src/commands/search.rs`) so both shells rank identically.
@Suite("LocalSearch")
struct LocalSearchTests {
    // MARK: term parsing

    @Test("terms: whitespace-split, lowercased, de-duped, sorted, empties dropped")
    func termParsing() {
        #expect(LocalSearch.terms(from: "  VLC   media VLC ") == ["media", "vlc"])
        #expect(LocalSearch.terms(from: "") == [])
        #expect(LocalSearch.terms(from: "   ") == [])
    }

    // MARK: single-field weights

    private func score(name: String = "zzz", desc: String? = nil, friendly: String? = nil,
                       summary: String? = nil, tags: [String] = [], labels: [String] = [],
                       _ query: String) -> Int? {
        LocalSearch.score(name: name, desc: desc, friendlyName: friendly, summary: summary,
                          tags: tags, labels: labels, terms: LocalSearch.terms(from: query))
    }

    @Test("name match ranks exact > starts-with > substring")
    func nameTiers() {
        #expect(score(name: "vlc", "vlc") == LocalSearch.Weight.nameExact)
        #expect(score(name: "vlc-nightly", "vlc") == LocalSearch.Weight.nameStartsWith)
        #expect(score(name: "libvlccore", "vlc") == LocalSearch.Weight.nameSubstring)
    }

    @Test("non-name fields carry their own weights")
    func fieldWeights() {
        #expect(score(friendly: "VLC media player", "player") == LocalSearch.Weight.friendlyName)
        #expect(score(labels: ["Video & Audio"], "video") == LocalSearch.Weight.categoryLabel)
        #expect(score(summary: "plays most media files", "plays") == LocalSearch.Weight.summary)
        #expect(score(desc: "a media player", "player") == LocalSearch.Weight.desc)
        #expect(score(tags: ["ffmpeg"], "ffmpeg") == LocalSearch.Weight.tag)
    }

    @Test("per-term score is the single best field; total sums across terms")
    func bestAndSum() {
        // "vlc" matches name exactly (1000); a friendly match is ignored (max wins).
        #expect(score(name: "vlc", friendly: "vlc player", "vlc") == LocalSearch.Weight.nameExact)
        // Two terms: name-exact (1000) + label (280).
        let s = score(name: "vlc", labels: ["Video & Audio"], "vlc video")
        #expect(s == LocalSearch.Weight.nameExact + LocalSearch.Weight.categoryLabel)
    }

    @Test("AND semantics: every term must match some field, else nil")
    func andSemantics() {
        #expect(score(name: "vlc", labels: ["Video & Audio"], "vlc nonsense") == nil)
        #expect(score(name: "vlc", "vlc") != nil)
    }

    @Test("empty query yields no score")
    func emptyQuery() {
        #expect(score(name: "vlc", "") == nil)
    }

    // MARK: fair-split cap

    @Test("fairSplit halves the cap, spilling unused capacity to the longer side")
    func fairSplitSpill() {
        // 10 formulae, 300 casks, cap 200 → 100 formulae + 100 casks.
        let f = Array(0..<10), c = Array(0..<300)
        let r = LocalSearch.fairSplit(formulae: f, casks: c, topN: 200)
        #expect(r.formulae.count == 10)
        #expect(r.casks.count == 190) // unused formula half (90) spills to casks
        #expect(r.formulae.count + r.casks.count == 200)
    }

    @Test("fairSplit returns everything when under the cap")
    func fairSplitUnder() {
        let r = LocalSearch.fairSplit(formulae: [1, 2, 3], casks: [4, 5], topN: 200)
        #expect(r.formulae == [1, 2, 3])
        #expect(r.casks == [4, 5])
    }
}
