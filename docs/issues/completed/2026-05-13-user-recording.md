# User Recording To `.axn`

## Context

Today `.axn` files capture only MCP/CLI-initiated actions: the agent did it, Axon recorded it, the file replays it. A natural next step is letting a user demonstrate a workflow by hand and have Axon transcribe the demonstration into the same `.axn` format. The agent then learns paths it never walked.

This collapses two recording modes into one substrate. Agent-driven and human-driven sessions become indistinguishable `.axn` files, which also enables hybrid sessions where a user does the fiddly setup by hand and the agent picks up mid-file to run the repetitive part.

The target UX is a menubar Record / Stop control, scoped to a chosen app.

## Mechanism

macOS provides the needed primitives. Axon already holds Accessibility trust, which is the gate for both of them:

- `CGEventTap` installed in passive listen-only mode for the recording window. Sees mouse and keyboard events globally.
- `AXObserver` notifications on the target app: `AXValueChanged`, `AXFocusedUIElementChanged`, `AXMenuItemSelected`, `AXWindowCreated`, etc.

The recorder fuses both streams. Raw input events get translated to semantic actions by hit-testing against the target app's AX tree at event time — the inverse of the resolver's normal job. Where an AX-native signal is observable (a menu pick fired by a keyboard shortcut, an `AXValueChanged` after typing), prefer that representation over the literal input.

## Desired Shape

- Menubar `Record` opens a target picker (running apps), then begins capture scoped to that app's pid.
- A loud recording indicator (menubar status item color/icon, optional window border overlay) makes capture state unmistakable.
- `Stop` closes the file, prompts for a name, writes a `.axn` into a configurable directory.
- Output is a normal `.axn` runnable by CLI `axon run` or MCP `run` with no special treatment.

Translation rules:

- Mouse-down/up at point P → `click` against the AX element hit-tested at P with a locator emitted from the element's attributes.
- Mouse-down + threshold-crossing motion + mouse-up → single `drag` from source element to destination element (or coordinates if either end lacks an AX target).
- Wheel events scoped to a scroll surface → single `scroll` call against that surface.
- Keystrokes into a focused text field → coalesced `type` when the resulting AXValue is observable, else `keyboard`.
- Keyboard shortcuts that trigger a menu item (observable via `AXMenuItemSelected`) → `invoke(name: AXPress)` on the menu item, not the keystroke.
- Bare keystrokes with no AX-observable result → `keyboard`.

Embedded verification:

- Every recorded action has an observable result event during capture (value change, focus shift, new window, navigation settle).
- The recorder writes those results into the `.axn` as implicit assertions ("after this click, this AX state should hold").
- Replays self-verify against the original demonstration. This is a structural upgrade over a dumb event log.

Chapter segmentation (optional, second pass):

- Auto-segment the recording when the active window changes, the user switches apps, or there is a long idle pause.
- Each segment is a named block within the `.axn`, addressable for partial replay.

## Privacy And Safety

Non-negotiable:

- Honor `IsSecureEventInputEnabled()`. Drop all events while secure input is active. macOS sets this flag during password entry.
- Drop events targeting AX roles or attributes that hint at sensitive content (password fields, secure text areas).
- Recording is scoped to a single target app's pid by default. Global recording, if ever offered, is a separate explicit mode.
- The recording indicator is always visible; no quiet-record mode.

## Open Questions

- Where do recordings live by default? A user-visible folder (`~/Documents/Axon Recordings/`) makes them discoverable but conflicts with treating them as agent memory. A library folder hides them from the user.
- Should mid-recording pauses become `wait_until` predicates or just be discarded? Discarding feels right for now — the agent's verification primitives should handle "wait for X to be true" rather than baking literal sleeps into the file.
- How does recording interact with hybrid sessions? If the user records, then asks the agent to continue, does the agent append to the same file in-place, or start a new one and offer to splice?
- Element-not-in-AX-tree fallback: emit a point-target action with a screenshot crop for later visual matching, or refuse to record the action and surface the gap?

## Non-Goals

- No global "record everything I do all day" mode.
- No screen-recording or pixel diffing as the primary capture path. Recording is AX-first, with point/visual targets as a documented fallback.
- No automatic editing or beautification of the recorded file. The file is the artifact; the user (or agent) edits it deliberately if needed.

## Next Steps

- Prototype the CGEventTap + AXObserver fusion against a known-good test app (TextEdit, Finder).
- Decide on the `.axn` element-locator shape emitted by the recorder — likely a stable subset of the resolver's full locator language plus an optional `originHint` (point, element identifier) for debugging.
- Wire the menubar Record / Stop UI to the existing Axon.app service binary.
- Add a verification-assertion field to the `.axn` schema so recorded result events can travel with the action.

## Implementation Notes

Initial support landed with verified `.axn` metadata on normal batch actions:

- actions may carry mechanical `id`, `requires`, `expects`, `observed`, and `warnings`
- `run` verifies `requires` before dispatch and `expects` after dispatch, then strips metadata before calling the primitive tool
- passed expectations enter the per-run fact table for later requirements
- recorded evidence remains audit-only unless promoted to `expects`

The menu bar app now exposes `Record...` / `Stop Recording...`, scopes capture to a selected running app, shows a red recording status item, and saves to `~/Documents/Axon Recordings/` by default. The recorder uses a passive `CGEventTap`, AX hit-testing, focused-value reads, and target-app `AXObserver` notifications. It currently emits locator-backed clicks, settable text as `type`, submit keys as `keyboard`, scrolls, drags, and warning-marked point fallbacks.

Remaining hardening work:

- exercise the live recorder manually against TextEdit and Finder and capture fixture recordings
- improve keyboard burst segmentation beyond stop/click/submit flushing
- promote more AX notification patterns into stable `expects`
- add richer secure-field detection as more app-specific AX shapes are observed
