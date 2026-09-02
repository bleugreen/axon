import { createConnection } from "node:net";

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string | null;
  result?: Record<string, unknown>;
  error?: JsonRpcError;
}

export interface Transport {
  send(request: JsonRpcRequest): Promise<JsonRpcResponse>;
}

export interface SocketTransportOptions {
  socketPath?: string;
  timeoutMs?: number;
  longTimeoutMs?: number;
  maxResponseBytes?: number;
}

/**
 * The methods the daemon may hold open while it waits, which the reference Swift client
 * (`Sources/AxonCore/CommandHandling.swift`) gives the long bound. Anything else answers promptly
 * or is in trouble.
 */
export const longRunningMethods: ReadonlySet<string> =
  new Set(["run", "wait_for_value", "wait_for_stability"]);

export const defaultSocketPath = (): string => {
  if (process.env.AXON_SOCKET_PATH) return process.env.AXON_SOCKET_PATH;
  if (process.platform === "win32") return String.raw`\\.\pipe\axon-v1`;
  if (process.platform === "linux") {
    return `${process.env.XDG_RUNTIME_DIR ?? "/tmp"}/axon-v1.sock`;
  }
  return "/tmp/axon.sock";
};

export class SocketTransport implements Transport {
  readonly socketPath: string;
  readonly timeoutMs: number;
  readonly longTimeoutMs: number;
  readonly maxResponseBytes: number;

  constructor(options: SocketTransportOptions = {}) {
    this.socketPath = options.socketPath ?? defaultSocketPath();
    this.timeoutMs = options.timeoutMs ?? 30_000;
    this.longTimeoutMs = options.longTimeoutMs ?? 300_000;
    this.maxResponseBytes = options.maxResponseBytes ?? 64 * 1024 * 1024;
  }

  send(request: JsonRpcRequest): Promise<JsonRpcResponse> {
    return new Promise((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      const chunks: Buffer[] = [];
      let bytes = 0;
      let settled = false;
      const timeoutMs = longRunningMethods.has(request.method) ? this.longTimeoutMs : this.timeoutMs;
      const finish = (error?: Error, response?: JsonRpcResponse) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        if (error) reject(error);
        else resolve(response!);
      };

      socket.setTimeout(timeoutMs);
      socket.once("timeout", () => finish(new Error(
        `Axon request "${request.method}" timed out after ${timeoutMs}ms`,
      )));
      socket.once("error", (error) => finish(new Error(
        `Could not communicate with the Axon daemon at ${this.socketPath}: ${error.message}`,
        { cause: error },
      )));
      socket.once("connect", () => socket.write(`${JSON.stringify(request)}\n`));
      socket.on("data", (chunk: Buffer) => {
        const newline = chunk.indexOf(0x0a);
        const piece = newline >= 0 ? chunk.subarray(0, newline) : chunk;
        bytes += piece.byteLength;
        if (bytes > this.maxResponseBytes) {
          finish(new Error(`Axon response exceeded the ${this.maxResponseBytes}-byte limit`));
          return;
        }
        chunks.push(piece);
        if (newline < 0) return;
        try {
          finish(undefined, JSON.parse(Buffer.concat(chunks, bytes).toString("utf8")) as JsonRpcResponse);
        } catch (error) {
          finish(new Error(`Axon returned invalid JSON: ${String(error)}`, { cause: error }));
        }
      });
      socket.once("end", () => {
        if (!settled) finish(new Error("Axon closed the connection before returning a newline-terminated response"));
      });
    });
  }
}