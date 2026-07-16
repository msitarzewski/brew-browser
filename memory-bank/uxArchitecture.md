# UX Architecture — brew-browser

**Owner:** UX Architect
**Date:** 2026-05-23
**Status:** Wave 1 spec (no code). Implementation target: Wave 2 by Frontend Developer.
**Mental model:** macOS-native developer tool — quiet, fast, dense, keyboard-first. Reference vibe: Linear / Raycast / Things. Not a "store", not a "manager dashboard" — a focused utility.

---

## 1. Information architecture

### Decision: Sidebar navigation + global command palette

A persistent left **sidebar** is the primary navigation surface; a global **command palette** (Cmd+K) is the secondary surface for power users. No top tabs.

### Why sidebar + palette, not the alternatives

| Option | Why rejected / accepted |
|--------|-------------------------|
| Top tabs only | Looks like a settings dialog. Doesn't scale if we ever add per-tap or per-machine views. Wastes vertical space — and the main views (Installed, Discover) are vertical lists where vertical pixels are the scarce resource. |
| Sidebar only | Accepted as base. Matches Finder, Mail, Music, Linear, Things. Mac users reach for the sidebar instinctively for "switch context." |
| Command palette only | Rejected as sole surface — too "I'm Raycast." First-launch users need a visible map. But strongly accepted as a secondary surface. |
| **Hybrid: sidebar + Cmd+K palette** | **Chosen.** Sidebar for the map, palette for the verbs. Same pattern as Linear and modern Slack. |

### Mental model the IA reflects

A Mac user thinks in five buckets when "doing brew things visually":
1. **What do I have?** → Library
2. **What's out there?** → Discover
3. **What did I save?** → Snapshots
4. **What did brew just do?** → Activity
5. **What's everyone else installing?** → Trending

The sidebar names map 1:1 to those questions.

---

## 2. Primary navigation surfaces

### Sidebar sections (top → bottom)

| Section | Phases served | Purpose |
|---------|---------------|---------|
| **Library** | 1, 3 | Installed formulae + casks. Default landing. Includes outdated badge. |
| **Discover** | 2, 3 | Search the full Homebrew index; click to view detail, install. |
| **Trending** | 6 | `formulae.brew.sh` analytics. Top-N by install count. Window selector. |
| **Snapshots** | 4 | Saved Brewfiles. Create new, restore, delete. "Set up new Mac" entry point. |
| **Activity** | 3, 4 | Streaming console log. Every brew invocation lands here, live + historical (session). |

### Sidebar footer

- **Theme toggle** (light / dark / system) — bottom-left corner.
- **Brew status indicator** — small dot + version (`brew 5.1.13`). Green = ready, amber = command running, red = brew not found / unhealthy. Click to open a small popover with `brew --version`, `brew doctor`-lite info.

### What's intentionally NOT a top-level section

- **Settings** — there are essentially none. A small gear icon in the footer opens a tiny preferences popover (theme, default install confirmation, trending cache TTL). Not a section.
- **Taps** — out of scope per `projectbrief.md`.
- **Help** — README link in footer, not a section.

---

## 3. Primary flows

### Naming convention used below

- **`>`** = user action
- **`→`** = UI response
- **`⤷`** = backend (Rust/brew) work

### 3.1 Browse installed packages (Phase 1)

1. > App launches.
2. → Sidebar renders, **Library** is active by default.
3. ⤷ Background: `brew_list_all()` invoked.
4. → Library shows skeleton rows for ~300ms while loading.
5. → On data return: two-column dense table.
   - Columns: **Name** · **Version** · **Type** (formula/cask pill) · **Outdated** (chevron if upgrade available) · **Size on disk** (deferred, Phase 5).
6. → Filter chips above the table: `All` · `Formulae` · `Casks` · `Outdated only`. Sticky.
7. → Local-filter input top-right (`/` to focus). Filters the loaded set client-side. Fast.
8. > Click a row → opens detail panel (see 3.2).

**Sort:** name (A–Z) default; clickable column headers for Version, Type, Outdated.

### 3.2 View package details (Phase 1)

Detail surfaces as a **right-side slide-over panel** (~420px wide), not a separate page or modal. Library list remains visible and interactive on the left.

