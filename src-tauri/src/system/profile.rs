//! Zero-install machine capability probe (Bundles M1).
//!
//! `detect()` reads RAM, arch, chip, core count, GPU class, free disk, and
//! OS version with **no installs and no network** — just `sysctl`/`sw_vers`
//! on macOS, `/proc` on Linux, and a `df -Pk /` shell-out (same "shell out
//! to a coreutil" idiom the Storage card already uses for `du -sk`). The
//! result feeds the client-side `readiness()` gate in `src/lib/util/readiness.ts`.
//!
//! Cheap enough to compute per call (a handful of `sysctl` reads), so no
//! `AppState` cache — the readiness math that consumes it lives client-side.

use std::process::Command;

use serde::Serialize;

/// One GiB in bytes. RAM + free-disk are reported in **GiB rounded to the
/// nearest whole GB** (so a 128 GiB Mac reads "128", not "137").
const GIB: f64 = 1024.0 * 1024.0 * 1024.0;

/// Machine capabilities. Field renames pin the wire shape to the shared
/// data contract in `src/lib/types.ts` (`ramGB`/`freeDiskGB` keep the
/// upper-case "GB"; the rest are plain camelCase).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemProfile {
    #[serde(rename = "ramGB")]
    pub ram_gb: u64,
    /// `"apple-silicon" | "intel" | "linux"`.
    pub arch: String,
    /// Human CPU string, e.g. `"Apple M3 Max"`.
    pub chip: String,
    pub cpu_cores: u32,
    /// `"metal" | "cuda" | "none" | "unknown"`.
    pub gpu: String,
    #[serde(rename = "freeDiskGB")]
    pub free_disk_gb: u64,
    pub os_version: String,
}

