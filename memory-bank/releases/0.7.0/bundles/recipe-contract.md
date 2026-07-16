# Bundle Recipe Contract (v1)

The normative spec a **recipe** must satisfy. Contributors add one JSON file per recipe; CI validates it against this contract. The app never trusts a recipe it can't validate. Implemented by **[M2](./m2-recipe-contract-and-loader.md)**; capability numbers come from **[capability-baselines.md](./capability-baselines.md)**.

> **Design goal:** a non-maintainer can open a PR that adds `recipes/<id>.json`, and CI alone decides if it's mergeable — no app code change, no maintainer judgement call for the common case.

## Where recipes live
- **Source of truth:** one file per recipe at `recipes/<id>.json` (repo root or `data/recipes/`, decided in M2). One-file-per-recipe keeps PR diffs clean and avoids merge conflicts in a monolithic file.
- **Build artifact:** CI concatenates all valid recipes into `bundles.json` (schema `{ schemaVersion, generatedAt, bundles: [...] }`), which is (a) bundled into both apps at build time and (b) published to the live-refresh host (M5). The apps only ever read the concatenated artifact.
- **JSON Schema:** `recipes/recipe.schema.json` (Draft 2020-12) is the machine-checkable half of this contract; this doc is the human half. They must agree.

## Recipe shape
```jsonc
{
  "id": "local-llm",                 // REQUIRED. kebab-case, unique, STABLE (it's the persistence key). ^[a-z0-9]+(-[a-z0-9]+)*$
  "name": "Local LLMs",              // REQUIRED. Display name. ≤ 40 chars.
  "tagline": "Run models locally with Ollama + a web UI", // REQUIRED. One line. ≤ 90 chars.
  "description": "Run open-weight models entirely on your own machine …", // optional. 2–4 sentence "intent" paragraph: what this bundle is / who it's for / why these tools. DISTINCT from the short tagline and from caveats. 40–600 chars.
  "category": "AI",                  // REQUIRED. enum: AI | Graphics | Media | Development | Data | Productivity
  "icon": "brain",                   // optional. lucide (Tauri) / SF Symbol (native) — a name that exists in BOTH maps, or omit for a default.
  "packages": [                      // REQUIRED. ≥ 1. Order = display + install order.
    { "name": "ollama",     "kind": "formula" },
    { "name": "open-webui", "kind": "cask" }
  ],
  "tap": null,                       // optional. "user/repo" — an EXTRA tap to add (+ trust, Homebrew 6.0) before install. null = all packages are in homebrew/core or homebrew/cask.
  "requires": {                      // optional. Absent = "runs anywhere" (always Ready).
    "minRamGB": 8,                   // hard floor: below this → Not recommended (still installable behind a confirm).
    "recommendedRamGB": 16,          // at/above → Ready; between min and recommended → Marginal.
    "minDiskGB": 12,                 // free-disk floor.
    "arch": "any",                   // any | apple-silicon | intel. Mismatch → Not recommended (with reason).
    "gpu": "preferred"               // none | preferred | required.
  },
  "capabilityNotes": {               // optional. RAM-tier (GB, as string key) → human note. Used to phrase the readiness reason. Keys are the LOWER bound of each tier.
    "8":  "small (~7–8B Q4) models only; larger will swap",
    "16": "13–14B comfortably",
    "32": "32B class",
    "64": "70B models"
  },
  "setup": [                         // optional, ordered post-install steps. See "Setup steps" below.
    { "kind": "service", "service": "ollama", "label": "Start Ollama" },
    { "kind": "command", "run": "ollama pull llama3.2", "label": "Pull a starter model", "external": true },
    { "kind": "open",    "url": "http://localhost:8080", "label": "Open Open WebUI" }
  ],
  "caveats": "Installs the tools; you still download models (several GB).", // optional. Shown prominently. ≤ 240 chars.
  "links": [                         // optional. Further reading. Every url MUST be https and reachable (CI HEAD-checks).
    { "label": "Ollama docs",  "url": "https://docs.ollama.com" },
    { "label": "Open WebUI",   "url": "https://openwebui.com" }
  ],
  "maintainer": "brew-browser",      // optional. GitHub handle or "brew-browser" for first-party.
  "addedIn": "0.7.0"                 // optional. Provenance.
}
```

## Setup steps — the automation boundary
Each step is one of four kinds. **Only brew-native kinds auto-run; everything else is copy-only.** This is a hard rule (the app never executes arbitrary shell).

| kind | fields | behavior |
|---|---|---|
| `service` | `service`, `label` | Renders a button → `brew services start <service>` (reuses the existing Services action). Auto-runnable. |
| `open` | `url`, `label` | Button → open the URL via the existing `safeOpenUrl` (http/https allowlist). Auto-runnable. |
| `reveal` | `path`, `label` | Button → reveal a path in Finder / file manager. Auto-runnable. |
| `command` | `run`, `label`, `external: true` | A **copy-only** row (copy-to-clipboard). `external: true` is **required** — the contract forbids an auto-runnable arbitrary command. |
| `note` | `text` | A markdown info line. No action. |

## Validation (CI must pass — the actual contract)
A recipe is mergeable iff **all** hold:
1. **Schema**: validates against `recipe.schema.json` (Draft 2020-12).
2. **id**: matches `^[a-z0-9]+(-[a-z0-9]+)*$`, unique across all recipes.
3. **packages**: ≥1; each `kind ∈ {formula, cask}`.
4. **brew resolution**: every package resolves via `brew info --json=v2 <name>` to the declared `kind`. If its `tap` is **not** `homebrew/core`/`homebrew/cask`, the recipe **must** declare that tap in the top-level `tap` field (so the app can add + `brew trust` it — Homebrew 6.0). CI fails a third-party-tapped package with no `tap` declared.
5. **requires**: if present, `minRamGB ≤ recommendedRamGB`, all numbers > 0, `arch`/`gpu` in enum.
6. **setup**: `command` steps have `external: true`; `service` steps name a real brew service (best-effort: the service package is in `packages`); `open` urls are http/https.
7. **links**: every `url` is https and returns < 400 on a HEAD request (CI, with a short allowlist for known-bot-blocking hosts).
8. **strings**: length caps above respected; no control characters.

CI is a single script (`scripts/validate-recipes.mjs`, run in a GitHub Action) that emits a per-recipe pass/fail table on the PR. See **[M5](./m5-live-refresh-and-contributions.md)** for the pipeline + `CONTRIBUTING-bundles.md`.

## Forward-compat
- Parsers on both shells use tolerant decoding (`#[serde(default)]` / optional decode) so an app one version behind ignores unknown fields rather than rejecting the whole `bundles.json` — mirrors the enrichment/vulns-cache pattern.
- `schemaVersion` bumps only on an incompatible change; a newer-schema file loads as empty on an older app (fail-soft), never crashes.

## Non-goals (v1)
- No user-authored recipes inside the app (that overlaps Snapshots — a bundle ≈ a curated Brewfile + guidance). Contribution is via PR.
- No executing external/`command` steps. Ever.
- No per-recipe scripts/hooks beyond the four step kinds.
