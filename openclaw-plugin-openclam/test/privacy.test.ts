import { describe, expect, it } from "vitest";
import {
  containsPrivatePathReference,
  redactPrivatePathReferences,
} from "../src/privacy.js";

describe("OpenClam private path redaction", () => {
  it("removes complete local Markdown destinations, including unsupported files", () => {
    const text =
      "[Source](/Users/adam/My Project/main.swift), " +
      "[Home](~/Private Project/main.swift), and " +
      "[Web](https://example.com/main.swift).";

    expect(redactPrivatePathReferences(text)).toBe("Source, Home, and [Web](https://example.com/main.swift).");
    expect(containsPrivatePathReference(text)).toBe(true);
  });

  it("redacts full spaced absolute and home-relative file paths", () => {
    const text =
      "Saved at /Users/adam/My Project/main.swift and copied to " +
      "~/Private Project/final report.pdf.";

    expect(redactPrivatePathReferences(text)).toBe(
      "Saved at attached file and copied to attached file.",
    );
    expect(containsPrivatePathReference(text)).toBe(true);
  });

  it("leaves remote Markdown links unchanged", () => {
    const text = "[Video](https://example.com/output/final%20movie.mp4)";
    expect(redactPrivatePathReferences(text)).toBe(text);
    expect(containsPrivatePathReference(text)).toBe(false);
  });
});
