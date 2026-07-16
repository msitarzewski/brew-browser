# Building brew-browser

## Dev build

```sh
npm install
npm run tauri dev
```

Opens the app with HMR. No signing, no notarization — local development only.

## Release build (signed + notarized .dmg)

The release build produces a `.dmg` that's signed with the Developer ID Application certificate and notarized by Apple — no Gatekeeper warning on install.

### Prerequisites (one-time)

1. **Apple Developer ID Application certificate** installed in your login keychain. Verify:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see your `Developer ID Application: <name> (TEAMID)` identity. If not, create one at <https://developer.apple.com/account/resources/certificates/list>.

2. **App-specific password** generated at <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords. Label it `brew-browser-notarization` (or anything memorable).

3. **Apple credentials** in a local env file the build will source. **This file MUST NOT be committed.**

   Create `~/.config/brew-browser/signing.env` (or wherever you prefer — outside the repo):
   ```sh
   # NEVER commit this file. .gitignore covers any .env in the repo root,
   # but the best place is outside the repo entirely.

   export APPLE_ID="your@email.com"
   export APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
   export APPLE_TEAM_ID="XXXXXXXXXX"             # 10-char team ID

   # Optional — only if you have multiple Developer ID certs and need to be explicit.
   # Tauri normally picks the right one from tauri.conf.json's bundle.macOS.signingIdentity.
   # export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   ```

   Then `chmod 600 ~/.config/brew-browser/signing.env` so it's user-only readable.

### Build it

```sh
# Source the signing env (one-shot, current shell only)
source ~/.config/brew-browser/signing.env

# One command — runs the full flow (compile + sign + notarize-app + notarize-dmg + staple + verify)
./tools/build/sign-and-notarize.sh
```

Output: signed, notarized, stapled macOS artifacts under `src-tauri/target/**/release/bundle/`:
- Apple Silicon: `src-tauri/target/release/bundle/dmg/brew-browser_<version>_aarch64.dmg`
- Intel, when built with `--target x86_64-apple-darwin`: `src-tauri/target/x86_64-apple-darwin/release/bundle/dmg/brew-browser_<version>_x64.dmg`

### What the wrapper does (and why a wrapper exists)

Under the hood it runs:

```sh
npm run tauri build                                 # compile + sign + notarize .app
xcrun notarytool submit "$DMG" --wait …             # notarize the .dmg wrapper too
xcrun stapler staple "$DMG"                         # staple the ticket
spctl --assess --type install --verbose=4 "$DMG"    # verify
```

**Why the second `notarytool submit` is needed:** Tauri's bundler correctly notarizes the `.app` inside the `.dmg`, but does NOT notarize the `.dmg` wrapper itself. macOS Gatekeeper assesses the `.dmg` first when a user downloads it — so an un-notarized `.dmg` still triggers warnings even though the app inside is fine. Submitting + stapling the `.dmg` separately closes the gap. (Known Tauri 2.x behavior as of 2026-05.)

Full round-trip is ~5–15 min. Subsequent builds with no code changes can be faster — Apple's notary caches by binary hash.

If notarization fails, the wrapper prints the notary log URL. Read it; the failure reason is usually obvious (entitlement mismatch, unsigned helper binary, network blip). Re-run after fixing.

### Verify the signed `.dmg`

```sh
DMG=src-tauri/target/release/bundle/dmg/brew-browser_0.7.0_aarch64.dmg

# Code signature
codesign -dv --verbose=4 "$DMG"

# Gatekeeper assessment — should say "accepted" with source "Notarized Developer ID"
spctl --assess --type install --verbose=4 "$DMG"

# Notarization ticket is stapled?
xcrun stapler validate "$DMG"
```

All three should pass cleanly.

## Why the env file lives outside the repo

The signing identity (cert name + team ID) is **public** — it's embedded in every signed binary you distribute, anyone can read it with `codesign -dv`. Committing it in `tauri.conf.json` is fine.

The **app-specific password** is a credential. It can be regenerated easily, but you don't want it in git history. Tauri reads it from env vars at build time only — it never ends up in the binary.

If you ever do commit it by accident: regenerate at appleid.apple.com immediately. The old password is invalidated on regenerate.

