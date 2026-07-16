import Testing
import Foundation
@testable import BrewBrowserKit

// Tests for CategoryCatalog — the membership/breakdown logic that powers the
// Dashboard "Top categories" card and the #58 Library category filter.

@Suite("CategoryCatalog")
struct CategoryCatalogTests {
    static let fixtureJSON = """
    {
      "categories": {
        "dev": { "label": "Developer Tools", "iconSF": "hammer" },
        "media": { "label": "Media", "iconSF": "play" },
        "uncategorized": { "label": "Uncategorized" }
      },
      "formulae": { "git": ["dev"], "ffmpeg": ["media", "dev"], "foo": ["uncategorized"] },
      "casks": { "iterm2": ["dev"] }
    }
    """

    private func catalog() throws -> CategoryCatalog {
        let data = Data(Self.fixtureJSON.utf8)
        return try #require(CategoryCatalog.parse(data: data))
    }

    @Test func parseRejectsGarbage() {
        #expect(CategoryCatalog.parse(data: Data("not json".utf8)) == nil)
    }

    @Test func isMemberMatchesFormulaeAndCasks() throws {
        let c = try catalog()
        #expect(c.isMember(token: "git", kind: .formula, slug: "dev"))
        #expect(c.isMember(token: "ffmpeg", kind: .formula, slug: "media"))
        #expect(c.isMember(token: "iterm2", kind: .cask, slug: "dev"))
        // Negatives: wrong slug, wrong kind, unknown token.
        #expect(!c.isMember(token: "git", kind: .formula, slug: "media"))
        #expect(!c.isMember(token: "git", kind: .cask, slug: "dev"))
        #expect(!c.isMember(token: "nope", kind: .formula, slug: "dev"))
    }

    @Test func categoryLabelsExcludeUncategorized() throws {
        let c = try catalog()
        #expect(c.categoryLabels(for: "git", kind: .formula) == ["Developer Tools"])
        // "foo" is only uncategorized → no labels surfaced.
        #expect(c.categoryLabels(for: "foo", kind: .formula).isEmpty)
    }

    @Test func allCategoriesExcludesUncategorizedAndSorts() throws {
        let c = try catalog()
        let all = c.allCategories()
        #expect(all.map(\.slug) == ["dev", "media"])  // alphabetised by label
        #expect(!all.contains { $0.slug == "uncategorized" })
    }

    @Test func breakdownCountsMembershipsAndFoldsOther() throws {
        let c = try catalog()
        let installed = [
            InstalledPackage(name: "git", version: "1", kind: .formula),     // dev
            InstalledPackage(name: "ffmpeg", version: "1", kind: .formula),  // media, dev
            InstalledPackage(name: "iterm2", version: "1", kind: .cask),     // dev
            InstalledPackage(name: "foo", version: "1", kind: .formula),     // uncategorized
        ]
        let bd = c.breakdown(installed: installed)
        let byslug = Dictionary(uniqueKeysWithValues: bd.map { ($0.slug, $0.count) })
        #expect(byslug["dev"] == 3)     // git + ffmpeg + iterm2
        #expect(byslug["media"] == 1)   // ffmpeg
        #expect(byslug["other"] == 1)   // uncategorized folded into Other
    }
}

// Feature #6 — co-occurrence sub-groups. These mirror the Rust/Tauri parity
// cases so the two shells produce identical sub-group keys, labels, membership,
// and ordering for the same input. NOT a true taxonomy: each bucket is a
// co-assigned category slug, or the "__general__" sentinel for solo members.
@Suite("CategorySubgroups")
struct CategorySubgroupTests {
    // Larger fixture exercising solo + cross-tagged members across categories.
    // dev members: git(solo), ffmpeg(dev+media), aws(dev+cloud), sec(dev+security),
    //              both(dev+security+data), cur(dev+data), uncat-only-other(dev+uncategorized solo)
    static let fixtureJSON = """
    {
      "categories": {
        "dev":      { "label": "Developer Tools", "iconSF": "hammer" },
        "media":    { "label": "Media", "iconSF": "play" },
        "cloud":    { "label": "Cloud", "iconSF": "cloud" },
        "security": { "label": "Security", "iconSF": "lock" },
        "data":     { "label": "Data", "iconSF": "cylinder" },
        "uncategorized": { "label": "Uncategorized" }
      },
      "formulae": {
        "git":    ["dev"],
        "ffmpeg": ["media", "dev"],
        "aws":    ["dev", "cloud"],
        "sec":    ["dev", "security"],
        "both":   ["dev", "security", "data"],
        "cur":    ["dev", "data"],
        "devun":  ["dev", "uncategorized"],
        "solo":   ["uncategorized"]
      },
      "casks": {
        "iterm2": ["dev"]
      }
    }
    """

