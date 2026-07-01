# Really Good Live AX Inspector Sidebar

Status: Open. Filed 2026-05-17. Reconfirmed 2026-05-22.

## 2026-05-22 Conceptual Maintenance Note

This issue remains open. The current editor sidebar is named like a live AX
tree, but `Sources/AxonEditorApp/Editor/AXTreeInspector.swift` still reads
through `SocketClient` calls to `look` for the primary tree and `find` for
acted-on target cues. That means the shipped sidebar is a snapshot-backed
inspection client, not the direct editor-owned AX instrument specified here.

The corrected contract below is still the desired shape: keep compact
`look`/snapshot behavior for CLI, MCP, replay, and locator resolution, and build
a separate inspector session when the editor needs a full live AX surface.

## Context

The editor needs a debugger sidebar that can explain what the automated app actually exposes through macOS Accessibility. The current AX Tree layer is not that. It reuses `look` / retained snapshot plumbing that was intentionally built for compact agent observations, so it inherits the wrong defaults: shallow roots, sibling budgets, handles, and "truncated" language. That is a reasonable design for `look`; it is the wrong design for an inspector.

This inspector must be a direct AX surface. It should read from the target app's live `AXUIElement` graph, keep live element references in the editor process, and render the full tree the app exposes. The compact snapshot/capture path remains unchanged and continues serving CLI/MCP observation and replay resolution.

## Research Notes

- Apple exposes app accessibility objects through `AXUIElementCreateApplication(pid)` and child-like arrays through attributes read by `AXUIElementCopyAttributeValue` / `AXUIElementCopyAttributeValues`. `AXUIElementCopyAttributeValues` pages array attributes by index/count, which is useful for reading a direct child array without imposing an inspector-level sibling budget.
- AppKit's `NSAccessibility` model is tree-shaped from the assistive-technology point of view: elements expose children, frames, roles, values, actions, and related metadata. The inspector should present that tree, not Axon's compact observation summary.
- Axon's existing performance note in [Locator Replay Speed](2026-05-14-locator-replay-speed.md) is load-bearing: full traversal can be expensive because every attribute is a cross-process AX call. That argues for cancellation/progress/streaming in the inspector, not for silently truncating it.
- The same note documents Firefox/Safari support for `AXUIElementsForSearchPredicate` under web scopes. Predicate search is useful as a supplementary search/discovery mechanism, but it is not a replacement for the full tree view.

References:

- Apple Developer Documentation: [`AXUIElementCopyAttributeValues`](https://developer.apple.com/documentation/applicationservices/1462060-axuielementcopyattributevalues?language=objc)
- Apple Developer Documentation: [`NSAccessibilityProtocol`](https://developer.apple.com/documentation/AppKit/NSAccessibilityProtocol)
- Local issue: [Locator Replay Speed](2026-05-14-locator-replay-speed.md)

## Product Intent

The sidebar should feel like an instrument panel for understanding and repairing automation, not a diagnostic dump. It answers four questions quickly:

1. What does the target app expose right now?
2. Where is the node my recipe just acted on?
3. What replayable locator or direct action target can callers derive from this node?
4. What locator or repair should I make from here?

The tree should be dense, navigable, and inspectable. Rows should be small and stable. Details should be rich but secondary. Hovering or selecting a node should draw a frame over the target app. Search should expand to matching nodes. During debug playback, the sidebar should jump to the acted-on node.

## Non-Negotiables

- **No snapshot capture.** The inspector must not call `look`, `CommandRouter`, `MCPRouter`, `AXSnapshotCapturer`, `SnapshotObservationFormatter`, or retained snapshot handle paging for its primary tree.
- **No silent truncation.** If a node exposes 600 direct children, the inspector's model knows there are 600 direct children. The UI may virtualize rows for rendering, but the data layer must not pretend only 24 exist.
- **Direct AX data.** Nodes are backed by live `AXUIElement` references held in an editor-side session. Rows and details are derived from live AX attributes.
- **Full tree means full exposed AX tree.** "Full" is bounded only by what the target app's AX server exposes and by explicit user-visible cancellation/error states. It does not mean DOM scraping, OCR, or hidden browser internals.
- **Existing slim capture remains untouched.** Compact `look` behavior stays optimized for agent context. Replay locator speed work stays separate. The inspector gets a different reader because it has a different job.

## Architecture

### `LiveAXInspectorSession`

Create an editor-owned session object, likely in `Sources/AxonApp/Editor` or a clearly separate `AxonCore` module namespace such as `LiveAXInspector`, not inside snapshot capture.

Responsibilities:

- Resolve the target app by recipe `primaryAppName` through `AppResolver`.
- Create the app root with `AXUIElementCreateApplication`.
- Own a per-refresh in-memory registry: `InspectorNodeID -> AXUIElement`.
- Traverse the AX graph on a background task.
- Stream node batches or publish incremental state to the SwiftUI view model.
- Cancel immediately when the target app, recipe document, or sidebar layer changes.

The session does not serialize handles for external callers. Its IDs are editor-local and expire on refresh.

### `LiveAXNode`

The tree model should be deliberately inspector-oriented:

- `id`: stable within refresh, preferably path-derived plus a monotonic sequence to handle duplicate references.
- `path`: index path from root for expansion/jump.
- `attributeSource`: which child-bearing attribute produced the edge, usually `AXChildren`, but not limited to it.
- `role`, `subrole`, `title`, `value`, `description`, `help`, `identifier`.
- `frame`, `enabled`, `focused`.
- `actions`.
- `parameterizedAttributeNames`.
- `childGroups`: groups of direct child arrays discovered from AX attributes.
- `attributeErrors`: per-attribute errors, visible in details without poisoning the whole tree.

Rows show the readable summary. Details show the raw-ish data.

### Child Discovery

Do not hard-code the tree to `kAXChildrenAttribute` only. The reader should:

1. Read `AXUIElementCopyAttributeNames` for each node.
2. Prefer known structural attributes first: `AXChildren`, then useful alternates such as visible/contents-oriented child attributes when advertised by the host.
3. For each candidate attribute, read the value.
4. If the value is `[AXUIElement]`, treat it as a direct child group.
5. If the value is a single `AXUIElement` and it is structurally useful, expose it as a related node in details, not necessarily in the main tree.

This is still direct AX data. It also avoids assuming every host funnels web content through the one attribute Axon's compact capture currently reads.

### Traversal

Default traversal should be full and recursive:

- Start at an app root group with sections for application, windows, focused window/element, and menu bar when available.
- Traverse windows and descendants depth-first or breadth-first.
- Read all direct children for each child-bearing attribute.
- Avoid cycles by tracking a lightweight element identity set per path. When identity is uncertain, allow duplicate paths but mark repeated references.
- Keep per-node AX messaging timeouts short enough to avoid freezing, but surface timeout/error badges on nodes.
- Stream progress: "3,421 nodes read" is better than a spinner with no explanation.

This is not a "deep snapshot". It is a live AX walk with direct child reads at each node.

### Search Predicate Supplement

`AXUIElementsForSearchPredicate` belongs as a supplemental search accelerator:

- If a selected or searched scope advertises the parameterized attribute, expose a "host search" result lane.
- Returned elements should be inserted into a "Search Results" section with their ancestor path if the parent chain can be reconstructed.
- If they cannot be attached to the visible tree, show them as live result nodes with a clear source label.

This helps Firefox/Safari web content without pretending predicate results are the tree itself.

## Sidebar Surface

### Header

Compact, always stable:

- Target app name.
- Refresh button.
- Follow Debug toggle.
- Search field.
- Small progress/error indicator.

No explanatory prose in the app.

### Tree

Rows should be compact and scan-friendly:

- Disclosure chevron.
- Role token.
- Best label: title, value, description, identifier, in that order.
- Badges: focused, actionable, has frame, error, repeated reference.
- Optional count: direct children count after the node has loaded.

Interactions:

- Hover row: temporarily draw frame overlay if a frame exists.
- Click row: select and pin frame overlay.
- Double-click row: expand/collapse.
- Keyboard: up/down, left/right, return, command-F.
- Context menu: Copy locator, Copy AX path, Highlight, Perform action, Use as selected step target.

### Details

Bottom pane, resizable/collapsible:

- Summary: role, title/value, frame, actions.
- Attributes: key/value table for readable scalar attributes.
- Children: child groups by attribute name and count.
- Parameterized attributes: advertised names.
- Locator: generated locator preview using the same target-shaping rules as recording.
- Warnings: missing frame, structural-only element, repeated reference, inaccessible children, timed-out attributes.

Details should make target repair obvious: selected node -> generated locator -> replace/insert target.

### Debug Integration

When a recipe action runs:

- Resolve the acted-on target to a live AX element when possible.
- If the action target is a locator, use the live resolver result as a bridge into the inspector session.
- If the action target is a point, use `AXUIElementCopyElementAtPosition` to find the live element under that point.
- Reconstruct or search the parent chain, expand ancestors, select the node, and draw the frame.
- Mark the node with the action id and status.

Follow Debug should be on by default while paused/running. Turning it off keeps the user's current tree selection stable.

## Performance Model

Full does not mean careless:

- Traversal runs off the main thread.
- Every refresh is cancellable.
- The UI renders virtualized rows.
- Attribute reads are tiered:
  - Tier 1 for rows: role, title/value/description, frame, actions, child groups.
  - Tier 2 for selected details: full attribute table.
  - Tier 3 for optional host search/predicate probes.
- Expensive or failing nodes are marked, not hidden.

The important rule: performance controls may affect scheduling and presentation, but not silently replace the full-tree contract with a truncated tree.

## Implementation Plan

### Phase 1: Boundary And Model

- Add `LiveAXInspectorSession` / `LiveAXInspectorReader`.
- Move AX tree sidebar off socket `look`.
- Define `LiveAXNode`, `LiveAXChildGroup`, and a SwiftUI view model.
- Preserve all existing `look` / snapshot code unchanged.

Acceptance:

- No calls from `AXTreeInspector` to `SocketClient`, `look`, or snapshot handles for primary tree loading.
- Unit tests can exercise the reader through an `AXElementReading` protocol with fake elements.

### Phase 2: Full Tree Rendering

- Implement full recursive traversal from app root/windows.
- Discover child-bearing attributes instead of only hard-coding `AXChildren`.
- Stream progress and render the outline.
- Search loaded nodes and expand ancestors to matches.

Acceptance:

- Firefox page content reachable through exposed AX children appears in the tree, not only browser chrome.
- No `<truncated>` / snapshot id / handle language appears in the sidebar.

### Phase 3: Selection, Details, And Repair

- Frame highlight on hover/select.
- Details pane with attributes/actions/child groups.
- Generate locator preview from selected live node.
- Add "Use as selected step target" for replacing a selected action target.

Acceptance:

- Selecting a web link/button/text field can produce a locator shaped like recorded actions.
- Repairing a failed/selected step does not require manually reading raw AX text.

### Phase 4: Debug Follow

- Bridge action targets to live elements.
- Expand/select acted-on node during run/step/resume.
- Support point targets through hit testing.
- Add action status badges in the tree.

Acceptance:

- During step/run, the sidebar visibly follows the node Axon acted on.
- Turning Follow Debug off preserves manual inspection state.

### Phase 5: Host Search Supplement

- Surface `AXUIElementsForSearchPredicate` support in details.
- Add scoped host search for Firefox/Safari web areas.
- Attach returned results to ancestor paths when possible, otherwise show a separate live result lane.

Acceptance:

- Search can find known Firefox web links/buttons via predicate search even if the host virtualizes or withholds parts of the child tree.
- Predicate results are labeled as supplemental live AX results, not confused with the main tree.

## Open Design Questions

- Which child-bearing attributes should be promoted into the primary tree besides `AXChildren`? The reader can discover arrays dynamically, but the UI still needs ordering and grouping rules.
- Should the app root include menu bar and focused element sections by default, or should the sidebar start at windows only?
- Should details show every scalar attribute immediately, or only on selection to reduce AX traffic?
- How aggressive should automatic debug-follow refresh be after each action? A full refresh after every step may be too much; targeted parent-chain reconstruction may be the right default.

## Non-Goals

- Replacing `look` or MCP observation.
- Changing `AXSnapshotCapturer` sibling budgets.
- Building a browser DOM inspector.
- OCR fallback for the tree.
- Hiding AX host limitations. If the app does not expose a node, the inspector should say what it could and could not read.