1. > Click row in Library (or Discover, or Trending).
2. → Panel slides in from right (200ms ease-out).
3. ⤷ `brew_info(name)` invoked.
4. → Panel renders, in order:
   - Package name (h1) + type pill (formula / cask)
   - Installed version (or "Not installed")
   - Latest available version (if different → "Upgrade available" inline)
   - One-line description
   - Homepage link (opens via `tauri-plugin-opener`)
   - Dependencies (collapsed by default; click to expand)
   - Dependents (collapsed by default; appears only if non-empty)
   - License
   - Caveats (if any, expanded by default — they matter)
5. → Primary action button bar (bottom of panel):
   - If installed + up to date: `[Uninstall]` (destructive style) · `[Reinstall]` (secondary)
   - If installed + outdated: `[Upgrade]` (primary) · `[Uninstall]` (destructive)
   - If not installed: `[Install]` (primary)
6. > **Esc** or click outside → panel closes.

### 3.3 Search for a new package (Phase 2)

Two entry points:

**A. From Discover section**
1. > Click **Discover** in sidebar.
2. → Empty state: large search input, helper text "Search the Homebrew index — ~7,000 formulae and ~6,000 casks." Recent searches listed below (session-only).
3. > Type query, hit Enter (or 300ms debounce after 2+ chars).
4. ⤷ `brew_search(query)` invoked.
5. → Loading: subtle progress bar at top of pane (search is slow on cold cache).
6. → Results table: Name · Type · One-line desc · Already-installed badge if applicable.
7. > Click row → detail panel (3.2).

**B. From global command palette (Cmd+K)**
1. > Cmd+K anywhere in app.
2. → Palette overlay opens (centered, ~640px wide).
3. > Type query.
4. → Live results: top section "Installed matches" (instant, from in-memory list) · bottom section "Index matches" (debounced `brew_search`).
5. > Enter on result → opens detail panel + switches sidebar to the appropriate section (Library if installed, Discover if not).
6. > Esc → close palette, no nav change.

### 3.4 Install a package (Phase 3)

1. > In detail panel: click `[Install]`.
2. → If preference "Confirm before install" is on (default OFF for non-destructive): brief inline confirmation strip appears in the panel ("Install `wget`?  [Cancel] [Install]"). Default is to skip confirmation for installs — they're additive.
3. → Action begins. UI changes:
   - Button row shows `[Installing…]` with spinner, button disabled.
   - **Activity drawer auto-opens** from bottom (see §4).
   - Sidebar **Activity** badge shows `1` (count of running ops).
   - Brew status dot in footer turns amber.
4. ⤷ `brew_install(name)` invoked. Stdout/stderr stream to frontend via Tauri events.
5. → Drawer console renders streaming lines in monospace, auto-scroll-to-bottom (with "pause autoscroll" if user scrolls up).
6. → On success: toast top-right "Installed wget (1.21.4)" · Library refreshes · detail panel button row updates to installed state · drawer line shows green check + final summary. Drawer stays open but minimizable.
7. → On failure: toast "Install failed" (red) · drawer console shows error · detail panel re-enables action buttons · a "Copy log" affordance appears.

### 3.5 Uninstall a package (Phase 3) — destructive confirm

1. > In detail panel: click `[Uninstall]`.
2. → **In-page modal** opens (see §5). Title: "Uninstall `<name>`?" Body: lists dependents that will be orphaned (from `brew_info`). Checkbox: "Also remove unused dependencies" (default off, maps to `brew autoremove` later in Phase 5). Buttons: `[Cancel]` (default) · `[Uninstall]` (destructive red).
3. > Click `[Uninstall]`.
4. → Same as install flow §3.4 steps 3–7, with success toast "Uninstalled <name>".

### 3.6 Upgrade all outdated (Phase 3)

1. > In **Library**, filter chip "Outdated only" shows count badge (e.g., `7`). Click chip.
2. → Outdated-only view. Toolbar adds a button: `[Upgrade all (7)]` (primary).
3. > Click `[Upgrade all]`.
4. → Confirmation modal: "Upgrade 7 packages? This may take several minutes." `[Cancel]` · `[Upgrade all]`.
5. → Same streaming-console flow. The Activity drawer header reads "Upgrading 7 packages — wget (1/7)". Progress derived from line-by-line `==>` markers in brew output.
6. → On completion: toast "7 packages upgraded" · Library refreshes · outdated badge clears (or shows remaining if some failed).

