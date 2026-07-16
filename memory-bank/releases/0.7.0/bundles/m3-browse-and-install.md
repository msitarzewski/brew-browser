# M3 — Bundles browse & install

**Goal:** a first-class **Bundles** section — cards with capability-aware readiness, a detail view, and one-click **Install all** that streams into Activity. This is the visible feature.

**Depends on:** M1 (readiness), M2 (bundle data). **Blocks:** M4 (setup checklist lives in the detail view).

## Scope
- **In:** new "Bundles" nav section (both shells), bundle cards + readiness pill, bundle detail (packages w/ installed state, capability verdict, Install all), install-set backend + Activity streaming, "already installed" awareness.
- **Out:** the post-install setup checklist (M4), live-refresh (M5).

## Navigation
- **Native:** add `.bundles` to the `Section` enum (`AppModel.swift`) with a symbol; add a case in `ContentView`'s detail switch → `BundlesView`. Keyboard shortcut ⌘7 (Activity currently ⌘6 — append). Sidebar badge: none (or count of "Ready" bundles — optional).
- **Tauri:** add `bundles` to the sidebar `nav` array (`Sidebar.svelte`) + `SidebarSection` type + a route/section in the main view switch. Icon from lucide (e.g. `package-plus` / `boxes`).

## Install a set — reuse, don't reinvent
The Snapshots/Brewfile-restore path already installs a set and streams into Activity. **Decision at BUILD:** either (a) reuse the Brewfile-restore command with the bundle's package list, or (b) add a thin `brew_install_bundle(packages)` mirroring `brew_upgrade_many` (Tauri `commands/actions.rs`) + native `installMany(_:)` on `AppModel` (mirrors `upgradeMany`). (b) is cleaner if the Brewfile path is heavyweight. Either way: validate names, write-lock, stream `BrewStreamEvent` → Activity, `invalidate_caches()` on success, then reload `packages`.
- If a bundle declares a `tap`, prepend `brew tap <tap>` + surface the `brew trust` requirement (Homebrew 6.0) — reuse the existing tap-trust messaging. (None of the six first-party recipes need this.)
- Skip already-installed packages (install is idempotent, but the UI should show per-package state).

## Tauri (Svelte)
- **`src/lib/components/Bundles.svelte`** — grid of `BundleCard`s. Each card: icon, name, tagline, a **readiness pill** (`readiness(bundle.requires, systemProfile)` from M1), package-kind chips.
- **`BundleDetail.svelte`** (or a slide-over reusing PackageDetail's inspector) — packages list with installed/outdated state (cross-ref `packages` store), the capability verdict + `capabilityNotes` reason, `caveats`, `links`, and **Install all** (→ `brewInstallBundle` in `api.ts` → Activity drawer). Blocked verdict → Install behind a `DestructiveConfirm`-style "your machine may not run this well" gate.
- Readiness pill component shared with cards.

## Native (SwiftUI)
- **`BundlesView.swift`** — a `LazyVGrid` of bundle cards (stock `GroupBox`/card style, like the Dashboard cards). Readiness pill = a small `Chip` tinted by verdict.
- **`BundleDetailView.swift`** (or reuse the inspector) — packages (with installed-state via `installedPackageMatching`), verdict + note, caveats, links (`Link`), **Install all** button → `model.installBundle(_:)` → streaming Activity job. Blocked → `confirmationDialog` before install.
- Cards read the cached `SystemProfile` + `BundleReadiness`.

## Shared behavior
- Readiness pill: ✅ Ready · ⚠️ Marginal (tooltip = the tier note) · ⛔ Not recommended (tooltip = the blocking reason). Never hard-block.
- Per-package state: not installed / installed / outdated — reuse the same signals the Library uses.
- Install all → one streaming brew job (not N) → Activity; on success reload packages so states flip.

## Tests
- Readiness pill mapping (verdict → tone/label) — small unit tests both shells.
- Install-set arg builder (`brew_install_bundle` / `installMany`) — pure arg test (mirrors the `upgrade_args` tests): `["install", "--formula", "ollama", "--cask", "open-webui"]` ordering / kind flags.
- (Manual/verify) drive an install of the Media bundle (all homebrew/core formulae, cheap) end-to-end into Activity.

## Acceptance criteria
- Bundles section appears in both shells; the six cards render with correct readiness pills against the real profile (all Ready on the 128 GB dev Mac; debug RAM override shows Marginal/Blocked for Local LLMs / Image Gen).
- Bundle detail shows packages with live installed state, the verdict + reason, caveats, and working links.
- **Install all** on the Media bundle installs `ffmpeg`+`yt-dlp`+`mpv` in one streamed job; packages flip to installed afterward.
- A Blocked bundle still installs behind an explicit confirm.

## Risks
- Two Table/inspector reuse temptations — keep the bundle detail simple; don't overload PackageDetail. A dedicated `BundleDetailView`/`BundleDetail.svelte` is fine.
- Install-set backend choice (reuse Brewfile vs new command) — spike both briefly; prefer the one already covered by tests.
