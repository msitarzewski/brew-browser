# M2 — Recipe contract & loader

**Goal:** define the recipe data (the **[recipe contract](./recipe-contract.md)**), ship the initial curated recipes bundled into both apps, and parse them tolerantly on both shells. This is where "contributors add a recipe against a contract" becomes real.

**Depends on:** M1 (`BundleRequires`/readiness types). **Blocks:** M3 (needs bundles to render), M5 (live-refresh + CI of the same artifact).

## Scope
- **In:** JSON Schema (`recipe.schema.json`), `recipes/*.json` (the ~6 first-party recipes grounded in [capability-baselines.md](./capability-baselines.md)), the build step that concatenates them into `bundles.json`, the bundled-data plumbing + tolerant parsers both shells, parse unit tests.
- **Out:** UI (M3), live-refresh + CI action (M5 — but author the validate script here so recipes are checkable as they're written).

## Data flow (mirrors catalog/enrichment/trending)
```
recipes/<id>.json  ──(validate + concat, build script)──►  bundles.json
bundles.json  ──bundled at build──►  Tauri: src-tauri/resources/ (or the catalog bundling path)
              └─bundled at build──►  native: Sources/BrewBrowserKit/Resources/ (Bundle.module)
              └─(M5) published──────►  live-refresh host
```
`bundles.json` = `{ "schemaVersion": 1, "generatedAt": "...", "bundles": [ <recipe>... ] }`.

## The initial recipes (author under the contract)
Six files in `recipes/`, tokens/requires from [capability-baselines.md](./capability-baselines.md):
- `local-llm.json` — `ollama` (formula) + `open-webui` (cask); requires 8/16/12; setup: start ollama · `ollama pull llama3.2` (external) · open :8080.
- `image-gen.json` — `comfy` (cask); requires 16/24/30, apple-silicon, gpu required; heavy caveats.
- `graphics.json` — `inkscape`,`gimp`,`krita` (casks); no requires.
- `media.json` — `ffmpeg`,`yt-dlp`,`mpv` (formulae); no requires.
- `web-dev.json` — `node` (+ TBD); light.
- `databases.json` — `postgresql@16`,`redis` (formulae); setup: start services.

## Tauri (Rust + TS)
- **Types:** `Bundle`, `BundlePackage`, `BundleRequires`, `SetupStep` in `src-tauri/src/types.rs` (serde, `#[serde(default)]` everywhere) + the TS mirror in `src/lib/types.ts`.
- **Loader:** mirror the catalog/enrichment bundling. Either bake `bundles.json` into the binary (like the bundled catalog) exposed via a `bundles() -> Vec<Bundle>` command, or read it from the resources dir. Tolerant deserialize (unknown fields ignored; a bad single recipe is skipped, not fatal — collect + log).
- **Store:** `src/lib/stores/bundles.svelte.ts` — loads bundles, holds them; readiness computed client-side (M1's `readiness.ts`) against the M1 profile.

## Native (Swift)
- **Models:** `Bundle`, `BundlePackage`, `BundleRequires`, `SetupStep` structs in a new `Bundles.swift` (mirror `Categories`/enrichment models). Tolerant `Decodable` (optional fields, per-recipe try/skip).
- **Loader:** `BundleCatalog` service that parses the bundled `bundles.json` from `Bundle.module` off the main thread at launch (same pattern as `loadBundledData()` for categories/enrichment). Expose on `AppModel` (`var bundles: [Bundle]`).
- Readiness via M1's `BundleReadiness.readiness(_:_:)` against the cached `SystemProfile`.

## Validation script (author now; wired to CI in M5)
- `scripts/validate-recipes.mjs` (Node, no deps or ajv): for each `recipes/*.json` → schema-validate, id-unique, `brew info --json=v2` resolves each package to its declared kind, third-party tap ⇒ `tap` field required, `requires` sane, `command` steps `external:true`, `links` https + HEAD < 400 (whitelist known bot-blockers), string caps. Emits a pass/fail table. Also concatenates passing recipes → `bundles.json`.
- Run it locally in M2 so the six recipes are known-valid before M3 renders them.

## Tests (parity)
- **Parse tests both shells:** a fixture `bundles.json` with (a) a full recipe, (b) a recipe with only required fields, (c) an unknown-field recipe (must ignore), (d) a malformed recipe (must skip, not crash the batch). Assert the good ones parse and requires/setup map correctly. (Rust: `types`/loader test; native: `BundleParsingTests.swift`; vitest for the TS types if a transform exists.)
- **Schema self-test:** `validate-recipes.mjs` passes on all six first-party recipes.

## Acceptance criteria
- Six recipes exist, all pass `validate-recipes.mjs` (schema + brew-resolves + links reachable).
- Both apps load the bundled `bundles.json` and expose the six bundles with correct packages/requires/setup.
- A deliberately-malformed 7th recipe is skipped by both parsers without breaking the other six.
- No app code change is needed to add a valid recipe — only the JSON file.

## Risks
- **Cask drift:** `comfy`/`open-webui` are real casks today but niche; CI's `brew info` resolution catches renames/removals at PR time. Live-refresh (M5) lets us fix a broken recipe without an app release.
- **Bundling path parity:** confirm where each shell bundles static JSON (Tauri resources vs native `Bundle.module`) — reuse the exact catalog/enrichment path, don't invent a new one.
