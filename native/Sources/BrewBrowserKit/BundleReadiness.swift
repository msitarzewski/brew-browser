import Foundation

/// What a bundle/recipe needs from the host to run. Shared data contract with
/// the Tauri side (`BundleRequires` in src/lib/types.ts); `arch == "any"` means
/// no arch constraint.
public struct BundleRequires: Sendable, Codable, Equatable, Hashable {
    public let minRamGB: Int
    public let recommendedRamGB: Int
    public let minDiskGB: Int
    public let arch: String
    public let gpu: String

    public init(minRamGB: Int, recommendedRamGB: Int, minDiskGB: Int, arch: String, gpu: String) {
        self.minRamGB = minRamGB
        self.recommendedRamGB = recommendedRamGB
        self.minDiskGB = minDiskGB
        self.arch = arch
        self.gpu = gpu
    }
}

/// Three-state gate. `blocked` is advisory — the UI still allows install behind
/// a confirm (M3).
public enum ReadinessVerdict: String, Sendable, Codable, Equatable {
    case ready
    case marginal
    case blocked
}

/// Verdict + a human-readable reason string. Reason strings are part of the
/// parity contract (test-fixtures/readiness-cases.json) — keep them byte-identical.
public struct Readiness: Sendable, Equatable {
    public let verdict: ReadinessVerdict
    public let reason: String

    public init(verdict: ReadinessVerdict, reason: String) {
        self.verdict = verdict
        self.reason = reason
    }
}

/// Pure `(requires, capabilityNotes, profile) -> Readiness`. No I/O, no state —
/// the foundation M3 (readiness pills) builds on. Mirrors the TS/Rust rules
/// exactly; the shared fixture is the source of truth for order and strings.
public enum BundleReadiness {
    /// Human label for a `requires.arch` value, used in the "Built for …" reason.
    private static func archLabel(_ arch: String) -> String {
        switch arch {
        case "apple-silicon": return "Apple Silicon"
        case "intel": return "Intel"
        case "linux": return "Linux"
        default: return arch
        }
    }

    /// The capability note for the highest tier the host qualifies for: the
    /// value at the largest integer-parsed key ≤ `ramGB`, or nil if none.
    private static func nearestTierNote(_ notes: [String: String]?, _ ramGB: Int) -> String? {
        guard let notes else { return nil }
        var best: (key: Int, note: String)?
        for (rawKey, note) in notes {
            guard let key = Int(rawKey), key <= ramGB else { continue }
            if best == nil || key > best!.key {
                best = (key, note)
            }
        }
        return best?.note
    }

    public static func readiness(_ requires: BundleRequires?,
                                 _ capabilityNotes: [String: String]?,
                                 _ profile: SystemProfile) -> Readiness {
        guard let requires else {
            return Readiness(verdict: .ready, reason: "Ready.")
        }

        // 1. Arch mismatch beats everything else.
        if requires.arch != "any" && requires.arch != profile.arch {
            return Readiness(verdict: .blocked, reason: "Built for \(archLabel(requires.arch)).")
        }

        // 2. Hard RAM floor.
        if profile.ramGB < requires.minRamGB {
            return Readiness(verdict: .blocked,
                             reason: "Needs ≥\(requires.minRamGB) GB RAM (you have \(profile.ramGB) GB).")
        }

        // 3. Hard disk floor.
        if profile.freeDiskGB < requires.minDiskGB {
            return Readiness(verdict: .blocked,
                             reason: "Needs ≥\(requires.minDiskGB) GB free disk (you have \(profile.freeDiskGB) GB).")
        }

        // 4. Soft recommendation → marginal, else ready. Prefer the tier note.
        let note = nearestTierNote(capabilityNotes, profile.ramGB)
        if profile.ramGB < requires.recommendedRamGB {
            return Readiness(verdict: .marginal,
                             reason: note ?? "Below the recommended \(requires.recommendedRamGB) GB — may be slow.")
        }
        return Readiness(verdict: .ready, reason: note ?? "Ready.")
    }
}
