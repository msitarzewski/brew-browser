import { beforeEach, describe, expect, it } from "vitest";

import { ui } from "./ui.svelte";

// Bundles reuses the canonical master-list + right-side Details mechanics
// (Library/Trending). These cover the `selectedBundle` selection contract that
// drives the pane in +page.svelte: select opens it, closeDetail clears it, and
// any section change clears it (so entering Bundles starts with nothing
// selected / pane closed — matches Library, no auto-select).
describe("ui store — bundle selection", () => {
  beforeEach(() => {
    // Reset the two pieces of selection state the pane branches read.
    ui.selectedBundle = null;
    ui.selectedPackage = null;
  });

  it("selectBundle sets the selected bundle id", () => {
    expect(ui.selectedBundle).toBeNull();
    ui.selectBundle("ai-local");
    expect(ui.selectedBundle).toBe("ai-local");
    // Swapping to another bundle just replaces the id.
    ui.selectBundle("web-dev");
    expect(ui.selectedBundle).toBe("web-dev");
  });

  it("closeDetail clears the selected bundle (and package)", () => {
    ui.selectBundle("ai-local");
    ui.selectPackage("wget", "formula");
    ui.closeDetail();
    expect(ui.selectedBundle).toBeNull();
    expect(ui.selectedPackage).toBeNull();
  });

  it("setSection clears the selected bundle on any nav change", () => {
    ui.selectBundle("ai-local");
    ui.setSection("bundles");
    expect(ui.selectedBundle).toBeNull();

    // Even navigating to the same section it was selected under clears it —
    // a new section click is a new context.
    ui.selectBundle("ai-local");
    ui.setSection("library");
    expect(ui.selectedBundle).toBeNull();
  });
});
