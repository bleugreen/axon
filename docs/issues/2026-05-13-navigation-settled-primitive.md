# Navigation Settled Primitive

## Context

Tester feedback from browser automation showed that `look(since:)` is too coarse for page-load completion. It can fire on tab-open or focus transitions even when the useful goal is "the URL/page has settled."

Related observations:

- URL bars that expose `AXValue` work well with `type`.
- Waiting on a lock/info button by `title contains "View site information"` failed because Firefox exposes that user-facing label as `AXDescription`, not `AXTitle`; use locator `label` for this class of target.
- A robust navigation wait should read stable app state, not infer from generic window-change notifications.

## Desired Shape

Add an agent-facing primitive that waits on specific readable state:

- `read_value(target)` or a plan predicate that reads AXValue/label from a resolved locator.
- `wait_for_value(target, contains|equals|matches, timeoutMs?, intervalMs?)`.
- Browser-friendly sugar such as `wait_for_url(app, contains|equals|matches)` can be built on the URL bar locator once the generic value read exists.

## Notes

This should not replace `look(since:)`. Broad change checks remain useful for "did the surface mutate?", while navigation needs a goal-specific settled condition.
