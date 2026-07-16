import Testing
import Foundation
@testable import BrewBrowserKit

// Tests for the Manual vs Dependency Library filters (feature #3). The pure
// predicate + on-request parsing logic is the cross-shell parity core, so these
// cases mirror the Tauri Vitest cases (src/lib/components/Library predicates) so
// the native and Tauri shells select the SAME packages from the SAME flags.
//
// Parity contract (both shells):
//   Manual     = installed_on_request is true.
//   Dependency = installed as a dependency AND NOT on request (formula-only in
//                practice; native models this as kind==.formula && !onRequest).
//   A both-true package counts as Manual only (Dependency excludes on-request).
//   Installed casks are always on-request → Manual, never Dependency.
//   Neither flag (rare/legacy) → under All, but neither Manual nor Dependency.

// MARK: - on-request set parsing (mirrors countOnRequest's lineCount handling)

@Suite("OnRequestSetParsing")
struct OnRequestSetParsingTests {

    @Test func parsesNewlineDelimitedNames() {
        let raw = "wget\nopenssl@3\nca-certificates\n"
        #expect(BrewService.parseNameSet(raw) == ["wget", "openssl@3", "ca-certificates"])
    }

    @Test func skipsBlankLines() {
        // Trailing newline + an interior blank line must not yield empty names.
        let raw = "wget\n\nopenssl@3\n\n"
        let set = BrewService.parseNameSet(raw)
        #expect(set == ["wget", "openssl@3"])
        #expect(!set.contains(""))
    }

    @Test func emptyOutputIsEmptySet() {
        #expect(BrewService.parseNameSet("") == [])
        #expect(BrewService.parseNameSet("\n\n") == [])
    }
}

// MARK: - InstalledPackage tagging defaults

@Suite("InstalledPackageOnRequest")
struct InstalledPackageOnRequestTests {

    @Test func defaultsToFalse() {
        // The list --versions constructors omit the flag → must default false.
        let p = InstalledPackage(name: "openssl@3", version: "3.0", kind: .formula)
        #expect(!p.installedOnRequest)
    }

    @Test func idStaysNameAfterAddingFlag() {
        let p = InstalledPackage(name: "wget", version: "1.24", kind: .formula, installedOnRequest: true)
        #expect(p.id == "wget")
    }

    // MARK: tagging (the loadLibrary mapping rule, extracted + pure)

    @Test func formulaInSetTaggedOnRequest() {
        let tagged = BrewService.taggingOnRequest(
            [InstalledPackage(name: "wget", version: "1.24", kind: .formula)],
            onRequest: ["wget"]
        )
        #expect(tagged[0].installedOnRequest)
    }

    @Test func formulaNotInSetTaggedNotOnRequest() {
        let tagged = BrewService.taggingOnRequest(
            [InstalledPackage(name: "openssl@3", version: "3.0", kind: .formula)],
            onRequest: ["wget"]
        )
        #expect(!tagged[0].installedOnRequest)
    }

    @Test func installedCaskAlwaysTaggedOnRequest() {
        // Casks are never in the --installed-on-request --formula set, yet must
        // be tagged on-request (parity with Tauri's cask=on_request rule).
        let tagged = BrewService.taggingOnRequest(
            [InstalledPackage(name: "visual-studio-code", version: "1.90", kind: .cask)],
            onRequest: []
        )
        #expect(tagged[0].installedOnRequest)
    }

