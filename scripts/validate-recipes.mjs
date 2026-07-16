#!/usr/bin/env node
// Validate bundle recipes against the contract (memory-bank/releases/0.7.0/bundles/recipe-contract.md)
// and, on success, concatenate them into bundles.json. Dependency-free (Node 20+ global fetch).
//
//   node scripts/validate-recipes.mjs                 # structure + brew + links(warn on net err); writes bundles.json
//   node scripts/validate-recipes.mjs --strict-links  # link failures are errors (CI)
//   node scripts/validate-recipes.mjs --no-brew       # skip `brew info` resolution (offline dev)
//
// Exit non-zero if any recipe fails a hard check.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, basename } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const RECIPES_DIR = join(ROOT, "recipes");
const OUT = join(ROOT, "bundles.json");
const args = process.argv.slice(2);
const STRICT_LINKS = args.includes("--strict-links");
const NO_BREW = args.includes("--no-brew");

const CATEGORIES = ["AI", "Graphics", "Media", "Development", "Data", "Productivity"];
const ARCHS = ["any", "apple-silicon", "intel", "linux"];
const GPUS = ["none", "preferred", "required"];
const STEP_KINDS = ["service", "open", "reveal", "command", "note"];
// Hosts that bot-block automated HEAD requests but are known-good (verified manually).
const LINK_WHITELIST = ["docs.openwebui.com"];

const isKebab = (s) => /^[a-z0-9]+(-[a-z0-9]+)*$/.test(s);

function checkStructure(r, errs) {
  const req = (c, m) => { if (!c) errs.push(m); };
  req(typeof r.id === "string" && isKebab(r.id), "id must be kebab-case");
  req(typeof r.name === "string" && r.name.length >= 1 && r.name.length <= 40, "name 1–40 chars");
  req(typeof r.tagline === "string" && r.tagline.length >= 1 && r.tagline.length <= 90, "tagline 1–90 chars");
  if (r.description != null) req(typeof r.description === "string" && r.description.length >= 40 && r.description.length <= 600, "description 40–600 chars");
  req(CATEGORIES.includes(r.category), `category must be one of ${CATEGORIES.join(", ")}`);
  req(Array.isArray(r.packages) && r.packages.length >= 1, "packages: ≥1 required");
  for (const p of r.packages ?? []) {
    req(p && typeof p.name === "string" && p.name.length >= 1, "package.name required");
    req(p && (p.kind === "formula" || p.kind === "cask"), `package.kind must be formula|cask (${p?.name})`);
  }
  if (r.tap != null) req(/^[^/]+\/[^/]+$/.test(r.tap), "tap must be 'user/repo'");
  if (r.requires) {
    const q = r.requires;
    req(Number.isInteger(q.minRamGB) && q.minRamGB > 0, "requires.minRamGB int > 0");
    req(Number.isInteger(q.recommendedRamGB) && q.recommendedRamGB > 0, "requires.recommendedRamGB int > 0");
    req(Number.isInteger(q.minDiskGB) && q.minDiskGB > 0, "requires.minDiskGB int > 0");
    req(q.minRamGB <= q.recommendedRamGB, "requires.minRamGB ≤ recommendedRamGB");
    req(ARCHS.includes(q.arch), `requires.arch in ${ARCHS.join("|")}`);
    req(GPUS.includes(q.gpu), `requires.gpu in ${GPUS.join("|")}`);
  }
  if (r.capabilityNotes) for (const k of Object.keys(r.capabilityNotes))
    req(/^[0-9]+$/.test(k), `capabilityNotes key '${k}' must be an integer (GB tier)`);
  for (const s of r.setup ?? []) {
    req(STEP_KINDS.includes(s.kind), `setup.kind '${s.kind}' invalid`);
    if (s.kind === "command") req(s.external === true, `command step '${s.run}' MUST set external:true (contract: no auto-run shell)`);
    if (s.kind === "service") req(typeof s.service === "string", "service step needs 'service'");
    if (s.kind === "open") req(typeof s.url === "string" && /^https?:\/\//.test(s.url), "open step url must be http(s)");
  }
  if (typeof r.caveats === "string") req(r.caveats.length <= 240, "caveats ≤ 240 chars");
  for (const l of r.links ?? []) {
    req(typeof l.label === "string", "link.label required");
    req(typeof l.url === "string" && l.url.startsWith("https://"), `link url must be https (${l.url})`);
  }
}

function checkBrew(r, errs) {
  if (NO_BREW) return;
  for (const p of r.packages ?? []) {
    let json;
    try { json = JSON.parse(execFileSync("brew", ["info", "--json=v2", p.name], { encoding: "utf8" })); }
    catch { errs.push(`brew: '${p.name}' does not resolve`); continue; }
    const f = json.formulae?.[0], c = json.casks?.[0];
    const kind = f ? "formula" : c ? "cask" : null;
    const tap = (f ?? c)?.tap;
    if (!kind) { errs.push(`brew: '${p.name}' not found`); continue; }
    if (kind !== p.kind) errs.push(`brew: '${p.name}' is a ${kind}, recipe says ${p.kind}`);
    const official = tap === "homebrew/core" || tap === "homebrew/cask";
    if (!official && r.tap !== tap) errs.push(`brew: '${p.name}' is in third-party tap '${tap}' — declare it in the recipe's top-level "tap" field (Homebrew 6.0 needs trust)`);
  }
}

async function checkLinks(r, errs) {
  // Only "further reading" links[] get reachability-checked. `open`-step URLs are
  // runtime app URLs (often localhost) and are validated for scheme only (in checkStructure).
  const urls = (r.links ?? []).map((l) => l.url);
  for (const url of urls) {
    let host; try { host = new URL(url).host; } catch { errs.push(`bad url ${url}`); continue; }
    if (LINK_WHITELIST.includes(host)) continue;
    // A real dead link returns a 4xx/5xx STATUS (hard fail). A network/TLS/bot-block
    // THROW is ambiguous, so it's only ever a warning — even in --strict-links.
    const headers = { "User-Agent": "Mozilla/5.0 (compatible; brew-browser-recipe-validator)" };
    const tryOnce = async (method) => {
      const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 12000);
      try { return await fetch(url, { method, redirect: "follow", headers, signal: ac.signal }); }
      finally { clearTimeout(t); }
    };
    try {
      let res = await tryOnce("HEAD");
      if (res.status >= 400) res = await tryOnce("GET"); // some hosts reject HEAD
      if (res.status >= 400) errs.push(`link ${url} → HTTP ${res.status}`);
    } catch {
      try {
        const res = await tryOnce("GET");
        if (res.status >= 400) errs.push(`link ${url} → HTTP ${res.status}`);
      } catch (e2) {
        console.warn(`  ⚠︎ link ${url} unreachable (${e2.name}) — warning only, not a dead-link status`);
      }
    }
  }
}

