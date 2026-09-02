import { describe, expect, test } from "bun:test";
import { SocketTransport, defaultSocketPath, longRunningMethods } from "../src/transport.js";
import { FakeDaemon, ok } from "./daemon.js";

const request = (method: string, id = 1) =>
  ({ jsonrpc: "2.0" as const, id, method, params: {} });

describe("socket framing", () => {
  test("sends one newline-terminated request per connection", async () => {
    const daemon = await FakeDaemon.start((received) => ok(received.id, { echoed: received.method }));
    const transport = new SocketTransport({ socketPath: daemon.path });
    try {
      expect(await transport.send(request("look", 1))).toEqual(
        { jsonrpc: "2.0", id: 1, result: { echoed: "look" } } as never,
      );
      await transport.send(request("find", 2));

      // Each request gets its own connection: the daemon never multiplexes.
      expect(daemon.connections).toBe(2);
      expect(daemon.received.map((r) => r.method)).toEqual(["look", "find"]);
      expect(daemon.received.every((r) => r.jsonrpc === "2.0")).toBe(true);
      expect(daemon.received[0]!.text).not.toContain("\n");
    } finally {
      await daemon.stop();
    }
  });

  test("rejects when nothing is listening, naming the endpoint", async () => {
    const transport = new SocketTransport({ socketPath: "/tmp/axon-sdk-test-absent.sock" });
    await expect(transport.send(request("health"))).rejects.toThrow(/axon-sdk-test-absent\.sock/);
  });

  test("rejects a connection closed before a complete response", async () => {
    const daemon = await FakeDaemon.start(() => "{\"jsonrpc\":\"2.0\"");
    try {
      const transport = new SocketTransport({ socketPath: daemon.path });
      await expect(transport.send(request("look"))).rejects.toThrow(/newline-terminated/);
    } finally {
      await daemon.stop();
    }
  });

  test("rejects a response that is not JSON", async () => {
    const daemon = await FakeDaemon.start(() => "not json\n");
    try {
      const transport = new SocketTransport({ socketPath: daemon.path });
      await expect(transport.send(request("look"))).rejects.toThrow(/invalid JSON/);
    } finally {
      await daemon.stop();
    }
  });
});

describe("limits", () => {
  test("rejects a response past the size cap instead of buffering it", async () => {
    const daemon = await FakeDaemon.start((received) =>
      ok(received.id, { padding: "x".repeat(4096) }));
    try {
      const transport = new SocketTransport({ socketPath: daemon.path, maxResponseBytes: 128 });
      await expect(transport.send(request("look"))).rejects.toThrow(/128-byte limit/);
    } finally {
      await daemon.stop();
    }
  });

  test("times out a silent daemon", async () => {
    const daemon = await FakeDaemon.start(() => undefined);
    try {
      const transport = new SocketTransport({ socketPath: daemon.path, timeoutMs: 60 });
      await expect(transport.send(request("look"))).rejects.toThrow(/timed out after 60ms/);
    } finally {
      await daemon.stop();
    }
  });

  test("gives waiting and replay methods the long timeout", async () => {
    const daemon = await FakeDaemon.start(() => undefined);
    try {
      const transport = new SocketTransport({
        socketPath: daemon.path, timeoutMs: 40, longTimeoutMs: 600,
      });
      // The short bound applies to an ordinary method and not to a waiting one.
      await expect(transport.send(request("look"))).rejects.toThrow(/timed out after 40ms/);

      const waiting = transport.send(request("wait_for_stability"));
      await Bun.sleep(150);
      expect(daemon.received.map((r) => r.method)).toEqual(["look", "wait_for_stability"]);
      // Well past the short bound, still waiting; it ends on the long one instead.
      await expect(waiting).rejects.toThrow(/timed out after 600ms/);
    } finally {
      await daemon.stop();
    }
  });
});

describe("timeout table", () => {
  test("matches the reference client's long-running methods", () => {
    // Sources/AxonCore/CommandHandling.swift decides this set; the SDK mirrors it rather than
    // inventing its own bounds.
    expect([...longRunningMethods].sort())
      .toEqual(["run", "wait_for_stability", "wait_for_value"]);
  });
});

describe("endpoint defaults", () => {
  test("prefers AXON_SOCKET_PATH over the platform default", () => {
    const previous = process.env.AXON_SOCKET_PATH;
    process.env.AXON_SOCKET_PATH = "/tmp/axon-override.sock";
    try {
      expect(defaultSocketPath()).toBe("/tmp/axon-override.sock");
    } finally {
      if (previous === undefined) delete process.env.AXON_SOCKET_PATH;
      else process.env.AXON_SOCKET_PATH = previous;
    }
  });
});