**Per-package upgrade:** From a single outdated package's detail panel, `[Upgrade]` runs `brew upgrade <name>`. Same console flow, no confirmation modal (single-package upgrade is non-destructive enough).

### 3.7 Snapshot current state to a Brewfile (Phase 4)

1. > Click **Snapshots** in sidebar.
2. → List of saved Brewfiles (from `~/Library/Application Support/brew-browser/brewfiles/`). Each row: Name · Created date · Package count · `[Restore]` · `[Export…]` · `[Delete]` (delete is destructive).
3. → Top of pane: `[+ New Snapshot]` primary button.
4. > Click `[+ New Snapshot]`.
5. → Modal: "Name this snapshot" (default: `before-<timestamp>` or `daily-2026-05-23`). Optional note field.
6. > Confirm.
7. ⤷ `brew_bundle_dump(path)` invoked. (Slow on big libraries — warned in techContext.)
8. → Activity drawer auto-opens, progress message "Dumping Brewfile…". Note: `brew bundle dump` doesn't stream much; we show a determinate spinner with elapsed time.
9. → On completion: toast "Snapshot saved — 142 packages" · row appears at top of list, highlighted briefly.

**Export to disk:** Each saved snapshot has `[Export…]` → opens native save dialog → copies the Brewfile to user-chosen location.

### 3.8 Restore from a saved Brewfile (Phase 4) — "Set up new Mac" framing

Two entry points: per-snapshot row `[Restore]`, or a prominent **"Set up this Mac from a Brewfile…"** button at the top of the Snapshots view (also accepts a Brewfile from disk via file picker).

1. > Click `[Restore]` on a snapshot.
2. → **Pre-flight modal** (destructive-ish — it installs many things):
   - Title: "Restore from `<snapshot-name>`?"
   - Subtitle: "This will install packages from the snapshot. Existing packages are skipped."
   - Diff preview: "**142** packages in snapshot · **38** already installed · **104** will be installed · **0** will be removed (Brewfile install is additive)."
   - Estimated time (rough heuristic: 30s × packages-to-install).
   - `[Cancel]` · `[Restore]` (primary, NOT red — additive op).
3. > Click `[Restore]`.
4. ⤷ `brew_bundle_install(path)` invoked. Streams.
5. → Activity drawer opens. Console shows progress per package.
6. → On completion: toast "Restore complete — 104 packages installed" · Library refreshes.

**Set up new Mac flow:** Same modal, but file-picker first → snapshot is loaded (not saved into Snapshots automatically; user can opt-in).

### 3.9 Browse trending packages (Phase 6)

1. > Click **Trending** in sidebar.
2. → On first open per session: loading shimmer.
3. ⤷ `fetch_trending("30d")` invoked. Backend handles 1h memory cache.
4. → Renders table: Rank · Name · Type · Installs (number) · Δ from previous window (Phase 6 stretch).
5. → Window selector top-right segmented control: `30d` (default) · `90d` · `365d`.
6. → Sort: by installs (default desc), by name, by rank-change.
7. → Refresh button top-right (circular arrow icon) with relative timestamp "Updated 14 min ago". Click → force refresh. Auto-refresh: every 1 hour while tab is active (sync with backend cache TTL).
8. > Click row → detail panel (3.2). If not installed, primary button `[Install]` works identically to §3.4.

---

## 4. Long-running command UX

### Decision: Dedicated bottom drawer ("Activity drawer")

Not a modal. Not an inline expanding pane. A **persistent bottom drawer** that opens automatically when any brew command starts, can be minimized to a thin status strip, and is always reachable via the sidebar's **Activity** section.

### Why a bottom drawer

| Option | Verdict |
|--------|---------|
| Modal log overlay | Blocks the UI. Hostile to "let me look something up while this installs." Rejected. |
| Inline expanding pane in detail panel | Fine for one-off install from a detail view, but if user navigates away the log feels lost. Doesn't scale to "upgrade all". |
| **Bottom drawer** | Always reachable, doesn't block the main views, scales from 1 op to N ops, mirrors macOS-native pattern (Xcode bottom debug pane, Terminal split). **Chosen.** |
| Separate window | Overkill for a single-window utility. Adds OS chrome tax. Rejected. |

