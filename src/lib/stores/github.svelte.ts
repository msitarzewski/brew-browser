/**
 * GitHub integration store (Phase 12c + 12e).
 *
 * Mirrors backend `github::*` commands into the renderer:
 *
 * - `status` — sign-in summary from the Keychain (no token here, ever).
 * - `repoStatsCache` — per-homepage memo so repeat-opening the same
 *   PackageDetail doesn't re-hit even the backend's 24h disk cache.
 * - `signIn()` — runs the full Device Flow loop: start → poll until
 *   approved/denied/expired. Polling honours the server-provided
 *   `interval` and doubles on `slowDown` per RFC 8628 §3.5.
 *
 * **No token state on the frontend.** Everything authed-sensitive is
 * derived from `status.signedIn`. The actual token lives in the
 * macOS Keychain and is read server-side by the IPC commands.
 */

import {
  githubCreateIssue,
  githubIsStarred,
  githubRepoStats,
  githubSigninPoll,
  githubSigninStart,
  githubSignout,
  githubStar,
  githubStatus,
  githubUnstar,
  githubUnwatch,
  githubWatch,
} from "$lib/api";
import { t } from "$lib/i18n/messages";
import { ui } from "$lib/stores/ui.svelte";
import { safeOpenUrl } from "$lib/util/url";
import { toast } from "./toast.svelte";
import {
  brewErrorMessage,
  isBrewError,
  type CreatedIssue,
  type DeviceFlowStart,
  type GithubStatus,
  type RepoStats,
} from "$lib/types";

/** Per-row outcome we cache in the frontend. */
export type RepoStatsOutcome =
  | { kind: "loading" }
  | { kind: "loaded"; stats: RepoStats }
  /** Backend returned `null` — homepage isn't GitHub, settings off,
      or 404. UI shows nothing. */
  | { kind: "miss" }
  /** Anonymous 60/hr rate limit hit. UI suggests sign-in. */
  | { kind: "rateLimited"; resetAt: number }
  /** Offline mode is on. */
  | { kind: "blocked" }
  /** Other backend error. */
  | { kind: "error"; message: string };

/**
 * Public state of an in-flight Device Flow session. The modal
 * subscribes to this to render the user code + polling spinner.
 */
export type SigninState =
  | { kind: "idle" }
  | { kind: "starting" }
  | {
      kind: "waiting";
      userCode: string;
      verificationUri: string;
      deviceCode: string;
      expiresAt: number;
      intervalMs: number;
    }
  /** Carries the freshly-loaded username so the toast can render
      personalization without an extra `github.status` read at the
      call site. The signin-result toast is fired imperatively from
      `signIn()` at the moment of the approved transition (NOT via
      a $effect — that pattern caused issue #1's infinite-loop chain
      in the Svelte 5 effect scheduler). */
  | { kind: "approved"; username: string | null }
  | { kind: "denied" }
  | { kind: "expired" }
  | { kind: "error"; message: string };

/**
 * Per-homepage starred-state cache shared by PackageDetail (single
 * row) and Dashboard (batch). Values:
 *
 *   - `true | false` — known, from a successful IPC.
 *   - `"unknown"`    — not yet checked OR previous attempt failed
 *                      (auth/scope/rate-limit/blocked). UI should
 *                      render a neutral "Star" button without an
 *                      indicator until a future call resolves it.
 *   - `null`         — homepage isn't a GitHub URL; skip entirely.
 */
/**
 * The cached starred-state for a package.
 * - `true` / `false` — fetched from GitHub, definitive answer
 * - `null` — homepage isn't a GitHub URL; nothing to fetch
 * - `"unknown"` — **display sentinel only** for "not yet fetched"; never
 *   written to the cache itself (cache uses `undefined` for that state)
 * - `"error"` — fetch was attempted but failed; do NOT refetch on every
 *   read (would create an infinite loop with the PackageDetail effect)
 *
 * Issue #1 root cause: the catch block in `isStarred()` used to write
 * `"unknown"` on failure, which collided with the cache-miss display
 * sentinel. The PackageDetail effect couldn't distinguish "we tried
 * and failed" from "we haven't tried yet", so it kept retrying. Each
 * retry wrote the cache, re-triggered the effect, re-issued the IPC.
 * Fix: use a distinct `"error"` value.
 */
