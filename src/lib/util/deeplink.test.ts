import { describe, it, expect } from "vitest";
import { parseDeepLink } from "./deeplink";

describe("parseDeepLink", () => {
  it("parses brewbrowser://bundle/<id> (host authority)", () => {
    expect(parseDeepLink("brewbrowser://bundle/local-llm")).toEqual({
      kind: "bundle",
      id: "local-llm",
    });
  });

  it("tolerates the empty-authority form brewbrowser:///bundle/<id>", () => {
    expect(parseDeepLink("brewbrowser:///bundle/image-gen")).toEqual({
      kind: "bundle",
      id: "image-gen",
    });
  });

  it("percent-decodes the bundle id", () => {
    expect(parseDeepLink("brewbrowser://bundle/web%2Ddev")).toEqual({
      kind: "bundle",
      id: "web-dev",
    });
  });

  it("rejects other schemes", () => {
    expect(parseDeepLink("https://bundle/local-llm")).toBeNull();
    expect(parseDeepLink("file:///etc/passwd")).toBeNull();
  });

  it("rejects unknown hosts / missing id", () => {
    expect(parseDeepLink("brewbrowser://package/jq")).toBeNull();
    expect(parseDeepLink("brewbrowser://bundle")).toBeNull();
    expect(parseDeepLink("brewbrowser://bundle/")).toBeNull();
  });

  it("returns null for malformed input instead of throwing", () => {
    expect(parseDeepLink("not a url")).toBeNull();
    expect(parseDeepLink("")).toBeNull();
  });
});
