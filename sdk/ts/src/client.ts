import {
  availability,
  schemaProductVersion,
  type CaptureScreenParams,
  type ClickParams,
  type DragParams,
  type FindParams,
  type InvokeParams,
  type KeyboardParams,
  type LookParams,
  type NavigateParams,
  type PermitParams,
  type RawClient,
  type RunParams,
  type SaveParams,
  type ScrollParams,
  type TabsParams,
  type TypeParams,
  type WaitForStabilityParams,
  type WaitForValueParams,
  type WindowsParams,
} from "./generated.js";
import { SocketTransport, type JsonRpcError, type Transport } from "./transport.js";

/** The health-v1 document the daemon returns from `health`. */
export interface Health {
  schemaVersion: string;
  version: string;
  platform: "macos" | "linux" | "windows";
  daemon: { running: boolean; ready: boolean; reason?: string | null; detail?: string | null };
  [key: string]: unknown;
}

/** A JSON-RPC `error`: the request never reached its tool. A refusal is not one of these. */
export class AxonRpcError extends Error {
  constructor(readonly rpcError: JsonRpcError, readonly method: string) {
    super(`Axon JSON-RPC error ${rpcError.code} from "${method}": ${rpcError.message}`);
    this.name = "AxonRpcError";
  }
}

export type Facade = "swift" | "mac" | "windows" | "linux";

/** `.axn` replay debugging, dispatched by the daemon's `debug.*` methods. */
export type DebugMethod =
  | "create" | "start" | "step" | "retry" | "continue"
  | "resume" | "runTo" | "setBreakpoints" | "stop";

/**
 * A platform can be served by more than one daemon build, and health-v1 names the operating
 * system rather than the build. macOS therefore admits any tool either macOS facade advertises;
 * the daemon stays the authority and refuses what it does not implement.
 */
const facadesFor = (platform: Health["platform"]): readonly Facade[] =>
  platform === "macos" ? ["swift", "mac"] : [platform === "linux" ? "linux" : "windows"];

/** One typed method per tool over one transport. Results stay loose; the daemon owns their shape. */
export class RawAxonClient implements RawClient {
  private nextId = 1;

  constructor(
    readonly transport: Transport,
    readonly platform?: Health["platform"],
    readonly sessionId?: string,
  ) {}

  withSession(sessionId: string): RawAxonClient {
    return new RawAxonClient(this.transport, this.platform, sessionId);
  }

  /** Whether the connected platform advertises this socket method at all. */
  supports(method: string): boolean {
    const support = availability[method as keyof typeof availability];
    if (!support || !this.platform) return true;
    return facadesFor(this.platform).some((facade) => support[facade]);
  }

  async request(method: string, params: object = {}): Promise<Record<string, unknown>> {
    if (!this.supports(method)) {
      throw new Error(`Axon tool "${method}" is not available on ${this.platform}`);
    }
    const sent: Record<string, unknown> = this.sessionId
      ? { ...params, _session: this.sessionId }
      : { ...params };
    const response = await this.transport.send({
      jsonrpc: "2.0", id: this.nextId++, method, params: sent,
    });
    if (response.error) throw new AxonRpcError(response.error, method);
    if (!response.result) throw new Error(`Axon response to "${method}" had neither result nor error`);
    return response.result;
  }

  health() { return this.request("health"); }
  shutdown(params: object = {}) { return this.request("shutdown", params); }

  /**
   * The stepping-debugger family for `.axn` replay. It is not part of the generated tool surface,
   * so its parameters and results stay loose; only the method names are enumerated.
   */
  debug(method: DebugMethod, params: object = {}) { return this.request(`debug.${method}`, params); }

  capture_screen(params: CaptureScreenParams = {}) { return this.request("capture_screen", params); }
  look(params: LookParams = {}) { return this.request("look", params); }
  navigate(params: NavigateParams) { return this.request("navigate", params); }
  windows(params: WindowsParams) { return this.request("windows", params); }
  tabs(params: TabsParams) { return this.request("tabs", params); }
  find(params: FindParams) { return this.request("find", params); }
  wait_for_value(params: WaitForValueParams) { return this.request("wait_for_value", params); }
  wait_for_stability(params: WaitForStabilityParams) { return this.request("wait_for_stability", params); }
  permit(params: PermitParams = {}) { return this.request("permit", params); }
  run(params: RunParams = {}) { return this.request("run", params); }
  save(params: SaveParams = {}) { return this.request("save", params); }
  click(params: ClickParams) { return this.request("click", params); }
  type(params: TypeParams) { return this.request("type", params); }
  keyboard(params: KeyboardParams) { return this.request("keyboard", params); }
  scroll(params: ScrollParams = {}) { return this.request("scroll", params); }
  drag(params: DragParams) { return this.request("drag", params); }
  invoke(params: InvokeParams) { return this.request("invoke", params); }
}

export interface ConnectOptions {
  transport?: Transport;
  socketPath?: string;
  warn?: (message: string) => void;
}

/** A connected daemon. `connect` proves the daemon is reachable and ready before returning. */
export class Axon {
  readonly version: string;

  protected constructor(readonly raw: RawAxonClient, readonly health: Health) {
    this.version = health.version;
  }

  static async connect(options: ConnectOptions = {}): Promise<Axon> {
    const transport = options.transport ?? new SocketTransport({ socketPath: options.socketPath });
    let health: Health;
    try {
      health = await new RawAxonClient(transport).health() as unknown as Health;
    } catch (error) {
      throw new Error("Axon daemon is not running or could not be reached", { cause: error });
    }
    if (!health.daemon?.ready) {
      const detail = health.daemon?.detail ?? health.daemon?.reason;
      throw new Error(`Axon daemon is not ready${detail ? `: ${detail}` : ""}`);
    }
    if (health.version !== schemaProductVersion) {
      (options.warn ?? console.warn)(
        `Axon SDK was generated for ${schemaProductVersion}, but the daemon reports ${health.version}`,
      );
    }
    return new Axon(new RawAxonClient(transport, health.platform), health);
  }