const files = readdirSync(RECIPES_DIR).filter((f) => f.endsWith(".json") && f !== "recipe.schema.json");
const seenIds = new Set();
const passing = [];
let failed = 0;

console.log(`Validating ${files.length} recipe(s)${NO_BREW ? " (no-brew)" : ""}${STRICT_LINKS ? " (strict-links)" : ""}:\n`);
for (const file of files.sort()) {
  const errs = [];
  let r;
  try { r = JSON.parse(readFileSync(join(RECIPES_DIR, file), "utf8")); }
  catch (e) { console.log(`  ✗ ${file} — invalid JSON: ${e.message}`); failed++; continue; }
  checkStructure(r, errs);
  if (r.id) { if (seenIds.has(r.id)) errs.push(`duplicate id '${r.id}'`); seenIds.add(r.id); }
  checkBrew(r, errs);
  await checkLinks(r, errs);
  if (errs.length) { console.log(`  ✗ ${file}`); for (const e of errs) console.log(`      - ${e}`); failed++; }
  else { console.log(`  ✓ ${basename(file)}  (${r.packages.length} pkg)`); passing.push(r); }
}

console.log(`\n${passing.length}/${files.length} valid.`);
if (failed) { console.error(`\n${failed} recipe(s) FAILED the contract.`); process.exit(1); }

// NOTE: intentionally NO timestamp — bundles.json must be deterministic so the
// CI "up to date" check (git diff) is meaningful and re-runs don't churn git.
// Provenance lives per-recipe in `addedIn`. Bundles sorted by id for stable diffs.
const bundles = { schemaVersion: 1, bundles: passing.sort((a, b) => a.id.localeCompare(b.id)) };
const json = JSON.stringify(bundles, null, 2) + "\n";
// Write the canonical artifact AND both app-bundled copies so they never drift.
// Each shell embeds its own copy at build time (Tauri include_str!, native Bundle.module).
const TARGETS = [
  OUT,
  join(ROOT, "src-tauri", "data", "bundles.json"),
  join(ROOT, "native", "Sources", "BrewBrowserKit", "Resources", "bundles.json"),
];
for (const t of TARGETS) writeFileSync(t, json);
console.log(`\n✓ wrote ${passing.length} bundles to:\n  ${TARGETS.map((t) => t.replace(ROOT + "/", "")).join("\n  ")}`);
