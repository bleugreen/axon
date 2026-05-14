# Locator Replay Speed

Status: In progress. Core shared live resolver strategy implemented; more host coverage and tuning remain.

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
    "AXSearchText": "Coluccio Salutati",
    "AXResultsLimit": 5
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

## Probe Results, 2026-05-14

Added `scripts/probe-ax-search-predicate`, a standalone Swift AX probe that:

- finds bounded scopes in running apps by AX role;
- records each scope's `AXUIElementCopyParameterizedAttributeNames`;
- tries `AXUIElementsForSearchPredicate` and `AXResultsForSearchPredicate` with known search keys;
- emits JSON with AX errors, result counts, and sampled returned elements.

Important correction from local SDK constants: the AppKit raw dictionary keys are `AXSearchKey`, `AXSearchText`, and `AXResultsLimit`. The earlier sketch's `AXSearchKeyText` / `AXSearchKeyResultsLimit` shape returned successful empty results in Firefox but did not produce useful matches.

Observed on the local machine:

- Firefox `org.mozilla.firefox`: `AXToolbar`, `AXScrollArea`, and `AXWebArea` scopes advertise `AXUIElementCountForSearchPredicate` and `AXUIElementsForSearchPredicate`. `AXUIElementsForSearchPredicate` returns real elements from `AXWebArea` with the corrected AppKit keys. Example: searching visible text `Deploy` under Firefox `AXWebArea` returned `AXLink` samples titled `Deploy` / `Deploys` for `AXLinkSearchKey`, and `AXButton` samples titled `Deploy Production` / `Deploy Staging` for `AXButtonSearchKey`.
- Safari `com.apple.Safari`: positive on a local fixture page. `AXScrollArea` and `AXWebArea` advertise `AXUIElementsForSearchPredicate`; `AXLinkSearchKey` returned the fixture link and `AXButtonSearchKey` returned the fixture button.
- Google Chrome `com.google.Chrome`: negative on the same local fixture page in this environment. Bounded probes only found `AXWindow` / `AXGroup` scopes and no search predicate attributes or nonempty predicate results, even after activating Chrome and increasing depth/child budgets.
- Purpose-built native AppKit sample (`AxonPredicateProbeApp` with toolbar item, button, and static text): negative. Probed `AXWindow`, `AXToolbar`, `AXButton`, `AXStaticText`, and `AXGroup`; no searched scopes advertised search predicate attributes or returned results.
- VS Code `com.microsoft.VSCode`, Codex `com.openai.codex`, Cursor `com.todesktop.230313mzl4w4u92`: no searched Electron scopes advertised search predicate attributes in the bounded probe.
- Finder, Mail, TextEdit, Notes, Discord: no searched scopes advertised search predicate attributes or returned successful predicate results in the bounded probe.

Current conclusion: predicate search is very promising for the Firefox web-content case and should be the primary fast path when a scoped element advertises `AXUIElementsForSearchPredicate`. It still needs runtime gating because host/scope coverage is uneven.

## Implementation Notes, 2026-05-14

The default `CommandRouter` path now owns one long-lived `AXLiveLocatorResolver` instance. All command surfaces that resolve locator targets (`find`, `click`, `invoke`, `type`, `scroll`, `drag`, and `run` actions routed through `CommandRouter`) share that resolver and its short-TTL live element cache.

The live resolver strategy is:

1. reuse a cached live `AXUIElement` for the same app/locator when still inside TTL;
2. use recorded ancestry to narrow from app windows to the deepest matching scope;
3. if that scope advertises `AXUIElementsForSearchPredicate`, issue a scoped predicate search using `AXSearchKey`, `AXSearchText`, and `AXResultsLimit`;
4. run returned candidates through the existing `LocatorResolver` semantics using small synthetic snapshots;
5. if predicate search is unavailable or no fast candidate matches, try bounded descendants within the narrowed scope;
6. fall back to the previous full snapshot resolver.

Recorded locators now preserve stable ancestor path information. Ancestors can carry `role`, `subrole`, `identifier`, and non-window `title`; volatile window titles remain omitted. `LocatorResolver` now matches ancestor `subrole` and `identifier` as well as the existing role/title/label signals.

Live smoke test against the local Firefox page `Deploy - Ops - AggFlow Ops`:

- locator: `AXLink` titled `Deploy`, action `AXPress`, ancestors `AXWindow` -> `AXWebArea`;
- fast resolver narrowed to one `AXWebArea`;
- predicate search returned two `AXLinkSearchKey` candidates;
- existing matcher accepted one unique candidate and returned handle index `0`, confirming the full snapshot fallback was avoided.

Live smoke test against Safari on a local fixture page:

- locator: `AXLink` titled `Axon Predicate Probe Link`, action `AXPress`, ancestors `AXWindow` -> `AXWebArea`;
- fast resolver narrowed to one `AXWebArea`;
- predicate search returned one `AXLinkSearchKey` candidate;
- existing matcher accepted one unique candidate and returned handle index `0`.

Cache smoke test against the same Safari locator:

- first resolution: predicate path, cache miss, then cache store;
- second resolution through the same daemon: live element cache hit, validating that the shared resolver survives across socket requests.

## Open Questions

- **Predicate API host coverage.** Initial probe confirms Firefox and Safari `AXWebArea` / related scopes support `AXUIElementsForSearchPredicate` with useful results. Bounded probes did not find support in Google Chrome, VS Code, Codex, Cursor, Finder, Mail, TextEdit, Notes, Discord, or a purpose-built native AppKit toolbar/control sample.
- **Ancestor stability.** Some hosts mutate ancestors aggressively — virtualized lists where an `AXGroup` parent disappears on scroll, web pages where wrappers shift. The path-walking resolver needs a notion of which roles are unstable and should be skipped in the recorded chain. The right list isn't obvious; likely emerges from running real recipes.
- **Cache invalidation signals.** TTL is the blunt version. `kAXUIElementDestroyedNotification` and `kAXFocusedWindowChangedNotification` via `AXObserver` are precise but cost setup per resolved element. TTL probably wins for a first pass; revisit if cache misses turn out to matter.
- **Recorded ancestry size.** The current 12-ancestor cap in `UserActionRecorder.elementAncestry` is fine for the walk, but persisting all 12 in every locator bloats `.axn` files. Probably want to keep ancestors with stable identity (identifier or title) and skip pure-structural intermediates. Heuristic worth validating against real recordings.

## Non-Goals

- **No machine-learning relevance scoring.** Faster traversal, not smarter scoring. Locator semantics stay deterministic.
- **No record-time AX-tree caching.** The recorder is already fast; the cost lives entirely in replay.
- **No bypass of `LocatorResolver` matching semantics.** New resolvers produce candidates that flow through the existing matcher. Only the traversal strategy and the candidate population change.
- **No new locator schema fields beyond ancestry.** The locator stays a description of "what element"; the resolver gets smarter about how to find it.

## Next Steps

- Run the predicate-API probe against remaining representative hosts: Chrome, Safari, Slack, and a purpose-built native AppKit toolbar app. Record which search keys each implements. Use `AXUIElementCopyParameterizedAttributeNames` as the runtime gate before any predicate call.
- Run more live latency measurements and tune path-walk budgets for Firefox/Safari and Chrome fallback behavior.
- Revisit Chrome with `--force-renderer-accessibility` or equivalent if Chrome support becomes important.
- Consider `AXObserver`-driven cache invalidation if TTL misses or stale hits become common.
