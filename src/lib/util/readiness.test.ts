import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import type { BundleRequires, Readiness, SystemProfile } from "$lib/types";
import { readiness } from "./readiness";

/**
 * SHARED PARITY FIXTURE. The exact same `test-fixtures/readiness-cases.json`
 * drives the Swift suite too, so both shells must produce byte-identical
 * verdicts + reason strings. Loaded from disk (not a JSON import) so `npm run
 * check` doesn't need `resolveJsonModule`, and resolved relative to THIS file
 * so it works regardless of cwd.
 */
interface ReadinessCase {
  name: string;
  requires: BundleRequires | null;
  capabilityNotes: Record<string, string> | null;
  // Fixture profiles carry only the fields readiness() reads; widen to the
  // full type since the extra keys are irrelevant to the gate.
  profile: SystemProfile;
  expect: Readiness;
}

const fixturePath = fileURLToPath(
  new URL("../../../test-fixtures/readiness-cases.json", import.meta.url),
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
  cases: ReadinessCase[];
};

describe("readiness() parity fixture", () => {
  for (const c of fixture.cases) {
    it(c.name, () => {
      expect(readiness(c.requires, c.capabilityNotes, c.profile)).toEqual(
        c.expect,
      );
    });
  }
});
