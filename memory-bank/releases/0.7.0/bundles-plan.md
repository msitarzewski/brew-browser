# Feature Plan: Bundles (capability-gated recipes) — OVERVIEW

**Target:** 0.7.0 / native 0.3.0 (this release). **Status:** plan complete; approved to build; not yet started.
**One-liner:** Curated one-click package stacks with post-install setup guidance, gated/recommended by a **zero-install system profile** so we never tell an 8GB Mac to install a local-LLM stack it can't run.

## Plan documents (build against these)
This file is the design overview. The build is broken into 5 milestones, each its own doc, plus the contributor contract and the grounded capability data:

| Doc | What |
|---|---|
| [`bundles/recipe-contract.md`](./bundles/recipe-contract.md) | **The contract** — recipe JSON shape, setup-step kinds, CI validation rules. What a contributor authors against. |
| [`bundles/capability-baselines.md`](./bundles/capability-baselines.md) | July-2026 minimum-capability data per bundle type + verified links (the `requires` numbers). |
| [`bundles/m1-capability-engine.md`](./bundles/m1-capability-engine.md) | SystemProfile (zero-install) + `readiness()` pure fn, both shells. Foundation. |
| [`bundles/m2-recipe-contract-and-loader.md`](./bundles/m2-recipe-contract-and-loader.md) | `bundles.json` schema + loader + the 6 first-party recipes + validate script. |
| [`bundles/m3-browse-and-install.md`](./bundles/m3-browse-and-install.md) | Bundles nav section, cards + readiness, detail, Install all → Activity. |
| [`bundles/m4-setup-guidance.md`](./bundles/m4-setup-guidance.md) | Post-install checklist (brew-native auto + external copy-only). |
| [`bundles/m5-live-refresh-and-contributions.md`](./bundles/m5-live-refresh-and-contributions.md) | Live-refresh of `bundles.json` + CI contribution pipeline + `CONTRIBUTING-bundles.md`. |

**Build order:** M1 → M2 → M3 → M4 (M5 parallel to M4 once M2 lands). Each milestone = its own branch off `main`, PLAN→BUILD→verify, both shells green before the next.

## Decisions locked (with the user, 2026-07-12)
- **Build now** — headline of this release (revisit if scope balloons).
- **Surface:** a new **"Bundles"** sidebar nav section (first-class, like Discover/Snapshots).
- **Automation boundary:** brew-native steps auto-run (install, `brew services start`, open URL, reveal); **external** steps (`ollama pull`, model downloads, docker) are shown as a **copy-paste checklist** — never execute arbitrary shell.
- **Capability gating:** **rule-based on a zero-install profile.** No "System Eval that installs tools" — detection ≠ installation, and reading RAM/arch/disk needs nothing installed. Verified 2026-07-12: `sysctl hw.memsize` / `uname -m` / `df` return RAM/arch/disk instantly; unified memory (the RAM number) is the dominant "can I run a local LLM" signal on Apple Silicon.

## Why it's mostly reuse
A bundle ≈ **a curated Brewfile + metadata + setup guidance**. Existing machinery covers ~80%:
- **Data**: the bundled-JSON + optional live-refresh pattern (catalog / enrichment / trending) → add `bundles.json`, tunable via live-refresh without an app release.
- **Install a set**: the Snapshots/Brewfile-restore path already installs a set and streams into Activity. (Verify at BUILD whether to reuse that or add a thin `brew_install_bundle(names)` mirroring `brew_upgrade_many` + the native `upgradeMany`.)
- **Actions**: services start (existing Services action), open URL (`safeOpenUrl`), copy (clipboard).
- Real new cost is **content + upkeep**, not code.

## Data model — `bundles.json` (bundled at build, live-refreshable)
```jsonc
{
  "schemaVersion": 1,
  "bundles": [{
    "id": "local-llm",
    "name": "Local LLMs",
    "tagline": "Run models locally with Ollama + a web UI",
    "category": "AI",
    "packages": [ {"name": "ollama", "kind": "cask"}, {"name": "open-webui", "kind": "cask"} ],
    "requires": { "minRamGB": 8, "recommendedRamGB": 16, "minDiskGB": 12, "arch": "any", "gpu": "preferred" },
    "capabilityNotes": { "8": "small (~7B quantized) models only; larger will swap", "16": "7–13B comfortably", "32": "30B+ / multiple models" },
    "setup": [
      { "kind": "service", "service": "ollama", "label": "Start Ollama" },              // brew-native → auto button
      { "kind": "command", "run": "ollama pull llama3.2", "label": "Pull a model", "copyOnly": true }, // external → copy
      { "kind": "open", "url": "http://localhost:8080", "label": "Open Open WebUI" }     // brew-native → auto button
    ],
    "caveats": "Installs the tools; you'll still download models (several GB)."
  }]
}
```
`#[serde(default)]` / tolerant decode everywhere (forward-compat, mirrors the enrichment/vulns cache pattern).

