//! Canonical brew execution patterns.
//!
//! Two functions:
//! - [`run_brew_capture`] — spawn `brew <args...>`, await completion,
//!   return stdout. Errors map to `BrewExitNonZero` or `Io`.
//! - [`run_brew_streaming`] — spawn `brew <args...>`, line-pump
//!   stdout/stderr into a `Channel<BrewStreamEvent>`, emit lifecycle
//!   events, register the child in the provided jobs map so
//!   `cancel_job` can find it.

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Instant;

use chrono::Utc;
use tauri::ipc::Channel;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{oneshot, Mutex};
use uuid::Uuid;

use crate::brew::error_patterns::{doctor_advisory_exit, friendlify, upgrade_warnings_only};
use crate::error::{truncate_tail, BrewError};
use crate::state::JobHandle;
use crate::types::{BrewStreamEvent, JobResult};

const MAX_STDERR_EXCERPT: usize = 4096;
const MAX_LINE_LEN: usize = 4096;

pub type JobsMap = Arc<Mutex<HashMap<Uuid, JobHandle>>>;

/// Run `brew <args>` and capture stdout. Used for `--json=v2` queries.
///
/// On non-zero exit, returns `BrewError::BrewExitNonZero` with the last
/// ~4 KB of stderr. The `display_command` string is the user-facing form.
/// A directory that is guaranteed to exist and be readable by the
/// invoking user on every supported platform. We set this as the
/// working directory for every `brew` subprocess.
///
/// **Why:** Homebrew refuses to run when its current working directory
/// isn't readable by the user — on Linux it aborts with "The current
/// working directory must be readable to <user> to run brew." A GUI app
/// inherits whatever cwd it was launched from (the app-launcher's cwd,
/// a stale deleted directory, or — when launched oddly — a root-owned
/// path the user can't read). Pinning every spawn to `/` makes the brew
/// invocation independent of how the app happened to be launched. `/`
/// is world-readable on macOS and Linux and always exists.
///
/// Discovered during the v0.6.0 Linux bring-up: launching the app from
/// a directory the user couldn't read made every `brew info` fail with
/// the readable-cwd error, surfacing as "Couldn't load packages."
const BREW_SPAWN_CWD: &str = "/";

/// Environment overrides applied to EVERY `brew` subprocess this app spawns.
///
/// `HOMEBREW_NO_ANALYTICS=1` disables Homebrew's own analytics so our
/// automated brew calls never trigger its ping to Homebrew's InfluxDB
/// endpoint (`*.influxdata.com`). Brew Browser itself sends no telemetry, and
/// it must not cause `brew` to send any on the user's behalf either — a user
/// reported the startup `*.influxdata.com` connection, which was Homebrew's,
/// fired because we shell out to `brew`. The user's OWN global brew-analytics
/// preference (for their manual CLI use) is untouched; this only scopes the
/// commands WE spawn. See https://docs.brew.sh/Analytics.
pub(crate) const BREW_ENV: &[(&str, &str)] = &[("HOMEBREW_NO_ANALYTICS", "1")];

/// Apply [`BREW_ENV`] to a brew command. Call at every spawn site so no
/// `brew` invocation can leak past the analytics-off policy.
pub(crate) fn apply_brew_env(cmd: &mut Command) {
    for (key, val) in BREW_ENV {
        cmd.env(key, val);
    }

    // Ensure Homebrew paths are prepended to PATH so GUI process launches (Finder, Dock)
    // inherit correct Homebrew resolution priority for subcommands (git, openssl, python).
    // macOS Apple Silicon (/opt/homebrew) + Intel (/usr/local) + Linuxbrew
    // (/home/linuxbrew/.linuxbrew). Non-existent prefixes on a given host are
    // harmless — they just don't resolve anything.
    let path = std::env::var_os("PATH").unwrap_or_default();
    let additional_paths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin";
    let mut new_path = std::ffi::OsString::from(additional_paths);
    if !path.is_empty() {
        new_path.push(":");
        new_path.push(path);
    }
    cmd.env("PATH", new_path);
}

