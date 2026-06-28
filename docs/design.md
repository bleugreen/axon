# Axon Design

## Purpose

Axon is a background macOS service for local UI automation. It should let an agent inspect and operate arbitrary apps through the Accessibility API without binding workflows to fragile screen coordinates or transient tree indexes.

The immediate target is an MCP-facing service with primitives similar to Computer Use:

- list running apps
- capture app/window state
- resolve element locators
- click, set values, type, scroll, drag, and perform accessibility actions
- verify UI state after actions
- record sequences of actions as replayable `.axn` files

## Design Principles

1. Prefer semantic locators over raw coordinates.
2. Treat snapshot indexes as temporary handles, not durable identity.
3. Make ambiguity explicit instead of silently choosing the wrong element.
4. Use Accessibility actions first and input-event fallback second.
5. Preserve a small, stable core that can support app-specific higher-level tools later.
6. Keep safety policy above the action layer, so destructive or externally visible workflows can be gated consistently.

## Architecture

```text
MCP client / local agent
  -> Axon MCP facade
    -> command router
      -> app registry
      -> snapshot engine
      -> locator resolver
      -> action executor
      -> observer/event stream
        -> macOS Accessibility + CoreGraphics events
```

### Background Service

Axon should run as a local background service from the start, installed through a user LaunchAgent. Persistent service state matters because Axon should be able to observe UI changes between requests, invalidate stale snapshots, and eventually report that the user changed something since the last agent observation.

The service needs Accessibility permission and should fail loudly when permission is missing.

The preferred transport is JSON-RPC over a local Unix domain socket owned by the daemon. MCP can be exposed by the same binary in a facade mode if stdio compatibility is needed:

```text
MCP client -> `axon mcp` stdio facade -> local socket -> `axon serve` daemon
```

This keeps the install surface to one binary while allowing the observer/cache layer to stay alive independently of any single MCP session.

### Snapshot Engine

The snapshot engine captures the active state for a target app or window:

- app identity: bundle id, localized name, pid
- window identity: title, role, subrole, frame, focus/main status
- accessibility tree: roles, labels, values, descriptions, help text, actions, frames, children
- embedded screenshot data for coordinate fallback, visual debugging, and human inspection

Every snapshot receives an opaque id. Tree indexes are scoped to that snapshot only.

Example handle:

```text
01HZAXON:19
```

That handle is valid only while the referenced snapshot is still retained.

### Locator Resolver

Durable operation should be based on locators, not indexes.

Locators should be AX-native and honest about macOS semantics. They can borrow useful ideas from browser automation, but they should not imitate Playwright where the mapping is misleading.

```json
{
  "role": "AXButton",
  "title": { "contains": "Profile concurrent batch exploration" },
  "actions": ["AXPress"],
  "ancestors": [
    { "role": "AXWindow", "title": { "contains": "cairn" } },
    { "role": "AXScrollArea" }
  ],
  "geometryHint": {
    "xPct": 0.42,
    "yPct": 0.31,
    "wPct": 0.28,
    "hPct": 0.04
  }
}
```

Resolution should score candidates using multiple signals:

1. app and window scope
2. AX identifier, role, subrole, title/name, description, value, placeholder, help text
3. supported actions
4. nearby labels and section context
5. ancestry and sibling structure
6. normalized geometry as a tie-breaker

Role, subrole, title, label, description, identifier, non-editable value, and
ancestor requirements are hard filters. Supported actions and editable text
values are replay signals: they explain and score a candidate when present, but
they do not make an otherwise stable editable text target disappear just because
the current field value or host-reported action list changed.

The resolver should return one of:

- `unique`: one high-confidence match
- `ambiguous`: multiple plausible matches with explanations
- `missing`: no reasonable match, optionally with recovery hints

The implemented locator subset is intentionally AX-native:

```json
{
  "role": "AXButton",
  "subrole": "AXStandardButton",
  "title": { "exact": "NEW" },
  "value": { "contains": "draft" },
  "description": { "contains": "Issue" },
  "identifier": "new-issue-button",
  "actions": ["AXPress"],
  "ancestors": [
    { "role": "AXWindow", "title": { "contains": "cairn" } }
  ]
}
```

Text fields accept either a string, which means exact case-insensitive match, or `{ "exact": "..." }` / `{ "contains": "..." }` with optional `"caseSensitive": true`. Geometry and nearby-text signals remain future scoring inputs, not hidden behavior.

