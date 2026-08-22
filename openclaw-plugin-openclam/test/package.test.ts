import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("OpenClam release package", () => {
  it("points every runtime entry at compiled output and excludes development trees", async () => {
    const root = resolve(import.meta.dirname, "..");
    const packageJson = JSON.parse(await readFile(resolve(root, "package.json"), "utf8"));
    expect(packageJson.main).toBe("./dist/index.js");
    expect(packageJson.exports).toEqual({ ".": "./dist/index.js" });
    expect(packageJson.openclaw.extensions).toEqual(["./dist/index.js"]);
    expect(packageJson.openclaw.setupEntry).toBe("./dist/setup-entry.js");
    expect(packageJson.files).toEqual(["dist", "openclaw.plugin.json", "README.md"]);
    const manifest = JSON.parse(await readFile(resolve(root, "openclaw.plugin.json"), "utf8"));
    const schema = manifest.channelConfigs.openclam.schema.properties;
    expect(schema.defaultAccount.pattern).toBe("^[a-z0-9][a-z0-9_-]{0,63}$");
    expect(schema.accounts.propertyNames.pattern).toBe("^[a-z0-9][a-z0-9_-]{0,63}$");
    await access(resolve(root, "dist/index.js"));
    await access(resolve(root, "dist/setup-entry.js"));
  });
});
