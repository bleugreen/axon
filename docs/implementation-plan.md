# Axon Implementation Plan

## Phase 0: Project Foundation

- Create a Swift package with a small CLI entrypoint.
- Add formatting, linting, and a basic test target.
- Add a permission check that reports whether Accessibility access is available.
- Establish one binary with daemon and client modes.
- Add a LaunchAgent-friendly `axon serve` mode.
- Add a JSON-RPC local Unix domain socket transport between client commands and the daemon.

Exit criteria:

- `axon doctor` reports Accessibility permission status.
- `axon serve` can start locally and answer a health check.
- The package builds and tests run locally.

## Phase 1: Accessibility Tree Capture

- Resolve apps by bundle id, app name, and pid.
- Read front/main windows for a target app.
- Recursively serialize accessibility nodes.
- Include role, subrole, title/name, value, description, help, actions, frame, enabled/focused state, and child indexes.
- Return a stable snapshot id plus transient per-snapshot element indexes.
- Capture embedded screenshots with snapshots.

Exit criteria:

- `axon snapshot com.apple.finder` prints a useful tree.
- `axon snapshot com.cairn.desktop.dev` can see Tauri/WebView controls.
- `axon screenshot com.cairn.desktop.dev` returns usable embedded image data.
- Snapshot handles are scoped and invalidated intentionally.

## Phase 2: Primitive Actions

- Implement click by snapshot handle using `AXPress` when available.
- Implement `perform_action` for arbitrary exposed AX actions.
- Implement `set_value` for settable elements.
- Implement keyboard text and key-combination input.
- Add CoreGraphics click fallback using element frame centers.

Exit criteria:

- Can click buttons and set simple fields in native apps.
- Can operate exposed controls in a WebView app.
- Each action returns enough detail to verify what happened.

## Phase 3: Locator Model

- Define locator JSON schema.
- Implement candidate matching for role, subrole, title, value, description, identifier, actions, and ancestry.
- Return `unique`, `ambiguous`, or `missing` with candidate explanations.
- Allow all primitive actions to accept either a snapshot handle or locator.
- Keep nearby text and geometry hints explicit future scoring signals until they can be implemented honestly.

Exit criteria:

- A locator can reliably re-find a known button after a fresh snapshot.
- Ambiguous matches return useful candidate details instead of acting.

## Phase 4: MCP Facade

- Expose the core operations as MCP tools.
- Keep transport types separate from core AX model types.
- Implement the MCP facade as a stdio mode of the same `axon` binary.
- Return successful tool data as `structuredContent` plus a JSON text content block.
- Report command execution errors as MCP tool errors with structured error content.
- Keep tool names plain because MCP clients already namespace tools by server.

Exit criteria:

- A local MCP client can call `get_app_state`, `resolve`, and `click`.
- The tool surface is small and matches the design document.

## Phase 5: Observer And Service Mode

- Use `AXObserver` for focus, window, title, and value changes.
- Maintain app/window caches with explicit invalidation.
- Add coarse `changed_since(snapshotId)` support for app/window changes.
- Add `axon daemon install`, `axon daemon start`, `axon daemon stop`, `axon daemon status`, and `axon daemon uninstall`.
- Make `axon mcp` a socket-backed facade so the daemon owns snapshots, retained handles, observer state, and overlay configuration.

Exit criteria:

- Axon can run in the background and serve repeated requests.
- Stale snapshots are detected rather than reused silently.
- A client can tell that an app/window changed since a prior snapshot.

## Phase 6: Safety And Workflow Layer

- Add optional policy hooks above primitive actions.
- Add action metadata for risky operations: delete, upload, send, purchase, permission changes.
- Support invocation-scoped automation plans accepted by the daemon as direct source, structured objects, or file paths.
- Keep plans ephemeral: the daemon executes a submitted plan, traces it, and does not own a recipe registry or cache.
- Prefer compact YAML source for agent-authored plans while keeping JSON-RPC as the daemon transport.
- Include basic control flow: conditionals, polling waits, repeat loops with limits, assertions, argument substitution, and dry-run tracing.

Exit criteria:

- The primitive action layer remains simple.
- Multi-step action sequences can compose existing primitives without introducing a second action system.
- Safety gates can be enforced by consumers without rewriting the AX core.

## Test Strategy

- Unit tests for locator scoring and ambiguity behavior using saved synthetic trees.
- Integration tests against excellent local fixture apps that keep the surface simple while covering meaningful AX behavior.
- Manual smoke tests against Finder, System Settings, Safari/Chrome, and Cairn.
- Regression snapshots for representative native and WebView trees.
- Screenshot capture tests that verify dimensions and non-empty image output.
