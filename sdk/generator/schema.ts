export interface JsonSchema {
  type?: string | string[];
  description?: string;
  enum?: unknown[];
  const?: unknown;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  anyOf?: JsonSchema[];
  oneOf?: JsonSchema[];
  additionalProperties?: boolean | JsonSchema;
}

export interface ToolDefinition {
  name: string;
  description: string;
  socketMethod: string;
  availability: Record<string, boolean>;
  inputSchema: JsonSchema;
}

export interface ToolSurface {
  formatVersion: number;
  productVersion: string;
  tools: ToolDefinition[];
}

/**
 * A branch that states only `required` refines the schema around it rather than describing a
 * shape of its own: `keyboard` is one object whose `oneOf` demands either `text` or `key`.
 * Such a branch is rendered by promoting its keys to required on the enclosing object.
 *
 * This and the two helpers below are schema semantics rather than rendering choices, so every
 * language target reads them from here. A target that reimplemented the rule would agree with
 * the others only until the rule changed.
 */
export function isRefinement(schema: JsonSchema): boolean {
  return schema.required !== undefined &&
    schema.type === undefined && schema.properties === undefined && schema.enum === undefined &&
    schema.const === undefined && schema.items === undefined &&
    schema.anyOf === undefined && schema.oneOf === undefined;
}

export interface SchemaBranches {
  /** Every branch in declaration order, which is what a target names its emitted types after. */
  all: readonly JsonSchema[];
  refinements: readonly JsonSchema[];
  variants: readonly JsonSchema[];
}

export function branchesOf(schema: JsonSchema): SchemaBranches {
  const all = schema.anyOf ?? schema.oneOf ?? [];
  return {
    all,
    refinements: all.filter(isRefinement),
    variants: all.filter((branch) => !isRefinement(branch)),
  };
}

/** A tool needs an argument only when some property is required outright or by a refinement. */
export function demandsParams(schema: JsonSchema): boolean {
  if ((schema.required ?? []).length > 0) return true;
  return branchesOf(schema).refinements.some((branch) => (branch.required ?? []).length > 0);
}

export function parseToolSurface(value: unknown): ToolSurface {
  if (!value || typeof value !== "object") throw new Error("tool surface must be an object");
  const surface = value as Partial<ToolSurface>;
  if (typeof surface.productVersion !== "string" || !Array.isArray(surface.tools)) {
    throw new Error("tool surface is missing productVersion or tools");
  }
  for (const tool of surface.tools) {
    if (!tool || typeof tool.name !== "string" || typeof tool.socketMethod !== "string" ||
        typeof tool.description !== "string" || !tool.inputSchema || !tool.availability) {
      throw new Error("tool surface contains an incomplete tool definition");
    }
  }
  return surface as ToolSurface;
}