    private func catalog() throws -> CategoryCatalog {
        let data = Data(Self.fixtureJSON.utf8)
        return try #require(CategoryCatalog.parse(data: data))
    }

    private func tokens(_ g: CategorySubgroup) -> [String] { g.members.map(\.token) }

    /// 'general' bucket size == count of solo members (members whose only real
    /// category is the selected one — uncategorized doesn't count as "other").
    @Test func generalBucketHoldsSoloMembers() throws {
        let g = try catalog().subgroups(in: "dev")
        let general = try #require(g.first { $0.key == categorySubgroupGeneralKey })
        // Solo dev members: git, iterm2 (cask), devun (other slug is only uncategorized).
        #expect(Set(tokens(general)) == ["git", "iterm2", "devun"])
        #expect(general.label == "General Developer Tools")
    }

    /// A member tagged dev+security+data appears in BOTH the security and data
    /// sub-groups, never in 'general'.
    @Test func crossTaggedMemberAppearsInEachOtherBucket() throws {
        let g = try catalog().subgroups(in: "dev")
        let security = try #require(g.first { $0.key == "security" })
        let data = try #require(g.first { $0.key == "data" })
        #expect(tokens(security).contains("both"))
        #expect(tokens(data).contains("both"))
        let general = try #require(g.first { $0.key == categorySubgroupGeneralKey })
        #expect(!tokens(general).contains("both"))
    }

    /// No duplicate token within a single sub-group.
    @Test func noDuplicateTokenWithinSubgroup() throws {
        for g in try catalog().subgroups(in: "dev") {
            #expect(Set(tokens(g)).count == g.members.count)
        }
    }

    /// Sub-group labels follow the "<Selected> + <Other>" convention.
    @Test func labelsUseCoOccurrenceWording() throws {
        let g = try catalog().subgroups(in: "dev")
        let byKey = Dictionary(uniqueKeysWithValues: g.map { ($0.key, $0.label) })
        #expect(byKey["security"] == "Developer Tools + Security")
        #expect(byKey["data"] == "Developer Tools + Data")
        #expect(byKey["cloud"] == "Developer Tools + Cloud")
    }

    /// Deterministic ordering: descending count, tie-break by ascending slug,
    /// with the 'general' sentinel pinned LAST.
    @Test func deterministicOrderingGeneralLast() throws {
        let g = try catalog().subgroups(in: "dev")
        // Counts: security=2 (sec,both), data=2 (both,cur), cloud=1 (aws),
        // media=1 (ffmpeg), general=3 (git,iterm2,devun pinned last).
        let keys = g.map(\.key)
        #expect(keys.last == categorySubgroupGeneralKey)
        // Among non-general: count desc, then slug asc → data,security (both 2),
        // then cloud,media (both 1).
        #expect(keys == ["data", "security", "cloud", "media", categorySubgroupGeneralKey])
    }

    /// Degenerate case: a category whose members all carry ONLY that slug yields
    /// a single 'general' bucket. In the REAL catalog "uncategorized" members
    /// carry only uncategorized, so selecting it collapses to one bucket. (This
    /// fixture's "devun" also carries "dev", so uncategorized here splits into a
    /// "dev" bucket + general — see `uncategorizedSplitsByRealCoOccurrence`. To
    /// assert the all-solo invariant we use "media", whose every member here is
    /// cross-tagged, so instead we verify the all-solo path on a synthetic slug.)
    @Test func allSoloCategoryProducesSingleGeneralBucket() throws {
        // Build a minimal all-solo fixture: two members carry only "x".
        let json = """
        {
          "categories": { "x": { "label": "X" }, "uncategorized": { "label": "Uncategorized" } },
          "formulae": { "a": ["x"], "b": ["x", "uncategorized"] },
          "casks": {}
        }
        """
        let c = try #require(CategoryCatalog.parse(data: Data(json.utf8)))
        let g = c.subgroups(in: "x")
        // Both a and b are solo in x ("uncategorized" doesn't count as a co-tag).
        #expect(g.count == 1)
        #expect(g.first?.key == categorySubgroupGeneralKey)
        #expect(Set(tokens(g[0])) == ["a", "b"])
        #expect(g.first?.label == "General X")
    }

