# Tool Surface

Axon exposes the same core commands through the daemon JSON-RPC socket, the CLI, and MCP. The CLI and MCP are clients of the daemon command surface; they should not maintain separate accessibility or screenshot implementations. MCP tool names are plain because clients already namespace by server.

## MCP Tools

```text
list_apps(format?)
request_accessibility()
get_app_state(app, screenshot?, screenText?, sensitive?, format?, frames?)
get_children(target, offset?, limit?, format?, frames?)
get_screenshot(app)
resolve(app, locator)
changed_since(snapshotId, sensitive?)
run_batch(actions? | source? | path? | batch?, continueOnError?, dryRun?)
export_script(sessionId?, from?, to?, path?, includeReads?)
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
axon apps [--details]
axon snapshot <app> [--screenshot] [--sensitive] [--frames]
axon snapshot-json <app> [--compact] [--screenshot] [--sensitive]
axon screenshot <app>
axon resolve <app> '<locator-json>'
axon changed-since <snapshot-id>
axon children <handle> [--offset n] [--limit n] [--frames]
axon run <path.axn>|--source '<yaml-or-json>' [--dry-run] [--continue-on-error]
axon export-script [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]
axon click '<handle-or-target-json>'
axon scroll [--app app] [--target '<target-json-or-handle>'] [--dx n] [--dy n]
axon drag [--app app] [--duration-ms n] '<from-json-or-handle>' '<to-json-or-handle>'
axon perform-action <handle> <action>
axon set-value <handle> <value>
axon type-text <app> <text>
axon press-key <app> <key>
```

## App Queries

`list_apps` is compact by default. It returns app names rather than full bundle/pid records:

```text
apps: 3 running, 2 names
- Example (2)
- Example Helper
```

Use `format: debug` in MCP or `axon apps --details` in the CLI when bundle identifiers or process ids are needed.

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
- `screenText`: OCR-recognized visible text when `screenText: true`
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

Observation output is planned around useful leaves, not raw AX traversal order. Axon collapses anonymous wrapper chains, coalesces adjacent static text into parent summaries, omits pointer-like AX debug labels, and pages broad sibling sets such as browser tab lists. The default capture sibling page is 24 children per node.

For apps with sparse AX trees, set `screenText: true` to add an OCR-derived `screenText` list to the app-state observation. This internally captures a screenshot but does not return screenshot image bytes unless `screenshot: true` is also set:

```json
{ "app": "cairn", "screenText": true }
```

Screen text is ordered top-to-bottom, left-to-right, and includes OCR confidence when available. It omits frames by default; set `frames: true` to include the OCR text rectangles.

When a node is truncated, fetch the next slice of that node with `get_children`. This returns only that node's child list, not a whole app snapshot:

```yaml
target: s12:4
offset: 24
limit: 24
```

The result has `items` and `nextOffset`. Call again with `offset: nextOffset` to continue.

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

Sensitive snapshots reject `screenshot: true` and `screenText: true`. Image/OCR redaction is a separate capability; until that exists, screenshots, OCR, and sensitive mode do not overlap.

## Locator Targets

Locator targets are AX-native. Supported fields today:

```yaml
role: AXButton
subrole: AXStandardButton
title:
  contains: Issues
label:
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
    label:
      contains: cairn
```

`title`, `value`, `description`, `identifier`, and `help` match raw AX attributes. `label` matches the same display label Axon shows in observations, trying title, value, description, identifier, then help. Prefer `label` when writing plans from observed output, especially for ancestors.

Ancestor matching is transitive and ordered. This matches a URL bar nested below Firefox's Navigation toolbar even if intermediate groups exist:

```yaml
role: AXComboBox
label:
  contains: example.com
ancestors:
  - role: AXToolbar
    label: Navigation
```

Text matchers can be a string for case-insensitive exact match:

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

Pointer actions (`click`, `scroll`, and `drag`) accept four target shapes:

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

```json
{
  "location": {
    "app": "cairn",
    "text": "Backlog",
    "source": "auto"
  }
}
```

Location targets are point-producing text targets. They let callers say "the visible text Backlog" without providing raw screen coordinates. `source: auto` first tries AX text geometry and falls back to screenshot OCR when AX text is missing. `source: ax` forces AX text geometry. `source: screenshot` captures the app window, recognizes visible text with OCR, and returns the center of the matched text bounding box.

Location text uses the same matcher shape as locators: a string means case-insensitive exact match, and matcher objects may use `exact`, `contains`, and `caseSensitive`.

```yaml
target:
  location:
    app: cairn
    text:
      contains: Back
```

Missing or ambiguous location targets fail before dispatch. Successful action results include `locationResolutions` with the matched text, source, frame, point, and candidates for auditability; callers normally should not feed those coordinates back into later actions.

Point targets are screen coordinates and should be treated as an escape hatch. The current drag follow-up is tracked in `docs/issues/2026-05-12-drag-targeting-and-verification.md`.

AX element actions (`perform_action` and `set_value`) accept only snapshot handles and locator targets because they require an accessibility element, not a screen point.

## Action Semantics

`click` prefers `AXPress` when the element exposes it, then falls back to a CoreGraphics click at the element frame center.

`perform_action` runs a named AX action such as `AXPress` or `AXShowMenu`.

`set_value` sets the AX value for a settable element. Prefer it for writable fields such as URL bars and text fields because it uses AXValue directly and avoids keyboard timing/focus races.

`type_text` and `press_key` activate the app and post keyboard events. Use them when AXValue is not writable or when the workflow specifically needs keystrokes.

`scroll` does not post wheel events. It resolves a scroll surface from the target or app, finds an offscreen descendant in the requested direction, and requests `AXScrollToVisible`. A successful result means the AX action succeeded, not that a specific pixel delta was applied.

Primitive action success means dispatch success, not goal success. Use plan assertions or fresh snapshots around actions whose result matters, especially drag and keyboard-heavy flows.

## Batches

`run_batch` executes a sequence of existing tool calls. Each action uses the same shape as the standalone tool:

```yaml
actions:
  - tool: set_value
    target: s12:19
    value: Mitch
  - tool: click
    target:
      app: cairn
      locator:
        role: AXButton
        label: Save
```

The same schema can be saved as a `.axn` file and run with:

```sh
axon run ./workflow.axn
```

Use batches for simple ordered composition. History/export generates these files from observed calls rather than expecting agents to hand-author scripts from scratch.

## History Export

Axon records recent tool calls in daemon memory. Calls in the same session form a parent chain, so an interaction can be exported later as an editable `.axn` batch.

Export the default session:

```sh
axon export-script --path ./workflow.axn
```

Export over MCP:

```json
{
  "sessionId": "default",
  "from": "c12",
  "to": "c18",
  "path": "/Users/mitch/projects/app/workflow.axn",
  "includeReads": false
}
```

History may include reads such as `get_app_state`, `resolve`, and `get_children`, but export omits read/context calls by default. Use `includeReads: true` or `--include-reads` only when the reads should become part of the replayed script.

## Change Detection

`changed_since(snapshotId)` asks whether the app/window surface changed since a retained snapshot. It uses observer events when available and always compares a fresh coarse app/window signature. It is not a navigation-settled signal; for navigation, prefer waiting on a stable URL/value locator such as an `AXComboBox` value or a page-specific heading.

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
