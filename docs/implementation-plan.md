# Axon Implementation Plan

## Phase 0: Project Foundation

- Create a Swift package with a small CLI entrypoint.
- Add formatting, linting, and a basic test target.
- Add a permission check that reports whether Accessibility access is available.
- Decide whether the first transport is MCP over stdio or a local daemon socket.

Exit criteria:

- `axon doctor` reports Accessibility permission status.
- The package builds and tests run locally.

## Phase 1: Accessibility Tree Capture

- Resolve apps by bundle id, app name, and pid.
- Read front/main windows for a target app.
- Recursively serialize accessibility nodes.
- Include role, subrole, title/name, value, description, help, actions, frame, enabled/focused state, and child indexes.
- Return a stable snapshot id plus transient per-snapshot element indexes.

Exit criteria:

- `axon snapshot com.apple.finder` prints a useful tree.
- `axon snapshot com.cairn.desktop.dev` can see Tauri/WebView controls.
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
- Implement candidate scoring for role, name, actions, ancestry, nearby text, and geometry hints.
- Return `unique`, `ambiguous`, or `missing` with confidence and candidate explanations.
- Allow all primitive actions to accept either a snapshot handle or locator.

Exit criteria:

- A locator can reliably re-find a known button after a fresh snapshot.
- Ambiguous matches return useful candidate details instead of acting.

## Phase 4: MCP Facade

- Expose the core operations as MCP tools.
- Keep transport types separate from core AX model types.
- Add structured errors for missing app, missing permissions, ambiguous locator, stale handle, unsupported action, and failed fallback.

Exit criteria:

- A local MCP client can call `get_app_state`, `resolve`, and `click`.
- The tool surface is small and matches the design document.

## Phase 5: Observer And Service Mode

- Add a LaunchAgent-friendly service mode.
- Use `AXObserver` for focus, window, title, and value changes.
- Maintain app/window caches with explicit invalidation.
- Add `axon install-service`, `axon start`, `axon stop`, and `axon status` if they prove useful.

Exit criteria:

- Axon can run in the background and serve repeated requests.
- Stale snapshots are detected rather than reused silently.

## Phase 6: Safety And Workflow Layer

- Add optional policy hooks above primitive actions.
- Add action metadata for risky operations: delete, upload, send, purchase, permission changes.
- Support composable workflows as client-side procedures or higher-level MCP tools.

Exit criteria:

- The primitive action layer remains simple.
- Safety gates can be enforced by consumers without rewriting the AX core.

## Test Strategy

- Unit tests for locator scoring and ambiguity behavior using saved synthetic trees.
- Integration tests against simple local fixture apps where AX metadata is controlled.
- Manual smoke tests against Finder, System Settings, Safari/Chrome, and Cairn.
- Regression snapshots for representative native and WebView trees.