### Drawer anatomy

```
┌──────────────────────────────────────────────────────────────────────┐
│  Library / Discover / Snapshots / Trending content above             │
├──────────────────────────────────────────────────────────────────────┤
│ ▼ Activity · Installing wget · 0:14 elapsed              [⌃][✕]      │  ← header strip (always visible when an op is running, hidden otherwise unless pinned)
├──────────────────────────────────────────────────────────────────────┤
│  ==> Fetching wget                                                   │
│  ==> Downloading https://ghcr.io/v2/homebrew/core/wget/...           │
│  ######################################################## 100.0%     │
│  ==> Pouring wget--1.21.4.arm64_tahoe.bottle.tar.gz                  │
│  🍺  /opt/homebrew/Cellar/wget/1.21.4: 89 files, 4.5MB               │
└──────────────────────────────────────────────────────────────────────┘
```
- **Sizing:** default height is 280 px (≈ 30% of the 720-px default window). User-draggable handle to resize. The expanded drawer has a 252-px minimum (200-pt console plus drawer chrome) and a maximum of 60% of the current window height. The current height persists across sessions using localStorage on Tauri builds or UserDefaults on SwiftUI builds.
- **Header strip:** current op name, elapsed time, collapse `⌃` and dismiss `✕`. When collapsed, only the strip remains (~32px tall).
- **Console body:** monospace, system mono (SF Mono), 12px. Each event line includes microsecond-relative timestamp on hover. Auto-scroll with smart pause when user scrolls up.
- **History tabs:** when more than one op has run this session, drawer header shows tabs: `wget` (active) · `git (succeeded)` · `node (failed)`. Closing a completed-op tab removes it. The full history is also browsable in the **Activity** sidebar section.

### Progress indication

- **Determinate where possible:** "Upgrading 7 packages — 3/7" derived from counting `==>` lines that match install markers.
- **Indeterminate fallback:** spinner + elapsed timer.
- **Footer dot:** brew status indicator goes amber while any op is running. Tooltip shows current op.

### Can the user start another action while one is running?

