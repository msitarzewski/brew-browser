import Foundation
import Testing
@testable import BrewBrowserKit

/// Parity tests for `BundleReadiness.readiness(_:_:_:)`, driven by the SHARED
/// fixture (test-fixtures/readiness-cases.json) that the Tauri/TS suite also
/// loads. Both shells must produce byte-identical verdicts and reason strings,
/// so the fixture — not this file — is the source of truth.
@Suite("BundleReadiness")
struct BundleReadinessTests {

    // The fixture profile carries only the fields readiness() reads; the other
    // SystemProfile fields (chip, cpuCores, osVersion) are irrelevant to the
    // gate, so we default them when reconstructing a full SystemProfile.
    private struct FixtureProfile: Decodable {
        let ramGB: Int
        let arch: String
        let freeDiskGB: Int
        let gpu: String

        var profile: SystemProfile {
            SystemProfile(ramGB: ramGB, arch: arch, chip: "test",
                          cpuCores: 8, gpu: gpu, freeDiskGB: freeDiskGB, osVersion: "27.0")
        }
    }

    private struct Expect: Decodable {
        let verdict: String
        let reason: String
    }

    private struct Case: Decodable {
        let name: String
        let requires: BundleRequires?
        let capabilityNotes: [String: String]?
        let profile: FixtureProfile
        let expect: Expect
    }

    private struct Fixture: Decodable {
        let cases: [Case]
    }

    /// Resolve the repo-root fixture from this file's location:
    /// native/Tests/BrewBrowserKitTests/BundleReadinessTests.swift
    ///   → up 4 (file → BrewBrowserKitTests → Tests → native → repo root)
    ///   → test-fixtures/readiness-cases.json
    private static func loadCases() throws -> [Case] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BrewBrowserKitTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // native/
            .deletingLastPathComponent()   // repo root
        let fixtureURL = repoRoot.appendingPathComponent("test-fixtures/readiness-cases.json")
        guard let data = try? Data(contentsOf: fixtureURL) else {
            print("readiness fixture not found at: \(fixtureURL.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    @Test func fixtureParity() throws {
        let cases = try Self.loadCases()
        #expect(!cases.isEmpty, "fixture decoded zero cases")
        for c in cases {
            let result = BundleReadiness.readiness(c.requires, c.capabilityNotes, c.profile.profile)
            #expect(result.verdict.rawValue == c.expect.verdict,
                    "verdict mismatch for '\(c.name)': got \(result.verdict.rawValue), want \(c.expect.verdict)")
            #expect(result.reason == c.expect.reason,
                    "reason mismatch for '\(c.name)': got '\(result.reason)', want '\(c.expect.reason)'")
        }
    }
}
