# Active Context

> ## 🔧 IN FLIGHT 2026-08-10: `fix/rosetta2-arch-detection` (committed + pushed, PR pending)
>
> **Issue #158** — a user installed the **Intel (x64) dmg on Apple Silicon**, so
> the app runs under Rosetta 2; every spawned `brew` (arm `/opt/homebrew`) fails
> *"Cannot install under Rosetta 2 in ARM default prefix."* Terminal works
> because that `brew` runs natively. Apple retires Rosetta 2 in a future macOS
> release, so the native build is the durable fix.
>
> **Fix (both shells), committed `1d5e461`, pushed, all green (Rust 688 · native
> 201 · svelte-check 0 · vitest 57):**
>
> - **Detect** via `sysctl.proc_translated` — a *runtime* check (the compile-time
>   `#if arch(arm64)` / `cfg!(target_arch)` can't see translation). Cached; a
>   pure helper is unit-tested. `SystemProfile.is_translated()` (Rust) /
>   `SystemProfile.isTranslated()` (Swift). A `BREWBROWSER_FAKE_ROSETTA=1`
>   override (mirrors `BREWBROWSER_FAKE_RAM_GB`) exercises the path on native-arm.
> - **Bridge**: every brew spawn routes through `arch -arm64 <brew>` when
>   translated **and** the prefix is `/opt/homebrew` (Intel brew at `/usr/local`
>   is left alone), so operations keep working. One helper per shell —
>   `exec.rs brew_command()` / `BrewService.brewInvocation()` — which also closed
>   a gap where `brew bundle check` skipped the analytics-off env.
> - **Notice**: a Dashboard **card** (NOT a top-of-window banner), same
>   `.card`/`GroupBox` + warning-row language as the Exposure card, steering to
>   the Apple Silicon build. `RosettaCard` in `DashboardView.swift`; a `.card` in
>   `Dashboard.svelte`. `SystemStatus.rosettaTranslated` carries the flag to the
>   Tauri frontend at startup.
>
> **Lesson (SwiftUI window sizing):** the first attempt was a top banner wrapping
> `NavigationSplitView` in a `VStack`; that broke free window resizing under the
> scene's `.windowResizability(.contentMinSize)`. The true culprit was
> `.fixedSize(vertical: true)` on the banner text — it locked the window's
> minimum height — compounded by a corrupted frame persisted under the
> `NSWindow Frame SwiftUI.WindowGroup<…>` defaults key. Resolved by moving to a
> Dashboard card (window chrome untouched). Full record to land in a task doc.
>
> **Next:** open PR (closes #158) → cut release **Tauri 0.7.3 / native 0.3.3** →
> reply on #158 → issue-triage sweep (brew-not-app class + #128/#139/#159/#160,
> label #161 `enhancement`).

> ## 🔧 IN FLIGHT 2026-06-10/11: `feat/intel-builds-and-onboarding` (committed + pushed, PR pending)
>
> Triggered by post-release "corrupt download" reports → root cause was Intel
> users opening arm64-only dmgs (artifacts audited bit-perfect; nothing corrupt).
> Three workstreams, all BUILT + QA GREEN + VM-VERIFIED — full record:
> `tasks/2026-06/13-intel-builds-onboarding-linux.md`:
>
> - **WS1 Onboarding (both shells):** brew-missing → guided first-run view
>   (CLT step on macOS, apt-deps note on Linux, Copy primary, Open Terminal
>   macOS-only, fixed-constant command strings) + 2s poll → auto-dissolve into
>   the library, same process, no relaunch. **Proven live on the Linux VM**
>   (real nuke → onboarding → real reinstall → auto-recovery).
> - **WS2 Intel:** Tauri x86_64 (separate dmgs, NOT universal — user decision;
>   `darwin-x86_64` manifest key; per-arch cask at release time) + native
>   per-arch zips/dmgs (`release.sh` loops arches; appcast-ordering bug fixed).
>   x64 cross-compiles verified BOTH stacks (native x64 .app assembled end-to-
>   end). ⚠️ **Tauri release builds on this host: E0463 proc-macro failures
>   ROOT-CAUSED** — `tauri build` exports `MACOSX_DEPLOYMENT_TARGET=13.0` and
>   the macOS 27 beta toolchain makes proc-macro dylibs built under that env
>   unloadable; cargo doesn't fingerprint the var so the taint persists until
>   `cargo clean`. Recipe: rustup toolchain on PATH + PRIME with plain
>   `cargo build --release [--target …]` before each `npm run tauri build`.
>   Full forensics + recipe: task doc 13 caveats.
> - **WS3 Linux:** `282d8ff` integrated (3-way, conflicts resolved), deb/rpm/
>   AppImage build + install + run **verified in the Scratch VM** (GNOME
>   Wayland, Linuxbrew detect, real installs). **Casks fully gated on Linux**
>   (data layer: catalog/search; UI sweep: Dashboard/Library/Trending/Discover/
>   Settings/Snapshots/About — casks are a macOS-only concept, no Linux variant).
>
> **QA:** cargo 618 ✅ | svelte-check 0 err ✅ | swift 44 ✅ | dead-code warnings
> cleaned (vulns/cache.rs `#[allow]` per file precedent). **Next:** PR → release
> (proposed Tauri 0.5.2 + native 0.1.1, user to confirm), per-arch cask body in
> ws2-tauri agent report, Linux artifacts ship "manual install, no auto-update"
> first round (updater story unwired). VM left brew 6.0.0 + jq/tree/alluxio.
>
> ---
>
> ## 🚀 SHIPPED 2026-06-07: Tauri 0.5.1 + native 0.1.0 (first native release)
>
> Both builds signed, notarized, released (tag `v0.5.1` on `main`); Tauri updater
> + native Sparkle feed live; cask bumped; **keychain sign-in verified on the
> signed build.** Everything below is now merged/shipped. Next deploy: see the
> runbook + gotchas in `tasks/2026-06/12-release-v0.5.1-native-0.1.0.md`.
> Open backlog: 6 Reddit feature requests (unfiled), catalog-from-brew-cache
> hybrid (roadmap), docs/landing brand still "Brew Browser".
>
> ---
>
> ## Prior: launch batch (PR #60, merged) — both builds
>
> Off `main` (which now contains the native app + #51, merged via #56). This
> branch was the **launch batch, both builds**:
> - **Upgrade-all firehose fix** (non-fatal `brew upgrade` exits = success;
>   closes ~20 issues), **#58** (category click → Library), **#57** (progress
>   counts). All in Tauri + native.
> - **Native test target** (0 → 36 tests, Swift Testing) + Rust fuzz tests.
> - **Pre-release security pass** clean (cargo audit 0 vulns, semgrep 0, gitleaks
>   clean; injection/path/CSP/signature review pass). `audit.toml` +
>   `.gitleaksignore` added. See `tasks/2026-06/11-*` and `security.md` §19.
> - **Docs + landing** rewritten for **both builds** (README/SECURITY/CONTRIBUTING +
>   Hall of fame for @neodave/#46); new dashboard screenshots; **landing page
>   published live** to brew-browser.zerologic.com (rsync, no `--delete`).
> - **Post-batch fixes (commits `57f6f5f`…):** GitHub keychain → ONE combined
>   item (`github_credential_v1`, ported from native; one prompt, status
>   hydrates); launch hydration of vuln cache + GitHub status; Tauri name
>   reverted to `brew-browser`; bundled catalog refreshed (as_of 2026-06-07).
> - **Keychain "won't stick" was `tauri dev` identity churn** — verify
>   persistence on a SIGNED build, not dev. See `decisions.md` 2026-06-07.
> - QA: `cargo test` green (110 github), `npm run check` 0 errors, `swift test`
>   36 green. Runtime/MITM + signed-build keychain smoke test still pending.
> - **Next: merge PR #60 → main, then BUILD + DEPLOY** (Tauri 0.5.1 sign+notarize;
>   native first notarized release via `release.sh`). Smoke-test sign-in
>   persistence on the signed build before shipping.
> - Filed #57/#58; six Reddit feature requests triaged, NOT yet filed. Deferred
>   roadmap: catalog-from-brew-cache hybrid; docs/landing brand still "Brew Browser".
> - Build host: ssh `umacbookpro` (see auto-memory [[reference-build-host]]) — one
>   web root serves landing + `updater.json`; never `rsync --delete` it.
>
> ---
>
> ## ⚗️ Prior: `experiment/native-swift-liquid-glass` (2026-06-06)
>
> Off-`main` branch: native Swift 6 + SwiftUI + Liquid Glass (macOS 26) port of
> the Tauri app, in `native/`. `main` is the shipped Tauri v0.5.0.
>
> **STATUS: native is at FULL feature parity with Tauri.** All committed + pushed
> (`892cbdf`…`e08a377`). The big parity push (bundles A–F: keyboard+⌘K palette,
> vulnerability surfacing, Sparkle updater, enrichment/Discover, upgrade sheet +
> GitHub detail, About/toasts/window-state) is DONE — see
> `tasks/2026-06/09-native-parity-roadmap.md` (roadmap) + `10-*` (polish/Sparkle/
> rename). The Sparkle/vulns "deferred" items from the old banner are now done.
>
> **App is now "Brew Browser"** (both builds; menu bar + Dock). Native version
> 0.1.0, Tauri 0.5.0 (independent on purpose). Native NOT yet
> notarized/distributed — that's the deploy step (needs Developer ID +
> `native/release.sh`).
>
> **Open threads → see [[project-resume-state]] (auto-memory):** Tauri-rename
> release-notes migration line; optional About "Opus 4.7→4.8" + prose
> capitalization; native notarization for deploy. Two intentional stock
> divergences remain (detail-pane width not persisted; Activity drawer aria-live).
>
> Build loop: `cd native && ./build-app.sh && open native/BrewBrowser.app` (use
> the .app, NOT Xcode Run / `swift run` — unbundled binary = no Info.plist, and
> Sparkle stays inert there). Tauri: `npm run check`. Constraint: **stock Apple
> components only, no overrides.**
>
> See `decisions.md` (2026-06-06 deploy-prep entry), `tasks/2026-06/09`+`10`.
>
> **Tauri side (now on `main`, merged in):** tauri-parity (#37), live-enrichment
> pipeline + app (#41/#43), pipeline-rsync (#42), trending tap-tokens (#44), cask
> manual-install detection (#45), brewfile path-traversal (#46). This branch was
> synced with `origin/main` on 2026-06-06 ahead of the native→main PR.

---

**Date:** 2026-05-30 EOD (v0.5.0 launched big; Homebrew tap live; post-launch fixes shipped)
**State:** v0.5.0 released and **launched successfully on r/MacOS (Saturday — the only day app posts are allowed there)**. Final launch numbers: **29 → 128 stars in one day**; r/MacOS post 300↑ @ 92.6%, r/MacOSApps post 106↑ @ 97.3% (the predecessor closed-source "Homebrew Store" post that triggered this whole project was deleted by its author at 65%). Post-launch work all landed: issue #8 fix (merged, PR #10), Homebrew tap (live), docs across README/landing/memory-bank (merged, PR #11), landing site redeployed to the server (was stale at v0.3.0, now v0.5.0). First external contributor PR (#15) reviewed.

## Repo

- **github.com/msitarzewski/brew-browser** — public, MIT
- **Released:** v0.1.0 → v0.5.0 (live on GitHub Releases — `gh release list`)
- **Tap:** `github.com/msitarzewski/homebrew-brew-browser` — `brew tap msitarzewski/brew-browser && brew install --cask brew-browser` (live, `auto_updates true`, audit-clean, fetch-verified). README + landing now **recommend the direct .dmg**, cask kept as a full second option.
- **Branch:** `main`. `feat/linux-support` committed (`282d8ff`) but **intentionally unmerged** (user wanted a commit, not a merge yet).
- **Stars:** **128** (was 29 at start of day) — now **past the 75 official-homebrew-cask notability bar** (still under the 225 self-submit bar; the "great fanfare" exception is now realistic).
- **Open PRs:** #15 (external contributor — "Installed by User" cask detection + force-override). Reviewed COMMENTED: detection + UX praised, blocker = a `std::fs::remove_file` sweep of the Homebrew prefix violating the app's "we never delete outside our data dir; brew owns the prefix" invariant. Path to merge given (drop the rm block, rely on the `--force` it already passes). Ball in contributor's court.

## Carry-forward / next-session candidates

- **Official homebrew-cask submission** — now unblocked (128★ > 75). Self-submit hits the higher 225★ bar, so the play is either a non-author submitter or leaning on the "recently released to great fanfare" exception while the launch is hot. User leans dmg-preferred but keeps the cask; this is additive.
- **Cask version/sha256 auto-bump** in `tools/release/` — still a TODO; manual `shasum` + edit each release until built. Now a hard requirement (user wants the cask bumped every release).
- **feat/linux-support** — committed, unmerged. Verified building+running on arm64 Ubuntu 26.04 in a Parallels VM ("Scratch", 10.211.55.6, sshable as `scratch` / `scratch-m`). Decide if/when to merge + whether to ship Linux artifacts.
- **Title-bar / UX redesign** — scoped with user (Option A: standard macOS title bar, drop the in-window vibrancy/overlay; move tools to sidebar bottom; kill panel-title row). NOT built — parked as premature during launch.
- **Known dead control:** the Settings → Appearance "Window vibrancy" dropdown is dead-wired (backend hardcodes HudWindow, never reads the pref). Slated for removal in the title-bar redesign.
- **MacPorts backend** — requested on Reddit. Scoped: core package ops portable, but trending/vulns/snapshots/enrichment have no MacPorts equivalent → would be a partial second backend, not parity. Open an issue if pursuing.
- **PR #9 (Linux)** was closed (user wanted commit not PR); branch + commit remain.

## v0.5.0 shipped on the branch (Steps 1–8)

Full file:line detail + decisions + verification narrative in `tasks/2026-05/20-v0.5.0-vulnerability-scanning.md`. Bullet summary:

- **Step 1** — `Settings.vulnerability_scanning_enabled` (default `false`, forward-compat tested), `state::require_vulnerability_scanning()` gate composing master paranoid with per-feature toggle, new `BrewError::VulnsNotInstalled { install_command }` variant routing the user to the one-click installer affordance instead of a generic exit-non-zero toast. Five rejection paths pinned by tests (toggle off, paranoid on, paranoid-wins-over-toggle, FirstLaunch, Corrupt).
- **Step 2** — New `src-tauri/src/vulns/{client,cache,fingerprint,enrich}.rs` module (~2,100 lines). `client` invokes `brew vulns --json` via `tokio::process::Command`, parses with serde-default defenses, exposes `check_brew_vulns_installed` + `scan_all` + `scan_one` + `install_brew_vulns`. `cache` is the persistent `vulns_cache.json` layer (1 MiB cap, atomic-write, fail-soft, 6h per-record TTL). `fingerprint` produces a deterministic SHA-256 over sorted `kind:name:version` lines for the whole-scan skip predicate. New `sha2 = "0.10"` + `hex = "0.4"` deps.
- **Step 3** — Four IPC commands: `vulns_scan_all(force)`, `vulns_scan_one(name)`, `vulns_install_helper`, `vulns_invalidate(kind, name, version)`. Gate composition documented inline + pinned by tests. `vulns_install_helper` intentionally bypasses the per-feature toggle (first-run flow is "install → toggle on → scan"); still respects master paranoid gate.
- **Step 4** — GHSA enrichment via `vulns::enrich::enrich()`. Fetches `api.github.com/advisories/{GHSA_ID}` when (a) the OSV record carries a `GHSA-…` ID AND (b) `settings.github_enabled` is on AND (c) the master paranoid gate is off — triple-defense. Parallel cache at `ghsa_cache.json` (2 MiB cap). Best-effort: 403/429/network error leaves the OSV record unchanged and logs (no toast).
- **Step 5** — Frontend store `src/lib/stores/vulnerabilities.svelte.ts` (~350 lines). `byPackage` Map keyed by `"{kind}:{name}"`, `severityCounts` derived rollup, `scanAll` / `scanOne` / `installHelper` / `invalidate` wrappers, sync lookups for inline UI consumers (`maxSeverityFor`, `vulnsFor`). Error routing: `vulns_not_installed` → captured for Settings card install affordance; everything else → `reportableToastError`. Types ported in `src/lib/types.ts`, IPC bindings in `src/lib/api.ts`.
- **Step 6** — UI surface: new `SettingsSectionVulnerabilities.svelte` opt-in subsection mounted in `SettingsSectionNetwork.svelte` alongside Updates + Enhanced Trending History; Dashboard `Exposure` card with severity counts + Scan-now button + ✓ clean-state framing; Sidebar count badge with max-severity tone; PackageRow inline severity dot; PackageDetail Security card with per-CVE rows, severity pills, fixed-in ranges, "Upgrade to fix" button wired to existing `brew_upgrade` pipeline. Cask rows render honest "Cask coverage isn't supported — brew vulns is formula-only" message rather than fake clean state.
- **Step 7** — Refresh-feed integration: post-`brew update` fan-out (Dashboard Refresh, Library Refresh) fires `vulnerabilities.scanAll(force=false)` so freshly learned upstream versions get scanned. Post-mutation hooks (install / upgrade / uninstall in `packages.svelte.ts`) call `vulns_invalidate(kind, name, version)` + `vulnerabilities.scanOne(name)` so the affected package's CVE row reflects the new state immediately. The `force=false` parameter on the post-update scan means the install-set fingerprint skip predicate still applies — a refresh that didn't change install state won't re-shell `brew vulns`.
- **Step 8** — Memory bank + docs (this commit): projectbrief ten → eleven paths, decisions.md ADR, security.md §17 endpoint audit, techContext.md (brew-vulns + sha2/hex deps), backendApi.md §13.15, frontendComponents.md v0.5.0 additions block, `docs/release-notes/0.5.0.md`, README disclosure refresh, task record `tasks/2026-05/20-v0.5.0-vulnerability-scanning.md`.

## Tests & lint at PR-open

- `cargo test`: **585 passed**, 0 failed, 6 ignored (507 → 585, +78 new — the +6 over the original +72 is the captured-fixture suite added during the smoke-test cycle)
- `cargo build`: clean (zero dead-code warnings — every new symbol is wired)
- `npm run check`: 0 errors, 3 pre-existing warnings (v0.4.0 baseline)
- `npm run build`: clean Vite build

## Smoke-test cycle (2026-05-27)

Five integration bugs surfaced + fixed during the first end-to-end smoke test on the user's real install (326 packages, 11 vulnerable). Each required either a real `brew` subprocess or the actual `brew vulns` binary on disk — none were catchable by unit-test sandbox. Full table + lessons in `tasks/2026-05/20-v0.5.0-vulnerability-scanning.md` under "Smoke test cycle". Summary:

1. `brew commands --include-aliases` errors without `--quiet` (modern brew 5.x) — added `--quiet`, then superseded
2. `brew commands` doesn't list external `brew-FOO` formula shims — switched install probe to `brew --prefix brew-vulns`
3. JSON severity is UPPERCASE in wire — custom case-folding `Deserialize` impl (also accepts `MODERATE` → Medium)
4. JSON uses `fixed_versions: [String]` (array), not `fixed_in: String` — `first_string_or_none` deserializer maps array's first element into the existing `fixed_in: Option<String>` field
5. `brew vulns --json` exits 1 when findings present (CI-scanner convention) — new `run_vulns_capture` helper accepts exit 0 OR 1 as success, only typed-errors on ≥ 2

Regression-pinned by the captured-fixture test `vulns::client::tests::raw_scan_result_parses_real_brew_vulns_output` using real `brew vulns --json` output from the user's install. All five failure modes are commented at their trap sites in `vulns/client.rs` so future maintainers see why the fix exists.

## Decisions locked (per-decision rationale in task #20 + decisions.md ADR)

- **Why shell out to brew-vulns instead of native OSV query?** Inherits upstream fixes automatically; correct attribution ("Powered by brew vulns"); escape hatch via the internal interface if upstream stagnates. Cost: requires brew-vulns to be installed (we provide the one-click installer).
- **Why GHSA enrichment is best-effort?** GHSA enrichment is a UX nicety, not a correctness requirement. A 403/429/network error from `api.github.com` should not break the whole scan; we leave the OSV record unchanged and log without toasting.
- **Why install-set SHA-256 fingerprint?** `DefaultHasher` is non-deterministic across runs (HashDoS defense) — a hash recorded in v0.5.0 disk cache would mismatch every subsequent launch, silently invalidating the skip predicate. SHA-256 is deterministic across runs, machines, Rust versions.
- **Why opt-in?** Adds an eleventh outbound path (`api.osv.dev` via subprocess + `api.github.com/advisories` from our code). The first-launch posture stays "zero outbound beyond what the user has explicitly consented to."
- **Casks not supported.** `brew vulns` is formula-only; we render honest "coverage isn't supported" rather than fake clean state.

## Workflow note

Branch ready for PR. Follows the durable v0.4.0+ workflow: push branch → `gh pr create` → review → merge. No direct pushes to `main`.

## What's left

- Open PR for the v0.5.0 branch.
- Cut the v0.5.0 release after merge: `tools/build/sign-and-notarize.sh` → `tools/release/publish-manifest.sh 0.5.0` → `gh release create v0.5.0 ...` → `gh api PATCH` for asset rename → manifest rsync to `brew-browser.zerologic.com:Sites/brew-browser/updater.json`. Same flow as v0.4.0; Tauri-release gotchas in cross-session memory `tauri_release_pipeline_gotchas.md`.

## Memory bank inventory

`toc.md`, `projectbrief.md`, `techContext.md`, `decisions.md`, `activeContext.md` (this), `progress.md`, `systemPatterns.md`, `designSystem.md`, `uxArchitecture.md`, `visualStory.md`, `backendApi.md`, `frontendComponents.md`, `codeReview.md`, `apiTests.md`, `accessibility.md`, `realityCheck.md`, `security.md` (now through §17), `ideas.md`, `agentLog.md` (dormant), `NEXT-SESSION.md`, `tasks/2026-05/` (20 task records + README + deferred), `phases/`, `scans/2026-05-23/`.
