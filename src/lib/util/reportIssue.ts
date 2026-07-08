/**
 * "Report to brew-browser" — surfaces a pre-filled GitHub new-issue URL
 * from any error context the user encounters in the app.
 *
 * Two entry points:
 *
 *   - `reportableToastError(title, error)` — for catch blocks. Shows a
 *     `toast.error` with the friendly message in the body. Unknown failures
 *     include a "Report to brew-browser" action button below it. One-call upgrade
 *     of the old `toast.error(title, isBrewError(e) ? e.code : String(e))`
 *     anti-pattern (which threw away the friendly message and gave the
 *     user no recourse beyond the raw discriminator string).
 *
 *   - `openReportIssueFromJob(job, summary)` — for the Activity drawer's
 *     failed-job footer. Reads command + exitCode + accumulated stderr
 *     lines from the streamed job log.
 *
 * The opened URL routes through `safeOpenUrl`, so the http(s)-only +
 * Tauri-opener sandbox apply identically to GitHub as to any other
 * outbound link.
 */

import { appVersion } from "$lib/api";
import { t } from "$lib/i18n/messages";
import { env } from "$lib/stores/env.svelte";
import { toast } from "$lib/stores/toast.svelte";
import { ui } from "$lib/stores/ui.svelte";
import {
  brewErrorMessage,
  isBrewError,
  type ActivityJob,
  type BrewErrorPayload,
} from "$lib/types";
import { safeOpenUrl } from "$lib/util/url";

const REPO_NEW_ISSUE_URL =
  "https://github.com/msitarzewski/brew-browser/issues/new";

/** Cap on the stderr excerpt we include in the pre-filled body. Keeps
 *  the resulting URL well under GitHub's ~8 KiB limit even with the
 *  rest of the templated context. */
const STDERR_MAX_CHARS = 2000;

interface ReportContext {
  /** User-facing summary (becomes the issue title's suffix). */
  summary: string;
  /** Command that failed (when available). */
  command?: string;
  /** Process exit code (when available). */
  exitCode?: number;
  /** Tail of stderr output, capped to {@link STDERR_MAX_CHARS}. */
  stderrExcerpt?: string;
  /** Backend-generated friendly message, when the error matched a known
   *  upstream pattern. Surfaces in the body so the maintainer knows the
   *  user already saw the friendly version. */
  friendlyMessage?: string;
  /** Raw BrewError discriminator (e.g. "brew_exit_non_zero"). Helps
   *  triage when the user types unrelated free-form text. */
  errorCode?: string;
}

/** Cached app version. `appVersion()` is cheap but does cross the IPC
 *  boundary; we only need to resolve it once per session. */
let cachedAppVersion: string | null = null;
async function getAppVersion(): Promise<string> {
  if (cachedAppVersion !== null) return cachedAppVersion;
  try {
    cachedAppVersion = await appVersion();
  } catch {
    cachedAppVersion = "unknown";
  }
  return cachedAppVersion;
}

/** Build the issue body (markdown). */
function buildBody(ctx: ReportContext, appVer: string, brewVer: string): string {
  const lines: string[] = [
    `**brew-browser:** ${appVer}`,
    `**Homebrew:** ${brewVer}`,
  ];
  if (ctx.errorCode) lines.push(`**Error code:** \`${ctx.errorCode}\``);
  if (ctx.command) lines.push(`**Command:** \`${ctx.command}\``);
  if (ctx.exitCode !== undefined) lines.push(`**Exit code:** ${ctx.exitCode}`);
  if (ctx.friendlyMessage) {
    lines.push("", `**Friendly message shown to user:**`, "", `> ${ctx.friendlyMessage}`);
  }
  if (ctx.stderrExcerpt && ctx.stderrExcerpt.trim().length > 0) {
    const trimmed =
      ctx.stderrExcerpt.length > STDERR_MAX_CHARS
        ? "…(truncated)…\n" + ctx.stderrExcerpt.slice(-STDERR_MAX_CHARS)
        : ctx.stderrExcerpt;
    lines.push("", "**stderr excerpt:**", "", "```", trimmed, "```");
  }
  lines.push(
    "",
    "---",
    "",
    "_Replace this line with what you were doing when the error appeared, and what you expected to happen._",
  );
  return lines.join("\n");
}

