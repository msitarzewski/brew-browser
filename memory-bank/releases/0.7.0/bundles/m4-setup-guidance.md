# M4 — Setup guidance (post-install checklist)

**Goal:** after "Install all", land the user on a **setup checklist** that does the brew-native steps for them and hands them honest copy-paste for the rest. This is the differentiator over "just a curated Brewfile".

**Depends on:** M3 (bundle detail + install). **Blocks:** nothing (M5 is parallel).

## Scope
- **In:** render `bundle.setup[]` as an ordered checklist in the bundle detail; wire the four step kinds to their actions; honor the automation boundary; show `caveats` prominently.
- **Out:** tracking step completion across launches (v1 is stateless — the checklist just offers actions), any external-command execution (forbidden).

## The four step kinds → behavior (contract: [recipe-contract.md](./recipe-contract.md))
| kind | UI | action |
|---|---|---|
| `service` | row + "Start" button | reuse the existing Services action (`performServiceAction(.start)` native / the services store command Tauri) → `brew services start <service>`. Reflect running state if known. |
| `open` | row + "Open" button | reuse `safeOpenUrl(url)` (http/https allowlist — already used for cask homepages). |
| `reveal` | row + "Reveal" button | reveal path in Finder (macOS) / file manager (Linux) — reuse the Storage card's reveal. |
| `command` | row + **Copy** button, monospace `run` | copy-to-clipboard only. **Never executes.** `external:true` is enforced by the contract. |
| `note` | markdown line | none. |

## Tauri (Svelte)
- Extend `BundleDetail.svelte` with a `<SetupChecklist>` section under Install all: iterate `bundle.setup`; render per-kind rows. Service → the services store's start; open → `safeOpenUrl`; command → `navigator.clipboard.writeText` + a "Copied" toast; note → rendered markdown (the same sanitizer PackageDetail enrichment uses).
- The checklist appears after install completes (and is also visible pre-install, greyed, so the user sees the full recipe).

## Native (SwiftUI)
- Extend `BundleDetailView.swift` with a setup section: `ForEach(bundle.setup)` → a row per kind. Service → `Button("Start") { model.performServiceAction(.start, name:) }`; open → `Link`/`Button` → `safeOpenUrl`; command → a monospaced `Text` + `Button` copying to `NSPasteboard` + a toast (`pushToast(.success, "Copied")`); note → `Text` (markdown via `AttributedString`).
- Caveats: a prominent callout box above the checklist (reuse the deprecation-notice style).

## Honesty rules (spec, not optional)
- External steps (`command`) are visibly marked as "you run this" — no button that looks like it'll do it for you.
- `caveats` is shown before Install all AND on the post-install checklist (e.g. Image Gen: "installs ComfyUI; you still download models, several GB").
- If a `service` step's package isn't actually installed (partial install), the button is disabled with a reason.

## Tests
- Step-kind → renderer mapping (unit, both shells): service/open/reveal → actionable; command → copy-only, never an execute path; note → text.
- A `command` step with `external:false` (or missing) is rejected by the loader/validator (contract violation) — assert the validator fails it.
- (Manual/verify) Local LLMs bundle: Start Ollama button starts the service; `ollama pull` row copies; Open button opens :8080.

## Acceptance criteria
- Installing Local LLMs then following the checklist starts Ollama, copies the model-pull command, and opens Open WebUI — with the model-pull clearly marked "you run this".
- No UI path executes an external/`command` step.
- Caveats are unmissable on a heavy bundle (Image Gen).
