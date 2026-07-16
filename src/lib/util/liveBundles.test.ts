import { describe, expect, it } from "vitest";

import type { Bundle } from "$lib/types";
import { shouldReplaceWithLive } from "./liveBundles";

describe("shouldReplaceWithLive", () => {
  it("replaces only on a non-empty result — an empty payload never wipes the shipped set", () => {
    expect(shouldReplaceWithLive([])).toBe(false);
    expect(shouldReplaceWithLive([{ id: "x" } as unknown as Bundle])).toBe(true);
  });
});