/// True when brew must be launched through `arch -arm64`: this process is
/// running under Rosetta 2 (an Intel build on Apple Silicon) *and* the resolved
/// `brew` lives in the arm-native prefix (`/opt/homebrew`). In that state a
/// translated (x86_64) process spawning arm `brew` fails with
/// "Cannot install under Rosetta 2 in ARM default prefix" (issue #158), so we
/// re-exec it natively. An Intel Homebrew at `/usr/local` already matches the
/// translated process, so we leave those untouched.
fn needs_arm64_reexec(brew_path: &Path) -> bool {
    should_reexec_arm64(crate::system::profile::is_translated(), brew_path)
}

/// Pure gating logic behind [`needs_arm64_reexec`], split out so the
/// `translated` + arm-prefix combination is unit-testable without a real
/// Rosetta process.
fn should_reexec_arm64(translated: bool, brew_path: &Path) -> bool {
    translated && brew_path.starts_with("/opt/homebrew")
}

/// Construct the `brew` command with the analytics-off env + Homebrew PATH
/// prepend applied ([`apply_brew_env`]), transparently routing through
/// `/usr/bin/arch -arm64` when [`needs_arm64_reexec`] is true. Every brew spawn
/// site goes through this so the Rosetta 2 stopgap and the env policy stay in
/// one place. Subsequent `.args(..)` on the returned command append the brew
/// arguments as normal (after the `brew` path when re-execing via `arch`).
pub(crate) fn brew_command(brew_path: &Path) -> Command {
    if needs_arm64_reexec(brew_path) {
        let mut cmd = Command::new("/usr/bin/arch");
        cmd.arg("-arm64").arg(brew_path);
        apply_brew_env(&mut cmd);
        cmd
    } else {
        let mut cmd = Command::new(brew_path);
        apply_brew_env(&mut cmd);
        cmd
    }
}

pub async fn run_brew_capture(
    brew_path: &Path,
    args: &[&str],
    display_command: &str,
) -> Result<String, BrewError> {
    let mut cmd = brew_command(brew_path);
    cmd.args(args)
        .current_dir(BREW_SPAWN_CWD)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let output = cmd.output().await.map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
        _ => BrewError::Io {
            message: format!("failed to spawn brew: {}", e),
        },
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let excerpt = truncate_tail(stderr.trim_end(), MAX_STDERR_EXCERPT);
        let friendly_message = friendlify(&excerpt, display_command);
        return Err(BrewError::BrewExitNonZero {
            command: display_command.to_string(),
            exit_code: output.status.code().unwrap_or(-1),
            stderr_excerpt: excerpt,
            friendly_message,
        });
    }

    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Spawn `brew <args>`, stream stdout/stderr into the provided channel,
