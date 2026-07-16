import Foundation

/// Zero-install snapshot of the machine's capabilities, read once at launch and
/// cached on `AppModel`. Feeds `BundleReadiness.readiness(_:_:_:)` so the
/// Bundles UI can gate recipes against the host (RAM / arch / free disk).
///
/// Parity: mirrors the Tauri `SystemProfile` (src-tauri/src/system/profile.rs).
/// The shape is a shared data contract — the readiness parity fixture
/// (test-fixtures/readiness-cases.json) decodes the same field names.
public struct SystemProfile: Sendable, Codable, Equatable {
    public let ramGB: Int
    public let arch: String
    public let chip: String
    public let cpuCores: Int
    public let gpu: String
    public let freeDiskGB: Int
    public let osVersion: String

    public init(ramGB: Int, arch: String, chip: String, cpuCores: Int,
                gpu: String, freeDiskGB: Int, osVersion: String) {
        self.ramGB = ramGB
        self.arch = arch
        self.chip = chip
        self.cpuCores = cpuCores
        self.gpu = gpu
        self.freeDiskGB = freeDiskGB
        self.osVersion = osVersion
    }

    /// Read real capabilities with zero installs and zero network. All reads are
    /// direct `sysctl`/`Foundation` calls; nothing spawns `system_profiler`
    /// (that's ~1s and unnecessary for the RAM/arch/disk gate).
    public static func detect() -> SystemProfile {
        let env = ProcessInfo.processInfo.environment

        // RAM: hw.memsize is total physical bytes; round to whole GB.
        let ramBytes = sysctlUInt64("hw.memsize") ?? 0
        var ramGB = Int((Double(ramBytes) / 1_073_741_824).rounded())
        // Debug override so Marginal/Blocked states are reachable on a 128 GB dev Mac.
        if let fake = env["BREWBROWSER_FAKE_RAM_GB"], let fakeGB = Int(fake) {
            ramGB = fakeGB
        }

        #if arch(arm64)
        let arch = "apple-silicon"
        let gpu = "metal"
        #else
        let arch = "intel"
        let gpu = "none"
        #endif

        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        let cpuCores = sysctlInt("hw.ncpu") ?? 0

        // Free disk on the boot volume — the "important usage" figure matches
        // what Finder reports as available (purgeable space reclaimable on demand).
        var freeDiskGB = 0
        if let capacity = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            freeDiskGB = Int(capacity / 1_000_000_000)
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion).\(v.minorVersion)"

        return SystemProfile(ramGB: ramGB, arch: arch, chip: chip, cpuCores: cpuCores,
                             gpu: gpu, freeDiskGB: freeDiskGB, osVersion: osVersion)
    }
}

// MARK: - sysctl helpers

/// Read a string-valued `sysctl` (e.g. `machdep.cpu.brand_string`).
private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    // sysctl strings are NUL-terminated; drop the terminator before decoding.
    if let nul = buffer.firstIndex(of: 0) { buffer.removeSubrange(nul...) }
    return String(decoding: buffer, as: UTF8.self)
}

/// Read a 64-bit unsigned `sysctl` (e.g. `hw.memsize`).
private func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

/// Read an `Int`-valued `sysctl` (e.g. `hw.ncpu`, returned as a C `int`).
private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}
