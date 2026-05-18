# Make The Editor Worth Keeping

Status: Implemented 2026-05-17. Filed 2026-05-16.

## 2026-05-17 Implementation Note

The friction-removal phase is implemented:

- Double-click / Finder open now routes file URLs through the run path instead of opening `DocumentGroup`.
- The visual editor is explicit via `axon edit <path>` or the menubar `Open Recipe...` item.
- Stop-recording opens an unsaved review window with Replay / Save / Discard.
- The app launches as an accessory service and promotes to regular foreground presence only while editor windows are open.
- Empty-arg recipes start with the Inputs sidebar collapsed.
- The fake prefix-truncation debugger was replaced with a real paused session model.

## 2026-05-17 Debugger Rework Note

The first debugger UI pass was not good enough. It exposed toolbar buttons whose labels and icons did not communicate the state machine, left breakpoint behavior ambiguous after a run, and rendered pause snapshots as raw diagnostic text. That was an implementation-shaped imitation of the original design, not the design itself.

The corrected debugger contract and editor surface are now implemented:

- `debug.create` creates a paused session without executing any action.
- `debug.step` executes exactly one block and pauses before the next executable block.
- `debug.resume` runs until the next active breakpoint or completion.
- `debug.runTo` runs to a selected block and pauses before it.
- `debug.setBreakpoints` updates breakpoints on a live session, so breakpoints remain editable after a run starts.
- `debug.retry` reruns the failed block in the existing session.
- Debug status now reports `cursorBlockId`, `lastActionId`, `pauseReason`, active `breakpoints`, and `availableActions` so the app no longer infers state from ambiguous fields.
- The editor debugger is an in-window icon control strip with help text for each command, grouped by run/debug/repair lifecycle rather than mixed with document save controls.
- The save/discard controls are no longer interleaved with run/step controls.
- Breakpoint affordances remain visible independently from success/failure status, so completed/failed steps can still be breakpoint targets; duplicate row-toolbar breakpoint controls are gone.
- The collapsed sidebar rail now exposes multiple layers instead of one generic button.
- The editor includes a live AX Tree sidebar layer for the recipe target app. It captures top-level windows first, then fetches direct AX children per expanded node instead of rendering a truncated deep snapshot.
- The AX Tree sidebar supports refresh, search over loaded nodes, expandable children, node details, selected-node frame highlighting, and acted-on target highlighting while a debug session runs.
- Record From Here inserts newly captured blocks at the paused point by default, preserving following blocks.

## Context

The recipe editor shipped per [Recipe Editor And Preferences App](2026-05-14-recipe-editor-app.md). That doc made an explicit call: the editor, not Finder, owns replay — double-clicking an `.axn` opens an editor window instead of running it. After living with it, that call is wrong, and the editor as shipped costs more UX than it returns.

This is not a bug report. The behaviors below are working as the prior doc designed them. This issue revises that design from lived experience: the editor took on all of the disruptive parts of the original plan and almost none of the valuable parts.

## What Actually Shipped (evidence)

**1. Double-click opens the editor; the run-on-open path is gone.**
`scripts/package-app` registers `com.bleugreen.axon.recipe` with `CFBundleTypeRole` `Editor`. `AxonAppMain` (`Sources/AxonApp/AppDelegate.swift:480`) is a `DocumentGroup`; opening any `.axn` instantiates `AxonDocument` → `DocumentView`. There is no run-on-open path anywhere. Running requires the toolbar Run button (`DocumentView.swift:46-67`), which sends a one-shot `run` over the socket.

**2. Record → save → find → reopen → run is a nine-step round trip.**
`stopRecording()` (`AppDelegate.swift:259`) calls `saveRecording()` (`AppDelegate.swift:313`): an `NSSavePanel`, a write to disk, and the app forgets the recording. No replay, no review, no discard. To replay what you just captured you must locate it in Finder, double-click (which opens the editor, not a run), and press Run. `AxonDocument` only has `init(recipe:)` and `init(configuration:)` — there is **no entry point that opens an in-memory, unsaved recording for review**.

**3. The dock icon disappears while the app is still running.**
`applicationWillFinishLaunching` and `applicationDidFinishLaunching` force `NSApp.setActivationPolicy(.regular)` three times, including a `DispatchQueue.main.async` (`AppDelegate.swift:34-53`). A triple-call workaround is a tell that the policy does not stick. Nothing re-asserts `.regular` after launch — no reopen handler, no window-close handler. The app has two conflicting identities at once: a `DocumentGroup` foreground app, and a long-lived `NSStatusItem` socket service that the CLI relaunches via `open -b com.bleugreen.axon` (and that self-relaunches on update, `spawnRelaunchHelper`, `AppDelegate.swift:231`). The activation policy is being fought, not decided.

**4. Every launch reopens all past editor windows.**
`DocumentGroup` + macOS window-state restoration, with no opt-out in source. Because the socket-service process is relaunched repeatedly (no-arg `axon` → `open -b`, plus self-relaunch on update), each service launch is treated as a document-app launch and restores the entire prior editor window set. Same root cause as #3.