/// register the child with the jobs map so it can be canceled.
///
/// Returns the final `JobResult` once the child exits. Emits the full
/// `BrewStreamEvent` lifecycle: `Started` → `Stdout`/`Stderr` → `Exit`
/// or `Canceled`.
///
/// The caller is responsible for holding the write mutex for the
/// duration of the call — this function does not acquire it.
pub async fn run_brew_streaming(
    brew_path: &Path,
    args: Vec<String>,
    display_command: String,
    on_event: Channel<BrewStreamEvent>,
    jobs: JobsMap,
) -> Result<JobResult, BrewError> {
    let job_id = Uuid::new_v4();
    let started_at_chrono = Utc::now();
    let started_at_inst = Instant::now();

    let _ = on_event.send(BrewStreamEvent::Started {
        job_id,
        command: display_command.clone(),
        started_at: started_at_chrono.to_rfc3339(),
    });

    let str_args: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    let mut cmd = brew_command(brew_path);
    cmd.args(&str_args)
        .current_dir(BREW_SPAWN_CWD)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let err = match e.kind() {
                std::io::ErrorKind::NotFound => BrewError::BrewNotFound,
                _ => BrewError::Io {
                    message: format!("failed to spawn brew: {}", e),
                },
            };
            let _ = on_event.send(BrewStreamEvent::Error {
                job_id,
                error: err.clone(),
            });
            return Err(err);
        }
    };

    let child_id = child.id().unwrap_or(0);
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
    {
        let mut map = jobs.lock().await;
        map.insert(
            job_id,
            JobHandle {
                child_id,
                started_at: started_at_inst,
                cancel_tx: Some(cancel_tx),
            },
        );
    }

    let stdout_chan = on_event.clone();
    let stdout_task = tokio::spawn(async move {
        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();
            let mut progress = ProgressParser::new();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let line = clamp_line(line);
                        // Heuristic progress from brew's `==>` markers (best
                        // effort; never blocks the stream). Emitted alongside
                        // the raw line so the UI can show a determinate bar.
                        if let Some(p) = progress.observe(&line) {
                            let _ = stdout_chan.send(BrewStreamEvent::Progress {
                                job_id,
                                phase: p.phase,
                                package: p.package,
                                current: p.current,
                                total: p.total,
                            });
                        }
                        let _ = stdout_chan.send(BrewStreamEvent::Stdout {
                            job_id,
                            line,
                            ts: Utc::now().to_rfc3339(),
                        });
                    }
                    Ok(None) => break,
                    Err(_) => break,
                }
            }
        }
    });

    // Bounded ring of recent stderr lines so a non-zero exit can carry a
    // meaningful `stderr_excerpt` even when the caller doesn't subscribe
    // to the Channel (see Wave 3 code review C4).
    let stderr_buf: Arc<Mutex<StderrRing>> =
        Arc::new(Mutex::new(StderrRing::new(MAX_STDERR_EXCERPT)));
    let stderr_chan = on_event.clone();
    let stderr_buf_writer = Arc::clone(&stderr_buf);
    let stderr_task = tokio::spawn(async move {
        if let Some(stderr) = stderr {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let line = clamp_line(line);
                        {
                            let mut buf = stderr_buf_writer.lock().await;
                            buf.push(&line);
                        }
                        let _ = stderr_chan.send(BrewStreamEvent::Stderr {
                            job_id,
                            line,
                            ts: Utc::now().to_rfc3339(),
                        });
                    }
                    Ok(None) => break,
                    Err(_) => break,
                }
            }
        }
    });

    let exit_status = tokio::select! {
        status = child.wait() => status,
        _ = cancel_rx => {
            let _ = child.start_kill();
            match tokio::time::timeout(std::time::Duration::from_secs(5), child.wait()).await {
                Ok(s) => s,
                Err(_) => child.wait().await,
            }
        }
    };

    let _ = tokio::join!(stdout_task, stderr_task);

    let canceled = {
        let mut map = jobs.lock().await;
        let handle = map.remove(&job_id);
        handle.map(|h| h.cancel_tx.is_none()).unwrap_or(false)
    };

    let duration_ms = started_at_inst.elapsed().as_millis() as u64;

    match exit_status {
        Ok(status) => {
            let exit_code = status.code().unwrap_or(-1);
            let success = status.success();

            if canceled {
                let _ = on_event.send(BrewStreamEvent::Canceled { job_id });
                return Err(BrewError::Canceled);
            }

            // Snapshot stderr only on a non-zero exit (cheap path on success).
            let excerpt = if success {
                String::new()
            } else {
                let buf = stderr_buf.lock().await;
                buf.snapshot()
            };

            // brew exits 1 on non-fatal upgrade/install warnings (post-install
            // warnings, link conflicts, already-linked kegs) even though the
            // work completed. Treat those as success — they were the dominant
            // source of bogus "Upgrade-all failed" reports. See error_patterns.
            let warnings_only = !success && upgrade_warnings_only(&excerpt, &display_command);
            // `brew doctor` exits 1 on advisories — diagnostics, not a failure.
            let advisory_only = !success && doctor_advisory_exit(&display_command);
            let effective_success = success || warnings_only || advisory_only;
            let friendly_message = if effective_success {
                None
            } else {
                friendlify(&excerpt, &display_command)
            };

            let _ = on_event.send(BrewStreamEvent::Exit {
                job_id,
                exit_code,
                success: effective_success,
                duration_ms,
                friendly_message: friendly_message.clone(),
            });

            if effective_success {
                Ok(JobResult {
                    job_id,
                    exit_code,
                    success: effective_success,
                    duration_ms,
                })
            } else {
                Err(BrewError::BrewExitNonZero {
                    command: display_command,
                    exit_code,
                    stderr_excerpt: excerpt,
                    friendly_message,
                })
            }
        }
        Err(e) => {
            let err = BrewError::Io {
                message: format!("waiting on brew child failed: {}", e),
            };
            let _ = on_event.send(BrewStreamEvent::Error {
                job_id,
                error: err.clone(),
            });
            Err(err)
        }
    }
}

