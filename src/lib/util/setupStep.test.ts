import { describe, expect, it } from "vitest";

import { stepMode } from "./setupStep";

describe("stepMode", () => {
  it("maps kinds to render modes (command is copy-only, never an action)", () => {
    expect(stepMode("service")).toBe("action");
    expect(stepMode("open")).toBe("action");
    expect(stepMode("reveal")).toBe("action");
    expect(stepMode("command")).toBe("copy");
    expect(stepMode("note")).toBe("note");
    // Unknown/forward-compat kinds render as inert text, never an action.
    expect(stepMode("something-new")).toBe("note");
  });
});