    @Test func installedInfoV2ParsesFormulaeCasksAndOnRequestFlags() throws {
        let raw = """
        {
          "formulae": [
            {
              "name": "wget",
              "versions": { "stable": "1.25.0" },
              "installed": [
                { "version": "1.25.0", "installed_on_request": true }
              ]
            },
            {
              "name": "openssl@3",
              "versions": { "stable": "3.6.0" },
              "installed": [
                { "version": "3.6.0", "installed_on_request": false }
              ]
            }
          ],
          "casks": [
            { "token": "docker-desktop", "version": "4.77.0", "installed": "4.65.0,221669" }
          ]
        }
        """
        let packages = try BrewService.parseInstalledInfoV2(raw)
        let byName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0) })

        #expect(byName["wget"]?.version == "1.25.0")
        #expect(byName["wget"]?.installedOnRequest == true)
        #expect(byName["openssl@3"]?.installedOnRequest == false)
        #expect(byName["docker-desktop"]?.kind == .cask)
        #expect(byName["docker-desktop"]?.version == "4.65.0,221669")
        #expect(byName["docker-desktop"]?.installedOnRequest == true)
    }

    @Test func installedInfoV2ReadsPinnedForFormulaeAndCasks() throws {
        // `brew info --installed --json=v2` exposes a top-level `pinned` bool on
        // both formulae and casks; parseInstalledInfoV2 must surface it so the
        // Library badge + honest update count work (#90). Absent = false.
        let raw = """
        {
          "formulae": [
            { "name": "php@8.4", "pinned": true,
              "installed": [ { "version": "8.4.1", "installed_on_request": true } ] },
            { "name": "wget",
              "installed": [ { "version": "1.25.0", "installed_on_request": true } ] }
          ],
          "casks": [
            { "token": "google-chrome", "version": "1.0", "installed": "1.0", "pinned": true },
            { "token": "rectangle", "version": "0.84", "installed": "0.84" }
          ]
        }
        """
        let byName = Dictionary(uniqueKeysWithValues:
            try BrewService.parseInstalledInfoV2(raw).map { ($0.name, $0) })

        #expect(byName["php@8.4"]?.pinned == true)
        #expect(byName["wget"]?.pinned == false)        // absent → false
        #expect(byName["google-chrome"]?.pinned == true) // casks pin too
        #expect(byName["rectangle"]?.pinned == false)
    }

    @MainActor
    @Test func tapQualifiedTokensMatchBareInstalledPackage() {
        let m = AppModel()
        m.installed = [
            InstalledPackage(name: "opencode", version: "1.17.3", kind: .formula, installedOnRequest: true)
        ]

        #expect(m.isPackageInstalled(token: "anomalyco/tap/opencode", kind: .formula))

        let detail = m.packageForDetail(
            InstalledPackage(name: "anomalyco/tap/opencode", version: "1.17.4", kind: .formula)
        )
        #expect(detail.name == "anomalyco/tap/opencode")
        #expect(detail.version == "1.17.3")
        #expect(detail.installedOnRequest)
    }
}

// MARK: - libraryRows membership under each filter (AppModel-level)

@MainActor
@Suite("ManualDependencyFilter")
struct ManualDependencyFilterTests {

    /// Fixture mirroring the Tauri parity fixture:
    ///   wget        — formula, on request           → Manual
    ///   openssl@3   — formula, dependency-only       → Dependency
    ///   ruby        — formula, on request AND a dep  → Manual only (tiebreak)
    ///   visual-studio-code — cask, always on request → Manual, never Dependency
    ///   legacy-keg  — formula, neither flag set      → All only
    /// In native, "dependency-only" is modeled as kind==.formula && !onRequest,
    /// so `installedOnRequest=false` on a formula == the dependency case.
    private func makeModel() -> AppModel {
        let m = AppModel()
        m.installed = [
            InstalledPackage(name: "wget", version: "1.24", kind: .formula, installedOnRequest: true),
            InstalledPackage(name: "openssl@3", version: "3.0", kind: .formula, installedOnRequest: false),
            InstalledPackage(name: "ruby", version: "3.3", kind: .formula, installedOnRequest: true),
            InstalledPackage(name: "visual-studio-code", version: "1.90", kind: .cask, installedOnRequest: true),
            InstalledPackage(name: "legacy-keg", version: "0.1", kind: .formula, installedOnRequest: false),
        ]
        return m
    }

    @Test func manualSelectsOnlyOnRequest() {
        let m = makeModel()
        m.libraryFilter = .manual
        let names = Set(m.libraryRows.map(\.name))
        #expect(names == ["wget", "ruby", "visual-studio-code"])
    }

    @Test func dependencySelectsFormulaeNotOnRequest() {
        let m = makeModel()
        m.libraryFilter = .dependency
        let names = Set(m.libraryRows.map(\.name))
        // openssl@3 + legacy-keg: formulae not on request. Casks excluded.
        #expect(names == ["openssl@3", "legacy-keg"])
    }

