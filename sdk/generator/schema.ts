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