/** Open the GitHub new-issue page pre-filled with the supplied context. */
export async function openReportIssue(ctx: ReportContext): Promise<void> {
  const appVer = await getAppVersion();
  const brewVer = env.report?.version ?? "unknown";

  const params = new URLSearchParams();
  params.set("title", `[brew-browser] ${ctx.summary}`);
  params.set("body", buildBody(ctx, appVer, brewVer));
  params.set("labels", "from-app");

  await safeOpenUrl(`${REPO_NEW_ISSUE_URL}?${params.toString()}`);
}

/** Extract a ReportContext from a typed BrewError. */
export function reportContextFromBrewError(
  e: BrewErrorPayload,
  summary: string,
): ReportContext {
  if (e.code === "brew_exit_non_zero") {
    return {
      summary,
      command: e.command,
      exitCode: e.exitCode,
      stderrExcerpt: e.stderrExcerpt,
      friendlyMessage: e.friendlyMessage,
      errorCode: e.code,
    };
  }
  // Non-shell errors: capture the friendly message so the report carries
  // human-readable context, and pin the discriminator for triage.
  return {
    summary,
    friendlyMessage: brewErrorMessage(e),
    errorCode: e.code,
  };
}

/** Extract a ReportContext from an in-app Activity job (typically a
 *  failed `brew` invocation). The drawer's footer offers this path so
 *  the user can report a failure without re-navigating to whatever
 *  toast spawned it. */
export function reportContextFromActivityJob(
  job: ActivityJob,
  summary: string,
): ReportContext {
  const stderr = job.lines
    .filter((l) => l.stream === "stderr")
    .map((l) => l.text)
    .join("\n");
  return {
    summary,
    command: job.command,
    exitCode: job.exitCode,
    stderrExcerpt: stderr.length > 0 ? stderr : undefined,
  };
}

/**
 * Drop-in replacement for the old anti-pattern:
 *   toast.error(title, isBrewError(e) ? e.code : String(e))
 *
 * Renders unknown failures in a toast with a "Report to brew-browser" action
 * button. Classified streaming brew failures are already rendered in the
 * Activity drawer, so those do not create a second popup.
 *
 * The friendly message comes from `brewErrorMessage(e)` — which on
 * `brew_exit_non_zero` errors uses the backend's `friendlyMessage`
 * field (populated by `brew::error_patterns::friendlify` when the
 * stderr matches a known upstream-brew-bug pattern, e.g. the shiva
 * `brew bundle` topo-sort crash).
 */
export function reportableToastError(title: string, e: unknown): void {
  if (isBrewError(e)) {
    // A brew command that exited non-zero is a Homebrew/formula problem, NOT a
    // brew-browser bug — never offer "Report to brew-browser" for it (that was
    // the dominant source of misfiled "[brew-browser] Upgrade-all failed"
    // issues). Classified failures are already shown in the Activity drawer's
    // failure card, so skip the toast entirely; unclassified ones get a plain
    // error toast with NO report action.
    if (e.code === "brew_exit_non_zero") {
      if (e.friendlyMessage) return;
      toast.error(title, brewErrorMessage(e, ui.locale));
      return;
    }
    // Other BrewError codes (Io, Internal, parse failures, …) are app-side
    // problems worth reporting.
    const ctx = reportContextFromBrewError(e, title);
    toast.error(title, brewErrorMessage(e, ui.locale), {
      label: t("Report to brew-browser", ui.locale),
      onClick: () => {
        void openReportIssue(ctx);
      },
    });
    return;
  }
  const stringified = String(e);
  toast.error(title, stringified, {
    label: t("Report to brew-browser", ui.locale),
    onClick: () => {
      void openReportIssue({
        summary: title,
        stderrExcerpt: stringified,
      });
    },
  });
}

/** Convenience wrapper for the Activity drawer footer button. */
export function openReportIssueFromJob(
  job: ActivityJob,
  summary: string,
): Promise<void> {
  return openReportIssue(reportContextFromActivityJob(job, summary));
}
