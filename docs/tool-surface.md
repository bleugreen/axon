# Tool Surface

Axon exposes the same core commands through the CLI, the daemon JSON-RPC socket, and MCP. MCP tool names are plain because clients already namespace by server.

## MCP Tools

```text
list_apps()
request_accessibility()
get_app_state(app, screenshot?, sensitive?, format?, frames?)
get_screenshot(app)
resolve(app, locator)
changed_since(snapshotId, sensitive?)
run_plan(source? | path? | plan?, args?, dryRun?)
click(target)
scroll(target?, app?, deltaX?, deltaY?)
drag(from, to, app?, durationMs?)
perform_action(target, action)
set_value(target, value)
type_text(app, text)
press_key(app, key)
```

## CLI Commands

```sh
axon apps
axon snapshot <app> [--screenshot]
axon snapshot-json <app> [--compact] [--screenshot] [--sensitive]
axon screenshot <app>
axon resolve <app> '<locator-json>'
axon changed-since <snapshot-id>
axon run <path>|--source '<yaml-or-json>' [--dry-run] [--arg key=value]
axon click '<handle-or-target-json>'
axon scroll [--app app] [--target '<target-json-or-handle>'] [--dx n] [--dy n]
axon drag [--app app] [--duration-ms n] '<from-json-or-handle>' '<to-json-or-handle>'
axon perform-action <handle> <action>
axon set-value <handle> <value>
axon type-text <app> <text>
axon press-key <app> <key>
```

## App Queries

`app` can be a bundle id, pid, exact app name, or partial app name.

Examples:

```text
com.cairn.desktop.dev
85900
cairn
System Settings
```

Prefer bundle id when available. Partial names are convenient but can become ambiguous.

## Snapshots and Handles

`get_app_state` captures an app snapshot and returns an agent-facing observation by default:

- `format: observation`
- `snapshot`: short snapshot id
- `app`, `pid`, and `bundle` when available
- `tree`: compact visible AX tree with short handles
- `screenshot`: screenshot metadata when `screenshot: true`
- `redaction`: sensitive-mode metadata when `sensitive: true`

MCP defaults are tree-first and screenshot-free:

```yaml
app: cairn
screenshot: false
```

Each tree node has a snapshot-scoped handle:

```text
s12:19
```

Handles are convenient within a short observe/action loop, but they are not durable identity. Use locators in reusable plans. Legacy prefixed handles are not supported.

Observation output omits frame rectangles by default. Set `frames: true` only when coordinates matter. Set `format: debug` only when diagnosing Axon internals; debug output returns the raw snapshot JSON with `indexedNodes` and accepts `includeTree`.

## Screenshots

Screenshots are opt-in. In MCP responses, Axon moves PNG bytes into MCP image content blocks and redacts `base64Data` from structured JSON. Structured screenshot fields still include width, height, media type, and `contentTransport: "mcp_image"`.

Use:

```json
{ "app": "cairn", "screenshot": true }
```

or:

```text
get_screenshot(app)
```

## Sensitive Reads

Sensitive reads are opt-in and text-only:

```json
{ "app": "cairn", "sensitive": true }
```

When `sensitive: true`, Axon redacts AX `value` fields and secret-like text before returning JSON. Redaction preserves a short prefix, such as `sk-proj-abcd...[redacted]`, so the agent can distinguish nearby controls without receiving the full generated key or token. Node-level `redaction` metadata lists the fields that were changed.

Sensitive snapshots reject `screenshot: true`. Image/OCR redaction is a separate capability; until that exists, screenshots and sensitive mode do not overlap.

## Locator Targets

Locator targets are AX-native. Supported fields today:

```yaml
role: AXButton
subrole: AXStandardButton
title:
  contains: Issues
value:
  exact: Draft
description:
  contains: issue
identifier: new-issue-button
actions:
  - AXPress
ancestors:
  - role: AXWindow
    title:
      contains: cairn
```

Text fields can be a string for case-insensitive exact match:

```yaml
title: Issues
```

or an object:

```yaml
title:
  contains: Issue
  caseSensitive: true
```

`resolve` returns `unique`, `ambiguous`, or `missing` with candidate summaries. Actions that receive locator targets resolve against a fresh snapshot before dispatching.

## Target Shapes

Primitive actions accept three target shapes:

```json
"s12:19"
```

```json
{
  "app": "cairn",
  "locator": {
    "role": "AXButton",
    "title": { "contains": "Issues" },
    "actions": ["AXPress"]
  }
}
```

```json
{
  "point": { "x": 320, "y": 240 }
}
```

Point targets are screen coordinates and should be treated as an escape hatch. The current drag follow-up is tracked in `docs/issues/2026-05-12-drag-targeting-and-verification.md`.

## Action Semantics

`click` prefers `AXPress` when the element exposes it, then falls back to a CoreGraphics click at the element frame center.

`perform_action` runs a named AX action such as `AXPress` or `AXShowMenu`.

`set_value` sets the AX value for a settable element.

`type_text` and `press_key` activate the app and post keyboard events.

`scroll` does not post wheel events. It resolves a scroll surface from the target or app, finds an offscreen descendant in the requested direction, and requests `AXScrollToVisible`. A successful result means the AX action succeeded, not that a specific pixel delta was applied.

`drag` currently posts pointer events between resolved points. It reports dispatch success, not semantic success. Use plan assertions or fresh snapshots around drag until visual target resolution and postconditions are implemented.

## Change Detection

`changed_since(snapshotId)` asks whether the app/window surface changed since a retained snapshot. It uses observer events when available and always compares a fresh coarse app/window signature.

Focus-only interaction should not count as a meaningful layout change unless the app/window signature changes.

## Visual Target Badges

`Axon.app` displays target badges for actions so a user can see what the agent is operating on.

Defaults:

- planned target flash: 250 ms
- result linger: 1100 ms

Environment overrides are read by the service process:

```sh
AXON_VISUAL_OVERLAY=0
AXON_VISUAL_OVERLAY_PLANNED_MS=400
AXON_VISUAL_OVERLAY_RESULT_MS=1500
```
