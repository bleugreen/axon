import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { parseToolSurface } from "./generator/schema.ts";
import { renderTypeScript } from "./generator/typescript.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const schemaPath = resolve(root, "schema/tool-surface-v1.json");
export const outputPath = resolve(root, "sdk/ts/src/generated.ts");

export async function generate(): Promise<string> {
  return renderTypeScript(parseToolSurface(JSON.parse(await readFile(schemaPath, "utf8"))));
}

if (import.meta.main) {
  await writeFile(outputPath, await generate());
  console.log(`wrote ${outputPath}`);
}