    @Test func outdatedFilterMatchesTapQualifiedOutdatedName() {
        // Regression: `brew outdated` reports tap formulae fully-qualified
        // (`shivammathur/php/php@8.4`) while `brew info --installed` — the Library
        // row source — reports the bare token (`php@8.4`). The outdated filter
        // must match through bareToken, else tap-installed packages get dropped
        // from the filter + outdated dot (the "Swift shows 8, Tauri shows 9" bug).
        let m = AppModel()
        m.installed = [
            InstalledPackage(name: "php@8.4", version: "8.4.20", kind: .formula, installedOnRequest: true),
            InstalledPackage(name: "wget", version: "1.24", kind: .formula, installedOnRequest: true),
        ]
        m.outdated = [
            OutdatedPackage(name: "shivammathur/php/php@8.4", installedVersion: "8.4.20",
                            currentVersion: "8.4.23", kind: .formula),
        ]
        m.libraryFilter = .outdated
        #expect(m.libraryRows.contains { $0.name == "php@8.4" })  // tap-qualified matched the bare token
        #expect(m.libraryFilterCount(.outdated) == 1)
        // A bare outdated name still matches (no regression for non-tap formulae).
        m.outdated = [OutdatedPackage(name: "wget", installedVersion: "1.24",
                                      currentVersion: "1.25", kind: .formula)]
        #expect(m.libraryRows.map(\.name) == ["wget"])
    }

    @Test func bothTruePackageShowsManualNotDependency() {
        // `ruby` is on request AND a dependency of another formula → Manual wins,
        // never appears under Dependency (predicate excludes on-request).
        let m = makeModel()
        m.libraryFilter = .manual
        #expect(m.libraryRows.contains { $0.name == "ruby" })
        m.libraryFilter = .dependency
        #expect(!m.libraryRows.contains { $0.name == "ruby" })
    }

    @Test func caskAlwaysManualNeverDependency() {
        let m = makeModel()
        m.libraryFilter = .manual
        #expect(m.libraryRows.contains { $0.name == "visual-studio-code" })
        m.libraryFilter = .dependency
        #expect(!m.libraryRows.contains { $0.name == "visual-studio-code" })
    }

    @Test func neitherFilterClaimsNeitherFlagPackageButAllDoes() {
        let m = makeModel()
        // legacy-keg has installedOnRequest=false. As a formula it DOES match the
        // native Dependency predicate (kind==.formula && !onRequest), unlike a
        // truly-neither-flag package in the Tauri model. It must still appear
        // under All, and never under Manual.
        m.libraryFilter = .manual
        #expect(!m.libraryRows.contains { $0.name == "legacy-keg" })
        m.libraryFilter = .all
        #expect(m.libraryRows.contains { $0.name == "legacy-keg" })
    }

    @Test func countsEqualPredicateFilteredLengths() {
        let m = makeModel()
        #expect(m.libraryFilterCount(.manual) == 3)       // wget, ruby, vscode
        #expect(m.libraryFilterCount(.dependency) == 2)   // openssl@3, legacy-keg
        #expect(m.libraryFilterCount(.all) == 5)
    }

    @Test func manualAndDependencyAreAlwaysAvailable() {
        // Unlike .vulnerable (gated on scanning), these two are always offered.
        let m = makeModel()
        #expect(m.availableLibraryFilters.contains(.manual))
        #expect(m.availableLibraryFilters.contains(.dependency))
    }

    @Test func filterOrderingMatchesParityContract() {
        // ...outdated, manual, dependency, vulnerable (vulnerable may be hidden).
        let order = LibraryFilter.allCases
        let iOutdated = order.firstIndex(of: .outdated)!
        let iManual = order.firstIndex(of: .manual)!
        let iDependency = order.firstIndex(of: .dependency)!
        let iVulnerable = order.firstIndex(of: .vulnerable)!
        #expect(iOutdated < iManual)
        #expect(iManual < iDependency)
        #expect(iDependency < iVulnerable)
    }
}
