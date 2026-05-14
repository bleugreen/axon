# Locator Replay Speed

Status: Design. Not yet implemented.

## Context

Recipe playback resolves recorded locators by walking the entire app's accessibility tree and matching against an in-memory snapshot. The dominant cost is the walk, not the match.

Concrete trace for "click the AXLink titled 'Coluccio Salutati' in Firefox":

1. `AXLiveLocatorResolver.resolve(app:, locator:, scrollToVisible:)` calls `capture(app:)`.
2. `capture` resolves the app, calls `AXUIElementCreateApplication`, reads `kAXWindowsAttribute`, then recursively serializes every window and every descendant. Each node costs ~9 `AXUIElementCopyAttributeValue` calls (role, subrole, title, value, description, help, identifier, enabled, focused) plus frame and action names.
3. `LocatorResolver().resolve(locator, in: snapshot)` walks the materialized snapshot to find candidates.

Every `AXUIElementCopyAttributeValue` is a cross-process XPC roundtrip with a 0.2 s messaging timeout. For a Firefox window with a populated content area this is tens of thousands of roundtrips before the match even starts. The slow step is the snapshot capture.

A second observation, load-bearing for the fix: at record time, `UserActionRecorder.elementAncestry` already walks up to 12 ancestors, and `RecordedTargetSelector` already passes the full chain into `RecordedLocatorBuilder.locator()`. The builder then **discards every ancestor except `AXWindow`** before serializing. The saved locator carries `ancestors: [{role: AXWindow}]` and no path information, despite the full path being available for free.

The matcher (`LocatorResolver.matchesAncestors`) already supports fuzzy ordered ancestor matching, so the information loss is purely in the record-time serialization.

## Desired Shape

Four independently shippable changes, ordered by leverage.

### 1. Persist real ancestry in recorded locators

`RecordedLocatorBuilder.locator()` keeps the full ancestor chain (or a useful prefix) instead of collapsing to a single `AXWindow` entry. Each saved ancestor carries the stable attributes already collected at record time: role, subrole, identifier, and title when present. The matcher consumes them today; this change is record-side only.

This is the cheap baseline: even without any new resolver, a richer ancestor list lets the existing matcher reject most of the snapshot earlier — and it unlocks #2.

### 2. Path-walking resolver

A new resolution path that, given a locator with ancestry, walks top-down from the app root. At each level fetch `kAXChildrenAttribute` once, filter children matching the next ancestor predicate, descend. O(depth × siblings) AX calls instead of O(whole tree). Falls back to today's full-snapshot resolver only when the recorded path narrows to a wide ancestor and the leaf still isn't unique within it.

For most native UIs (toolbars, menu bars, sheets) the path walk reaches the leaf with a handful of XPC calls.

### 3. `AXUIElementsForSearchPredicate`

A parameterized AX attribute. One XPC call to the target host element runs the predicate inside the host process. Shape of the call:

```
let params: [String: Any] = [
    "AXSearchKey": "AXLinkSearchKey",
    "AXSearchKeyText": "Coluccio Salutati",
    "AXSearchKeyImmediateDescendantsOnly": false,
    "AXSearchKeyResultsLimit": 5
]
AXUIElementCopyParameterizedAttributeValue(
    scopeElement,
    "AXUIElementsForSearchPredicate" as CFString,
    params as CFTypeRef,
    &result
)
```

Returns matching `AXUIElement` references. Supported by any host that implements it — known good in AppKit and WebKit-backed apps; unknown in Firefox's Gecko AX server and in Electron until probed.

Combined with #2: walk the recorded ancestor chain top-down until reaching the first "wide" ancestor (large `kAXChildrenAttribute` count, or known-wide roles like `AXWebArea`, `AXOutline`, `AXTable`). From that ancestor issue one predicate call scoped to it. Native UI walks fast; web content gets one predicate call inside the web area instead of a full DOM crawl.

### 4. Per-recipe element cache

Recipes that do scroll-then-click resolve the same target twice today. After a successful resolution, hold the `AXUIElement` reference keyed by locator hash with a short TTL (until the next focus change or window event). The second step skips resolution entirely.

## Open Questions

- **Predicate API host coverage.** A throwaway probe needs to confirm `AXUIElementsForSearchPredicate` works in Firefox, Chrome, Safari, Finder, Slack, VS Code, and a native AppKit toolbar app. Output: which search keys each host implements. Until that's run, the predicate plan in #3 is conditional. Probe is small enough to live in `scripts/`.
- **Ancestor stability.** Some hosts mutate ancestors aggressively — virtualized lists where an `AXGroup` parent disappears on scroll, web pages where wrappers shift. The path-walking resolver needs a notion of which roles are unstable and should be skipped in the recorded chain. The right list isn't obvious; likely emerges from running real recipes.
- **Cache invalidation signals.** TTL is the blunt version. `kAXUIElementDestroyedNotification` and `kAXFocusedWindowChangedNotification` via `AXObserver` are precise but cost setup per resolved element. TTL probably wins for a first pass; revisit if cache misses turn out to matter.
- **Recorded ancestry size.** The current 12-ancestor cap in `UserActionRecorder.elementAncestry` is fine for the walk, but persisting all 12 in every locator bloats `.axn` files. Probably want to keep ancestors with stable identity (identifier or title) and skip pure-structural intermediates. Heuristic worth validating against real recordings.

## Non-Goals

- **No machine-learning relevance scoring.** Faster traversal, not smarter scoring. Locator semantics stay deterministic.
- **No record-time AX-tree caching.** The recorder is already fast; the cost lives entirely in replay.
- **No bypass of `LocatorResolver` matching semantics.** New resolvers produce candidates that flow through the existing matcher. Only the traversal strategy and the candidate population change.
- **No new locator schema fields beyond ancestry.** The locator stays a description of "what element"; the resolver gets smarter about how to find it.

## Next Steps

- Run the predicate-API probe against ~6 representative hosts and record which search keys each implements. Decides whether #3 ships at all or only on a per-host allowlist.
- Wire full ancestry through `RecordedLocatorBuilder` and confirm the existing matcher accepts the richer chain without change. Ship as #1 standalone; measurable as a first win.
- Build the path-walking resolver as a separate type. `AXLiveLocatorResolver` becomes the fallback path; the path resolver runs first when the locator has usable ancestry. Time replay latency on the Firefox example before and after.
- Layer the predicate call on top of the path walk once #1 confirms host support.
- Add the per-recipe element cache. TTL-based first; consider `AXObserver`-driven invalidation if misses are common.
