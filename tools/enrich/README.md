# brew-browser — enrich tool

Build-time tooling. Generates `src-tauri/data/enrichment.json.gz` from
the bundled Homebrew catalog (Phase 12a output), using Anthropic Haiku
4.5 to attach friendly names, expanded summaries, use-case bullets,
similar-package recommendations, and tech-stack tags to each token.

**Not runtime: this never runs from inside the brew-browser app.**
It runs offline, the output is committed, and the app reads the bundled
`enrichment.json.gz` via `include_bytes!`. **Zero LLM calls happen on
the user's machine** — every Anthropic API request is paid for by the
maintainer (or a fork's maintainer) at build time.

## What it produces

`src-tauri/data/enrichment.json.gz` — a gzipped JSON shaped like:

```json
{
  "version": "2026-05-24T12:00:00Z",
  "generated_at": "2026-05-24T12:00:00Z",
  "model": "claude-haiku-4-5-20251001",
  "tiers": ["A", "B"],
  "entries": {
    "postgresql@14": {
      "friendly_name": "PostgreSQL 14",
      "summary": "Open-source object-relational database. Install when you need SQL with rich data types, ACID transactions, and extensibility for production workloads.",
      "use_cases": ["Run a local development database", "Host a self-hosted SaaS backend", "Power a JSONB-backed analytics warehouse"],
      "similar": ["mariadb", "mysql", "sqlite", "redis"],
      "tags": ["database", "sql", "server", "relational"]
    }
  }
}
```

The Rust backend `include_bytes!`s the gzip stream and parses it once
at startup (`src-tauri/src/enrichment/mod.rs`). There is no runtime
file dependency on this script after the build.

## Localized enrichment overlays

The base enrichment bundle remains English and canonical. Localized UI
builds can add a small **partial overlay** per locale instead of
rewriting the whole 15k-package corpus. The current Russian seed overlay
ships as:

| Shell | File |
|-------|------|
| Tauri/Rust | `src-tauri/data/enrichment.ru.json.gz` |
| native SwiftUI | `native/Sources/BrewBrowserKit/Resources/enrichment.ru.json` |

Both files use the same JSON schema; the Tauri copy is gzipped because
Rust embeds it next to the base bundle.

```json
{
  "locale": "ru",
  "version": "2026-07-08-ru-seed",
  "generated_at": "2026-07-08T00:00:00Z",
  "base_version": "2026-05-24T11:53:38Z",
  "entries": {
    "wget": {
      "friendly_name": "Wget",
      "summary": "Консольная утилита для загрузки файлов по HTTP, HTTPS и FTP.",
      "use_cases": ["Скачивать файлы из shell-скриптов"],
      "search_terms": ["скачать", "загрузка файлов", "зеркалирование"]
    }
  }
}
```

Overlay rules:

- Keep Homebrew tokens, formula/cask names, package IDs, CLI flags,
  URLs, API names, and product names stable.
- Translate only user-facing prose: `friendly_name`, `summary`, and
  `use_cases`.
- Put extra natural-language search vocabulary in `search_terms`; these
  are indexed but never rendered as tags.
- Do not localize `similar`: it is a list of Homebrew package tokens.
- Do not localize `tags` in the overlay. Tags remain compact technical
  labels; localized discovery vocabulary belongs in `search_terms`.
- Omitted fields fall back to the base English entry. Omitted tokens are
  simply not localized yet.

To add a language to the app:

1. Add the UI locale first: create the TypeScript dictionary under
   `src/lib/i18n/`, register it in `src/lib/i18n/messages.ts`, expose it
   in the language selector, and add matching native `Localizable`
   resources under both SwiftPM targets.
2. Route the native locale through `native/Sources/BrewBrowserKit/Localization.swift`
   so SwiftUI and Tauri resolve the same locale bucket.
3. Add optional package-prose overlays only after the UI locale is
   selectable and covered by parity checks.

To add a package-prose overlay for that language:

1. Create the readable Swift resource
   `native/Sources/BrewBrowserKit/Resources/enrichment.<locale>.json`.
2. Generate the matching Tauri gzip from that source of truth:

   ```sh
   python3 - <<'PY'
   import gzip
   from pathlib import Path
   locale = "ru"
   src = Path(f"native/Sources/BrewBrowserKit/Resources/enrichment.{locale}.json")
   dst = Path(f"src-tauri/data/enrichment.{locale}.json.gz")
   dst.write_bytes(gzip.compress(src.read_bytes(), compresslevel=9, mtime=0))
   PY
   ```

3. Verify both copies are semantically identical:

   ```sh
   python3 - <<'PY'
   import gzip, json
   from pathlib import Path
   locale = "ru"
   swift = json.loads(Path(f"native/Sources/BrewBrowserKit/Resources/enrichment.{locale}.json").read_text())
   tauri = json.loads(gzip.decompress(Path(f"src-tauri/data/enrichment.{locale}.json.gz").read_bytes()))
   assert swift == tauri
   PY
   ```

4. Add the locale bucket to `normalize_locale` /
   `localized_overlay_bytes` in `src-tauri/src/enrichment/mod.rs`.
5. Add the SwiftPM resource in `native/Package.swift` and route it from
   `EnrichmentCatalog.applyLocaleOverlay`.
6. Add localized category search aliases in
   `src-tauri/src/commands/search.rs` and `L10n.display` if the locale
   translates category labels.
7. Extend the live-enrichment merge policy in both shells if the new
   locale has translated package prose. Today the app preserves localized
   prose over live English entries for the Russian bucket; future buckets
   must be added deliberately in `src/lib/stores/enrichment.svelte.ts`
   and `AppModel.preferredEnrichment`.
8. Run `npm run check`, `npm test`,
   `cargo test --manifest-path src-tauri/Cargo.toml`, and
   `cd native && swift build && swift test`.

The app indexes both localized overlay fields and English fallback
fields, so users can search for `браузер` and `browser` without losing
exact package-token matches.

## When to run

After `tools/catalog/fetch.py` has refreshed the catalog (the catalog
is the source of truth for which tokens exist). Suggested cadence:

1. `python tools/catalog/fetch.py` — pulls fresh catalog, ~5 sec.
2. `python tools/enrich/enrich.py --tier-a` — only enriches the delta
   (~30-50 packages/week after the initial bulk run), ~$0.01-0.05.
3. Commit + push the new `catalog/*.json.gz` + `enrichment.json.gz`.

The script is diff-aware via `state/last-snapshot.json` — re-runs only
hit the LLM for tokens whose name or description changed since last
run, AND whose existing enrichment lacks the requested tier's fields.

## Setup

```sh
cd tools/enrich
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env, paste your ANTHROPIC_API_KEY
```

The `.env` file is `.gitignored` — secrets never commit.

## Cost guard (read this first)

**The script never makes API calls unless you explicitly opt in.** Run
with no flags or `--help` to see the available tiers without spending
any money:

```sh
python enrich.py            # prints help, exits — zero API calls
python enrich.py --help     # same
```

To actually run enrichment you must pass one of:

| Flag        | What it does                                              | Approx cost |
|-------------|-----------------------------------------------------------|-------------|
| `--tier-a`  | friendly_name + summary for tokens with thin/missing desc | $3-5        |
| `--tier-b`  | use_cases + similar + tags for all tokens                 | $10-15      |
| `--all`     | both tiers in one pass                                    | $13-20      |
| `--dry-run` | (combined with above) compute diff + estimate, no API     | $0          |
| `--limit N` | (combined with above) cap candidates to N for testing     | scales      |

Costs are estimates against Claude Haiku 4.5 (~$0.80 in / $4.00 out per
1M tokens as of 2026-05). The delta cost on weekly cron runs is ~$0.05.

## Operational examples

```sh
# Preview what Tier A would enrich on the current catalog (zero cost):
python enrich.py --tier-a --dry-run

# Bake friendly names + summaries (initial run, ~$3-5):
python enrich.py --tier-a

# Bake use cases + similar + tags (initial run, ~$10-15):
python enrich.py --tier-b

# Both tiers in one pass (~$13-20):
python enrich.py --all

# Test with a tiny subset against the live API (~$0.01):
python enrich.py --tier-a --limit 20
```

## Diff state

`state/last-snapshot.json` records `token -> hash(name + desc)` for
every token successfully written to `enrichment.json.gz`. A token is
re-enriched when ANY of these are true:

- The hash changed (upstream rewrote the description).
- The existing entry is missing the requested tier's fields.
- The token is brand new.

Delete `state/last-snapshot.json` to force a full re-enrichment on the
next run (useful when you've tuned the prompt and want to re-bake).

## Prompts

Live as plain text in `prompts/`:

- `prompts/tier-a-friendly.txt` — Tier A system message.
- `prompts/tier-b-features.txt` — Tier B system message.

Edit them in place; the script picks them up on the next invocation.
The Tier B system message gets a 500-token slice of valid token names
appended at runtime so the LLM's `similar` suggestions stay in-vocab;
the parser also drops anything not in the full token set as a final
sanity check.

## Output safety

- Field-length caps are enforced in the parser (`friendly_name ≤ 100`,
  `summary ≤ 1024`, `use_case ≤ 200`, `tag ≤ 30`, `≤ 50 similar`).
  The Rust loader re-applies the same caps as defense-in-depth.
- `similar` is filtered against the full valid-token set; LLM
  hallucinations get silently dropped.
- `tags` are normalised to `[a-z0-9-]` and lowercased.

## What it does NOT do

- Does NOT touch `categories.json` (that's `tools/categorize/`).
- Does NOT make API calls at runtime — the app never imports the
  `anthropic` SDK.
- Does NOT support non-Anthropic providers in v1 (Tier B's prompt is
  Anthropic-tuned). Future versions may support OpenAI if asked.

## Caveats

- LLM output is heuristic. Spot-check a few entries after the first
  Tier A or Tier B run; bad outputs get a "Wrong?" link in the UI so
  users can report them upstream.
- New popular packages may take 24h to appear (the cron runs daily).
- This tool requires network: it talks to `api.anthropic.com`. The
  app itself never does — the bundled enrichment is the canonical
  read-only artifact.