fn clamp_line(line: String) -> String {
    if line.len() <= MAX_LINE_LEN {
        line
    } else {
        let mut end = MAX_LINE_LEN;
        while end > 0 && !line.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}…[truncated]", &line[..end])
    }
}

/// A single progress observation derived from one `==>` line.
struct ProgressTick {
    phase: String,
    package: String,
    current: u32,
    total: Option<u32>,
}

/// Best-effort progress tracker over brew's stdout `==>` markers. Stateful:
/// learns the total from "Upgrading N outdated packages:" /
/// "Installing dependencies for X: a, b, c", and advances a per-package
/// counter as work markers (Pouring / Installing / Upgrading) name new
/// packages. Heuristic by design — unrecognized output simply yields no tick,
/// so the stream and exit handling are never affected.
struct ProgressParser {
    total: Option<u32>,
    current: u32,
    last_package: Option<String>,
}

impl ProgressParser {
    fn new() -> Self {
        Self {
            total: None,
            current: 0,
            last_package: None,
        }
    }

    /// Extract a package name from the remainder of a work marker.
    /// `Pouring foo--1.2.arm64.bottle.tar.gz` → `foo`; `Installing foo` → `foo`.
    fn pkg_name(rest: &str) -> String {
        let first = rest.split_whitespace().next().unwrap_or("");
        match first.find("--") {
            Some(idx) => first[..idx].to_string(),
            None => first.to_string(),
        }
    }

    fn observe(&mut self, line: &str) -> Option<ProgressTick> {
        let t = line.trim_start();
        let rest = t.strip_prefix("==> ")?;

        // Total from the upgrade header: "Upgrading 32 outdated packages:".
        if let Some(r) = rest.strip_prefix("Upgrading ") {
            if r.contains("outdated package") {
                if let Some(n) = r
                    .split_whitespace()
                    .next()
                    .and_then(|w| w.parse::<u32>().ok())
                {
                    self.total = Some(n);
                }
                return None;
            }
            // Otherwise "Upgrading <pkg>" — fall through to the work markers.
        }

        // Total from a dependency list: "Installing dependencies for foo: a, b".
        if rest.starts_with("Installing dependencies for ") {
            if let Some(list) = rest.splitn(2, ':').nth(1) {
                let n = list.split(',').filter(|s| !s.trim().is_empty()).count() as u32;
                if n > 0 {
                    // +1 for the target formula itself.
                    self.total = Some(self.total.map_or(n + 1, |x| x.max(n + 1)));
                }
            }
            return None;
        }

        // Per-package work markers — advance the counter on a new package.
        for kw in ["Pouring ", "Installing ", "Upgrading "] {
            if let Some(r) = rest.strip_prefix(kw) {
                let pkg = Self::pkg_name(r);
                if pkg.is_empty() {
                    continue;
                }
                if self.last_package.as_deref() != Some(pkg.as_str()) {
                    self.current += 1;
                    self.last_package = Some(pkg.clone());
                }
                return Some(ProgressTick {
                    phase: kw.trim_end().to_string(),
                    package: pkg,
                    current: self.current,
                    total: self.total,
                });
            }
        }

        // Phase-only markers — update the phase without advancing the counter.
        for kw in ["Downloading ", "Fetching "] {
            if let Some(r) = rest.strip_prefix(kw) {
                let pkg = if kw.starts_with("Fetching") {
                    Self::pkg_name(r)
                } else {
                    // Downloading carries a URL, not a package — keep the last.
                    self.last_package.clone().unwrap_or_default()
                };
                return Some(ProgressTick {
                    phase: kw.trim_end().to_string(),
                    package: pkg,
                    current: self.current,
                    total: self.total,
                });
            }
        }

        None
    }
}

