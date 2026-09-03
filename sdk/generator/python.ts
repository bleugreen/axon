import { branchesOf, demandsParams, type JsonSchema, type ToolSurface } from "./schema.ts";

/**
 * Reserved words cannot be attribute names, so a tool whose schema names one — `save` and `drag`
 * each take a `from` — is declared through TypedDict's functional form, whose keys are strings.
 */
const keywords = new Set([
  "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
  "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
  "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
  "with", "yield",
]);

const identifier = /^[A-Za-z_][A-Za-z0-9_]*$/;
const isAttribute = (name: string) => identifier.test(name) && !keywords.has(name);
const pascal = (name: string) => name.split(/[^A-Za-z0-9]+/).filter(Boolean)
  .map((part) => part[0]!.toUpperCase() + part.slice(1)).join("");

const literal = (value: unknown): string =>
  value === null ? "None" : value === true ? "True" : value === false ? "False" : JSON.stringify(value);

/** Python has no block comment, so a description becomes one `#` line per line of it. */
const comment = (text: string, indent: string) =>
  text.split("\n").map((line) => `${indent}# ${line}`).join("\n");

const docstring = (text: string, indent: string) => {
  const body = text.replaceAll("\\", "\\\\").replaceAll('"""', '\\"\\"\\"');
  // A docstring whose last character is a quote would close its own delimiter.
  return body.includes("\n") || body.endsWith('"')
    ? `${indent}"""\n${body.split("\n").map((line) => `${indent}${line}`).join("\n")}\n${indent}"""`
    : `${indent}"""${body}"""`;
};

interface Field {
  key: string;
  description?: string;
  annotation: string;
}

/**
 * TypeScript can spell an object shape inline; Python cannot, so every object in the artifact
 * becomes a named TypedDict. A name is the path that reached it — `ClickParamsTarget2Point` is
 * `click`'s second `target` branch and its `point` property — which keeps names stable under any
 * change that does not move the property.
 */
class PythonSurface {
  readonly declarations: string[] = [];
  private readonly declared = new Set<string>();
  private readonly imported = new Set<string>();

  /** Records a `typing` name as used, so the import line states exactly what the file needs. */
  uses<Name extends string>(name: Name): Name {
    this.imported.add(name);
    return name;
  }

  typingImport(): string {
    return `from typing import ${[...this.imported].sort().join(", ")}`;
  }

  /** Emits every TypedDict a schema needs and returns the annotation that names them. */
  annotation(schema: JsonSchema, name: string, doc?: string): string {
    if (schema.const !== undefined) return `${this.uses("Literal")}[${literal(schema.const)}]`;
    if (schema.enum) return `${this.uses("Literal")}[${schema.enum.map(literal).join(", ")}]`;
    const { all, refinements, variants } = branchesOf(schema);
    if (variants.length) {
      // A branch is named for where it sits in the artifact, not for where it sits among the
      // branches that happened to need a name.
      return variants.map((variant) => this.annotation(
        variant, variants.length > 1 ? `${name}${all.indexOf(variant) + 1}` : name, doc,
      )).join(" | ");
    }
    if (Array.isArray(schema.type)) {
      return schema.type.map((type) => this.annotation({ type }, name, doc)).join(" | ");
    }
    const type = schema.type ?? (schema.properties ? "object" : undefined);
    switch (type) {
      case "string": return "str";
      case "number": return "float";
      case "integer": return "int";
      case "boolean": return "bool";
      case "null": return "None";
      case "array": return `list[${this.annotation(schema.items ?? {}, `${name}Item`)}]`;
      case "object": return this.object(schema, name, refinements, doc);
      default: return this.uses("Any");
    }
  }

  private object(
    schema: JsonSchema, name: string, refinements: readonly JsonSchema[], doc?: string,
  ): string {
    const properties = Object.entries(schema.properties ?? {});
    if (properties.length > 0 && schema.additionalProperties) {
      throw new Error(
        `${name} names properties and accepts further ones; a TypedDict cannot state both. ` +
        "Decide what that means for Python in sdk/generator/python.ts before regenerating.",
      );
    }
    // An object that names no properties but accepts any is a plain mapping. A TypedDict here
    // would claim a shape the artifact never stated.
    if (properties.length === 0 && schema.additionalProperties) return `dict[str, ${this.uses("Any")}]`;
    if (refinements.length === 0) return this.typedDict(name, schema, [], doc);
    return refinements.map((branch) => this.typedDict(
      `${name}${(branch.required ?? []).map(pascal).join("")}`, schema, branch.required ?? [], doc,
    )).join(" | ");
  }

