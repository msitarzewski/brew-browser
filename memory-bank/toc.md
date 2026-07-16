# Memory Bank — brew-browser

Project-scoped memory bank. **All agents working on this project read from and write to this directory.** Source of truth for design decisions, architectural choices, current state, and inter-agent insights.

## Quick-read order (every session)

1. `NEXT-SESSION.md` — current state + outstanding work, refreshed every milestone
2. `activeContext.md` — what's happening *right now* (the current wave / phase)
3. `progress.md` — the chronological log; latest entry covers the most recent release
4. Latest `tasks/YYYY-MM/*.md` records — per-shipped-unit detail

## File map

### Top-level docs

| File | Owner | Read by | Write when |
|------|-------|---------|------------|
| `toc.md` | Lead | all | structure changes |
| `NEXT-SESSION.md` | Lead | all (every session) | every milestone or release |
| `projectbrief.md` | Lead | all | mission shifts |
| `techContext.md` | Lead | all | new tech adopted |
| `decisions.md` | all | all | architectural decision made |
| `activeContext.md` | Lead | all | every wave start/end |
| `progress.md` | Lead | all | phase completes |
| `systemPatterns.md` | Backend Architect + Frontend Developer | all | new pattern emerges |
| `designSystem.md` | UI Designer | Frontend Developer, Whimsy Injector | design decisions |
| `uxArchitecture.md` | UX Architect | Frontend Developer, UI Designer | flow/IA decisions |
| `visualStory.md` | UI Designer | all | screenshot/voice/visual plans |
| `backendApi.md` | Backend Architect | Frontend Developer, API Tester | API surface changes |
| `frontendComponents.md` | Frontend Developer | UX Architect, Code Reviewer | component built |
| `codeReview.md` | Code Reviewer | Lead, Backend Architect, Frontend Developer | review pass done |
| `realityCheck.md` | Reality Checker | Lead | production gate evaluated |
| `apiTests.md` | API Tester | Backend Architect | tests defined/run |
| `accessibility.md` | Accessibility Auditor | UI Designer, Frontend Developer | a11y audit pass |
| `security.md` | Security Engineer | all | release-time + on new outbound surface |
| `agentLog.md` | all | Lead | each agent run (append-only stamp) — *currently dormant; re-enable if desired* |
| `ideas.md` | Lead | all | candidate feature surfaces |

### Subdirectories

| Path | Owner | Contents |
|------|-------|----------|
| `tasks/YYYY-MM/*.md` | Lead | Per-shipped-unit task records. One file per phase or release. See `tasks/2026-05/README.md` for index. |
| `phases/phaseNN-plan.md` | Lead | **Shipped** phase plans (Phase 12, Phase 13, Phase 15, etc.) — design-time intent preserved as historical context. In-flight plans live at `memory-bank/phase{N}-plan.md` (top level) while active, then move to `phases/` when the phase ships. **No in-flight plan as of v0.3.0.** |
| `releases/<version>/` | Lead | Per-release working directory: `README.md` (release tracker — contents, checklist, open items) + feature plans for that release. Current: `releases/0.7.0/` (0.7.0 / native 0.3.0 — pin/unpin shipped, Bundles planned). |
| `scans/YYYY-MM-DD/*` | Security Engineer | Point-in-time outputs from `cargo audit`, `cargo deny`, `semgrep`, `gitleaks`, etc. Date-stamped folders. Latest scans should match `security.md`'s most recent §N audit. |

## Agent collaboration protocol

1. **Read first.** Before writing, every agent reads at minimum: `NEXT-SESSION.md`, `projectbrief.md`, `activeContext.md`, `decisions.md`, the latest `tasks/YYYY-MM/*.md` records, and any files in their "Read by" column above.
2. **Write only your owned files.** Agents do not modify each other's spec files. To request a change, append a note to the file with `// REQUEST FROM <agent>:` and the owning agent integrates.
3. **Decisions go in `decisions.md`.** Any architectural choice (library pick, pattern adopted, tradeoff resolved) gets an ADR entry.
4. **No code generation without spec.** Implementation agents (Backend Architect, Frontend Developer) only write code that traces back to a spec file. If the spec is missing, write the spec first.
5. **Phase plans live at `memory-bank/phase{N}-plan.md` while in-flight, then move to `memory-bank/phases/phase{N}-plan.md` after the phase ships.** Keeps the top-level focused on what's actually active.
6. **Per-task records land in `tasks/YYYY-MM/{NN-slug}.md`** alongside the commit that ships them. See `tasks/2026-05/README.md` for the canonical shape; `tasks/2026-05/99-deferred-and-dropped.md` for the running ledger of work explicitly NOT shipped.
7. **Security scan artifacts go in `scans/YYYY-MM-DD/`** — each tool battery run gets its own dated folder so the historical trail is preserved.