/// Bounded buffer of recent stderr lines, capped at ~`max_bytes` total.
///
/// On overflow we drop oldest lines until the new line fits, then push.
/// `snapshot()` joins remaining lines with `\n` so the result is suitable
/// for `BrewExitNonZero.stderr_excerpt`. Bounded growth — chatty commands
/// can't OOM the process.
struct StderrRing {
    lines: std::collections::VecDeque<String>,
    cur_bytes: usize,
    max_bytes: usize,
}

impl StderrRing {
    fn new(max_bytes: usize) -> Self {
        Self {
            lines: std::collections::VecDeque::new(),
            cur_bytes: 0,
            max_bytes,
        }
    }

    fn push(&mut self, line: &str) {
        // +1 for the implicit '\n' separator the snapshot will add.
        let cost = line.len().saturating_add(1);
        // If a single line is larger than the cap, store just its tail.
        if cost > self.max_bytes {
            self.lines.clear();
            self.cur_bytes = 0;
            // Walk forward to a char boundary so we don't slice mid-UTF-8.
            let mut start = line.len().saturating_sub(self.max_bytes.saturating_sub(1));
            while start < line.len() && !line.is_char_boundary(start) {
                start += 1;
            }
            let tail = line[start..].to_string();
            self.cur_bytes = tail.len().saturating_add(1);
            self.lines.push_back(tail);
            return;
        }
        while self.cur_bytes + cost > self.max_bytes {
            match self.lines.pop_front() {
                Some(dropped) => {
                    self.cur_bytes = self
                        .cur_bytes
                        .saturating_sub(dropped.len().saturating_add(1));
                }
                None => break,
            }
        }
        self.cur_bytes = self.cur_bytes.saturating_add(cost);
        self.lines.push_back(line.to_string());
    }

    fn snapshot(&self) -> String {
        self.lines.iter().cloned().collect::<Vec<_>>().join("\n")
    }
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brew_env_disables_homebrew_analytics() {
        // The privacy contract: every app-spawned brew command must carry
        // HOMEBREW_NO_ANALYTICS=1 so we never trigger brew's InfluxDB ping.
        assert!(
            BREW_ENV.contains(&("HOMEBREW_NO_ANALYTICS", "1")),
            "brew spawn env must disable Homebrew analytics"
        );
    }

    #[test]
    fn arm64_reexec_only_for_translated_arm_prefix() {
        use std::path::Path;
        // Under Rosetta 2, an arm-native brew (/opt/homebrew) must be re-execed
        // via `arch -arm64` (issue #158)...
        assert!(should_reexec_arm64(
            true,
            Path::new("/opt/homebrew/bin/brew")
        ));
        // ...but an Intel brew (/usr/local) already matches the translated
        // process — leave it alone.
        assert!(!should_reexec_arm64(
            true,
            Path::new("/usr/local/bin/brew")
        ));
        // Native (non-translated) process: never re-exec, regardless of prefix.
        assert!(!should_reexec_arm64(
            false,
            Path::new("/opt/homebrew/bin/brew")
        ));
        assert!(!should_reexec_arm64(
            false,
            Path::new("/usr/local/bin/brew")
        ));
    }

    #[test]
    fn stderr_ring_keeps_lines_under_cap() {
        let mut r = StderrRing::new(100);
        r.push("first");
        r.push("second");
        let s = r.snapshot();
        assert_eq!(s, "first\nsecond");
    }

    #[test]
    fn stderr_ring_drops_oldest_when_full() {
        // Cap is just enough to hold ~2 short lines.
        let mut r = StderrRing::new(16);
        r.push("aaaaa"); // 5 + 1 = 6
        r.push("bbbbb"); // 5 + 1 = 6, total 12
        r.push("ccccc"); // would push to 18 > 16, drop "aaaaa"
        let s = r.snapshot();
        assert!(
            !s.contains("aaaaa"),
            "oldest line should be dropped, got {s:?}"
        );
        assert!(s.contains("bbbbb"));
        assert!(s.contains("ccccc"));
    }