**5. The sidebar is dead space for the common case.**
`RecipeSidebar` is solely the Inputs/args panel and `isSidebarVisible` defaults to `true` (`DocumentView.swift:11`). A freshly recorded recipe has no `args`, so the sidebar renders a 260pt "No inputs" placeholder (`RecipeSidebar.swift:55-60`). It only earns its width once a recipe is parameterized, which recordings never are at capture time.

**6. The breakpoint / play-pause affordances back nothing real.**
The "Run Model And Breakpoints" state machine from the prior doc is unimplemented. `runRecipe` (`DocumentView.swift:83`) is a one-shot socket `run`. "Run to Selection" and "Run to Breakpoint" just truncate the recipe to a prefix and run that prefix to completion (`recipePrefix`, `DocumentView.swift:159`). The gutter toggle only adds an ID to `editorMetadata.breakpoints`, which only feeds that truncation (`RecipeCanvas.swift:61`). There is no live pause, no step, no continue, no record-from-here, no snapshot-at-pause. The three toolbar buttons and the gutter dot promise a debugger that does not exist.

## Why It Isn't Worth Keeping As-Is

The editor shipped the disruptive parts of the design doc in full — double-click hijacked, record output stranded behind a save dialog, three debugger buttons in the toolbar — and none of the parts that justified the disruption: the run-to-pause/record-from-here debug loop, the parameterization payoff. It took the entire cost and delivered the least valuable slice.

"Worth keeping" means inverting that: remove the friction it introduced, and then either deliver the debug loop that was the whole point, or shrink the editor to the one job it is uniquely good at — letting you see and replay a fresh recording before you decide to keep it.

## Desired Shape

**Finder owns the run path again.** Double-clicking an `.axn` runs it, as it did before the editor. Opening it in the editor is an explicit, opt-in gesture (right-click → Open in Editor, or a menubar item), never the default for the file type. The editor is a tool you reach for, not a tollbooth on every open.

**Stop-recording opens an unsaved review window.** No save panel, no disk write, no Finder trip. The just-captured recording opens directly in an editor window as an unsaved buffer. From there: Replay (validate it on the spot), then Save (choose destination) or Discard. This is the one moment the editor is unambiguously the right surface — you have something fresh and want to confirm it before committing it. This needs a new "open document from in-memory source, unsaved" entry on `AxonDocument`, with `stopRecording` routing there instead of `saveRecording`.

**The app picks one identity.** It is fundamentally a background socket service with a menubar item that *sometimes* shows an editor window. Model it that way: an accessory that promotes to a foreground/dock presence only while an editor window is open and demotes when the last one closes — rather than forcing `.regular` and losing the fight. The socket-service launch must not be a document-app launch; that single decision fixes both the vanishing dock icon (#3) and the past-windows resurrection (#4), because window-state restoration stops firing on every service relaunch.

**The sidebar appears when it has something to say.** Don't render the Inputs panel for a recipe with no args. Default it collapsed for recordings; reveal it when the recipe is actually parameterized.

**Breakpoints are real or they are gone.** Either build the loop the prior doc described — run-to-here-and-pause against the live target, step, continue, record-from-here, snapshot-at-pause — or remove the gutter dot and the two prefix-truncation buttons until that loop exists. Shipping debugger chrome that silently means "truncate and run to completion" is worse than not shipping it: it teaches the user the buttons lie.

## Non-Goals

- **Not a rollback of the editor.** The block-rendered view of a recipe is worth keeping; the problem is where the editor sits in the flows, not that it renders recipes.
- **No raw-yaml editing pane.** Unchanged from the prior doc's non-goals.
- **No back-compat or migration framing.** There are no users; behavior can simply change. Don't scope this around preserving the current double-click behavior for anyone.
- **No new daemon IPC for the basics.** Replay-in-review uses the existing one-shot `run`. The real debug loop, if built, is a separate scoped effort and inherits the prior doc's daemon-coupling plan.

## Resolved Questions

- **Where does an unsaved review window live before Save?** In memory in an editor review window until the user saves or discards it.
- **Is the debug loop in scope here, or its own issue?** It is in scope here, but only with a real paused-session model and an editor surface whose controls map directly to debugger states.
- **What is the explicit "Open in Editor" entry point?** `axon edit <file>` plus the app's explicit editor-opening path.

## Completed Steps

- Restore run-on-open: change the `.axn` `CFBundleTypeRole` away from `Editor`-owns-open, and route a plain double-click through the existing run path. Provide one explicit Open-in-Editor gesture.
- Add an unsaved-document path to `AxonDocument`; route `stopRecording` into a review window with Replay / Save / Discard instead of `saveRecording`'s `NSSavePanel`.
- Decide the activation model and implement it once (accessory ↔ regular tied to editor-window presence); disable document window-state restoration for the service launch.
- Gate the sidebar on the recipe having args; default collapsed for recordings.
- Replace the breakpoint gutter and prefix-truncation toolbar buttons with a real paused debugger session.
- Rework the debugger API around explicit create/resume/run-to/step/set-breakpoints commands and clear cursor/last-action status.
- Move debugger controls into an icon-cluster in-window control strip with help text, keep save/discard separate, and make Reset available after a run.
- Add a navigable live AX Tree sidebar layer for inspecting the app being automated/debugged, backed by lazy direct AX child loading rather than raw pause snapshots.
- Complete the real run-to-pause / record-from-here debug loop, including intentional pause snapshots and failed-block retry.
