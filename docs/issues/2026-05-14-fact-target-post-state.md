# Fact Target Locators Should Be Recorded From Post-Action State

Status: In progress. Filed 2026-05-14.

## Context

Recipes encode `expects` facts that verify post-action state. Each fact has a `target` locator and a `state` predicate (e.g., `value.contains: wikipedia.org`). At replay, the resolver locates the fact's target element and checks the predicate against it.

Today the recorder builds the fact's target locator from the **pre-action** AX snapshot — the same snapshot used to build the action's target locator. For actions whose effect mutates the element's own attributes (`type`, value-setters, toggles), this guarantees at least one identifying attribute on the fact's locator is stale by the time the fact runs.

Concrete trace from `2026-05-14-193649-Firefox.axn`:

```
- id: a002
  tool: type
  target:
    locator:
      role: AXComboBox
      description: "Search with Google or enter address"
      ancestors: [...]
  value: wikipedia.org
  expects:
  - id: a002.value.0
    target:
      locator:
        role: AXComboBox
        description: "Search with Google or enter address"   # <-- stale post-action
        ancestors: [...]
    state:
      value:
        contains: wikipedia.org
```

`axon run` output:

```
{"factId":"a002.value.0","success":false,"error":"Fact a002.value.0 locator did not resolve uniquely: missing"}
```

The Firefox URL bar exposes `"Search with Google or enter address"` via `AXDescription` only while the field is empty. After the `type` action lands content, the description goes away, the locator's primary identifier no longer matches anything, and the resolver returns `missing`. The fact never gets a chance to evaluate its predicate against the element it was meant to verify.

This isn't unique to URL bars — it generalizes to any action whose purpose is to mutate the targeted element. The lazier the recorder is about post-state, the louder the fact-recording bug becomes as resolvers get faster.

## Why the Obvious "Fix" Is Wrong

Strip fragile attributes (`description`, `value`) from the fact locator and keep only stable ones (role, subrole, identifier, ancestors). This is the wrong shape: the whole reason facts exist is to confirm change. A locator that drops every attribute the action might touch is a locator that can't tell whether the action did anything. The predicate (`value.contains: wikipedia.org`) is then doing all the work, and the locator becomes ceremonial.

## Desired Shape

The recorder already holds the `AXUIElement` reference for the targeted element through the action. After the action's effect settles, re-read the element's attributes in its post-action state and build the fact's target locator from those.

Two locators per action+fact pair, both fully attributed:

- **Action locator**: built from the pre-action snapshot. Used to find the element to act upon.
- **Fact locator**: built from the post-action re-read of the same `AXUIElement`. Used to find the element when checking the predicate.

For the URL bar example the recorded recipe would look something like:

```
- id: a002
  tool: type
  target:
    locator:
      role: AXComboBox
      description: "Search with Google or enter address"   # pre-action
      ancestors: [...]
  value: wikipedia.org
  expects:
  - id: a002.value.0
    target:
      locator:
        role: AXComboBox
        value: "wikipedia.org"                              # post-action, freshly read
        # description omitted because the post-state element no longer exposes one
        ancestors: [...]                                    # re-read; usually identical
    state:
      value:
        contains: wikipedia.org
```

The fact target now identifies the URL bar **as it exists in the post-action state**, and the `value.contains` predicate is a real assertion about the change rather than a tautology.

### Settling the Post-State

The recorder needs a moment to elapse between the action and the post-read so that the action's effects are visible in AX. Cheapest reliable signal: the AX notification stream the recorder already subscribes to. For `type`, wait for `AXValueChanged` on the targeted element (or a short timeout if none arrives). For `click`/`AXPress`, wait for whatever notifications historically fire (the existing `observed:` block shows what to expect per host).

This settle step is also a useful boundary for case 2 below.

## Open Question: Facts About Other Elements

The fix above handles facts whose target is the action's own element. The harder case is facts whose target is a *different* element — the action causes focus to move, a page to load, a sheet to open, and the fact verifies state of the new element.

Possible shapes:

- **AX notification driven**: the recorder watches the notification stream and infers candidate fact targets from notifications like `AXFocusedUIElementChanged → AXWebArea` or `AXLoadComplete`. Each candidate is captured as a potential fact target and the user (or a heuristic) picks the right one.
- **User-directed**: at record time, when the user pauses to assert a fact, they click/identify the element the fact is about, and the recorder snapshots *that* element from the post-action state. Fact identity is explicit rather than inferred.
- **Hybrid**: notifications produce a shortlist; the user picks the one that matches their intent.

This is a larger design question than the same-element fix and should be scoped as a separate phase. The same-element fix is independently shippable and rescues every `type`/value-setter recording today.

## Non-Goals

- **No stripping fragile attributes from the pre-action locator.** Pre-action locators stay rich and accurate to the pre-state.
- **No changing fact predicate semantics.** `state.value.contains`, `state.changed`, etc. continue to behave as today. The fix is in *how the fact's target element gets identified*, not in what gets asserted about it.
- **No new resolver behavior.** The fast resolver from [[locator-replay-speed]] continues to be the path for both action and fact locators; this issue is purely about what gets recorded.

## Next Steps

- Done: identified the recorder/translator path. `UserActionRecorder.flushPendingText()` was serializing a single target through `RecordedUserAction.setValue`, and `UserRecordingTranslator` reused that target for the `value` fact.
- Done: same-element value facts can now carry a distinct post-action `factTarget`. The recorder captures the focused element/action target when a text burst starts, then re-reads the same AX element when the text burst is flushed and serializes that fresh target for the fact.
- Done: recorded locators now include non-empty `AXValue`, so the post-action locator can identify text controls by the value that exists after mutation.
- Still needed: add an explicit notification/timeout settle boundary if live Firefox recording shows the post-read can race AX value propagation.
- Re-record `2026-05-14-193649-Firefox.axn` and confirm `a002.value.0` resolves and asserts correctly.
- Scope the cross-element fact case (open question above) as a follow-up issue once the same-element fix lands.
