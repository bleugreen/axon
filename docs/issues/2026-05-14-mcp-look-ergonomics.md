# MCP Look Ergonomics

Status: Design. Not yet implemented.

## Context

Poking around Firefox via the MCP `look` tool surfaced three friction points that share a root cause: `look` was designed to faithfully serialize whatever the AX traversal captured at whatever depth was requested, rather than to *produce a good observation*. For a tool whose entire value is feeding a model or a human a usable picture of the world, faithful-but-noisy is the wrong shape. Specific observations:

### 1. Depth/observation limits are naive and misleading

Repro:

```
look(target: "Firefox", depth: 2)
  → Navigation toolbar at s16:3 has no children visible

look(target: "s16:3")
  → handle children API returns { total: 0, items: [] }

look(target: "Firefox", depth: 4)
  → same Navigation toolbar (s17:31) has 14 fully-labeled children
```

The depth-2 traversal stopped at the toolbar and stored a pruned representation. A subsequent handle-based look reports `total: 0` not because the toolbar is empty but because the depth-truncated snapshot has nothing left to paginate against. There is no marker on the toolbar saying *"children were truncated at depth N"*; the caller is left to discover by re-looking with greater depth that the toolbar actually has fourteen children.

This is a misapplication of depth as both a *capture* parameter and a *display* parameter. The capture should adapt to what's actually in the tree (web content with 142 tabs gets paginated; a Navigation toolbar with 14 buttons doesn't); the display should always make truncation visible. The current uniform ceiling is naive and obfuscating — it hides structure that downstream tools need.

### 2. App list is unfiltered process noise

`look()` with no target returned 173 unique app names across 302 process entries, including every renderer helper, dock extra, theme widget service, autofill helper, file panel service, and quicklook generator. The record picker already presents a curated "visible apps" list — apps that have windows on screen, registered as regular foreground applications. The MCP surface should reuse that filter; the raw process-table dump is hostile to any agent trying to ask "what is the user actually looking at?"

### 3. JSON output is cruft-laden compared to the CLI's YAML

Per-element JSON:

```json
{
  "role": "button",
  "handle": "s17:60",
  "actions": ["click"]
}
```

The CLI's YAML carrying the same data is already shorter, and a small DSL would be tighter still:

```
s17:60: button [click]
```

Multiplied by hundreds of elements, the savings are real — both in context bytes and in human/model legibility. The CLI is already YAML and reads better; MCP should match.

A proposed shape: the daemon renders the tree as a single DSL string. A structured envelope (snapshot id, app, bundle, errors, truncation markers) still wraps the tree for MCP's JSON-shaped wire format, but the *tree itself* is the same DSL whether the consumer is MCP or the CLI. CLI YAML, MCP JSON-per-node, and any other parallel tree renderers are deleted in the same change — there is one format. Indentation indicates nesting, role and handle lead each line, attributes follow:

```
s17:0: window "AggFlow Quarry"
  s17:1: group "AggFlow Quarry"
    s17:2: toolbar "Browser tabs"
      s17:3: checkbox "0" [click]
      s17:4: tabgroup ⟨truncated: 142 children, paged⟩
      s17:29: button "New Tab" [click]
    s17:31: toolbar "Navigation"
      s17:32: button "Sidebars" [click]
      ...
```

Truncation becomes a first-class visible marker (`⟨truncated: …⟩`) rather than silent absence.

## Desired Shape

Three changes, each independently shippable:

1. **Adaptive observation, visible truncation.** Replace the flat `depth` cap with role-aware traversal rules and explicit truncation markers on every parent whose children were pruned. Handle-targeted look should fetch live (re-walk the subtree), not replay a previously-pruned snapshot.

2. **Visible-apps default for the no-target app list.** Reuse the existing record-picker filter. Raw process-table output stays available behind a `format: debug` or `all: true` flag for diagnostics.

3. **DSL-formatted tree everywhere.** The daemon's single tree renderer emits DSL; both CLI and MCP consume that one renderer. CLI's existing YAML tree serializer and MCP's existing JSON-per-node serializer are removed in the same change.

## Open Questions

- **DSL grammar.** Handle-first vs role-first per line, where labels/frames/values live, how to represent parameterized actions vs plain click actions, whether to embed handle pagination cursors inline or in the envelope. Worth one short doc once we start building.
- **What "visible apps" actually means.** The record picker presumably uses `NSApplicationActivationPolicyRegular` plus a windows-on-screen check. Verify that filter actually exists and is the right one before claiming reuse.

## Non-Goals

- **No model inference for relevance.** A traversal heuristic ("this subtree is probably interesting") is fine; a classifier deciding what's worth showing is not.
- **No DSL extension to the read-only tools beyond `look`.** `find` already returns a single resolved locator + candidates; that's small enough that JSON is fine.
- **No tree-rewriting for "cleaner" output.** The DSL is a *rendering* of the AX tree, not an opinionated selection — every node the daemon captured appears in output, just more densely.

## Next Steps

- Trace the depth/limit application path through `SnapshotJSON`/`AXSnapshotCapturer` and identify where the toolbar's children were dropped at depth-2 capture vs where the depth-4 walk reaches them. The fix likely lives at capture time, not at serialization.
- Find the record-picker visible-apps filter and wire it into the no-target `look` path.
- Sketch the DSL grammar against a real Firefox snapshot, iterate until it parses cleanly from a paste, then implement a single `SnapshotRenderer` shared by CLI and MCP. Remove the existing CLI YAML and MCP per-node JSON serializers in the same change — they don't survive alongside the DSL.
