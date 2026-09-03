import { createServer, type Server, type Socket } from "node:net";
import { readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";

export interface ReceivedRequest {
  method: string;
  params: Record<string, unknown>;
  id: unknown;
  jsonrpc: unknown;
  text: string;
}

/**
 * What a fake daemon does with one request. Returning an object sends it as the JSON-RPC
 * response; returning a string writes those exact bytes; returning undefined answers nothing,
 * which is how a hung daemon is modelled.
 */
export type Responder = (request: ReceivedRequest) => unknown;

let counter = 0;

/**
 * A stand-in for the Axon daemon that speaks the real socket protocol: one request and one
 * response per connection, each newline-terminated. Tests assert against what it received.
 */
export class FakeDaemon {
  readonly received: ReceivedRequest[] = [];
  connections = 0;
  private readonly open = new Set<Socket>();

  private constructor(readonly path: string, private readonly server: Server) {}

  static async start(responder: Responder): Promise<FakeDaemon> {
    // Short path: a Unix socket address is capped near 100 bytes, well under a typical TMPDIR.
    const path = `/tmp/axon-sdk-test-${process.pid}-${counter++}.sock`;
    rmSync(path, { force: true });
    const server = createServer();
    const daemon = new FakeDaemon(path, server);

    server.on("connection", (socket) => {
      daemon.connections += 1;
      daemon.open.add(socket);
      socket.on("close", () => daemon.open.delete(socket));
      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        const text = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        const parsed = JSON.parse(text) as Record<string, unknown>;
        const request: ReceivedRequest = {
          method: String(parsed.method),
          params: (parsed.params ?? {}) as Record<string, unknown>,
          id: parsed.id,
          jsonrpc: parsed.jsonrpc,
          text,
        };
        daemon.received.push(request);
        const reply = responder(request);
        if (reply === undefined) return;
        socket.end(typeof reply === "string" ? reply : `${JSON.stringify(reply)}\n`);
      });
      socket.on("error", () => {});
    });

    await new Promise<void>((done, fail) => {
      server.once("error", fail);
      server.listen(path, done);
    });
    return daemon;
  }

  /** The single request received, asserted to be the only one. */
  get only(): ReceivedRequest {
    if (this.received.length !== 1) {
      throw new Error(`expected exactly one request, saw ${this.received.length}`);
    }
    return this.received[0]!;
  }

  last(method: string): ReceivedRequest {
    const match = [...this.received].reverse().find((request) => request.method === method);
    if (!match) throw new Error(`no ${method} request was received`);
    return match;
  }

  async stop(): Promise<void> {
    // A connection this daemon deliberately never answered would otherwise hold the close open.
    for (const socket of this.open) socket.destroy();
    await new Promise<void>((done) => this.server.close(() => done()));
    rmSync(this.path, { force: true });
  }
}

/** A JSON-RPC success envelope around a tool result. */
export const ok = (id: unknown, result: Record<string, unknown>) => ({ jsonrpc: "2.0", id, result });
/** A JSON-RPC error envelope: the request never reached its tool. */
export const rpcError = (id: unknown, code: number, message: string) =>
  ({ jsonrpc: "2.0", id, error: { code, message } });

/** A shared example under `schema/fixtures/`, which both implementations are checked against. */
const fixtures = resolve(import.meta.dir, "../../../schema/fixtures");
export const fixture = <T = Record<string, unknown>>(name: string): T =>
  JSON.parse(readFileSync(resolve(fixtures, name), "utf8")) as T;

/**
 * A healthy macOS daemon's answer to `health`, recorded from a live 0.3.6 daemon over the socket.
 *
 * The socket returns `DaemonReport` (`Sources/AxonCore/HealthStatus.swift`), which is flat. It is
 * not the `health-v1` document under `schema/fixtures/health/`: that one is what the CLI's
 * `status --json` synthesizes, and a fake replaying it lets a client pass tests it cannot pass
 * against a real daemon.
 */
export const socketHealth = (
  overrides: Record<string, unknown> = {},
): Record<string, unknown> => ({
  ...JSON.parse(
    readFileSync(resolve(import.meta.dir, "fixtures/socket-health-macos.json"), "utf8"),
  ) as Record<string, unknown>,
  ...overrides,
});
