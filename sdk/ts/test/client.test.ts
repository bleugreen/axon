import { describe, expect, test } from "bun:test";
import { Axon, AxonRpcError } from "../src/client.js";
import { SocketTransport } from "../src/transport.js";
import { schemaProductVersion } from "../src/generated.js";
import {
  FakeDaemon, fixture, ok, rpcError, socketFixture, socketHealth, type ReceivedRequest,
} from "./daemon.js";

type Result = Record<string, unknown>;
type Route = (request: ReceivedRequest) => Result | undefined;

/** A daemon that answers `health` from a fixture and routes tools through `route`. */
async function connectTo(
  health: Record<string, unknown>,
  route: Route = () => ({}),
  options: { warn?: (message: string) => void } = {},
) {
  const daemon = await FakeDaemon.start((received) =>
    ok(received.id, received.method === "health" ? health : route(received) ?? {}));
  const axon = await Axon.connect({
    transport: new SocketTransport({ socketPath: daemon.path }),
    warn: options.warn ?? (() => {}),
  });
  return { daemon, axon };
}

const snapshot = (id: string, pid = 4210): Result => ({
  snapshot: {
    id,
    app: { bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: pid },
    indexedNodes: [],
  },
});

describe("connect", () => {
  test("reports the daemon version and platform after a health handshake", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      expect(daemon.only.method).toBe("health");
      expect(axon.version).toBe(schemaProductVersion);
      expect(axon.health.platform).toBe("macos");
    } finally {
      await daemon.stop();
    }
  });

  test("warns without failing when the daemon version differs from the schema", async () => {
    const warnings: string[] = [];
    const { daemon, axon } = await connectTo(
      socketHealth({ version: "0.0.1" }), () => ({}), { warn: (message) => warnings.push(message) },
    );
    try {
      expect(axon.version).toBe("0.0.1");
      expect(warnings).toHaveLength(1);
      expect(warnings[0]).toContain(schemaProductVersion);
      expect(warnings[0]).toContain("0.0.1");
    } finally {
      await daemon.stop();
    }
  });

  test("refuses to hand back a client when the daemon reports itself unready", async () => {
    const unready = socketHealth({
      ready: false,
      session: { interactive: true, graphical: false, reason: "no-display", detail: "No graphical session is available" },
    });
    const daemon = await FakeDaemon.start((received) => ok(received.id, unready));
    try {
      await expect(Axon.connect({
        transport: new SocketTransport({ socketPath: daemon.path }),
      })).rejects.toThrow(/not ready: No graphical session is available/);
    } finally {
      await daemon.stop();
    }
  });

  test("names an ungranted permission at connect rather than leaving it to a later refusal", async () => {
    const warnings: string[] = [];
    const { daemon } = await connectTo(
      socketHealth({
        version: schemaProductVersion,
        permissions: [
          { name: "accessibility", granted: false, reason: "accessibility-not-granted" },
          { name: "screenRecording", granted: true },
        ],
      }),
      () => ({}),
      { warn: (message) => warnings.push(message) },
    );
    try {
      expect(warnings.join("\n")).toMatch(/not granted accessibility/);
    } finally {
      await daemon.stop();
    }
  });

  test("explains an unreachable daemon rather than surfacing a socket error", async () => {
    await expect(Axon.connect({ socketPath: "/tmp/axon-sdk-test-absent.sock" }))
      .rejects.toThrow(/daemon is not running or could not be reached/);
  });
});

describe("errors and refusals", () => {
  test("throws on a JSON-RPC error", async () => {
    const daemon = await FakeDaemon.start((received) => received.method === "health"
      ? ok(received.id, socketHealth({ version: schemaProductVersion }))
      : rpcError(received.id, -32602, "click requires a target"));
    try {
      const axon = await Axon.connect({
        transport: new SocketTransport({ socketPath: daemon.path }), warn: () => {},
      });
      const failure = axon.app("Safari").click("checkout/submit");
      await expect(failure).rejects.toThrow(AxonRpcError);
      await expect(failure).rejects.toThrow(/-32602.*click requires a target/);
    } finally {
      await daemon.stop();
    }
  });

  test("returns a refusal as an ordinary result", async () => {
    const refusal = fixture<{ cases: Result[] }>("delivery/results.json").cases
      .find((entry: Result) => entry.refusal !== null)!;
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }), () => refusal);
    try {
      const result = await axon.app("Safari").click("checkout/submit");
      expect(result.dispatchSuccess).toBe(false);
      expect(result.refusal).toEqual(refusal.refusal as never);
    } finally {
      await daemon.stop();
    }
  });
});