## Conventions currently in use

- ✅ `NEXT-SESSION.md` rewritten at every milestone
- ✅ `tasks/YYYY-MM/` populated per shipped unit (retroactively backfilled 2026-05-25; current cadence: contemporaneous)
- ✅ `phases/` for shipped plans, top-level for in-flight (Phases 12, 13, 15 in `phases/`; no in-flight plan currently)
- ✅ `scans/YYYY-MM-DD/` for tool-battery snapshots
- ✅ `security.md` §N appended per release-time audit
- ✅ Release notes (project-level, not memory-bank) live at `docs/release-notes/<version>.md` — one file per shipped release, fed to `gh release create --notes-file`. Started with v0.3.0.
- ⚗️ Native rebuild experiment lives in `native/` (branch `experiment/native-swift-liquid-glass`) with its own `native/README.md`; design context in `decisions.md` + `techContext.md` + `tasks/2026-05/21-*`.

## Project root vs memory-bank

Memory-bank is for **design + decision context** (specs, plans, audits, task records, ADRs). Project root + `docs/` are for **user/contributor-facing artifacts**:

- **Root `.md` files** are limited to GitHub conventions (`README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `LICENSE`) plus AI-workflow files that need root for tool discovery (`AGENTS.md` and the `CLAUDE.md` symlink).
- **`docs/`** holds everything else surfaced to users and contributors: `BUILD.md` (maintainer build flow), `PLAN.md` (full design + phase tracker), `PHILOSOPHY.md` (positioning), plus `release-notes/`, `icon/`, `screenshots/`.

If you're tempted to add a new top-level `.md` at the repo root, put it in `docs/` unless it's required there by a convention.

**Native rebuild experiment (branch `experiment/native-swift-liquid-glass`):** the
native Swift/SwiftUI/Liquid Glass port lives in `native/` as a Swift Package, with
its own contributor-facing `native/README.md` (build loop + source map). It's a
port of the shipped Tauri interface, not a separate product. Design/decision
context for it lives in the memory bank as usual: `decisions.md` (2026-05-30 ADR),
`techContext.md` ("Native rebuild" section), and `tasks/2026-05/22-native-swift-liquid-glass-rebuild.md`.

## Live vs historical entries within memory-bank

Some files are **live** (always reflect current state) and some are **historical** (snapshots of past state, immutable once written):

- **Live** — keep current: `toc.md`, `activeContext.md`, `NEXT-SESSION.md`, `decisions.md`, `projectbrief.md`, `techContext.md`, `systemPatterns.md`, `designSystem.md`, `uxArchitecture.md`, `visualStory.md`, `backendApi.md`, `frontendComponents.md`, `codeReview.md`, `realityCheck.md`, `apiTests.md`, `accessibility.md`, `security.md`, `ideas.md`.
- **Historical** — append-only, do NOT rewrite past entries: `progress.md` (chronological log), `agentLog.md` (per-run stamps), `tasks/YYYY-MM/*.md` (per-shipped-unit records), `scans/YYYY-MM-DD/*` (point-in-time tool output), `phases/*.md` (shipped phase plans frozen at ship time).

When the project changes (e.g., a file moves), update live docs to reflect the new state; leave historical entries alone — they're correct for the moment they describe.

## Conventions currently dormant

- ⏸ `agentLog.md` append-on-every-run stamping — sparse since Phase 12; Wave 1 parallel agents in Phase 15 didn't stamp. Either re-enable by including "append one line to agentLog.md" in every Agent prompt, or drop this protocol item.

## Conventions explicitly dropped

(none yet)