    /// "uncategorized" never co-occurs meaningfully: when an uncategorized member
    /// ALSO carries a real slug, that real slug forms the co-occurrence bucket;
    /// members carrying only uncategorized fall to 'general'. (Real catalog data
    /// is all-solo here, so this is the degenerate single-bucket case in prod.)
    @Test func uncategorizedSplitsByRealCoOccurrence() throws {
        let g = try catalog().subgroups(in: "uncategorized")
        let byKey = Dictionary(uniqueKeysWithValues: g.map { ($0.key, Set(tokens($0))) })
        // devun carries dev → lands in a "dev" bucket; solo is general.
        #expect(byKey["dev"] == ["devun"])
        #expect(byKey[categorySubgroupGeneralKey] == ["solo"])
    }

    /// Union of all sub-group members equals the flat category member set, and
    /// the summed bucket sizes are >= the flat count (cross-tagged members are
    /// counted once per bucket they appear in).
    @Test func unionEqualsFlatSetAndSumIsGreaterOrEqual() throws {
        let c = try catalog()
        let flat = Set(c.membersInCategory("dev").map(\.token))
        let g = c.subgroups(in: "dev")
        let union = Set(g.flatMap { $0.members.map(\.token) })
        #expect(union == flat)
        let sum = g.reduce(0) { $0 + $1.count }
        #expect(sum >= flat.count)
    }

    /// memberInSubgroup predicate matches subgroups() bucketing exactly (the
    /// drill-down list must match each bucket's member count).
    @Test func predicateMatchesBucketing() throws {
        let c = try catalog()
        for g in c.subgroups(in: "dev") {
            for m in c.membersInCategory("dev") {
                let inBucket = c.memberInSubgroup(token: m.token, kind: m.kind,
                                                  slug: "dev", subgroupKey: g.key)
                let listed = g.members.contains(m)
                #expect(inBucket == listed)
            }
        }
    }

    /// Unknown slug → no sub-groups.
    @Test func unknownSlugYieldsEmpty() throws {
        #expect(try catalog().subgroups(in: "does-not-exist").isEmpty)
    }
}

@Suite("EnrichmentLocaleOverlay")
struct EnrichmentLocaleOverlayTests {
    @Test func russianOverlayAppliesToSeedPackage() throws {
        let catalog = try #require(EnrichmentCatalog.loadBundled(locale: "ru-RU"))
        let entry = try #require(catalog.entry(for: "wget"))
        #expect(entry.summary?.contains("загруз") == true)
        #expect(entry.searchTerms.contains("скачать"))
        // Stable package-token suggestions remain identifiers, not translations.
        #expect(entry.similar.allSatisfy { !$0.contains(" ") })
    }

    @Test func englishBundleDoesNotUseRussianOverlay() throws {
        let catalog = try #require(EnrichmentCatalog.loadBundled(locale: "en"))
        let entry = try #require(catalog.entry(for: "wget"))
        #expect(entry.summary?.contains("загруз") != true)
        #expect(!entry.searchTerms.contains("скачать"))
    }

    @Test func localizedMergeIgnoresOverlayStableFields() {
        let base = EnrichmentEntry(
            friendlyName: "Wget",
            summary: "Download files.",
            useCases: ["Mirror a site"],
            similar: ["curl"],
            tags: ["network"],
            searchTerms: ["download"]
        )
        let patch = EnrichmentEntry(
            friendlyName: nil,
            summary: "Загружает файлы.",
            useCases: [],
            similar: ["локализованный токен"],
            tags: ["локализованный тег"],
            searchTerms: ["скачать"]
        )
        let merged = patch.localized(over: base)
        #expect(merged.summary == "Загружает файлы.")
        #expect(merged.similar == ["curl"])
        #expect(merged.tags == ["network"])
        #expect(merged.searchTerms == ["скачать"])
    }
}