describe("app handle state", () => {
  test("pins the observed process and reuses the last snapshot id", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }), (received) =>
      received.method === "look" && received.params.since === undefined
        ? snapshot("obs-safari-1", 4210)
        : { changed: true, reason: "tree", snapshotId: "obs-safari-1", currentSnapshotId: "obs-safari-2" });
    try {
      const app = axon.app("Safari");
      await app.look();
      expect(app.lastSnapshotId).toBe("obs-safari-1");
      // The name resolved to a process; every later call names that process instead.
      expect(app.appSelector).toBe("4210");

      await app.changedSince();
      expect(daemon.last("look").params).toEqual({ app: "4210", since: "obs-safari-1" });
      // A change check names the fresh snapshot, so the next one chains from it.
      expect(app.lastSnapshotId).toBe("obs-safari-2");

      await app.changedSince();
      expect(daemon.last("look").params.since).toBe("obs-safari-2");

      await app.changedSince("obs-explicit");
      expect(daemon.last("look").params.since).toBe("obs-explicit");
    } finally {
      await daemon.stop();
    }
  });

  test("chains a change check recorded from a live daemon", async () => {
    // The same two recordings the Python SDK's fake replays. A handle that reads the daemon's own
    // response correctly here reads it correctly there, and neither can drift onto a shape the
    // other invented.
    const look = socketFixture("socket-look-calculator-macos.json");
    const since = socketFixture("socket-look-since-calculator-macos.json");
    const { daemon, axon } = await connectTo(
      socketHealth({ version: schemaProductVersion }),
      (received) => received.params.since === undefined ? look : since,
    );
    try {
      const app = axon.app("Calculator");
      await app.look({ screenshot: false });
      const snapshotId = (look.snapshot as Record<string, unknown>).id as string;
      expect(app.lastSnapshotId).toBe(snapshotId);

      const verdict = await app.changedSince();
      expect(daemon.last("look").params.since).toBe(snapshotId);
      // Two digits were pressed between these snapshots and the daemon still says unchanged: the
      // check compares app identity and top-level window signatures, never values.
      expect(verdict.changed).toBe(false);
      expect(app.lastSnapshotId).toBe(since.currentSnapshotId as string);
    } finally {
      await daemon.stop();
    }
  });

  test("asks for a snapshot before it can report what changed", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      await expect(axon.app("Safari").changedSince())
        .rejects.toThrow(/needs a snapshot id or a prior look/);
      expect(daemon.received.map((r) => r.method)).toEqual(["health"]);
    } finally {
      await daemon.stop();
    }
  });

  test("maps each wrapper onto exactly one socket call", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      const app = axon.app("Safari");
      await app.type("form/email", "ada@example.com");
      expect(daemon.last("type").params).toEqual({
        target: { app: "Safari", name: "form/email" }, value: "ada@example.com",
      });

      await app.waitForValue("status", { contains: "Done", timeoutMs: 2_000 });
      expect(daemon.last("wait_for_value").params).toEqual({
        contains: "Done", timeoutMs: 2_000, target: { app: "Safari", name: "status" },
      });

      await app.waitForStability();
      expect(daemon.last("wait_for_stability").params).toEqual({ app: "Safari" });

      await app.key("cmd+s");
      expect(daemon.last("keyboard").params).toEqual({ app: "Safari", key: "cmd+s" });

      await app.invoke("row/first", "AXPress");
      expect(daemon.last("invoke").params).toEqual({
        target: { app: "Safari", name: "row/first" }, name: "AXPress",
      });

      // Nine wrapper calls, nine requests: the SDK never polls on the client side.
      expect(daemon.received).toHaveLength(6);
    } finally {
      await daemon.stop();
    }
  });
});

describe("sessions", () => {
  test("tags every call in a session and leaves untagged calls alone", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }), () => ({}));
    try {
      await axon.app("Safari").click("checkout/submit");
      expect(daemon.last("click").params._session).toBeUndefined();

      const session = axon.session("checkout-demo");
      await session.app("Safari").click("checkout/submit");
      expect(daemon.last("click").params._session).toBe("checkout-demo");

      await session.save({ path: "/tmp/checkout.axn" });
      expect(daemon.last("save").params).toEqual({
        path: "/tmp/checkout.axn", sessionId: "checkout-demo", _session: "checkout-demo",
      });
    } finally {
      await daemon.stop();
    }
  });

  test("rejects an empty session name", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      expect(() => axon.session("")).toThrow(/must not be empty/);
    } finally {
      await daemon.stop();
    }
  });
});

describe("replay debugging", () => {
  test("dispatches the debug family under its own method namespace", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      await axon.raw.debug("create", { path: "/tmp/checkout.axn" });
      await axon.raw.debug("setBreakpoints", { indexes: [2] });
      expect(daemon.received.map((r) => r.method))
        .toEqual(["health", "debug.create", "debug.setBreakpoints"]);
      expect(daemon.last("debug.create").params).toEqual({ path: "/tmp/checkout.axn" });
    } finally {
      await daemon.stop();
    }
  });
});

describe("platform availability", () => {
  test("refuses a tool the connected platform does not advertise, before the call", async () => {
    const { daemon, axon } = await connectTo(socketHealth({ version: schemaProductVersion }));
    try {
      expect(axon.supports("navigate")).toBe(true);
      expect(axon.supports("capture_screen")).toBe(false);
      await expect(axon.raw.capture_screen()).rejects.toThrow(/not available on macos/);
      expect(daemon.received.map((r) => r.method)).toEqual(["health"]);
    } finally {
      await daemon.stop();
    }
  });

  test("reads availability from the connected platform, not the host", async () => {
    const { daemon, axon } = await connectTo(
      socketHealth({ platform: "linux", version: schemaProductVersion }),
    );
    try {
      expect(axon.supports("capture_screen")).toBe(true);
      expect(axon.supports("navigate")).toBe(false);
      await expect(axon.raw.navigate({ app: "Safari", url: "https://example.com" }))
        .rejects.toThrow(/not available on linux/);
    } finally {
      await daemon.stop();
    }
  });
});
