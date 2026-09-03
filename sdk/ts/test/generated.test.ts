import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { generate, outputPath, schemaPath } from "../../generate.ts";
import { availability, schemaProductVersion, type KeyboardParams } from "../src/generated.js";

const surface = JSON.parse(readFileSync(schemaPath, "utf8")) as {
  productVersion: string;
  tools: { name: string; socketMethod: string; availability: Record<string, boolean> }[];
};

describe("generated client", () => {
  test("matches what the committed tool surface implies", async () => {
    const regenerated = await generate();
    const committed = readFileSync(outputPath, "utf8");
    expect(regenerated).toBe(committed);
  });

  test("is written beside the schema it is generated from", () => {
    expect(outputPath).toBe(resolve(import.meta.dir, "../src/generated.ts"));
  });

  test("carries every tool's availability, keyed by socket method", () => {
    expect(Object.keys(availability)).toEqual(surface.tools.map((tool) => tool.socketMethod));
    for (const tool of surface.tools) {
      expect(availability[tool.socketMethod as keyof typeof availability])
        .toEqual(tool.availability as never);
    }
  });

  test("states the product version the surface was exported at", () => {
    expect(surface.productVersion).toBe(schemaProductVersion);
  });

  test("resolves every schema construct to a real type", async () => {
    // A branch that only states `required` refines the object around it. Rendering such a branch
    // as a standalone type produced `unknown`, silently erasing a tool's whole parameter shape.
    expect(await generate()).not.toContain("unknown | unknown");
  });
});

describe("generated types", () => {
  test("require what the schema requires", () => {
    // These assertions are checked by `bun run typecheck`, not at runtime: the point is that the
    // emitted types reject calls the daemon would reject.
    const text: KeyboardParams = { text: "hello" };
    const key: KeyboardParams = { key: "cmd+s", app: "Safari" };
    // @ts-expect-error keyboard demands either text or key
    const neither: KeyboardParams = { app: "Safari" };
    expect([text, key, neither]).toHaveLength(3);
  });
});