**Yes for read-only operations** (browse Library, view detail, search, view Trending — these don't need the brew lock). **No for state-changing operations** (install/uninstall/upgrade/bundle). Per `decisions.md`, the Mutex serializes brew invocations. UI reflects this:

- Install/upgrade/uninstall/restore buttons across the whole UI go disabled with tooltip "A brew operation is already running" while the lock is held.
- Snapshot creation is similarly gated.
- The user can keep exploring, searching, viewing details, switching themes, opening URLs.

### Cancel

- Drawer header `✕` on a running op shows confirmation: "Cancel running install?". On confirm → backend sends SIGTERM to the child `brew` process. Backend reports cleanup state in console (`Process cancelled. brew may have left partial state — see output above.`).
- Cancellation is honest: we do NOT pretend it's instant or clean. `brew` cleanup is `brew`'s responsibility.

---

## 5. Confirm-destructive-action pattern

### Decision: In-page modal (custom Svelte component), not Tauri-native dialog

For all destructive confirmations: **uninstall**, **delete snapshot**, **cancel running op**. (Restore-from-Brewfile uses the same modal component but styled non-destructive since it's additive.)

### Why in-page modal over Tauri-native

| Option | Verdict |
|--------|---------|
| `tauri-plugin-dialog` native dialog | OS-native look, but: (1) limited content — can't show dependents list, diff preview, or checkbox for "remove deps"; (2) async-await ergonomics fight Svelte 5 runes a bit; (3) styling inconsistency vs. our themed UI. Rejected for the main destructive flows. **Kept** for native OS file pickers (snapshot export, Brewfile picker for restore) — that's what they're great at. |
| Inline "are you sure" with timer countdown | Cute (GitHub uses this), but a 3-second wait is friction-tax with no real protection. Rejected. |
| **Custom in-page modal** | Full control over content (dependents, diffs, extra options). Can be themed. Esc-to-cancel, focus-trap, return-key bound to safe (Cancel) action. **Chosen.** |

### Modal anatomy (destructive variant)

```
┌─────────────────────────────────────────────────────┐
│  Uninstall `wget`?                              [✕] │
├─────────────────────────────────────────────────────┤
│  This will remove wget from your system.            │
│                                                     │
│  Dependents that will be orphaned: none             │
│                                                     │
│  ☐ Also remove unused dependencies                  │
│                                                     │
│  ┌──────────────────────┐  ┌───────────────────┐    │
│  │  Cancel    [default] │  │  Uninstall   [⏎]  │    │
│  └──────────────────────┘  └───────────────────┘    │
│                              ↑ red, destructive     │
└─────────────────────────────────────────────────────┘
```

- **Default focus:** Cancel button. Pressing Enter without moving focus = safe.
- **Destructive button:** requires explicit click or Tab-then-Enter. Tinted red.
- **Esc:** closes modal, no action.
- **Backdrop click:** closes modal, no action (matches macOS sheet behavior).

### Applied to:

| Action | Modal copy |
|--------|------------|
| Uninstall package | "Uninstall `<name>`?" — lists dependents |
| Delete saved snapshot | "Delete snapshot `<name>`? The Brewfile will be removed from disk. This cannot be undone." |
| Restore from Brewfile | "Restore from `<name>`?" — non-destructive styling, but shows the diff preview |
| Cancel running operation | "Cancel running <op>? `brew` may leave partial state." |

---

## 6. Empty / loading / error states

### Library

- **Loading:** 8 skeleton rows. Filter chips visible but disabled.
- **Empty (no brew packages installed):** Centered illustration (simple beer-mug glyph), title "No packages installed yet", body "Use Discover to find something to install, or restore from a saved snapshot.", primary CTA `[Open Discover]` · secondary `[Restore Brewfile…]`.
- **Empty (filter no match):** Inline "No packages match `<filter>`" with `[Clear filter]` link.
- **Error (brew not found):** Big banner, title "Homebrew not found.", body "brew-browser couldn't locate `brew` on this Mac. Install Homebrew from brew.sh, then relaunch.", primary CTA `[Open brew.sh]`.
- **Error (brew_list failed):** Inline error card with stderr excerpt and `[Retry]` · `[Copy error]`.

### Discover

- **Empty (no search yet):** Large search input centered, helper text, recent searches (session) below.
- **Loading:** Subtle top progress bar; search input stays interactive.
- **Empty (no results):** "No matches for `<query>`. Try a shorter or different term."
- **Error:** Same pattern as Library.

### Trending

- **Loading:** Skeleton rows + window selector visible.
- **Empty:** N/A in practice — analytics is populated. If somehow empty: "No trending data available. [Refresh]".
- **Error (offline / 4xx / 5xx):** "Couldn't reach `formulae.brew.sh` — `<reason>`. [Retry]". Note: this is the only place the app touches the network beyond brew itself; failure is graceful and explicit.

### Snapshots

- **Empty:** "No snapshots yet. Save your current setup so you can restore it on another Mac." · `[+ New Snapshot]` primary · "Or [Set up this Mac from a Brewfile…]" link below.
- **Loading:** Skeleton rows.
- **Error (FS access):** "Couldn't read snapshots folder — `<path>`. `<reason>`. [Retry]".

### Activity

- **Empty (no ops this session):** "No activity yet. brew commands run by brew-browser appear here."
- **Loading:** N/A (event-driven).

### Detail panel

- **Loading:** Header skeleton + content skeleton lines.
- **Error (brew_info failed):** Panel stays open with error message inline + `[Retry]`.

---

## 7. Trending tab specifics

| Aspect | Decision |
|--------|----------|
| **Default window** | `30d`. Most actionable for "what's hot right now"; matches default `formulae.brew.sh` data freshness. |
| **Available windows** | `30d`, `90d`, `365d` — segmented control top-right. |
| **Refresh cadence** | Cached **1 hour in memory** (backend-side per `techContext.md`). Auto-refresh fires when cache expires while tab is active. Explicit refresh button always available with "Updated <relative-time> ago" label. NO pull-to-refresh (not a native macOS gesture). NO refresh-on-every-open (wastes the API hit; cache is the point). |
| **Default sort** | Installs, descending. |
| **Other sorts** | Name (A–Z), Rank change (Phase 6 stretch — requires fetching two windows). |
| **Row count** | Top 100, infinite-scroll for more (file is small, ~few thousand rows total per window). |
| **Row contents** | Rank · Name · Type pill · Install count (humanized: `1.2M`, `847k`) · Inline "Installed" badge if user has it. |
| **Click row** | Opens detail panel (§3.2). From there, `[Install]` runs the normal install flow (§3.4). |
| **Install from row?** | Phase 6 polish: secondary inline `[+]` button on hover, skips detail-panel step. Confirmation: none (install is non-destructive). |
| **Offline behavior** | If cache exists, show stale data with banner "Showing cached data from <time> — couldn't reach formulae.brew.sh". If no cache, show error state per §6. |

---

## 8. Keyboard shortcuts

Minimum set for v1 (Phase 1–6):

| Shortcut | Action |
|----------|--------|
| **Cmd+K** | Open global command palette |
| **Cmd+1** | Library |
| **Cmd+2** | Discover |
| **Cmd+3** | Trending |
| **Cmd+4** | Snapshots |
| **Cmd+5** | Activity |
| **Cmd+F** / **/** | Focus the in-view filter/search input |
| **Cmd+N** | New snapshot (when in Snapshots) |
| **Cmd+R** | Refresh current view (Library re-runs `brew list`; Trending re-fetches; Discover re-runs current query) |
| **Esc** | Close detail panel, close modal, close palette (priority in that order) |
| **Enter** | Open selected row's detail panel (in any list view) |
| **↑ / ↓** | Navigate rows in any list (including palette results) |
| **Cmd+,** | Open preferences popover |
| **Cmd+L** | Toggle Activity drawer |
| **Cmd+Shift+L** | Cycle theme (light → dark → system → light) |

All shortcuts are discoverable via the command palette (`Cmd+K` then start typing the verb).

---

## 9. First-run experience

**Decision: No onboarding screen. Go straight to Library.**

### Why no onboarding

- The audience is a Mac developer who already has brew installed and knows what brew is. A coachmark tour would be condescending.
- The app is small enough that the sidebar IS the tour.
- The narrative is "honest open" — extra screens feel like funnel design.

### First-launch sequence

1. App launches. Window opens at 1100×720.
2. Sidebar visible. **Library** selected.
3. Background: `brew --version` runs (sub-100ms).
   - **If brew is found:** `brew_list_all()` runs. Skeleton then data. Done.
   - **If brew is NOT found:** Library shows the "Homebrew not found" error state (§6). Other sections are still navigable but show their own brew-required messages. The footer brew status dot is red.
4. **If brew is found but no packages installed** (fresh Mac): Library shows the empty state from §6, which steers user to Discover or Restore. This is the "set up a new Mac" entry point users will hit on day one.

### Subtle first-run nicety

The very first time a user opens **Snapshots** with no snapshots saved, the empty state's secondary text adds: *"Tip: snapshot your current setup before making big changes. brew-browser keeps snapshots in `~/Library/Application Support/brew-browser/brewfiles/` so you can find them outside the app too."* — one line, no dismiss, no asterisk. Disappears once any snapshot exists.

---

## 10. Window structure

### Decision: Single window. Confirm existing defaults from `tauri.conf.json`.

| Property | Value | Rationale |
|----------|-------|-----------|
| Count | 1 | A utility, not a workspace. No multi-doc model. Detail is a slide-over, not a new window. |
| Default size | **1100 × 720** | Matches current `tauri.conf.json`. Confirmed: comfortable for a 2-pane layout (sidebar + main) + bottom drawer. |
| Min size | **800 × 500** | Matches current. Below this, sidebar would crowd the main pane. Confirmed. |
| Resizable | Yes | Default Tauri. Confirmed. |
| Title | "brew-browser" | Matches current. Lowercase, intentional — matches the brand voice. |
| Traffic-light position | macOS default | Don't get fancy; this is a focused utility, not a custom-chrome statement. |
| Window controls | Standard | Close hides window (or quits — decide in Phase 5); min/max standard. |
| Dock icon | Yes | Standard. Placeholder icon Phase 5. |
| Menubar | Standard macOS app menu | File · Edit · View · Window · Help. View menu mirrors sidebar shortcuts (Library Cmd+1 etc.) for discoverability. |
| Full-screen | Allowed | Standard macOS behavior. Sidebar stays visible. |
| Multi-display | Standard | Remembers last-window-position via Tauri default. |

**No second window** for: detail (panel), console (drawer), preferences (popover), modals (in-page). Single-window keeps the mental model crisp and matches the "small focused utility" vibe.

---

## 11. ASCII wireframes

### 11.1 Main view (Library, loaded, with one op running)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ brew-browser                                                                       ⏤ ▢ ✕ │
├──────────────┬───────────────────────────────────────────────────────────────────────────┤
│              │  Library                                                  🔍 filter…  / │ │
│  ▸ Library 142│                                                                          │
│  Discover    │  ┌──────────────────────────────────────────────────────────────────────┐ │
│  Trending    │  │ All  Formulae  Casks  Outdated (7)                                   │ │
│  Snapshots  3│  └──────────────────────────────────────────────────────────────────────┘ │
│  Activity   1│                                                                           │
│              │  Name              Version       Type      Outdated                       │
│              │  ────────────────────────────────────────────────────────────────────     │
│              │  bat               0.24.0        formula                                  │
│              │  fzf               0.46.1        formula   ⟶ 0.47.0                       │
│              │  git               2.44.0        formula                                  │
│              │  go                1.22.1        formula   ⟶ 1.22.3                       │
│              │  htop              3.3.0         formula                                  │
│              │  iterm2            3.5.0         cask                                     │
│              │  jq                1.7.1         formula                                  │
│              │  node              22.1.0        formula   ⟶ 22.2.0                       │
│              │  rectangle         0.78          cask                                     │
│              │  ripgrep           14.1.0        formula                                  │
│              │  …                                                                        │
│              │                                                                           │
│ ─────────────│                                                                           │
│  ☼ ◐ ●  Theme│                                                                           │
│  ● brew 5.1.13                                                                           │
├──────────────┴───────────────────────────────────────────────────────────────────────────┤
│ ▼ Activity · Installing wget · 0:14 elapsed                                  [⌃] [✕]    │
│ ==> Fetching wget                                                                        │
│ ==> Downloading https://ghcr.io/v2/homebrew/core/wget/manifests/1.21.4                   │
│ ######################################################################## 100.0%         │
│ ==> Pouring wget--1.21.4.arm64_tahoe.bottle.tar.gz                                       │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 11.2 Detail panel open (slide-over from right, Library still visible)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ brew-browser                                                                       ⏤ ▢ ✕ │
├──────────────┬─────────────────────────────────────┬─────────────────────────────────────┤
│              │  Library            🔍 filter…   /  │  ripgrep                       [✕]  │
│  ▸ Library   │                                     │  formula                            │
│  Discover    │  All  Formulae  Casks  Outdated     │  ─────────────────────────────────  │
│  Trending    │                                     │  Installed: 14.1.0                  │
│  Snapshots   │  Name        Version     Type       │  Latest:    14.1.0 (up to date)    │
│  Activity    │  ─────────────────────────────      │                                     │
│              │  bat         0.24.0      formula    │  Recursively search directories     │
│              │  fzf         0.46.1      formula    │  for a regex pattern, fast.         │
│              │  git         2.44.0      formula    │                                     │
│              │  ▸ ripgrep   14.1.0      formula    │  Homepage    github.com/BurntSus…↗ │
│              │  node        22.1.0      formula    │  License     MIT or Unlicense       │
│              │  …                                  │                                     │
│              │                                     │  ▾ Dependencies (0)                 │
│              │                                     │  ▸ Dependents (2)                   │
│              │                                     │                                     │
│              │                                     │  Caveats: none                      │
│              │                                     │                                     │
│ ─────────────│                                     │  ─────────────────────────────────  │
│  ☼ ◐ ●  Theme│                                     │  [ Reinstall ]   [ Uninstall ]      │
│  ● brew 5.1.13                                     │                                     │
└──────────────┴─────────────────────────────────────┴─────────────────────────────────────┘
```

### 11.3 Activity drawer fully expanded (mid-install)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ brew-browser                                                                       ⏤ ▢ ✕ │
├──────────────┬───────────────────────────────────────────────────────────────────────────┤
│              │  Activity                                                                 │
│  Library     │  ┌────────────────────────────────────────────────────────────────────┐   │
│  Discover    │  │  wget (running)  ·  git (✓ 0:08)  ·  node (✗ failed)              │   │
│  Trending    │  └────────────────────────────────────────────────────────────────────┘   │
│  Snapshots   │                                                                           │
│  ▸ Activity 1│  $ brew install wget                                                      │
│              │                                                                           │
│              │  ==> Fetching dependencies for wget: gettext, libidn2                     │
│              │  ==> Fetching gettext                                                     │
│              │  ==> Downloading https://ghcr.io/v2/homebrew/core/gettext/...             │
│              │  ######################################################## 100.0%         │
│              │  ==> Pouring gettext--0.22.5.arm64_tahoe.bottle.tar.gz                    │
│              │  🍺  /opt/homebrew/Cellar/gettext/0.22.5: 2,071 files, 22.4MB             │
│              │  ==> Fetching libidn2                                                     │
│              │  ==> Downloading https://ghcr.io/v2/homebrew/core/libidn2/...             │
│              │  ##############################                          45.7%   ▌       │
│              │                                                                           │
│              │  ─────────────────────────────────────────────────────────────────────    │
│              │  Started 0:14 ago  ·  pid 47213  ·  [Pause autoscroll]  [Copy log]  [✕]   │
│ ─────────────│                                                                           │
│  ☼ ◐ ●  Theme│                                                                           │
│  ● brew 5.1.13                                                                           │
└──────────────┴───────────────────────────────────────────────────────────────────────────┘
```

### 11.4 Destructive confirmation modal (Uninstall)

```
                ┌──────────────────────────────────────────────────┐
                │  Uninstall `node`?                          [✕]  │
                ├──────────────────────────────────────────────────┤
                │                                                  │
                │  This will remove node from your system.         │
                │                                                  │
                │  Dependents that will be orphaned:               │
                │   • npm-installed global packages will break     │
                │                                                  │
                │  ☐ Also remove unused dependencies               │
                │                                                  │
                │  ────────────────────────────────────────────    │
                │                                                  │
                │         ┌──────────┐    ┌──────────────┐         │
                │         │  Cancel  │    │  Uninstall   │         │
                │         └──────────┘    └──────────────┘         │
                │           default            red                 │
                └──────────────────────────────────────────────────┘
```

### 11.5 Command palette (Cmd+K)

```
              ┌────────────────────────────────────────────────────────────┐
              │  🔍  wge|                                              Esc │
              ├────────────────────────────────────────────────────────────┤
              │  INSTALLED                                                 │
              │    ▸ wget                       formula      installed     │
              │                                                            │
              │  INDEX                                                     │
              │      wgetpaste                  formula                    │
              │      wgrib                      formula                    │
              │      wgrib2                     formula                    │
              │                                                            │
              │  COMMANDS                                                  │
              │      Refresh Library                              Cmd+R    │
              │      New Snapshot…                                Cmd+N    │
              │      Toggle Activity drawer                       Cmd+L    │
              ├────────────────────────────────────────────────────────────┤
              │  ↑↓ navigate  ⏎ open  Esc close                            │
              └────────────────────────────────────────────────────────────┘
```

---

## Appendix: Open questions for other agents

- **UI Designer:** Need final color tokens for: brew-status dot (green/amber/red), destructive button red, "outdated" chevron color, type-pill background colors (formula vs. cask differentiation). Also need monospace font choice for the Activity drawer console.
- **Backend Architect:** Confirm that `brew_install/uninstall/upgrade` events emit cleanly-typed `{ op_id, stream: "stdout"|"stderr", line, ts }` payloads — the drawer's "tabs per op" pattern depends on `op_id`. Also confirm cancellation API (SIGTERM via op_id).
- **Lead:** Confirm preference defaults (confirm-install default OFF; confirm-uninstall default ON; trending cache TTL 1h). And confirm Cmd+W behavior (hide vs. quit) for Phase 5.

---

**End of spec. Implementation by Frontend Developer in Wave 2 should trace every component back to a flow or wireframe above.**
