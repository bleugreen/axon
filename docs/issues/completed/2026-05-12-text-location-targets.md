# Text Location Targets

Status: Complete. AX-backed and OCR-backed location targets are implemented for
primitive pointer actions.

## Context

Agents should be able to say "location of Backlog" and use the center point of that text as an action target. This is different from a normal AX locator:

- The desired output is a point, not an element handle.
- The source may be AX text, screenshot OCR, or both.
- It should work even when the app exposes poor element structure but visible text is clear.

## Desired Direction

Add a point-producing target form:

```yaml
target:
  location:
    text: Backlog
    app: cairn
    source: auto
```

`source: auto` should prefer AX text geometry when available and fall back to screenshot/OCR once that exists. Other explicit sources:

- `ax`: search accessible node titles, values, descriptions, labels, and text-like nodes with frames.
- `screenshot`: find visible text in the captured image and return the text bounding box center.

The resolved target should include:

- center point in screen coordinates
- matched text
- source used
- bounding frame
- confidence or ambiguity details

## Failure Behavior

Missing or ambiguous text should be reported honestly. The tool should not click the first fuzzy text match without exposing candidates.

## Next Steps

- Implemented: AX-backed text location first because frames are already available in snapshots.
- Implemented: OCR-backed screenshot text using captured app-window images.
- Implemented: Allow `click`, `scroll`, `drag`, and plans to accept text-location targets anywhere they accept point targets.
