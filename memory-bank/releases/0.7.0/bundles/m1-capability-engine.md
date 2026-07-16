# M1 — Capability engine (zero-install profile + readiness)

**Goal:** read the machine's capabilities with **zero installs**, and turn `(bundle.requires, profile) → readiness verdict` as a pure, unit-tested function. No UI, no bundle data yet — this is the foundation M2/M3 build on.

**Depends on:** nothing. **Blocks:** M3 (readiness pills), M2 (shares the `requires` type).

## Scope
- **In:** `SystemProfile` (RAM, arch, chip, cores, gpu, freeDiskGB, osVersion), cached; `readiness()` pure fn; a debug profile override; unit tests both shells.
- **Out:** any bundle/recipe data (M2), any UI (M3), GPU core-count detail (nice-to-have, not needed to gate).

## Shared data contract (both shells must agree)
```
SystemProfile { ramGB: number, arch: "apple-silicon"|"intel"|"linux", chip: string,
                cpuCores: number, gpu: "metal"|"cuda"|"none"|"unknown", freeDiskGB: number, osVersion: string }
Readiness     { verdict: "ready"|"marginal"|"blocked", reason: string }
readiness(requires, profile):
  if requires == null                         -> ready
  if profile.ramGB < requires.minRamGB        -> blocked  ("needs ≥{min} GB RAM, you have {ram}")
  if profile.freeDiskGB < requires.minDiskGB  -> blocked  ("needs ≥{minDisk} GB free, you have {free}")
  if requires.arch != "any" && mismatch       -> blocked  ("built for {arch}")
  if profile.ramGB < requires.recommendedRamGB-> marginal (capabilityNote for the nearest tier ≤ ramGB)
  else                                        -> ready    (capabilityNote for the nearest tier, if any)
"blocked" is advisory — the UI still allows install behind a confirm (M3).
```

## Tauri (Rust + TS)
- **New** `src-tauri/src/system/profile.rs` (+ `mod system;` in `lib.rs`): `SystemProfile` struct (`Serialize`), `fn detect() -> SystemProfile`. Reads:
  - macOS: `sysctl` (`hw.memsize`, `machdep.cpu.brand_string`, `hw.ncpu`), `std::env::consts::ARCH`; free disk via the existing disk-usage/`statvfs` path used by the Storage card; `gpu = metal` on Apple Silicon.
  - Linux: `/proc/meminfo`, `/proc/cpuinfo`, `df`/`statvfs`; `gpu` best-effort (`nvidia-smi` presence) else `unknown`.
  - Prefer a direct read; `sysinfo` crate is acceptable if it doesn't bloat the build. Cache in `AppState` (compute once).
- **Command** `system_profile() -> SystemProfile` in `commands/` (register in `lib.rs` handler).
- **Readiness** as pure TS in `src/lib/util/readiness.ts` (so it's vitest-able without IPC) — mirrors the Rust logic; OR keep readiness in Rust and expose per-bundle. **Decision:** compute readiness **client-side in TS** (the profile is small + the bundle list is client-side in M3); Rust only supplies the profile. Add `SystemProfile`/`Readiness`/`BundleRequires` to `src/lib/types.ts`.
- **Debug override:** a hidden env/localStorage key (`BREWBROWSER_FAKE_RAM_GB`) that overrides `ramGB` so Marginal/Blocked states are reachable on the 128 GB dev machine.

## Native (Swift)
- **New** `native/Sources/BrewBrowserKit/SystemProfile.swift`: a `Sendable struct SystemProfile` + `static func detect() async -> SystemProfile`. Reads `sysctl` via `Foundation`/`sysctlbyname` (`hw.memsize`, `machdep.cpu.brand_string`, `hw.ncpu`), `#if arch(arm64)` for arch, free disk via `URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` (or reuse the Storage path), `gpu = .metal` on Apple Silicon. Cache on `AppModel` (compute once at load, like the other dashboard probes).
- **New** `native/Sources/BrewBrowserKit/BundleReadiness.swift`: `enum ReadinessVerdict` + `static func readiness(_ requires: BundleRequires?, _ profile: SystemProfile) -> Readiness` — pure, mirrors the TS/Rust rules exactly.
- **Debug override:** `LocalPrefs`/env `BREWBROWSER_FAKE_RAM_GB` → overrides `ramGB`.

## Tests (parity — the SAME cases both shells)
Table-driven, covering the readiness matrix:
- no `requires` → ready.
- ramGB 4/8/16/32/64/128 against `{min:8, rec:16}` → blocked/marginal/ready/ready/ready/ready.
- disk floor blocks.
- arch mismatch (recipe `apple-silicon`, profile `intel`) → blocked.
- reason strings pull the correct `capabilityNotes` tier.
- Tauri: `src/lib/util/readiness.test.ts` (vitest). Native: `BundleReadinessTests.swift` (Swift Testing). Rust: a small parse/detect smoke test (detect() returns ram > 0).

## Acceptance criteria
- `system_profile()` (Tauri) and `SystemProfile.detect()` (native) return real RAM/arch/disk on this Mac (128 GB / apple-silicon / metal).
- `readiness()` unit tests green both shells, identical verdicts for identical inputs.
- Debug RAM override flips a fixed `requires` between ready/marginal/blocked.
- Zero new installs, zero network, no new permissions.

## Risks
- `system_profiler` (GPU core count) is ~1 s — **don't** call it on the gating path; RAM+arch+disk suffice. Fetch GPU detail lazily only if a later card wants to show it.
- Linux GPU detection is weak — `unknown` is a valid value; image-gen recipes degrade to a disk check + note.