### Action Executor

The action executor accepts either a snapshot handle or a locator.

For handles, it should verify the snapshot is current enough and the element still exists. For locators, it should resolve against a fresh tree before acting.

Action preference order:

1. native AX action such as `AXPress`, `AXShowMenu`, or settable value
2. keyboard input where the focused element is known
3. CoreGraphics click/drag fallback using current frame; AX-native scroll via `AXScrollToVisible`

After each action, Axon should support explicit verification by re-capturing state and checking a locator, predicate, or expected UI change.

### Observer Layer

Axon should use `AXObserver` where practical to track:

- focused window changes
- focused element changes
- value changes
- created/destroyed windows
- title changes

Observers should invalidate stale handles and reduce polling, but the service must still work with direct snapshots when observer coverage is incomplete.

Observer state should also support a "changed since snapshot" query. The initial version can be coarse-grained at the app/window level, then grow toward element-level invalidation as the model proves out.

### Public MCP Surface

Initial tools:

```text
look(target?, since?, screenshot?, screenText?, tree?, offset?, limit?, depth?, all?)
find(app, locator)
permit()
run(actions?, path?)
save(sessionId?, from?, to?, path?, includeReads?)
click(target)
type(target, value)
keyboard(keys, app?)
scroll(target?, app?, deltaX?, deltaY?)
drag(from, to, app?, durationMs?)
invoke(target, name)
```

Where `target` can be:

```text
s12:19
```

a locator object, or a point object such as `{ "point": { "x": 320, "y": 240 } }`.

Tool names should stay plain. MCP clients already namespace tools by server, so Axon exposes `click`, not `axon_click` or `axon_mcp_click`.

Screenshot-returning tools should embed image data in their response. File output can exist as a CLI/debug convenience later, but clients should not need filesystem coordination to inspect the visual state.

### Action Batches and `.axn` Files

`run` is an invocation-scoped composition layer. A batch is an ordered list of tool calls — each action is just `tool:` plus that tool's normal arguments. There is no separate plan language to learn, and no separate semantics for batched actions vs. standalone calls.

`.axn` files (axon // action) are batches saved to disk. They are the project's primary persisted artifact: a recorded sequence of past tool calls that can be replayed, edited, and shared. `save` generates them from observed sessions rather than expecting agents to hand-author scripts. The file shape mirrors `run` exactly, so `axon run path.axn` and an inline batch are interchangeable.

The daemon executes a submitted batch, traces it, and forgets it. It does not own a recipe registry or persistent script cache. Reusable `.axn` files live wherever the user or repo wants them.

YAML is the preferred on-disk format because it is compact and human-editable. JSON-RPC remains the daemon transport, and structured JSON batch objects remain acceptable when a caller already has data in memory.

Failures are part of the batch trace, not MCP transport failures. A failed batch stops at the first failing action unless `continueOnError: true`, preserves completed trace entries, and returns `success: false` with the failing action's index, tool, and error. Locator failures preserve the resolution status, snapshot id, candidate count, and candidate summaries so an agent can repair the batch without another broad state read.

Higher-order control flow (conditionals, polling waits, repeat loops, assertions, output binding) is intentionally not part of the batch surface. If those primitives prove necessary, they should be added to the underlying tool set so that batches remain a flat sequence of normal tool calls.

### Technology Direction

The implementation path is Swift first:

- direct access to Accessibility and CoreGraphics APIs
- good fit for a long-running macOS service
- simpler permission and app lifecycle integration than Python

The default implementation uses `ApplicationServices` directly. Direct `ApplicationServices` is more verbose than AXSwift, but the extra work is bounded: the hardest parts are still tree modeling, locator resolution, daemon lifecycle, screenshots, and action verification.

AXSwift remains a useful reference and possible spike input, but the core API should not depend on wrapper-specific concepts.

## Non-Goals For The First Version

- visual computer vision recognition
- cloud sync
- multi-user remote control
- app-specific workflow packs
- recently used app tracking beyond currently running apps
- guaranteed stable identity for every arbitrary UI element
- bypassing macOS security prompts or app sandboxing

## Risks

- many apps expose weak or inconsistent accessibility metadata
- WebView accessibility quality varies by framework and app implementation
- AX permissions and TCC behavior can make setup confusing
- locator scoring can become opaque if not designed with explanations from the start
- multiple clients may need shared service state sooner than expected
