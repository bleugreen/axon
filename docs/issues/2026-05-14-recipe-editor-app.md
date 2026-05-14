# Recipe Editor And Preferences App

Status: Design. Not yet implemented.

## Context

`.axn` files are the durable artifact of axon — recordings of tool-call sequences with declared parameters, replayable later. Today they exist only as yaml on disk: you record one through the daemon, edit it in a text editor if you're brave, and replay it from the CLI or MCP. That's enough for the engine to be useful, but it's not enough for the *recipe* metaphor to land — a cooking recipe you can only read as a database dump is not a recipe.

This issue defines the editor app that turns `.axn` files into a visual document type, and folds the daemon preferences surface into the same bundle. The [Parameter Model](2026-05-14-parameter-model.md) is the data layer this UI manipulates; the editor exists to make that model authorable, inspectable, and debuggable without dropping to yaml.

## Desired Shape

One macOS app bundle, three scenes:

1. **MenuBarExtra** — the existing menubar surface (daemon status, update flow). Already shipped.
2. **DocumentGroup** — document-based editor for `.axn`. `.axn` registers as the owned file type; double-click opens an editor window per file.
3. **Settings** — singleton preferences window (⌘,) for daemon-scoped config.

Two-apps was the obvious alternative. Rejected: the menubar bundle already owns daemon lifecycle, the in-app updater, and the IPC socket — splitting the editor out duplicates all of that for no gain. SwiftUI 4+ supports `MenuBarExtra` + `DocumentGroup` + `Settings` in a single `App` cleanly.

## Editor

The editor renders an `.axn` as a vertical list of **action blocks**, never as raw yaml. Each block is a typed form for one tool-call: tool icon and name at the top, target summary on a second line, per-tool fields on expansion. Parameter references inside string fields tokenize into chips with binding popovers — `value: Hello {{recipient}}` renders as `Hello [👤 recipient]` and clicking the chip surfaces literal / caller-arg / declared-source options with an op picker for `op://` and an environment picker for `env://`.

The block list is the document body. Drag to reorder, multi-select, delete, duplicate. `note:` blocks render as sticky-note rows interleaved with action blocks — non-executable annotations that travel with the file.

The locator picker that came up during design is a non-feature: recorded blocks already have a locator captured at record time, so there is no authoring path that needs hand-built locators. The one edit-time case is *repair* (a fragile locator broke between sessions) — selecting a block exposes a "Re-pick target" affordance that puts the daemon into picker-mode against the live app and replaces just the locator field.

## Run Model And Breakpoints

The editor's core verb is the **breakpoint**. The gutter is click-to-toggle; a breakpoint is a persistent annotation on a block, saved with the file.

Breakpoints compose three otherwise-separate workflows into one primitive:

- **Run to breakpoint** — replay actions up to the breakpoint, then pause. The target app is now in the state the next block would act on. The editor's snapshot panel shows the AX state at the pause point.
- **Record from here** — with the daemon paused at a breakpoint, hit record. New actions captured by the daemon append as blocks at the insertion point. This is how you extend a recipe, repair a broken middle section, or capture a variant from a shared prefix without redoing setup.
- **Step** — run one block, pause at the next. Standard debugger feel for inspecting intermediate state.

Persistent (saved-in-doc) breakpoints are the default because they are authoring scaffolding — useful next session, not just this one. Session-only "Run to here" is a ⌘-click on the gutter without committing a breakpoint.

`runState` is the editor's central state machine, computed once and consumed by the gutter, toolbar, and status bar:

| State | Gutter on relevant block | Toolbar |
|---|---|---|
| `.idle` | breakpoint dot if set | ● record · ▶ run · ▶| run-to-cursor |
| `.running(curr)` | yellow caret on `curr` | ⏸ pause · ⏹ stop |
| `.paused(at, snapshot)` | green caret on `at`, snapshot panel unfolds | ▶ continue · ⏭ step · ● record-from-here · ⏹ stop |
| `.failed(at, err)` | red caret on `at`, error inline | 🔧 fix · ↻ retry · ● re-record-from-here |
| `.recording(after)` | red recording bar between `after` and next | ⏹ stop-recording |

Failure surfaces **inline** in the block, never as a modal — modals break the debug flow. The failed block expands to show the error, the AX state at failure, and the fix/retry/re-record affordances.

## File Format Compatibility

