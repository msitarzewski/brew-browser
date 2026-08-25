import Foundation
import Testing
@testable import BrewBrowserKit

/// Rosetta 2 detection + `arch -arm64` re-exec gating (issue #158). Parity with
/// the Tauri suite (`profile.rs::translated_only_when_sysctl_reads_one` and
/// `exec.rs::arm64_reexec_only_for_translated_arm_prefix`).
@Suite("RosettaDetection")
struct RosettaDetectionTests {

    @Test("sysctl.proc_translated maps to translated only when it reads 1")
    func translatedFlagMapping() {
        // 1 = Rosetta 2, 0 = native, nil = key absent (Macs without Rosetta).
        #expect(translatedFromSysctl(1) == true)
        #expect(translatedFromSysctl(0) == false)
        #expect(translatedFromSysctl(nil) == false)
        // Defensive: any other value is treated as native, never "translated".
        #expect(translatedFromSysctl(2) == false)
        #expect(translatedFromSysctl(-1) == false)
    }

    @Test("brewInvocation re-execs via arch -arm64 only for translated + /opt/homebrew")
    func brewInvocationGating() {
        // The gating logic mirrors the Rust `should_reexec_arm64`. We can't
        // fake Rosetta at runtime, but we can pin the wrapping shape: an
        // arm-prefix brew under `arch -arm64` must run `arch -arm64 <brew> …`,
        // and a direct invocation must run `<brew> …` verbatim.
        let args = ["upgrade", "wget"]

        let direct = BrewService.brewInvocation(brew: "/opt/homebrew/bin/brew", args: args)
        let wrapped = (URL(fileURLWithPath: "/usr/bin/arch"), ["-arm64", "/opt/homebrew/bin/brew"] + args)

        // On a native (non-translated) machine — which the CI/dev host is —
        // brewInvocation must NOT wrap, regardless of prefix.
        if SystemProfile.isTranslated() {
            #expect(direct.executable == wrapped.0)
            #expect(direct.arguments == wrapped.1)
        } else {
            #expect(direct.executable == URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
            #expect(direct.arguments == args)
        }

        // An Intel brew (/usr/local) already matches a translated process, so it
        // is never wrapped — direct invocation on every host.
        let intel = BrewService.brewInvocation(brew: "/usr/local/bin/brew", args: args)
        #expect(intel.executable == URL(fileURLWithPath: "/usr/local/bin/brew"))
        #expect(intel.arguments == args)
    }
}
