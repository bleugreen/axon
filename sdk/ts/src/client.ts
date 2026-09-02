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

export interface Health {
  schemaVersion: string;
  version: string;
  platform: "macos" | "linux" | "windows";
  daemon: { running: boolean; ready: boolean; reason?: string | null; detail?: string | null };
  [key: string]: unknown;
}

export class AxonRpcError extends Error {
  constructor(readonly rpcError: JsonRpcError, readonly method: string) {
    super(`Axon JSON-RPC error ${rpcError.code} from "${method}": ${rpcError.message}`);
    this.name = "AxonRpcError";
  }
}

type PlatformKey = "swift" | "linux" | "windows";
const platformKey = (platform: Health["platform"]): PlatformKey =>
  platform === "macos" ? "swift" : platform;

export class RawAxonClient implements RawClient {
  private nextId = 1;

  constructor(
    readonly transport: Transport,
    readonly platform?: PlatformKey,
    readonly sessionId?: string,
  ) {}

  withSession(sessionId: string): RawAxonClient {
    return new RawAxonClient(this.transport, this.platform, sessionId);
  }

  async request(method: string, params: object = {}): Promise<Record<string, unknown>> {
    const support = availability[method as keyof typeof availability];
    if (support && this.platform && !support[this.platform]) {
      throw new Error(`Axon tool "${method}" is not available on ${this.platform === "swift" ? "macOS" : this.platform}`);
    }
    const tagged: Record<string, unknown> = this.sessionId
      ? { ...params, _session: this.sessionId }
      : { ...params };
    const response = await this.transport.send({
      jsonrpc: "2.0", id: this.nextId++, method, params: tagged,
    });
    if (response.error) throw new AxonRpcError(response.error, method);
    if (!response.result) throw new Error(`Axon response to "${method}" had neither result nor error`);
    return response.result;
  }

  health() { return this.request("health"); }
  shutdown(params: Record<string, unknown> = {}) { return this.request("shutdown", params); }
  debugCreate(params: Record<string, unknown> = {}) { return this.request("debug.create", params); }
  debugStart(params: Record<string, unknown> = {}) { return this.request("debug.start", params); }
  debugStep(params: Record<string, unknown> = {}) { return this.request("debug.step", params); }
  debugRetry(params: Record<string, unknown> = {}) { return this.request("debug.retry", params); }
  debugContinue(params: Record<string, unknown> = {}) { return this.request("debug.continue", params); }
  debugResume(params: Record<string, unknown> = {}) { return this.request("debug.resume", params); }
  debugRunTo(params: Record<string, unknown> = {}) { return this.request("debug.runTo", params); }
  debugSetBreakpoints(params: Record<string, unknown> = {}) { return this.request("debug.setBreakpoints", params); }
  debugStop(params: Record<string, unknown> = {}) { return this.request("debug.stop", params); }

  capture_screen(params: CaptureScreenParams) { return this.request("capture_screen", params); }
  look(params: LookParams) { return this.request("look", params); }
  navigate(params: NavigateParams) { return this.request("navigate", params); }
  windows(params: WindowsParams) { return this.request("windows", params); }
  tabs(params: TabsParams) { return this.request("tabs", params); }
  find(params: FindParams) { return this.request("find", params); }
  wait_for_value(params: WaitForValueParams) { return this.request("wait_for_value", params); }
  wait_for_stability(params: WaitForStabilityParams) { return this.request("wait_for_stability", params); }
  permit(params: PermitParams) { return this.request("permit", params); }
  run(params: RunParams) { return this.request("run", params); }
  save(params: SaveParams) { return this.request("save", params); }
  click(params: ClickParams) { return this.request("click", params); }
  type(params: TypeParams) { return this.request("type", params); }
  keyboard(params: KeyboardParams) { return this.request("keyboard", params as object); }
  scroll(params: ScrollParams) { return this.request("scroll", params); }
  drag(params: DragParams) { return this.request("drag", params); }
  invoke(params: InvokeParams) { return this.request("invoke", params); }
}

export interface ConnectOptions {
  transport?: Transport;
  socketPath?: string;
  warn?: (message: string) => void;
}

export class Axon {
  readonly version: string;
  readonly health: Health;