## System profile — zero-install, cached
`SystemProfile { ramGB, arch, chip, cpuCores, gpu, freeDiskGB, osVersion }`
- **macOS**: `sysctl hw.memsize` (RAM), `machdep.cpu.brand_string` (chip), `hw.ncpu`/`hw.physicalcpu`, `uname -m` (arch); free disk via the existing Storage/`statvfs` path; `sw_vers` (already have). GPU: Metal is always present on Apple Silicon → mark `gpu: metal`; core count from one lazy `system_profiler SPDisplaysDataType` (optional detail — **not** needed for gating v1).
- **Linux** (Tauri): `/proc/meminfo`, `/proc/cpuinfo`, `df`; GPU best-effort (`nvidia-smi`/`lspci`), degrade gracefully to `gpu: unknown`.
- Both shells: read once, cache. Rust could use `sysinfo` crate or direct reads; native reads `sysctl` via Foundation. Shared data contract.

## Readiness — pure, tested, both shells
```
readiness(requires, profile) → { verdict: ready | marginal | blocked, reason }
  blocked      : ramGB < minRamGB  OR  freeDiskGB < minDiskGB  OR  arch mismatch
  marginal     : minRamGB ≤ ramGB < recommendedRamGB
  ready        : ramGB ≥ recommendedRamGB  AND  disk ok
  reason       : from capabilityNotes[nearest tier] / the failing threshold
```
- **"blocked" warns but does not hard-block** — user's machine, user's call (install behind a confirm).
- Graded, not binary: the LLM example maps RAM tiers → capability text (see `capabilityNotes`).
- Bundles with no `requires` (Graphics, Media) → always Ready.

## UI (both shells)
- **New "Bundles" section**: cards, each with name/tagline/icon + a **readiness pill** (✅ Ready · ⚠️ Marginal · ⛔ Not recommended, with the reason on hover).
- **Bundle detail**: the package list (with per-package installed/outdated state), the capability verdict + note, **"Install all"** (→ install-set → Activity), and the **setup checklist** — brew-native steps are action buttons; external steps render as copy rows; caveats shown honestly.
- Post-install: the checklist is the landing surface ("installed — now do this").

## Initial recipe set (~6, hand-curated, honest)
| Bundle | Packages | Gate |
|---|---|---|
| Local LLMs | ollama, open-webui | RAM (graded), disk |
| Image Gen | comfyui | disk (heavy), GPU; strong caveats |
| Graphics / Design | inkscape, gimp, krita | none |
| Media Toolkit | ffmpeg, yt-dlp, mpv, handbrake | none |
| Web Dev | node, … | light |
| Databases | postgresql@16, redis, … | services guidance |

(Verify each cask/formula token + tap trust at BUILD; comfyui/open-webui are niche casks — confirm they resolve and set expectations. `automatic1111` / `stable-diffusion-webui` are NOT in brew — exclude or guidance-only.)

## Testing
- **`readiness()` unit tests** both shells (parity), covering the RAM tiers (4/8/16/32/128 GB), disk floor, arch mismatch, no-requires.
- **`bundles.json` parse tests** (schema, forward-compat unknown fields).
- **Debug profile override** (env var / hidden setting) to inject a synthetic 8/16/32 GB profile — required to *see* Marginal/Blocked states on the 128GB M5 Max dev machine.

## Milestones (detail in `bundles/mN-*.md`)
1. **M1 Capability engine** — SystemProfile (zero-install) + `readiness()`, both shells, pure + tested.
2. **M2 Recipe contract & loader** — schema + 6 recipes + tolerant parsers + `validate-recipes.mjs`.
3. **M3 Browse & install** — Bundles nav section, cards + readiness pills, detail, Install all → Activity.
4. **M4 Setup guidance** — post-install checklist (brew-native auto + external copy-only).
5. **M5 Live-refresh & contributions** — host-served `bundles.json` + CI validation + `CONTRIBUTING-bundles.md`.

## Risks / open questions
- **Curation upkeep**: casks get renamed/deprecated; niche casks (comfyui/open-webui) may be flaky. Live-refresh mitigates; start small; honest caveats.
- **Cask + GPU reality**: a one-click that installs ComfyUI still needs models/torch — guidance must not oversell.
- **Overlap with Snapshots** (a bundle is a curated Brewfile): position Bundles = opinionated starters, Snapshots = your own backup. Possible later: "save bundle as snapshot."
- **Install-set backend**: confirm whether to reuse Brewfile-restore or add `brew_install_bundle` / native `installMany`.
- **Linux GPU detection** weaker — the Image Gen gate degrades to a disk-only check with a GPU note.

---

*Plan drafted 2026-07-12. Approved to write; awaiting go-ahead to implement (would run as PLAN → BUILD → verify, both shells, its own branch off `main`).*
