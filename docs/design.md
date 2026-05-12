# Axon Design

## Purpose

Axon is a background macOS service for local UI automation. It should let an agent inspect and operate arbitrary apps through the Accessibility API without binding workflows to fragile screen coordinates or transient tree indexes.

The immediate target is an MCP-facing service with primitives similar to Computer Use:

- list running and recently used apps
- capture app/window state
- resolve element locators
- click, set values, type, scroll, drag, and perform accessibility actions
- verify UI state after actions

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

Axon should run as a local background service, likely installed through a user LaunchAgent. It needs Accessibility permission and should fail loudly when permission is missing.

The service should support at least one local transport for MCP clients. Stdio is the easiest first target for MCP integration. A local HTTP or Unix socket transport can come later if multiple clients need to share one long-lived daemon.

### Snapshot Engine

The snapshot engine captures the active state for a target app or window:

- app identity: bundle id, localized name, pid
- window identity: title, role, subrole, frame, focus/main status
- accessibility tree: roles, labels, values, descriptions, help text, actions, frames, children
- optional screenshot metadata for coordinate fallback and visual debugging

Every snapshot receives an opaque id. Tree indexes are scoped to that snapshot only.

Example handle:

```text
snapshot:01HZAXON:19
```

That handle is valid only while the referenced snapshot is still retained.

### Locator Resolver

Durable operation should be based on locators, not indexes.

```json
{
  "app": { "bundleId": "com.cairn.desktop.dev" },
  "window": { "title": "cairn-dev" },
  "role": "AXButton",
  "name": { "contains": "Profile concurrent batch exploration" },
  "actions": ["AXPress"],
  "context": {
    "nearText": "ACTIVE  (1)",
    "ancestorRoles": ["AXWindow", "AXScrollArea", "AXGroup"]
  },
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

The resolver should return one of:

- `unique`: one high-confidence match
- `ambiguous`: multiple plausible matches with explanations
- `missing`: no reasonable match, optionally with recovery hints

### Action Executor

The action executor accepts either a snapshot handle or a locator.

For handles, it should verify the snapshot is current enough and the element still exists. For locators, it should resolve against a fresh tree before acting.

Action preference order:

1. native AX action such as `AXPress`, `AXShowMenu`, or settable value
2. keyboard input where the focused element is known
3. CoreGraphics click/drag/scroll fallback using current frame

After each action, Axon should support explicit verification by re-capturing state and checking a locator, predicate, or expected UI change.

### Observer Layer

Axon should use `AXObserver` where practical to track:

- focused window changes
- focused element changes
- value changes
- created/destroyed windows
- title changes

Observers should invalidate stale handles and reduce polling, but the service must still work with direct snapshots when observer coverage is incomplete.

### Public MCP Surface

Initial tools:

```text
list_apps()
get_app_state(app)
resolve(locator)
click(target)
set_value(target, value)
perform_action(target, action)
type_text(app, text)
press_key(app, key)
scroll(target, direction, pages)
drag(app, from, to)
```

Where `target` can be either:

```text
snapshot:<snapshot-id>:<index>
```

or a locator object.

### Technology Direction

The likely implementation path is Swift first:

- direct access to Accessibility and CoreGraphics APIs
- good fit for a long-running macOS service
- simpler permission and app lifecycle integration than Python

AXSwift is worth evaluating as a bootstrap wrapper, but the core API should not depend on wrapper-specific concepts. If AXSwift leaks too much or is under-maintained, Axon can use `ApplicationServices` directly.

## Non-Goals For The First Version

- visual computer vision recognition
- cloud sync
- multi-user remote control
- app-specific workflow packs
- guaranteed stable identity for every arbitrary UI element
- bypassing macOS security prompts or app sandboxing

## Risks

- many apps expose weak or inconsistent accessibility metadata
- WebView accessibility quality varies by framework and app implementation
- AX permissions and TCC behavior can make setup confusing
- locator scoring can become opaque if not designed with explanations from the start
- multiple clients may need shared service state sooner than expected

