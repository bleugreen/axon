# Live AX Walk Crashed Machine

## Summary

An early Phase 1 live smoke test against Finder caused the user's computer to crash. No Axon capture processes remained afterward, but the crash means live capture must be treated as a safety issue, not just a performance issue.

## Likely Cause

The first live capturer called `AXUIElementCopyAttributeValue(... kAXChildrenAttribute ...)` and only applied `.prefix(...)` after receiving the full child array. For large or unusual accessibility trees, that still asks the target app/accessibility server to materialize an unbounded subtree.

## Immediate Changes

- Added default capture limits:
  - max depth: 14
  - max children per node: 24
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
- `axon snapshot com.apple.finder` completed under a 10-second subprocess timeout after the ranged-read fix. The captured tree included Finder outline truncation such as `children limited to 50 of 1642`, which verified the capturer did not materialize the full child array before applying limits.
- After raising the default depth from 5 to 8, Finder still completed under a 10-second subprocess timeout and exhausted the 400-node budget instead of walking the full outline.
- After later raising the default depth from 8 to 14, browser snapshots reached past common chrome and anonymous wrapper stacks while retaining the same per-child, node, window, and timeout guardrails.
- After later lowering the default sibling page from 50 to 24, broad containers such as browser tabs consume less raw capture budget before page content.

## Follow-Up

Before broader live app testing, add a fixture app and expose capture budgets in CLI output.