export type StarredOutcome = boolean | "unknown" | "error" | null;

class GithubStore {
  /** Last-known status from `githubStatus()`. Null until first load. */
  status: GithubStatus | null = $state(null);

  /** True while a `loadStatus()` is in flight. UI can disable the
      sign-in button. */
  statusLoading: boolean = $state(false);

  /** Per-homepage cache. Using a Map so reactive reads can iterate;
      Svelte 5 reactivity tracks the assignment to `repoStatsCache`. */
  repoStatsCache: Map<string, RepoStatsOutcome> = $state(new Map());

  /** Per-homepage starred-state cache (Phase 12f). Keyed by raw
      `homepage` so PackageDetail and Dashboard share a single source
      of truth. See [`StarredOutcome`] for value semantics. */
  starredCache: Map<string, StarredOutcome> = $state(new Map());

  /** True while a batch starred-state probe is in flight (Dashboard
      personal-stats card uses this to show a "Counting…" indicator
      instead of "0 of N"). */
  starredBatchLoading: boolean = $state(false);

  /** Current Device Flow session. The modal renders based on this. */
  signinState: SigninState = $state({ kind: "idle" });

  /** Per-session AbortController for the polling loop so `cancelSignin`
      can stop the in-flight loop without racing the modal close. */
  private pollAborter: AbortController | null = null;

  /** Centralized write helper for `signinState`. Single place to gate
      future cross-cutting concerns (logging, telemetry, invariants). */
  private _setSignin(_reason: string, next: SigninState): void {
    this.signinState = next;
  }

  /** Read the latest sign-in status from the backend. Idempotent. */
  async loadStatus(): Promise<void> {
    this.statusLoading = true;
    try {
      this.status = await githubStatus();
    } catch (e) {
      // Status read shouldn't fail under normal conditions; if it
      // does we keep the previous value so the UI doesn't flap.
      // (Keychain unavailable is the realistic case.)
      if (isBrewError(e) && e.code === "keychain_unavailable") {
        this.status = { signedIn: false, username: null, scopes: [] };
      }
    } finally {
      this.statusLoading = false;
    }
  }

  /**
   * Get cached stats for `homepage` (kicks off a fetch on first call).
   * Returns the current outcome synchronously; subsequent reads to
   * `repoStatsCache.get(homepage)` will see updates as they arrive.
   */
  async getRepoStats(homepage: string): Promise<RepoStatsOutcome> {
    const existing = this.repoStatsCache.get(homepage);
    if (existing && existing.kind !== "loading") {
      return existing;
    }
    if (existing?.kind === "loading") {
      // Already in flight; let the original call's update propagate.
      return existing;
    }

    // Mark loading and trigger the fetch. Svelte's reactivity tracks
    // the Map assignment.
    const next = new Map(this.repoStatsCache);
    next.set(homepage, { kind: "loading" });
    this.repoStatsCache = next;

    try {
      const stats = await githubRepoStats(homepage);
      const outcome: RepoStatsOutcome = stats
        ? { kind: "loaded", stats }
        : { kind: "miss" };
      const after = new Map(this.repoStatsCache);
      after.set(homepage, outcome);
      this.repoStatsCache = after;
      return outcome;
    } catch (e) {
      let outcome: RepoStatsOutcome;
      if (isBrewError(e)) {
        if (e.code === "github_rate_limited") {
          outcome = { kind: "rateLimited", resetAt: e.resetAt };
        } else if (e.code === "paranoid_mode_blocked") {
          outcome = { kind: "blocked" };
        } else {
          outcome = { kind: "error", message: e.code };
        }
      } else {
        outcome = { kind: "error", message: String(e) };
      }
      const after = new Map(this.repoStatsCache);
      after.set(homepage, outcome);
      this.repoStatsCache = after;
      return outcome;
    }
  }