  /** Whether the connected platform advertises a tool, answered without calling the daemon. */
  supports(tool: string): boolean { return this.raw.supports(tool); }

  /** A handle that remembers the app it looked at, so later calls need no repeated selector. */
  app(selector: string): App { return new App(this.raw, selector); }

  /** A client whose every call is recorded under a named history session, exportable with `save`. */
  session(name: string): Session {
    if (!name) throw new Error("Axon session name must not be empty");
    return new Session(this.raw.withSession(name), name, this.health);
  }
}

type LookOptions = Omit<LookParams, "app" | "since">;
type ClickOptions = Omit<ClickParams, "target">;
type TypeOptions = Omit<TypeParams, "target" | "value">;
type WaitValueOptions = Omit<WaitForValueParams, "target">;
type WaitStabilityOptions = Omit<WaitForStabilityParams, "app">;
type InvokeOptions = Omit<InvokeParams, "target" | "name">;
type FindOptions = Omit<FindParams, "app" | "locator">;
type ScrollOptions = Omit<ScrollParams, "app" | "target">;
type KeyboardOptions = { deliveryPolicy?: string };
type DragOptions = Omit<DragParams, "from" | "to">;

/**
 * An app-scoped handle. It holds exactly two pieces of state — the newest snapshot id this app
 * produced and the process id that snapshot named — so scripts read as a sequence of actions on
 * one running app. Every method is one socket call; nothing here polls or retries.
 */
export class App {
  private snapshotId?: string;
  private pinned?: string;

  constructor(readonly raw: RawAxonClient, readonly selector: string) {}

  /** The most recent snapshot id observed through this handle, if any. */
  get lastSnapshotId(): string | undefined { return this.snapshotId; }

  /**
   * The selector later calls use: the pid from the last look once one is known, which keeps a
   * script bound to the process it observed rather than re-resolving a name that may now match
   * a different instance.
   */
  get appSelector(): string { return this.pinned ?? this.selector; }

  private target(name: string) { return { app: this.appSelector, name }; }

  async look(options: LookOptions = {}): Promise<Record<string, unknown>> {
    return this.remember(await this.raw.look({ ...options, app: this.appSelector }));
  }

  /** The daemon's change check against a prior snapshot, defaulting to this handle's own. */
  async changedSince(snapshotId = this.snapshotId): Promise<Record<string, unknown>> {
    if (!snapshotId) throw new Error("changedSince needs a snapshot id or a prior look()");
    return this.remember(await this.raw.look({ app: this.appSelector, since: snapshotId }));
  }

  click(name: string, options: ClickOptions = {}) {
    return this.raw.click({ ...options, target: this.target(name) });
  }
  type(name: string, value: string, options: TypeOptions = {}) {
    return this.raw.type({ ...options, target: this.target(name), value });
  }
  invoke(name: string, action: string, options: InvokeOptions = {}) {
    return this.raw.invoke({ ...options, target: this.target(name), name: action });
  }
  drag(from: string, to: string, options: DragOptions = {}) {
    return this.raw.drag({ ...options, from: this.target(from), to: this.target(to) });
  }
  scroll(name?: string, options: ScrollOptions = {}) {
    return this.raw.scroll(name === undefined
      ? { ...options, app: this.appSelector }
      : { ...options, app: this.appSelector, target: this.target(name) });
  }
  key(key: string, options: KeyboardOptions = {}) {
    return this.raw.keyboard({ ...options, app: this.appSelector, key });
  }
  text(text: string, options: KeyboardOptions = {}) {
    return this.raw.keyboard({ ...options, app: this.appSelector, text });
  }
  /** The daemon polls; the SDK waits on one call. */
  waitForValue(name: string, options: WaitValueOptions = {}) {
    return this.raw.wait_for_value({ ...options, target: this.target(name) });
  }
  waitForStability(options: WaitStabilityOptions = {}) {
    return this.raw.wait_for_stability({ ...options, app: this.appSelector });
  }
  find(locator: FindParams["locator"], options: FindOptions = {}) {
    return this.raw.find({ ...options, app: this.appSelector, locator });
  }

  /**
   * A full look nests its snapshot; a `since` check names the fresh snapshot at the top level.
   * Both advance the handle so a script can keep asking "what changed" without tracking ids.
   */
  private remember(result: Record<string, unknown>): Record<string, unknown> {
    const snapshot = result.snapshot;
    if (snapshot && typeof snapshot === "object") {
      const value = snapshot as Record<string, unknown>;
      if (typeof value.id === "string") this.snapshotId = value.id;
      const app = value.app;
      if (app && typeof app === "object") {
        const pid = (app as Record<string, unknown>).processIdentifier;
        if (typeof pid === "number" && Number.isInteger(pid) && pid > 0) this.pinned = String(pid);
      }
    }
    if (typeof result.currentSnapshotId === "string") this.snapshotId = result.currentSnapshotId;
    return result;
  }
}

/** Every call this client makes is recorded under `name`; `save` exports it as a `.axn` file. */
export class Session extends Axon {
  constructor(raw: RawAxonClient, readonly name: string, health: Health) {
    super(raw, health);
  }

  save(params: Omit<SaveParams, "sessionId"> = {}) {
    return this.raw.save({ ...params, sessionId: this.name });
  }
}