  private typedDict(
    name: string, schema: JsonSchema, alsoRequired: readonly string[], doc?: string,
  ): string {
    if (this.declared.has(name)) throw new Error(`the Python client would declare ${name} twice`);
    this.declared.add(name);
    const required = new Set([...(schema.required ?? []), ...alsoRequired]);
    // Resolving the fields emits whatever they nest, so a declaration always follows the ones it
    // refers to and the file reads inside out.
    const fields: Field[] = Object.entries(schema.properties ?? {}).map(([key, property]) => ({
      key,
      description: property.description,
      annotation: `${this.uses(required.has(key) ? "Required" : "NotRequired")}`
        + `[${this.annotation(property, `${name}${pascal(key)}`)}]`,
    }));
    const description = doc ?? schema.description;
    this.declarations.push(fields.every((field) => isAttribute(field.key))
      ? this.classForm(name, fields, description)
      : this.functionalForm(name, fields, description));
    return name;
  }

  private classForm(name: string, fields: readonly Field[], description?: string): string {
    const heading = description ? [docstring(description, "    ")] : [];
    const entries = fields.flatMap((field) => [
      ...(field.description ? [comment(field.description, "    ")] : []),
      `    ${field.key}: ${field.annotation}`,
    ]);
    const body = entries.length === 0
      ? (heading.length === 0 ? ["    pass"] : heading)
      : [...heading, ...(heading.length === 0 ? [] : [""]), ...entries];
    return `class ${name}(${this.uses("TypedDict")}, total=False):\n${body.join("\n")}`;
  }

  private functionalForm(name: string, fields: readonly Field[], description?: string): string {
    const entries = fields.flatMap((field) => [
      ...(field.description ? [comment(field.description, "        ")] : []),
      `        ${JSON.stringify(field.key)}: ${field.annotation},`,
    ]);
    return `${description ? `${comment(description, "")}\n` : ""}`
      + `${name} = ${this.uses("TypedDict")}(\n    ${JSON.stringify(name)},\n`
      + `    {\n${entries.join("\n")}\n    },\n    total=False,\n)`;
  }
}

export function renderPython(surface: ToolSurface): string {
  const python = new PythonSurface();
  const methods = surface.tools.map((tool) => {
    const name = `${pascal(tool.name)}Params`;
    const annotation = python.annotation(tool.inputSchema, name, tool.description);
    // A tool whose schema is one object is already declared under its own name; one whose branches
    // refine it resolves to a union, which needs an alias for `RawClient` to name.
    if (annotation !== name) {
      python.declarations.push(
        `${comment(tool.description, "")}\n${name}: ${python.uses("TypeAlias")} = ${annotation}`,
      );
    }
    const params = demandsParams(tool.inputSchema) ? `params: ${name}` : `params: ${name} | None = None`;
    return `    def ${tool.socketMethod}(self, ${params}) -> dict[str, ${python.uses("Any")}]:\n`
      + `${docstring(tool.description, "        ")}\n        ...`;
  });
  const availability = surface.tools.map((tool) =>
    `    ${JSON.stringify(tool.socketMethod)}: {`
    + Object.entries(tool.availability)
      .map(([facade, supported]) => `${JSON.stringify(facade)}: ${literal(supported)}`).join(", ")
    + "},").join("\n");
  python.uses("Final");
  python.uses("Protocol");

  return `"""Generated by sdk/generate.ts from schema/tool-surface-v1.json. Do not edit."""\n\n`
    + "from __future__ import annotations\n\n"
    + "from collections.abc import Mapping\n"
    + `${python.typingImport()}\n\n`
    + `SCHEMA_PRODUCT_VERSION: Final = ${JSON.stringify(surface.productVersion)}\n\n`
    + "# Per-tool platform availability, keyed by socket method then by daemon facade.\n"
    + `AVAILABILITY: Final[Mapping[str, Mapping[str, bool]]] = {\n${availability}\n}\n\n\n`
    + `${python.declarations.join("\n\n\n")}\n\n\nclass RawClient(Protocol):\n`
    + '    """One method per tool in the committed tool surface, typed by that tool\'s schema."""\n\n'
    + `${methods.join("\n\n")}\n`;
}