  /**
   * Run the full Device Flow sign-in: start → poll until terminal.
   * Returns when the session is settled (approved / denied / expired /
   * error). The modal watches `signinState` for progress.
   */
  async signIn(): Promise<void> {
    if (this.signinState.kind === "waiting" || this.signinState.kind === "starting") {
      return; // already in flight
    }
    this._setSignin("signIn-starting", { kind: "starting" });
    let start: DeviceFlowStart;
    try {
      start = await githubSigninStart();
    } catch (e) {
      this._setSignin("signIn-startError", {
        kind: "error",
        message: isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e),
      });
      return;
    }

    const expiresAt = Date.now() + start.expiresIn * 1000;
    let intervalMs = Math.max(start.interval, 5) * 1000;
    this._setSignin("signIn-waiting", {
      kind: "waiting",
      userCode: start.userCode,
      verificationUri: start.verificationUri,
      deviceCode: start.deviceCode,
      expiresAt,
      intervalMs,
    });

    // Loop. Bounded by expiresAt and by cancellation.
    this.pollAborter = new AbortController();
    const aborter = this.pollAborter;
    let pollIteration = 0;

    while (true) {
      pollIteration++;
      if (aborter.signal.aborted) return;
      if (Date.now() > expiresAt) {
        this._setSignin("poll-expiresAt", { kind: "expired" });
        return;
      }
      // Wait one interval. We poll AFTER the wait so the very first
      // call respects the server's recommended cadence; GitHub returns
      // `authorization_pending` immediately if you hit them too fast.
      await sleep(intervalMs, aborter.signal);
      if (aborter.signal.aborted) return;

      let result;
      try {
        result = await githubSigninPoll(start.deviceCode);
      } catch (e) {
        this._setSignin("poll-error", {
          kind: "error",
          message: isBrewError(e) ? brewErrorMessage(e, ui.locale) : String(e),
        });
        return;
      }

      if (result.kind === "approved") {
        await this.loadStatus();
        const username = this.status?.username ?? null;
        this._setSignin("poll-approved", { kind: "approved", username });
        // ARCHITECTURAL: Fire the success toast IMPERATIVELY here, NOT
        // via a $effect observing signinState in DeviceFlowModal. Per
        // Svelte 5 docs and community guidance, $effect should NOT be
        // used for one-shot side effects of state transitions — that
        // pattern produces effect_update_depth_exceeded loops in the
        // reactivity scheduler (see issue #1 root cause; this app
        // exhibited 300+ effect re-runs per single signinState write).
        // The toast belongs at the call site of the transition.
        toast.success(username ? t("github.signedInAsToast", ui.locale, { username }) : t("github.signedInToast", ui.locale));
        // Auto-close the modal 1.5s after success so the user reads
        // the "Signed in as …" panel before it dismisses.
        setTimeout(() => this.cancelSignin(), 1500);
        return;
      }
      if (result.kind === "denied") {
        this._setSignin("poll-denied", { kind: "denied" });
        toast.error(t("github.signInDenied", ui.locale));
        setTimeout(() => this.cancelSignin(), 2000);
        return;
      }
      if (result.kind === "expired") {
        this._setSignin("poll-expired", { kind: "expired" });
        toast.error(t("github.signInExpired", ui.locale), t("github.signInExpiredBody", ui.locale));
        setTimeout(() => this.cancelSignin(), 2000);
        return;
      }
      if (result.kind === "slowDown") {
        // RFC 8628 §3.5 — double the interval, capped at 60s.
        intervalMs = Math.min(intervalMs * 2, 60_000);
        // Force-widen via assertion — CFA narrowed signinState away
        // from "waiting" because earlier `_setSignin` calls within
        // this method confused it. The runtime value at this point
        // genuinely can be "waiting".
        const cur = this.signinState as SigninState;
        if (cur.kind === "waiting") {
          this._setSignin("poll-slowDown-reassign", { ...cur, intervalMs });
        }
        continue;
      }
      // pending — keep polling.
    }
  }

  /** User clicked Cancel on the Device Flow modal. Aborts the poll
      loop and resets the session state. The backend has no concept
      of "abort sign-in" — the device_code just expires naturally on
      GitHub's side. */
  cancelSignin(): void {
    this.pollAborter?.abort();
    this.pollAborter = null;
    this._setSignin("cancelSignin", { kind: "idle" });
  }

  /** Sign out: delete Keychain credentials, refresh status. */
  async signOut(): Promise<void> {
    try {
      await githubSignout();
    } finally {
      // Always refresh — even if delete partially failed, status
      // reflects what's actually stored.
      await this.loadStatus();
    }
    // Drop cached stats so a future request gets the (now anonymous)
    // budget-limited response instead of a stale signed-in result.
    this.repoStatsCache = new Map();
    // Starred cache is now meaningless (anonymous can't check stars).
    this.starredCache = new Map();
  }

  // ---------- Phase 12f: starred / toggle / create issue ----------

  /**
   * Resolve "is the signed-in user starring this repo?" using the
   * shared cache. Returns:
   *
   *   - `null` — homepage isn't a GitHub URL (skip).
   *   - `boolean` — known answer (from cache or fresh IPC).
   *   - `"unknown"` — IPC failed (auth/scope/rate-limit/blocked).
   *     Caller should render the Star button without a fill state.
   *
   * The first call for a given homepage kicks off the IPC; subsequent
   * calls return the cached value immediately. Non-GitHub homepages
   * are recorded as `null` in the cache so we don't re-classify on
   * every PackageDetail open.
   */
  async isStarred(homepage: string): Promise<StarredOutcome> {
    if (!homepage) return null;
    if (!looksLikeGithubHomepage(homepage)) {
      const next = new Map(this.starredCache);
      next.set(homepage, null);
      this.starredCache = next;
      return null;
    }
    const existing = this.starredCache.get(homepage);
    if (existing !== undefined && existing !== "unknown") {
      return existing;
    }
    try {
      const result = await githubIsStarred(homepage);
      const next = new Map(this.starredCache);
      next.set(homepage, result);
      this.starredCache = next;
      return result;
    } catch (_e) {
      // Failure → "error" (NOT "unknown" — see StarredOutcome doc).
      // The cache records that we tried + failed; PackageDetail's
      // effect treats "error" as a settled state and does not refetch.
      // A future call (e.g., after the user clicks Star manually) will
      // overwrite this entry with a fresh attempt.
      const next = new Map(this.starredCache);
      next.set(homepage, "error");
      this.starredCache = next;
      return "error";
    }
  }

  /**
   * Flip the starred state for `homepage`. Optimistic — updates the
   * cache before the IPC resolves so the Star button responds
   * immediately; reverts on failure.
   *
   * Returns the *new* state on success (boolean), or `null` when the
   * homepage isn't a GitHub URL (no-op).
   */
  async toggleStar(homepage: string): Promise<boolean | null> {
    if (!homepage || !looksLikeGithubHomepage(homepage)) return null;
    const before = this.starredCache.get(homepage);
    // Resolve unknown / undefined to the freshly-fetched value so the
    // toggle picks a sane direction.
    let current: boolean;
    if (before === true || before === false) {
      current = before;
    } else {
      const resolved = await this.isStarred(homepage);
      current = resolved === true;
    }
    const target = !current;
    // Optimistic update.
    {
      const next = new Map(this.starredCache);
      next.set(homepage, target);
      this.starredCache = next;
    }
    try {
      if (target) {
        await githubStar(homepage);
      } else {
        await githubUnstar(homepage);
      }
      return target;
    } catch (e) {
      // Revert.
      const next = new Map(this.starredCache);
      next.set(homepage, current);
      this.starredCache = next;
      throw e;
    }
  }

  /**
   * Watch `homepage`. Thin wrapper around the IPC — the backend
   * enforces all the gates.
   */
  async watch(homepage: string): Promise<void> {
    if (!homepage || !looksLikeGithubHomepage(homepage)) return;
    await githubWatch(homepage);
  }

  /** Stop watching. Idempotent. */
  async unwatch(homepage: string): Promise<void> {
    if (!homepage || !looksLikeGithubHomepage(homepage)) return;
    await githubUnwatch(homepage);
  }

  /**
   * File an issue against `homepage` with the given content.
   * Returns the freshly-minted issue's `{ number, htmlUrl }` and
   * (on success) opens the URL in the user's browser via
   * `safeOpenUrl`. Errors propagate to the caller for inline display.
   */
  async createIssue(
    homepage: string,
    title: string,
    body: string,
    labels: string[],
  ): Promise<CreatedIssue> {
    const result = await githubCreateIssue(homepage, title, body, labels);
    // Best-effort open — `safeOpenUrl` swallows any error itself
    // (toasts on scheme rejection, falls back to window.open on
    // non-Tauri runtimes).
    await safeOpenUrl(result.htmlUrl);
    return result;
  }

  /**
   * Probe starred-state for a batch of homepages (Dashboard
   * personal-stats card). Bounded concurrency via a 50-permit
   * semaphore so a 300-package library doesn't burst 300 concurrent
   * connections at github.com.
   *
   * Returns a Map mirroring `starredCache` after the batch settles.
   * Non-GitHub homepages are skipped (recorded as `null`); IPC
   * failures collapse to `"unknown"` for that homepage and the
   * batch continues.
   */
  async batchIsStarred(
    homepages: string[],
  ): Promise<Map<string, StarredOutcome>> {
    this.starredBatchLoading = true;
    try {
      // Filter to GitHub-looking URLs we don't already have a
      // confirmed answer for. Non-GitHub homepages get cached as `null`
      // so we don't re-classify them.
      const todo: string[] = [];
      const cacheUpdates: Array<[string, StarredOutcome]> = [];
      for (const hp of homepages) {
        if (!hp) continue;
        if (!looksLikeGithubHomepage(hp)) {
          cacheUpdates.push([hp, null]);
          continue;
        }
        const existing = this.starredCache.get(hp);
        if (existing === true || existing === false) continue;
        todo.push(hp);
      }
      if (cacheUpdates.length > 0) {
        const next = new Map(this.starredCache);
        for (const [k, v] of cacheUpdates) next.set(k, v);
        this.starredCache = next;
      }

      // Bounded fan-out — 50 permits matches the §12f review's
      // requirement. The IPC layer already handles 24h disk caching on
      // the backend, so a re-issued call for a freshly-cached row
      // returns quickly.
      const PERMIT_COUNT = 50;
      let inFlight = 0;
      const queue = [...todo];
      const results = new Map<string, StarredOutcome>();

      await new Promise<void>((resolve) => {
        const tryDrain = () => {
          if (queue.length === 0 && inFlight === 0) {
            resolve();
            return;
          }
          while (inFlight < PERMIT_COUNT && queue.length > 0) {
            const hp = queue.shift()!;
            inFlight += 1;
            githubIsStarred(hp)
              .then(
                (r) => results.set(hp, r),
                () => results.set(hp, "unknown"),
              )
              .finally(() => {
                inFlight -= 1;
                tryDrain();
              });
          }
        };
        tryDrain();
      });

      // Flush results into the reactive cache in one assignment so
      // observers see the batch atomically.
      if (results.size > 0) {
        const next = new Map(this.starredCache);
        for (const [k, v] of results) next.set(k, v);
        this.starredCache = next;
      }

      // Return a snapshot covering every requested homepage so the
      // caller can compute "X of Y" without re-reading the live cache.
      const snapshot = new Map<string, StarredOutcome>();
      for (const hp of homepages) {
        snapshot.set(hp, this.starredCache.get(hp) ?? "unknown");
      }
      return snapshot;
    } finally {
      this.starredBatchLoading = false;
    }
  }
}

/** Module-level singleton. Components import { github } and read `$state`. */
export const github = new GithubStore();

// ---------- Helpers ----------

/** Promise-based sleep that resolves early on AbortSignal. */
function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(t);
        resolve();
      },
      { once: true },
    );
  });
}

/**
 * Cheap regex check used by the store's gating helpers. Mirrors the
 * helper in `PackageDetail.svelte` so the two stay in sync. The
 * backend's `parse_github_url` is the authoritative validator; this
 * just avoids an obviously-pointless IPC for a non-GitHub URL.
 */
function looksLikeGithubHomepage(url: string): boolean {
  return /^https?:\/\/github\.com\/[^/]+\/[^/?#]+/i.test(url.trim());
}
