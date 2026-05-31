# Tasks — 2026-05

Per-task records for May 2026 work on brew-browser. **Retroactively reconstructed on 2026-05-25** from `progress.md` + git commit history (commits `653e26f` through `928bbcb` plus the in-progress Phase 15).

## Index

| # | Task | Date | Commit | Release |
|---|---|---|---|---|
| 01 | [v0.1.0 initial release (Phases 0-8 + initial audit)](./01-v0.1.0-initial-release.md) | 2026-05-23 | `653e26f` | v0.1.0 |
| 02 | [Categorize bulk run + initial landing page](./02-categorize-bulk-run-and-landing.md) | 2026-05-24 | `c72e31d`, `2dad9be` | — |
| 03 | [Release pipeline: signed + notarized .dmg](./03-release-pipeline-signed-notarized.md) | 2026-05-24 | `cb60e4a` | — |
| 04 | [NEXT-SESSION handoff doc](./04-next-session-handoff-doc.md) | 2026-05-24 | `c2ab41f` | — |
| 05 | [Phase 9 — Discover category UI + chip linking + sortable columns](./05-phase-9-category-linking.md) | 2026-05-24 | `84ad010` (½) | — |
| 06 | [Phase 11 — Dashboard + Services + native macOS feel + Activity persistence](./06-phase-11-dashboard-services-vibrancy-persistence.md) | 2026-05-24 | `84ad010` (½) | — |
| 07 | [Phase 12 Wave 1+2 — bundled catalog + Settings + paranoid mode + GitHub anon + Device Flow](./07-phase-12-wave-1-2-catalog-settings-paranoid-github.md) | 2026-05-24 | `99a1f2c` | — |
| 08 | [Phase 12f + 13 — GitHub authed actions + catalog enrichment infrastructure](./08-phase-12f-13-github-authed-enrichment-infra.md) | 2026-05-24 | `8b89c40` | — |
| 09 | [Phase 12g/13b cleanup + Tier A enrichment baked + polish pass](./09-phase-12g-13b-cleanup-tier-a-bake-and-polish.md) | 2026-05-24 | `e1d6a87` | — |
| 10 | [v0.2.0 release — title bar + sidebar restructure + info popovers + intercept GitHub flow](./10-v0.2.0-release-title-bar-sidebar-restructure.md) | 2026-05-24 | `f556441` | v0.2.0 |
| 11 | [GitHub auth hydration + sign-in toast fixes](./11-github-auth-hydration-fixes.md) | 2026-05-24 | `e04dbff` | (rolled into v0.2.1) |
| 12 | [v0.2.1 release hotfix — lazy Keychain probe + attribution fix + real screenshots](./12-v0.2.1-release-hotfix.md) | 2026-05-24 | `928bbcb` | v0.2.1 |
| 13 | [Phase 15 — In-app updater + Offline Mode rename](./13-phase-15-updater-and-offline-mode-rename.md) | 2026-05-25 | uncommitted | target v0.3.0 |
| 14 | [Issue #1 hunt — starredCache infinite-loop fix](./14-issue-1-hunt-cache-loop.md) | 2026-05-25 | uncommitted | target v0.3.0 |
| 15 | [GitHub integration completion (toast pattern + scope parsing + watch scope + per-action gate + Octocat chip + re-auth UX)](./15-github-integration-completion.md) | 2026-05-25 | uncommitted | target v0.3.0 |
| 16 | [Phase 15 fix-up pass: 5 CRITICAL findings resolved](./16-phase-15-fixup-pass.md) | 2026-05-25 | `1bfe21f` | v0.3.0 |
| 17 | [Expand GitHub package resolution beyond homepage field](./17-github-resolution-beyond-homepage.md) | 2026-05-25 | `820c1f0` | v0.3.0 |
| 18 | [v0.3.1 release — magic search + curated upgrade + identity cleanup + lists overhaul](./18-v0.3.1-release.md) | 2026-05-25 | `6b97e65` (prep) + `v0.3.1` tag | v0.3.1 |
| 19 | [v0.4.0 ship — velocity scoring + opt-in history endpoint (backend + frontend + collector + docs)](./19-v0.4.0-backend.md) | 2026-05-26 | branch `feat/v0.4.0-velocity-and-history` | target v0.4.0 |
| 20 | [v0.5.0 ship — opt-in vulnerability scanning via brew vulns + optional GHSA enrichment](./20-v0.5.0-vulnerability-scanning.md) | 2026-05-27 | branch `feat/v0.5.0-vulnerability-scanning` | target v0.5.0 |
| 21 | [override manual install — detect manual app installs, prompt and force install safely](./21-override-manual-install.md) | 2026-05-31 | commit `8bcb493` | target v0.5.1 / PR feedback |
| 99 | [Deferred / dropped tasks](./99-deferred-and-dropped.md) | (ongoing) | — | — |

## Reconstruction notes

- **Tasks 01-12 are retroactive** — written 2026-05-25 from `progress.md` + git log. The protocol in `toc.md` specified `tasks/YYYY-MM/*.md` from day 1 but wasn't followed.
- **Task 13 is contemporaneous** — Phase 15 is in-progress as this file is written.
- **Task numbering is chronological, not commit-order strict** — the `e04dbff` GitHub-auth fixes commit (task 11) sits chronologically before `928bbcb` (task 12 = v0.2.1) but both shipped on the same day; v0.2.1 absorbs `e04dbff` and ships it as one release. Numbering reflects shipping reality.
- Tasks 05 + 06 split the single `84ad010` commit because Phase 9 (category linking) and Phase 11 (Dashboard / Services / vibrancy / persistence) are conceptually distinct work even though they shipped together.
- Tasks 02 share commits intentionally — the LLM categorize run and the landing page were two separate workstreams that happened to land in the same commit; splitting them across files would lose the parallel-tracks story.

## Going forward

New task records land here per shipped unit of work — typically one per phase or per release. Format is consistent: title + status + commit + release + scope + what landed + files + tests + notes. See `01-v0.1.0-initial-release.md` for the canonical shape.

When May rolls into June: new directory `memory-bank/tasks/2026-06/` with its own README.md index.