The editor reads and writes plain `.axn` yaml. Editor-only metadata (breakpoints, per-block notes that aren't action-level `note:` blocks) sits in a leading-comment header so files remain valid yaml outside the editor:

```yaml
# axon-editor: { breakpoints: [b3, b7], notes: { b3: "auth fails here" } }
version: 1
args: [...]
actions: [...]
```

The comment header is optional — a file recorded by the daemon and never opened in the editor has none. The editor parses it best-effort and silently regenerates it on save.

Block IDs (`b3`, `b7` above) are stable identifiers added to each action when the editor first writes the file, so breakpoints survive edits that reorder or insert blocks. The recorder emits IDs from the start; older files without IDs get them on first save through the editor.

## Daemon Coupling

The editor is just another client of the existing daemon socket — no new IPC surface invented. The required calls are the run/record primitives the CLI already needs:

- `run(blocks:until:)` — replay a block range, pause at a breakpoint.
- `recordSession(insertAfter:)` — start a recording session whose output appends to the open document at a given block ID.
- `look(snapshotAt:)` — fetch the AX snapshot the daemon captured at a paused point, for the snapshot panel.
- `pickElement()` — picker-mode for locator repair; returns a locator for the next user-clicked element.

If any of these don't exist yet on the daemon side, they fall out of the editor's needs and get added through this work — the editor is the forcing function for the daemon's public client surface.

## Preferences

The `Settings` scene is a small, singleton window. v1 surfaces:

- **Accessibility permission** — current grant status, button to open System Settings if missing.
- **Daemon** — install / uninstall / restart, last-launched, log tail.
- **Updates** — channel, "Check now", current cask status (reuses existing [HomebrewInstaller](../../Sources/AxonCore/HomebrewInstaller.swift)).
- **Secrets** — HMAC key status, rotate key (with confirmation), default `op` vault for new bindings.
- **History** — retention window, "Clear history" with confirmation, redaction-level setting.

Prefs is intentionally small. CLI parity matters more than UI breadth — anything a power user would script lives in `axon` first; prefs is the legible surface.

## Implementation Sketch

New types live in `Sources/AxonApp/Editor/`. The existing `Sources/AxonApp/main.swift` becomes a SwiftUI `@main App` with three scenes:

```swift
@main
struct AxonAppMain: App {
    @StateObject private var daemon = DaemonController()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        MenuBarExtra("Axon", systemImage: "waveform.path") {
            MenuBarContent(daemon: daemon, updates: updates)
        }
        DocumentGroup(newDocument: { AxonDocument() }) { file in
            DocumentView(document: file.document)
                .environmentObject(daemon)
        }
        Settings {
            PreferencesView(daemon: daemon, updates: updates)
        }
    }
}
```

`AxonDocument` is a `ReferenceFileDocument` wrapping a parsed `Recipe` from `AxonCore`, plus editor-side state (breakpoints, selection, `runState`, ephemeral arg bindings for testing).

The view hierarchy:

```
DocumentView (NavigationSplitView)
├── Sidebar: ArgsPanel       (declared params, current bindings, "Test args" set)
└── Detail:
    ├── Toolbar              (record / run / run-to-cursor / pause / step / stop)
    ├── BlockList (List)
    │   └── BlockRow ×N
    │       ├── Gutter       (index, breakpoint dot, run-state caret, error chevron)
    │       ├── Header       (tool icon, tool name, target summary)
    │       └── Body         (per-tool fields, parameter chips, expanded on selection)
    └── StatusBar            (run state, last error, snapshot-diff link)
```

Each tool verb gets a small dedicated body view (`LookBody`, `ClickBody`, `TypeBody`, …) keyed by the parsed action shape. A shared `ParamizableTextField` tokenizes `{{name}}` references into chips wherever string fields appear.

Info.plist gets `CFBundleDocumentTypes` + `UTExportedTypeDeclarations` for `com.bleugreen.axon.recipe` conforming to `public.yaml`, so `.axn` files double-click into the editor and round-trip through the system as owned documents.

## Non-Goals

- **No raw-yaml editor pane.** The block view is the only authoring surface. Power users edit `.axn` in their own editor; the app does not compete with that path.
- **No multi-pane live AX tree.** Single document window. The paused-snapshot panel shows AX state at a breakpoint, but there is no always-on live tree of the target app.
- **No locator hand-authoring.** Locators come from the recorder or from picker-mode repair, never from manual field entry.
- **No interactive prompting during replay.** Inherited from the parameter model — automations don't pause for typed input.
- **No editor-internal scripting / formula layer.** Parameters stay flat (see parameter model non-goals). The editor renders what the parameter model defines, no more.
- **No version-control UI.** Diff, blame, history-of-edits are out of scope. Git is git.

## Open Questions

- **Snapshot panel rendering.** The AX snapshot at a paused point is structural; rendering it as a tree is the obvious move, but a "what changed since the last snapshot" diff view might be more useful in practice. Decide once there's something to point at.
- **Record-collision UX.** When recording from a breakpoint with blocks after it: replace, push-down, or branch-into-new-doc? Three modes is too many; lean toward replace as default with a modifier for push-down, but defer until the record loop is wired.
- **Custom block kinds.** `note:` is the only obvious non-action block. `assert:` (verify some AX state before continuing) might be valuable for replay reliability and might belong in the model layer rather than as an editor-only concept. Out of scope here; flag for a future issue if recurring.

## Next Steps

One PR. The chunks below describe the shape of that PR, not separate landings:

- File-type registration (UTI + Info.plist) so `.axn` double-clicks into the app.
- `AxonDocument` + leading-comment metadata round-trip.
- Block-list rendering for the existing tool verbs (read-only at first, editing follows).
- Run-state machine wired to the daemon socket, including breakpoints and record-from-here.
- Preferences scene with the v1 sections.
- Stable block IDs emitted by the recorder, picked up by the editor on first save.
