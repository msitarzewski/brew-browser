import { describe, it, expect } from "vitest";
import { classifyPartialUpgrade } from "./partialUpgrade";
import type { ActivityJob, ActivityLine } from "$lib/types";

function job(partial: Partial<ActivityJob> & { text?: string }): ActivityJob {
  const lines: ActivityLine[] = (partial.text ?? "")
    .split("\n")
    .map((t) => ({ stream: "stdout", text: t, ts: "" }));
  return {
    jobId: "j1",
    label: "Upgrading all packages",
    command: "brew upgrade --greedy",
    startedAt: "",
    status: "failed",
    exitCode: 1,
    lines,
    ...partial,
  };
}

describe("classifyPartialUpgrade", () => {
  it("parses upgraded count + per-package failures (the miniconda/qlmarkdown case)", () => {
    const r = classifyPartialUpgrade(
      job({
        text: [
          "==> Upgrading miniconda",
          "Error: miniconda: Failure while executing; `/usr/bin/sudo … /bin/rm -r -f` exited with 1.",
          "==> Upgrading qlmarkdown",
          "Error: qlmarkdown: It seems the App source '/Applications/QLMarkdown.app' is not there.",
          "==> Upgraded 74 outdated packages",
        ].join("\n"),
      }),
    );
    expect(r).toEqual({ upgraded: 74, failures: ["miniconda", "qlmarkdown"] });
  });

  it("handles @-versioned tokens (temurin@17)", () => {
    const r = classifyPartialUpgrade(
      job({ text: "Error: temurin@17: Failure while executing; sudo rm exited with 1." }),
    );
    expect(r?.failures).toEqual(["temurin@17"]);
  });

  it("falls back to counting '==> Upgrading' lines minus failures when no summary", () => {
    const r = classifyPartialUpgrade(
      job({
        text: ["==> Upgrading a", "==> Upgrading b", "==> Upgrading c", "Error: c: boom."].join("\n"),
      }),
    );
    expect(r).toEqual({ upgraded: 2, failures: ["c"] });
  });

  it("de-dupes a package that errors across multiple lines", () => {
    const r = classifyPartialUpgrade(
      job({ text: "Error: miniconda: step 1 failed\nError: miniconda: step 2 failed" }),
    );
    expect(r?.failures).toEqual(["miniconda"]);
  });

  it("returns null when there are no named per-package failures", () => {
    // Untrusted-tap refusal has no `Error: <token>:` form → generic notice.
    expect(
      classifyPartialUpgrade(
        job({ text: "Error: Refusing to load formula steipete/tap/codexbar from untrusted tap." }),
      ),
    ).toBeNull();
  });

  it("ignores non-upgrade commands (install/uninstall go to recovery)", () => {
    expect(
      classifyPartialUpgrade(
        job({ command: "brew install --cask foo", text: "Error: foo: already exists." }),
      ),
    ).toBeNull();
  });

  it("ignores spawn failures (no exit code) and non-failed jobs", () => {
    expect(classifyPartialUpgrade(job({ exitCode: undefined, text: "Error: x: boom" }))).toBeNull();
    expect(classifyPartialUpgrade(job({ status: "succeeded", text: "Error: x: boom" }))).toBeNull();
  });
});
