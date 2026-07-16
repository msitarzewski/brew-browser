# M5 — Live-refresh & the contribution pipeline

**Goal:** make the recipe set updatable without an app release, and make community contribution a validated, low-friction PR. This is what turns Bundles from "6 hardcoded recipes" into a living, contributor-driven surface.

**Depends on:** M2 (contract + `bundles.json` artifact + validate script). **Parallel to:** M4.

## Scope
- **In:** live-refresh of `bundles.json` (opt-in, host-served, like enrichment/trending); the CI GitHub Action running `validate-recipes.mjs` on every PR touching `recipes/`; `CONTRIBUTING-bundles.md`; publishing the concatenated artifact to the host.
- **Out:** in-app recipe authoring (non-goal — contribution is via PR).

## Live-refresh (mirror enrichment/trending exactly)
- Bundled `bundles.json` ships in the app (M2) and always works offline. A **Settings → Network** opt-in fetches the latest `bundles.json` from the project host (same trust boundary + gating as the enrichment/trending-history endpoints — NOT a Homebrew path).
- Host path: `<brew-browser host>/bundles/bundles.json` (keep the actual host out of committed source — env/config, per the project rule). TTL + cache like the catalog (default off; weekly/daily opt-in).
- Both shells: reuse the enrichment/trending live-fetch service pattern (Rust `EnrichmentLiveService` analog; native `EnrichmentLiveService` analog). Newer bundled schema always wins if the live file is older-schema (fail-soft).
- **Retune-without-release:** because `requires`/`capabilityNotes` live in the data, a threshold change ("bump Image Gen to 20 GB") is a data push, not an app build.

## Contribution pipeline
```
contributor: add recipes/<id>.json  ──PR──►  GitHub Action: validate-recipes.mjs
   ├─ schema (recipe.schema.json, Draft 2020-12)
   ├─ id unique + kebab-case
   ├─ brew info --json=v2 resolves every package to its kind (+ tap-trust rule)
   ├─ requires sane · command steps external:true · links https + HEAD<400
   └─ emit a pass/fail table as a PR check + comment
   ▼ merge ▼
release/publish job: concat valid recipes ► bundles.json ► (a) committed for the next app build, (b) rsynced to the live host
```
- **CI Action:** `.github/workflows/validate-recipes.yml` — runs on PRs touching `recipes/**`; needs Homebrew available on the runner (`brew info` resolution). Cache brew to keep it fast. First-party recipes are validated by the same job (no special-casing).
- **`CONTRIBUTING-bundles.md`** (repo root or `docs/`): the human onramp — copy an existing recipe, fill the fields, run `node scripts/validate-recipes.mjs` locally, open a PR; links to [recipe-contract.md](./recipe-contract.md) and [capability-baselines.md](./capability-baselines.md) for the requirements reasoning.

## Governance (lightweight)
- `maintainer` field records provenance. First-party recipes = `brew-browser`.
- A recipe that later fails CI (cask renamed/removed) → the publish job drops it from the live `bundles.json` and opens a tracking issue; the bundled copy degrades gracefully (package resolves at install time or shows an error in Activity).
- Scope guard: recipes are **brew-installable stacks with guidance** — no recipe may add an auto-run external command (contract forbids it), and reviewers reject stacks whose value is entirely non-brew.

## Tests
- `validate-recipes.mjs` unit-style fixtures: a valid recipe passes; each contract violation (bad id, missing package kind, third-party tap w/o `tap`, `external:false` command, http link, dead link) fails with a clear message.
- CI dry-run on the six first-party recipes → all pass.
- Live-refresh: schema-version-skew test (older app + newer file → fail-soft to bundled) mirrors the enrichment cache test.

## Acceptance criteria
- Opening a PR that adds a valid `recipes/foo.json` goes green with no maintainer code; an invalid one gets a red check naming the exact rule it broke.
- Turning on the Bundles live-refresh opt-in pulls an updated `bundles.json` from the host; turning it off falls back to the bundled copy; offline works throughout.
- A `requires` retune shipped via the host changes readiness verdicts without an app update.

## Risks
- CI needs brew on the runner — macOS runner or `brew` on Linux (Linuxbrew); keep the resolution step cached/fast.
- Live `bundles.json` is attacker-relevant only insofar as it lists brew tokens (install is still an explicit user action + brew's own trust); no code, no auto-run — the contract's "no external auto-run" keeps the blast radius to "installs a package you clicked install on".
