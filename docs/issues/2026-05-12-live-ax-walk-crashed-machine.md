# Live AX Walk Crashed Machine

## Summary

An early Phase 1 live smoke test against Finder caused the user's computer to crash. No Axon capture processes remained afterward, but the crash means live capture must be treated as a safety issue, not just a performance issue.

## Likely Cause

The first live capturer called `AXUIElementCopyAttributeValue(... kAXChildrenAttribute ...)` and only applied `.prefix(...)` after receiving the full child array. For large or unusual accessibility trees, that still asks the target app/accessibility server to materialize an unbounded subtree.

## Immediate Changes

- Added default capture limits:
  - max depth: 5
  - max children per node: 50
  - max nodes: 400
  - max windows: 8
  - AX messaging timeout: 0.2 seconds
- Replaced unbounded child/window reads with `AXUIElementCopyAttributeValues` ranged reads.
- Added node-level `truncationReason` metadata.
- Switched screenshot capture to ScreenCaptureKit window capture instead of display capture.
- Decoupled the `screenshot <app>` command from AX traversal so screenshot smoke tests do not require walking a target app's accessibility tree.

## Verification After Guardrails

- `axon screenshot Codex` returned an embedded PNG without AX traversal.
- `axon snapshot com.cairn.desktop` completed under a 10-second subprocess timeout and returned an indexed AX tree with truncation metadata.
- `axon snapshot com.apple.finder` completed under a 10-second subprocess timeout after the ranged-read fix. The captured tree included Finder outline truncation such as `children limited to 50 of 1642`, which verifies the capturer did not materialize the full child array before applying limits.

## Follow-Up

Before broader live app testing, add a fixture app and expose capture budgets in CLI output.
