# Drag Targeting and Verification

## Context

Axon exposes `drag`, but the current shape is too close to raw pointer coordinates to be a good agent primitive. A manual test against the Codex project sidebar made two problems clear:

- Coordinate entry is fragile. The first attempt mixed screenshot pixels with macOS screen points and targeted the wrong place.
- Dispatch success is not semantic success. Axon returned `success: true` because it posted mouse events, but the UI did not visibly reorder.

This is different from scroll: scroll should be AX-native where possible, and `AXScrollToVisible` works for Cairn. Drag often is genuinely pointer-like because reorder/drop gestures may not expose an AX action. Still, Axon should not force agents to hand-enter coordinates or claim that a no-op gesture succeeded.

## Evidence

- Codex's project sidebar content was not exposed in the AX tree; `get_app_state` only returned the window shell.
- A screenshot showed usable visual targets, but the tool surface had no way to address them semantically.
- A direct `drag` from approximate point to approximate point returned `CGEventDrag` success without a visible sidebar reorder.
- The user saw a later attempt happen, but the coordinates were off. That confirms event dispatch can be visible while still not being a usable automation primitive.

## Desired Direction

- Keep point targets as an escape hatch, not the primary interface.
- Add screenshot-backed or visual target resolution for apps with poor AX trees.
- Support window-relative and screenshot-relative points explicitly so coordinate spaces are never ambiguous.
- Emit realistic drag paths when pointer events are necessary: mouse-down, threshold-crossing motion, multiple drag updates, hover/settle, mouse-up.
- Return honest results. A drag should report dispatch separately from semantic success unless a postcondition verifies the UI changed.
- Let plans express postconditions around drag, for example "row A appears below row B" or "snapshot changed in this region."

## Non-Goals

- Do not keep tuning hard-coded manual coordinates as a substitute for target resolution.
- Do not add daemon-owned recipes for app-specific reorder behavior.
- Do not mark a drag as behaviorally successful just because CoreGraphics accepted the events.

## Next Steps

- Design the visual target schema alongside the broader tool/plans documentation pass.
- Add a small live test target or fixture app with a reorderable list so drag behavior can be verified without depending on Codex internals.
- Revisit Codex sidebar reorder after visual target resolution and postconditions exist.
