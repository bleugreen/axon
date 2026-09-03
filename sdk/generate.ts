import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { parseToolSurface } from "./generator/schema.ts";
import { renderTypeScript } from "./generator/typescript.ts";
import { renderPython } from "./generator/python.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const schemaPath = resolve(root, "schema/tool-surface-v1.json");

export type Language = "typescript" | "python";

const renderers: Record<Language, (surface: ReturnType<typeof parseToolSurface>) => string> = {
  typescript: renderTypeScript,
  python: renderPython,
};

/** Where each language's client is committed, and so what its drift check compares against. */
export const outputPaths: Record<Language, string> = {
  typescript: resolve(root, "sdk/ts/src/generated.ts"),
  python: resolve(root, "sdk/python/axon/_generated.py"),
};

/** Retained for the TypeScript tests that name their own output before the language split. */
export const outputPath = outputPaths.typescript;

/** The client surface implied by the committed tool-surface artifact, in one language. */
export async function generate(language: Language = "typescript"): Promise<string> {
  return renderers[language](parseToolSurface(JSON.parse(await readFile(schemaPath, "utf8"))));
}

const isLanguage = (value: string): value is Language => value in renderers;

// An explicit destination lets a drift check generate beside the committed file and compare.
if (import.meta.main) {
  const args = [...process.argv.slice(2)];
  let language: Language = "typescript";
  const flag = args.findIndex((argument) => argument === "--lang" || argument.startsWith("--lang="));
  if (flag >= 0) {
    const inline = args[flag]!.startsWith("--lang=");
    const named = inline ? args[flag]!.slice("--lang=".length) : args[flag + 1];
    if (!named || !isLanguage(named)) {
      console.error(`unknown language: ${named ?? "(missing)"}; expected typescript or python`);
      process.exit(2);
    }
    language = named;
    args.splice(flag, inline ? 1 : 2);
  }
  const destination = args[0] ? resolve(args[0]) : outputPaths[language];
  await writeFile(destination, await generate(language));
  console.log(`wrote ${destination}`);
}