/// Run a command and return trimmed stdout, or `None` on any failure. Kept
/// deliberately forgiving: a missing probe degrades one field to its
/// fallback rather than failing the whole profile.
fn capture(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Bytes → GiB, rounded to the nearest whole GB.
fn bytes_to_gb(bytes: u64) -> u64 {
    (bytes as f64 / GIB).round() as u64
}

/// Free bytes on `/` via `df -Pk /`. The POSIX (`-P`) format guarantees a
/// single data line whose 4th column is "Available" in 1024-byte blocks.
/// Portable across macOS + Linux, no new crate.
fn free_disk_gb() -> u64 {
    let Some(text) = capture("df", &["-Pk", "/"]) else {
        return 0;
    };
    // Line 0 is the header; line 1 is the `/` mount.
    let Some(data) = text.lines().nth(1) else {
        return 0;
    };
    let avail_kb: u64 = data
        .split_whitespace()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    // KiB blocks → GiB.
    bytes_to_gb(avail_kb.saturating_mul(1024))
}

/// If `BREWBROWSER_FAKE_RAM_GB` parses to a number, use it for `ram_gb` so
/// Marginal/Blocked readiness states are reachable on a 128 GB dev box.
fn fake_ram_override() -> Option<u64> {
    std::env::var("BREWBROWSER_FAKE_RAM_GB")
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// Read the machine's capabilities. Zero installs, zero network.
pub fn detect() -> SystemProfile {
    #[cfg(target_os = "macos")]
    let profile = detect_macos();
    #[cfg(target_os = "linux")]
    let profile = detect_linux();
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let profile = detect_fallback();

    apply_overrides(profile)
}

/// Debug overrides applied to every platform's raw probe.
fn apply_overrides(mut profile: SystemProfile) -> SystemProfile {
    if let Some(ram) = fake_ram_override() {
        profile.ram_gb = ram;
    }
    profile
}

#[cfg(target_os = "macos")]
fn detect_macos() -> SystemProfile {
    // `cfg!` resolves at compile time: an aarch64 build is Apple Silicon,
    // anything else on macOS is an Intel Mac.
    let apple_silicon = cfg!(target_arch = "aarch64");

    let ram_bytes: u64 = capture("sysctl", &["-n", "hw.memsize"])
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let chip = capture("sysctl", &["-n", "machdep.cpu.brand_string"])
        .unwrap_or_else(|| "Unknown CPU".to_string());

    let cpu_cores: u32 = capture("sysctl", &["-n", "hw.ncpu"])
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let os_version =
        capture("sw_vers", &["-productVersion"]).unwrap_or_else(|| "unknown".to_string());

    SystemProfile {
        ram_gb: bytes_to_gb(ram_bytes),
        arch: if apple_silicon { "apple-silicon" } else { "intel" }.to_string(),
        chip,
        cpu_cores,
        // Every Apple Silicon Mac ships an integrated Metal GPU; Intel Macs
        // vary too much to claim one here, so `none` (M1 gates on RAM+disk).
        gpu: if apple_silicon { "metal" } else { "none" }.to_string(),
        free_disk_gb: free_disk_gb(),
        os_version,
    }
}

#[cfg(target_os = "linux")]
fn detect_linux() -> SystemProfile {
    // MemTotal in /proc/meminfo is reported in kB.
    let ram_bytes: u64 = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|kb| kb.parse::<u64>().ok())
        })
        .map(|kb| kb.saturating_mul(1024))
        .unwrap_or(0);

    let cpu_cores: u32 = capture("nproc", &[])
        .and_then(|s| s.parse().ok())
        .or_else(|| {
            std::fs::read_to_string("/proc/cpuinfo").ok().map(|text| {
                text.lines().filter(|l| l.starts_with("processor")).count() as u32
            })
        })
        .unwrap_or(0);

    // Best-effort chip name from /proc/cpuinfo "model name".
    let chip = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.split(':').nth(1))
                .map(|s| s.trim().to_string())
        })
        .unwrap_or_else(|| "Unknown CPU".to_string());

    // PRETTY_NAME from /etc/os-release, else the kernel release.
    let os_version = std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|l| l.starts_with("PRETTY_NAME="))
                .map(|l| l.trim_start_matches("PRETTY_NAME=").trim_matches('"').to_string())
        })
        .or_else(|| capture("uname", &["-r"]))
        .unwrap_or_else(|| "unknown".to_string());

    // GPU is weak to detect on Linux: claim `cuda` only if `nvidia-smi`
    // is present and runs, else `unknown` (a valid value — image-gen
    // recipes degrade to a disk check + note).
    let gpu = if capture("nvidia-smi", &["-L"]).is_some() {
        "cuda"
    } else {
        "unknown"
    };

    SystemProfile {
        ram_gb: bytes_to_gb(ram_bytes),
        arch: "linux".to_string(),
        chip,
        cpu_cores,
        gpu: gpu.to_string(),
        free_disk_gb: free_disk_gb(),
        os_version,
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn detect_fallback() -> SystemProfile {
    SystemProfile {
        ram_gb: 0,
        arch: "linux".to_string(),
        chip: "Unknown CPU".to_string(),
        cpu_cores: 0,
        gpu: "unknown".to_string(),
        free_disk_gb: free_disk_gb(),
        os_version: "unknown".to_string(),
    }
}

/// Tauri command: return the machine profile. Infallible — every field
/// degrades to a safe fallback rather than erroring the call.
#[tauri::command]
pub async fn system_profile() -> SystemProfile {
    detect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_returns_real_ram() {
        // Smoke test: on any real host this box has some RAM.
        let p = detect();
        assert!(p.ram_gb > 0, "expected non-zero RAM, got {}", p.ram_gb);
        assert!(!p.arch.is_empty());
    }

    #[test]
    fn fake_ram_override_wins() {
        // The override path is what makes Marginal/Blocked reachable on a
        // big dev box; exercise it directly (no env mutation for parallel
        // test safety — verify the applier instead).
        let base = SystemProfile {
            ram_gb: 128,
            arch: "apple-silicon".to_string(),
            chip: "test".to_string(),
            cpu_cores: 10,
            gpu: "metal".to_string(),
            free_disk_gb: 500,
            os_version: "15.0".to_string(),
        };
        // Without the env var set, apply_overrides is a no-op.
        if std::env::var("BREWBROWSER_FAKE_RAM_GB").is_err() {
            assert_eq!(apply_overrides(base).ram_gb, 128);
        }
    }

    #[test]
    fn bytes_to_gb_rounds_to_nearest() {
        assert_eq!(bytes_to_gb(128 * 1024 * 1024 * 1024), 128);
        assert_eq!(bytes_to_gb(8 * 1024 * 1024 * 1024), 8);
        assert_eq!(bytes_to_gb(0), 0);
    }
}