    #[test]
    fn stderr_ring_truncates_oversized_single_line() {
        let mut r = StderrRing::new(8);
        let huge = "x".repeat(100);
        r.push(&huge);
        let s = r.snapshot();
        // Result is bounded by the cap (allowing the +1 separator slop).
        assert!(s.len() <= 8, "snapshot {} bytes exceeds cap", s.len());
        // And we kept the tail of the huge line.
        assert!(s.chars().all(|c| c == 'x'));
    }

    #[test]
    fn stderr_ring_empty_snapshot_is_empty_string() {
        let r = StderrRing::new(64);
        assert_eq!(r.snapshot(), "");
    }

    #[test]
    fn stderr_ring_handles_utf8_boundary_on_truncate() {
        // Each "日" is 3 bytes. With cap 8, an oversize line gets its
        // tail kept, walking to a valid char boundary.
        let mut r = StderrRing::new(8);
        let s = "日本語日本語"; // 18 bytes
        r.push(s);
        let snap = r.snapshot();
        // Must be valid UTF-8 (no panic from above) and bounded.
        assert!(snap.len() <= 8);
        // The kept tail must end with one of the source chars.
        assert!(s.ends_with(&snap) || snap.is_empty());
    }

    #[test]
    fn progress_parses_upgrade_sequence() {
        let mut p = ProgressParser::new();
        // Header sets the total but is not itself a tick.
        assert!(p.observe("==> Upgrading 3 outdated packages:").is_none());
        // Non-marker lines are ignored.
        assert!(p.observe("foo 1.0 -> 1.1").is_none());

        let t1 = p
            .observe("==> Pouring foo--1.1.arm64.bottle.tar.gz")
            .unwrap();
        assert_eq!(
            (t1.phase.as_str(), t1.package.as_str(), t1.current, t1.total),
            ("Pouring", "foo", 1, Some(3))
        );

        // Downloading updates phase without advancing the counter.
        let t2 = p
            .observe("==> Downloading https://example.com/bar.bottle")
            .unwrap();
        assert_eq!((t2.phase.as_str(), t2.current), ("Downloading", 1));

        let t3 = p
            .observe("==> Pouring bar--2.0.arm64.bottle.tar.gz")
            .unwrap();
        assert_eq!((t3.package.as_str(), t3.current), ("bar", 2));

        // Repeating the same package's phase does not double-count.
        let t4 = p.observe("==> Installing bar").unwrap();
        assert_eq!(t4.current, 2);
    }

    #[test]
    fn progress_total_from_dependency_list() {
        let mut p = ProgressParser::new();
        assert!(p
            .observe("==> Installing dependencies for wget: openssl@3, ca-certificates")
            .is_none());
        let t = p.observe("==> Installing openssl@3").unwrap();
        assert_eq!(t.total, Some(3)); // 2 deps + the target
    }

    #[test]
    fn progress_parser_robust_against_adversarial_lines() {
        // stdout from brew is semi-trusted; the marker parser must never panic
        // (e.g. integer overflow on the package count) and the counter must be
        // monotonic non-decreasing.
        let mut p = ProgressParser::new();
        let lines: Vec<String> = vec![
            "".into(),
            "==>".into(),
            "==> ".into(),
            "==> Pouring".into(),
            "==> Pouring ".into(),
            "==> Pouring --".into(),
            "==> Pouring foo--".into(),
            "==> Upgrading 4294967296 outdated packages:".into(), // > u32::MAX → parse fails gracefully
            "==> Upgrading 999999999999999999999 outdated packages:".into(),
            "==> Upgrading -1 outdated packages:".into(),
            "==> Installing dependencies for x:".into(),
            "==> Installing dependencies for x: ,, , ,".into(),
            "==> Fetching ".into(),
            "==> Downloading ".into(),
            "==> Pouring x--".to_string() + &"y".repeat(100_000),
            "日本語==> Pouring 日本--1.0".into(),
        ];
        let mut last: u32 = 0;
        for _ in 0..200 {
            for l in &lines {
                if let Some(t) = p.observe(l) {
                    assert!(t.current >= last, "counter must be monotonic");
                    last = t.current;
                }
            }
        }
    }
}