  protected constructor(readonly raw: RawAxonClient, health: Health) {
    this.health = health;
    this.version = health.version;
  }

  static async connect(options: ConnectOptions = {}): Promise<Axon> {
    const transport = options.transport ?? new SocketTransport({ socketPath: options.socketPath });
    const probe = new RawAxonClient(transport);
    let health: Health;
    try {
      health = await probe.health() as unknown as Health;
    } catch (error) {
      throw new Error("Axon daemon is not running or could not be reached", { cause: error });
    }
    if (!health.daemon?.ready) {
      const detail = health.daemon?.detail ?? health.daemon?.reason;
      throw new Error(`Axon daemon is not ready${detail ? `: ${detail}` : ""}`);
    }
    if (health.version !== schemaProductVersion) {
      (options.warn ?? console.warn)(
        `Axon SDK schema targets ${schemaProductVersion}, but the daemon reports ${health.version}`,
      );
    }
    return new Axon(new RawAxonClient(transport, platformKey(health.platform)), health);
  }

  app(selector: string): App {
    return new App(this.raw, selector);
  }

  session(name: string): Session {
    if (!name) throw new Error("Axon session name must not be empty");
    return new Session(this.raw.withSession(name), name, this.health);
  }
}

type LookOptions = Omit<LookParams, "app" | "since" | "target">;
type ClickOptions = Omit<ClickParams, "target">;
type TypeOptions = Omit<TypeParams, "target" | "value">;
type WaitValueOptions = Omit<WaitForValueParams, "target">;
type WaitStabilityOptions = Omit<WaitForStabilityParams, "app">;
type InvokeOptions = Omit<InvokeParams, "target" | "name">;
type FindOptions = Omit<FindParams, "app" | "locator">;

export class App {
  private snapshotId?: string;
  private pinnedSelector?: string;

  constructor(readonly raw: RawAxonClient, readonly selector: string) {}

  private appSelector(): string { return this.pinnedSelector ?? this.selector; }
  private target(name: string) { return { app: this.appSelector(), name }; }

  async look(options: LookOptions = {}): Promise<Record<string, unknown>> {
    const result = await this.raw.look({ ...options, app: this.appSelector() });
    this.remember(result);
    return result;
  }

  async changedSince(snapshotId = this.snapshotId): Promise<Record<string, unknown>> {
    if (!snapshotId) throw new Error("changedSince requires a snapshot id or a prior app.look()");
    const result = await this.raw.look({ app: this.appSelector(), since: snapshotId });
    this.remember(result);
    return result;
  }

  click(name: string, options: ClickOptions = {}) {
    return this.raw.click({ ...options, target: this.target(name) });
  }
  type(name: string, value: string, options: TypeOptions = {}) {
    return this.raw.type({ ...options, target: this.target(name), value });
  }
  waitForValue(name: string, options: WaitValueOptions = {}) {
    return this.raw.wait_for_value({ ...options, target: this.target(name) });
  }
  waitForStability(options: WaitStabilityOptions = {}) {
    return this.raw.wait_for_stability({ ...options, app: this.appSelector() });
  }
  invoke(name: string, action: string, options: InvokeOptions = {}) {
    return this.raw.invoke({ ...options, target: this.target(name), name: action });
  }
  find(locator: FindParams["locator"], options: FindOptions = {}) {
    return this.raw.find({ ...options, app: this.appSelector(), locator });
  }

  private remember(result: Record<string, unknown>): void {
    const snapshot = result.snapshot ?? result.observation;
    if (!snapshot || typeof snapshot !== "object") return;
    const value = snapshot as Record<string, unknown>;
    if (typeof value.id === "string") this.snapshotId = value.id;
    const app = value.app;
    if (app && typeof app === "object") {
      const pid = (app as Record<string, unknown>).processIdentifier;
      if (typeof pid === "number" && Number.isInteger(pid) && pid > 0) this.pinnedSelector = String(pid);
    }
  }
}

export class Session extends Axon {
  constructor(raw: RawAxonClient, readonly name: string, health: Health) {
    super(raw, health);
  }

  save(params: Omit<SaveParams, "sessionId"> = {}) {
    return this.raw.save({ ...params, sessionId: this.name });
  }
}