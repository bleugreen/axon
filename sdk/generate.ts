import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { parseToolSurface } from "./generator/schema.ts";
import { renderTypeScript } from "./generator/typescript.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const schemaPath = resolve(root, "schema/tool-surface-v1.json");
export const outputPath = resolve(root, "sdk/ts/src/generated.ts");

/** The TypeScript client surface implied by the committed tool-surface artifact. */
export async function generate(): Promise<string> {
  return renderTypeScript(parseToolSurface(JSON.parse(await readFile(schemaPath, "utf8"))));
}

// An explicit destination lets the drift check generate beside the committed file and compare.
if (import.meta.main) {
  const destination = process.argv[2] ? resolve(process.argv[2]) : outputPath;
  await writeFile(destination, await generate());
  console.log(`wrote ${destination}`);
}