## Updater keypair + manifest publishing (Phase 15)

Starting with **v0.3.0**, brew-browser ships an in-app update mechanism built on `tauri-plugin-updater`. The plugin verifies every downloaded updater artifact against a [minisign](https://jedisct1.github.io/minisign/) signature before it touches the user's install. On macOS that updater artifact is a `.app.tar.gz`, not the first-install `.dmg`; on Linux it is the `.AppImage`. This section covers the one-time keypair setup (per maintainer machine) and the per-release manifest-publishing flow.

**Important:** none of this applies to the dev loop. `npm run tauri dev` does not consult the updater plugin and does not need a keypair. The updater paths only fire in release builds with a published manifest.

### One-time minisign keypair setup

You only do this once per maintainer machine. The keypair lets your release builds sign updater payloads so that end users' brew-browser installations can verify the artifact came from you and not from anyone else who managed to drop a file at the manifest URL.

1. **Install `tauri-cli`** if you don't already have it:
   ```sh
   cargo install tauri-cli --version "^2"
   # or, much faster:
   cargo binstall tauri-cli
   ```

2. **Generate the keypair:**
   ```sh
   tauri signer generate -w ~/.config/brew-browser/updater.key
   ```

   The command writes the **private** key to the path you gave it and prints the **public** key (a base64 blob) to stdout. Copy the public key — you'll need it in the next step.

3. **Lock down the private key:**
   ```sh
   chmod 600 ~/.config/brew-browser/updater.key
   ```

   Same posture as `signing.env` — user-only readable, lives outside the repo. The `~/.config/brew-browser/` directory is a fine home for both files; it's already where the Apple notarization credentials live.

4. **Embed the public key in source:**

   Open `src-tauri/src/lib.rs` and set the `PUB_KEY` const to the public key from step 2:
   ```rust
   const PUB_KEY: &str = "untrusted comment: minisign public key …\nRWQ…";
   ```

   Public keys are public — committing them in source is fine and intentional. That's the entire point of asymmetric crypto: the half users need to verify your signature is exactly the half that has to be widely distributed. The matching private key is what mints valid signatures, and that one stays on your machine.

5. **Back up the private key separately.** 1Password, an encrypted external drive, anywhere that isn't this machine's disk. Treat it the same way you treat your Developer ID certificate's private key.

   **If you lose this key**, users on the auto-update path can no longer verify signatures from a new keypair. Recovery means: cut a new release that ships a hardcoded new `PUB_KEY`, push that release to GitHub Releases, then ask all existing users to manually re-download the `.dmg` from the releases page (since their installed copy will reject the new key). This is degraded UX, not catastrophic — but it's the kind of cleanup you'd rather not do. Back up the key.

### Per-release manifest publishing flow

Every macOS release cuts at least **two** artifacts per arch:
- `brew-browser_X.Y.Z_aarch64.dmg` / `brew-browser_X.Y.Z_x64.dmg` — for fresh user installs (drag-to-Applications).
- `brew-browser.app.tar.gz` (under each arch's `bundle/macos/`) — for the auto-updater. **The Tauri updater plugin's macOS install path requires a gzipped tar of the `.app` bundle**, not the `.dmg`. Feeding the plugin a `.dmg` results in `"invalid gzip"` on every install attempt.

Both are produced by `npm run tauri build` when `bundle.targets` includes `"all"` (or explicitly lists `"app"` + `"dmg"`). Build Apple Silicon first, then Intel with `npm run tauri build -- --target x86_64-apple-darwin` when cutting a dual-arch release. You upload the `.dmg` and versioned `.app.tar.gz` files to the GitHub Release; only the `.app.tar.gz` files are referenced by `updater.json`.

The manifest itself is a small JSON file served from `https://brew-browser.zerologic.com/updater.json` (Caddy on umbp); end-user installs poll it on the configurable cadence (manual, weekly, or daily).

1. **Cut the release build first.** Per the "Build it" section above:
   ```sh
   source ~/.config/brew-browser/signing.env
   ./tools/build/sign-and-notarize.sh
   ```
   Produces:
   - `src-tauri/target/release/bundle/dmg/brew-browser_X.Y.Z_aarch64.dmg` (Apple-signed + notarized)
   - `src-tauri/target/release/bundle/macos/brew-browser.app.tar.gz` (Apple Silicon updater artifact)
   - optional Intel siblings under `src-tauri/target/x86_64-apple-darwin/release/bundle/`

2. **Generate the updater manifest** with the version you just built:
   ```sh
   tools/release/publish-manifest.sh 0.7.0
   ```

   The script:
   - Locates the Apple Silicon `.app.tar.gz` at `src-tauri/target/release/bundle/macos/brew-browser.app.tar.gz`
   - Locates the optional Intel `.app.tar.gz` at `src-tauri/target/x86_64-apple-darwin/release/bundle/macos/brew-browser.app.tar.gz`
   - Computes each artifact's `sha256`
   - Reads the Tauri-format `.sig` files produced by the signed build
   - Emits `dist/updater.json` in the shape Tauri's plugin expects (see "Manifest format" below)
   - Echoes the deploy command for you to run by hand

3. **Upload the release artifacts to the GitHub Release.** Copy/rename each `brew-browser.app.tar.gz` to the versioned form referenced by the manifest:
   ```sh
   cp src-tauri/target/release/bundle/macos/brew-browser.app.tar.gz \
      /tmp/brew-browser_0.7.0_aarch64.app.tar.gz
   cp src-tauri/target/x86_64-apple-darwin/release/bundle/macos/brew-browser.app.tar.gz \
      /tmp/brew-browser_0.7.0_x64.app.tar.gz

   gh release create v0.7.0 \
     src-tauri/target/release/bundle/dmg/brew-browser_0.7.0_aarch64.dmg \
     src-tauri/target/x86_64-apple-darwin/release/bundle/dmg/brew-browser_0.7.0_x64.dmg \
     /tmp/brew-browser_0.7.0_aarch64.app.tar.gz \
     /tmp/brew-browser_0.7.0_x64.app.tar.gz \
     --notes-file docs/release-notes/0.7.0.md
   ```
   Use real files with the final URL names; `gh release upload file#label` changes the asset label, not the URL filename, and the updater manifest needs the URL filename to match exactly.

4. **Deploy the manifest** to the umbp host. The script will print the exact rsync command; run it yourself so the deploy step stays a deliberate action:
   ```sh
   rsync -avz dist/updater.json michael@umacbookpro:Sites/brew-browser/updater.json
   ```

5. **Verify the manifest is live:**
   ```sh
   curl -s https://brew-browser.zerologic.com/updater.json | jq
   ```

   Confirm the `version` field matches what you just shipped and the `url` points at the GitHub Releases `.app.tar.gz` asset for that version. If `jq` complains, the manifest didn't deploy cleanly; re-run rsync.

### Manifest format

Tauri's updater plugin expects this shape. The script generates it for you — but it's worth knowing the layout so a future maintainer can hand-edit if the script breaks:

```json
{
  "version": "0.7.0",
  "notes": "See https://github.com/msitarzewski/brew-browser/releases/tag/v0.7.0",
  "pub_date": "2026-06-13T18:00:00Z",
  "platforms": {
       "darwin-aarch64": {
          "signature": "<minisign signature, single-line base64>",
          "url": "https://github.com/msitarzewski/brew-browser/releases/download/v0.7.0/brew-browser_0.7.0_aarch64.app.tar.gz",
          "sha256": "<hex digest of the .app.tar.gz>"
        },
       "darwin-x86_64": {
          "signature": "<minisign signature, single-line base64>",
          "url": "https://github.com/msitarzewski/brew-browser/releases/download/v0.7.0/brew-browser_0.7.0_x64.app.tar.gz",
          "sha256": "<hex digest of the Intel .app.tar.gz>"
        }
  }
}
```

Notes on the fields:

- **`version`** — semver string, no `v` prefix. The plugin compares this against the running binary's version and only prompts if it's strictly greater (downgrade attempts are rejected).
- **`notes`** — short text. We point at the GitHub release page rather than inlining release notes; keeps the manifest small and lets us edit notes after publish without re-signing.
- **`pub_date`** — RFC 3339 UTC timestamp. Tauri uses this for display only.
- **`platforms.darwin-aarch64`** — Apple Silicon macOS.
- **`platforms.darwin-x86_64`** — Intel macOS, present only when the x64 updater artifact exists. `tools/release/publish-manifest.sh` warns loudly and omits this key for arm64-only releases.
- **`signature`** — the minisign signature over the `.app.tar.gz` bytes. Tauri's plugin verifies this against the `PUB_KEY` const baked into the binary; mismatch aborts the install with no on-disk side effects.
- **`url`** — direct download URL for the `.app.tar.gz` (NOT the `.dmg`). The plugin unpacks the gzipped tar in place; feeding it a `.dmg` fails with `"invalid gzip"`. Constrained by the artifact-host allowlist in the plugin config (only `github.com` and `objects.githubusercontent.com` are accepted).
- **`sha256`** — hex digest of the `.app.tar.gz` bytes. The plugin checks this *first* (cheap) before invoking minisign (more expensive); a mismatch aborts before any signature math.

### If you forget to publish the manifest

Users on auto-check won't see the new version — the manifest still advertises the previous release, so the plugin reports "you're up to date." This is **degraded UX, not broken**: the new `.dmg` is still on the GitHub Releases page and users who go looking will find it. Catch it by running the `curl | jq` verification step above; if the deployed `version` doesn't match what you just shipped, re-run the publish script and rsync.

### Two separate signing concerns

The release flow now involves two independent cryptographic signatures, and it's worth being clear about which one does what:

| Signature | Purpose | Key location | Verified by |
|-----------|---------|--------------|-------------|
| **Apple Developer ID + notarization** | Proves the `.dmg` (fresh-install artifact) was built by an Apple-registered developer (you) and passed Apple's malware scan | Login keychain + `signing.env` | macOS Gatekeeper at install time |
| **Minisign signature** | Proves the `.app.tar.gz` (auto-update artifact) came from your specific brew-browser maintainer keypair (not anyone else who could host a file at the manifest URL) | `~/.config/brew-browser/updater.key` | `tauri-plugin-updater` at install time, against the `PUB_KEY` in the running binary |

Both are needed but cover **different artifacts**: Apple's signature lives on the `.dmg` and protects the fresh-install path; minisign lives on the `.app.tar.gz` and protects the auto-update path. Compromising your manifest endpoint without the minisign key still gets blocked at the plugin; compromising the `.dmg` distribution without the Developer ID still gets blocked at Gatekeeper. Skip either and one of the two install paths breaks (visibly via Gatekeeper warning, or invisibly via auto-update install failure).

## GitHub OAuth App (one-time setup before release)

brew-browser's GitHub integration uses the OAuth Device Flow (RFC 8628). The `client_id` is hardcoded in `src-tauri/src/github/auth.rs` and is **not a secret** — Device Flow client IDs are identifiers, not credentials (§3.1 of the RFC).

The upstream source tree ships with the real public `client_id` for the `msitarzewski/brew-browser` GitHub OAuth App. Device Flow client IDs are public identifiers, not secrets. Forks should replace it with their own GitHub App's `client_id` before publishing, so their rate-limit budget and any future revocation belong to the fork.

### One-time steps

1. Visit <https://github.com/settings/apps> and click **New GitHub App**.
2. Fill in:
   - **Name:** `brew-browser` (or your fork's name)
   - **Homepage URL:** `https://brew-browser.zerologic.com` (or your project's URL)
   - **Callback URL:** leave blank — Device Flow doesn't need one.
   - **Webhook:** uncheck "Active" — we don't receive any.
3. In the **Device Flow** section, check **Enable Device Flow**.
4. In **Permissions**, grant the absolute minimum:
   - **Repository permissions** → **Metadata:** Read-only (required for any auth).
   - Repository actions used by brew-browser: public repo metadata, stars, issue creation, and watch/unwatch. The app requests `read:user`, `public_repo`, and `notifications`.
5. Submit. GitHub shows the new app's `Client ID` (a string like `Iv23licABCXYZ123`).
6. Open `src-tauri/src/github/auth.rs` and replace the value of the `GITHUB_OAUTH_CLIENT_ID` constant.
7. **Do NOT** generate a client secret — Device Flow doesn't use one.

### Forking

If you fork brew-browser, repeat the steps above against your own GitHub account. Don't reuse the upstream `client_id` — it ties any sign-in attempts (and the resulting rate-limit consumption) back to the upstream maintainer's OAuth app.

> See [`memory-bank/phases/phase12-plan.md`](../memory-bank/phases/phase12-plan.md) for the full design of the GitHub integration (anonymous tier, Device Flow, Keychain isolation, paranoid-mode gates).

## Catalog enrichment (Phase 13 — optional)

The bundled `enrichment.json.gz` is the LLM-generated metadata layer
that adds friendly names, expanded summaries, use-case bullets,
similar-package recommendations, and tech-stack tags to each Homebrew
token. The release source tree carries the baked production payload; you only
need to run the enrichment pipeline when refreshing or extending that data.

### Zero runtime LLM calls

The app never calls an LLM. The enrichment payload is read-only and
`include_bytes!`d into the binary at compile time
(`src-tauri/src/enrichment/mod.rs`). Toggling AI Features off in
Settings → Appearance hides the enriched UI but doesn't change what's
in the bundle. The `anthropic` SDK never ends up in the Rust binary.

### Run order

```
tools/catalog/fetch.py          # refresh formula.json + cask.json
  → tools/categorize/categorize.py   # update categories.json (delta only)
  → tools/enrich/enrich.py           # update enrichment.json.gz (delta only)
  → cargo tauri build                # bake everything into the binary
```

The enrich step depends on a fresh catalog (its source of truth for
which tokens exist) but is otherwise independent of the categorize
step.

### Tier system + cost guard

`tools/enrich/enrich.py` accepts three opt-in flags. Running with no
flags prints help and exits — you cannot accidentally spend money on
an Anthropic API call.

| Flag        | What it bakes                                              | Approx cost |
|-------------|------------------------------------------------------------|-------------|
| `--tier-a`  | friendly_name + summary for tokens with thin/missing desc  | $3-5        |
| `--tier-b`  | use_cases + similar + tags for all tokens                  | $10-15      |
| `--all`     | both tiers in one pass                                     | $13-20      |
| `--dry-run` | (combined with above) compute diff + estimate, no API call | $0          |

Delta runs (after the initial bulk) cost ~$0.05/week — only changed
tokens get re-enriched, tracked by the hash-state file at
`tools/enrich/state/last-snapshot.json`.

### ANTHROPIC_API_KEY

Required for any non-`--dry-run` invocation. Lives in
`tools/enrich/.env` (gitignored, mirroring `tools/categorize/.env`):

```sh
cd tools/enrich
cp .env.example .env
# edit .env, paste ANTHROPIC_API_KEY=sk-ant-...
```

The Python script reads the key via `python-dotenv`. The Rust binary
NEVER reads it — there is no runtime path that needs an API key.

### Operational examples

```sh
# Always start with a dry run after refreshing the catalog:
python tools/enrich/enrich.py --tier-a --dry-run

# Bake Tier A (initial run):
python tools/enrich/enrich.py --tier-a

# Bake Tier B (initial run; takes longer due to bigger prompts):
python tools/enrich/enrich.py --tier-b

# Both tiers in one pass (full bulk):
python tools/enrich/enrich.py --all

# Subsequent delta-only run (typically ~30-50 tokens, <$0.05):
python tools/enrich/enrich.py --all
```

After a successful run, commit the updated
`src-tauri/data/enrichment.json.gz` alongside the catalog refresh.

> See [`memory-bank/phases/phase13-plan.md`](../memory-bank/phases/phase13-plan.md) for the full design — tier structure, prompt strategy, AI-Features toggle UX, and the rationale for build-time-only LLM calls.

## Unsigned builds (for testing only)

If you just want to test the build pipeline without notarization:

```sh
# Unset to skip signing entirely
unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID
npm run tauri build
```

Produces an unsigned `.dmg`. Gatekeeper will warn users on first launch ("developer cannot be verified"). For your own testing, fine; for distribution, never.
