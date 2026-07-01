# Debugger Snapshots And Record From Here

Status: Implemented after debugger API/surface rework 2026-05-17. Filed 2026-05-17.

## Context

The core paused debugger session landed as part of [Make The Editor Worth Keeping](2026-05-16-editor-worth-keeping.md). The first surface was rejected after use: it hid the state machine behind ambiguous toolbar controls and rendered snapshots as unreadable diagnostic text.

The corrected implementation keeps the useful execution engine but reworks the public contract and editor surface around explicit debugger verbs: create, resume, run-to-selected, step, update breakpoints, retry, stop, reset, and record-from-here.

## Decisions

- Paused snapshots are captured only for intentional pauses: saved breakpoints, run-to-selection, and failure. The editor does not render them as a bottom raw-tree panel; app inspection lives in the live AX Tree sidebar layer.
- The AX Tree sidebar is the editor's inspection surface rather than a raw pause-snapshot panel.
- Correction, 2026-05-22: the current sidebar is still backed by socket `look`/`find` calls, not live editor-retained AX elements. The direct live inspector remains tracked in [Really Good Live AX Inspector Sidebar](2026-05-17-live-ax-inspector-sidebar.md).
- Record-from-here inserts new recorded blocks at the paused point by default. Existing following blocks remain after the insertion.
- Debug sessions carry a caller-supplied `documentId` so app-side recording can target the active editor window without a new IPC layer.
- Breakpoints must be editable during a live session and after a run has produced trace status.
- Save/discard controls are document lifecycle controls, not debugger controls; they must not sit between run/step/continue.

## Implemented

- `debug.create` creates a paused session without executing actions.
- `debug.resume` runs until the next active breakpoint or completion.
- `debug.runTo` runs until a specific block and pauses before it.
- `debug.setBreakpoints` updates breakpoints on a live session.
- `debug.start` / `debug.continue` remain compatibility aliases for the earlier names.
- Debug status returns `cursorBlockId`, `lastActionId`, `pauseReason`, `breakpoints`, and `availableActions`.
- `debug.create` accepts and returns `documentId`.
- The editor sends its window document id when starting debug sessions.
- The editor exposes debugger commands in an in-window icon control strip with help text.
- Stop-recording inserts captured blocks into the active editor document before the paused block.
- Inserted recorder blocks are ID-remapped when needed so action ids, fact ids, and `requires` references do not collide with existing document ids.
- `debug.runTo` run-to-selection pauses and `debug.resume` breakpoint pauses expose `pauseSnapshot` metadata with a snapshot id, app identity, reason, and compact observation.
- Ordinary `debug.step` pauses do not capture snapshots.
- Failed actions capture a `pauseSnapshot` with reason `failure`, keep the debug session alive, and can be retried with `debug.retry`.
- The editor exposes Retry / Record From Here while failed.
- The editor has an AX Tree sidebar layer with refresh, search over loaded nodes, node details, selected-node frame highlighting, and acted-on target highlighting while playback/debugging advances. The direct live AX implementation remains a follow-up.

## Follow-Up Candidates

- Add explicit undo/confirmation after Record From Here inserts blocks.
- Decide whether inserted recorded blocks should inherit surrounding editor metadata such as notes or breakpoints.
