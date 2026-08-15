# Axon Decision Log

## Transport

Decision: Axon should be daemon-first.

A long-lived service is needed for observer state, cache invalidation, and "user changed X since last checked" behavior. Use one binary with multiple modes instead of multiple installable components:

```text
axon serve
axon doctor
axon look <app>
axon mcp
```

The daemon should own the persistent state. The MCP facade can speak to the daemon through JSON-RPC over a local Unix domain socket if stdio compatibility is required.

## Daemon Socket Protocol

Decision: Use JSON-RPC first.

JSON-RPC is simple, debuggable, and maps cleanly to request/response commands without inventing a bespoke protocol. It is also neutral enough that the daemon protocol can stay separate from MCP transport details.

One connection carries one request and one response, and no client's failure is the daemon's. A client may vanish before it asks anything, halfway through asking, or between asking and hearing the answer; each of those ends that connection and nothing else. A daemon serves a whole desktop session, so an outage for everything else on it is far too much to pay for one abandoned socket. A request that was received and carried out keeps its effect even when the answer cannot be delivered, which is why a `shutdown` whose caller walked away still stops the daemon.

## Wrapper Strategy

Decision: Prefer direct `ApplicationServices` unless a spike proves AXSwift saves enough work to justify the dependency.

Direct `ApplicationServices` is more verbose, but not a large conceptual expansion. The additional work is mostly typed wrappers, error normalization, and attribute/action helpers. The project complexity still lives in daemon lifecycle, snapshots, locator scoring, screenshots, observers, and action verification.

Working estimate: AXSwift may save early boilerplate, but direct APIs likely add days, not weeks, and reduce long-term dependency risk.

## Screenshot Support

Decision: Screenshots are required.

Snapshots and screenshot tools should return embedded image data. Screenshots are needed for coordinate fallback, visual debugging, and human inspection of failures. File output can be added later as a CLI/debug convenience, but embedded responses are the primary API.

## App Identity

Decision: Keep app identity simple at first.

The first version should list running apps and resolve apps by bundle id, name, and pid. Recently used app tracking is not important enough to justify extra persistence or LaunchServices complexity yet.

## Locator Schema

Decision: Locators should be AX-native, honest, and intuitive.

Borrow useful ideas from browser automation only where they map cleanly. Do not force Playwright concepts onto macOS Accessibility if they hide important constraints.

## Action Batches and `.axn` Files

Decision: composable automation is an invocation-scoped batch of normal tool calls, not a separate plan language.

The daemon should remain a stable local accessibility service. It can execute a submitted multi-step batch because that is just composition over its primitives, but it should not own a persistent recipe registry, cache, or app-specific workflow pack. Reusable batches live on disk as `.axn` files beside the codebase or task context that gives them meaning, and are passed to the daemon by path or source.

A batch is a flat list of `{ tool, ...args }` objects using the same shape as the standalone tool calls. Earlier sketches included a richer plan language with `if`, `wait_until`, `repeat_until`, `assert`, and bound outputs. That language has been removed: if a missing capability is needed for composition, the right move is to add it to the underlying tool set so that batches stay a flat sequence of real tool calls. Two ways of doing the same thing is worse than either one alone.

YAML is the preferred on-disk format for `.axn` files because it is compact and easy to edit. JSON-RPC remains the daemon transport, and structured JSON batch objects remain acceptable when a caller already has data in memory.

## Scroll Strategy and Dispatch Reporting

Decision: `scroll` picks its strategy from the kind of target the caller named, and a dispatched wheel is a success.

A point is a pointer-space instruction, and a scroll wheel is the pointer-space mechanism, so a point target posts `CGEventScroll` at that point and never consults the accessibility tree. A handle, locator, or bare app names something semantic, where `AXScrollToVisible` is more precise and is immune to window occlusion — a wheel posted at a point routes to whichever window is topmost there, which may not be the app that was named. So accessibility stays primary for named elements, and the wheel covers the case where the tree offers no scrollable descendant. This is a rule about the target, not a fallback chain: trying accessibility first for a point target only produced failures on surfaces that render their own contents, because the tree cannot answer a question about pixels.

`scroll` reports `success: true` once wheel events are dispatched, alongside `dispatchSuccess: true` and `semanticStatus: "unverified"`. `drag` fails closed in the same situation because a drag mutates state, and an unverified mutation is a claim that should not be made. A scroll only moves a viewport, and its real effect is implicitly checked by whatever the next action targets, so it reports the dispatch honestly in `semanticStatus` rather than as a failure. Keeping `success: true` also leaves `.axn` replay behavior unchanged, since the runner halts on `success: false` for every tool except `drag`.

Activation follows the same reasoning and is therefore scoped to the wheel rather than to the presence of an `app` argument. A wheel needs the target window raised because it lands wherever the topmost window is; `AXScrollToVisible` does not, so activating for it would take the user's focus to no purpose. `dispatchSuccess` is likewise never claimed without events: a zero delta is a no-op that reports `semanticStatus: "noop"`, and a delta that rounds to no whole pixel fails rather than reporting a dispatch that moved nothing.

`scroll` does not activate the app it was given, and this reversed an earlier decision to match `drag`. The argument for activating was that a wheel lands on whichever window is topmost under the point, so an occluded target window would swallow it. Measurement did not support the premise being worth its cost: a posted wheel reached the intended window in every trial across cursor positions and frontmost applications, so activation changed nothing except taking the user's focus on every scroll. `drag` still activates because a drag presses and moves the pointer, which is a mutation whose target must be unambiguous. The residual risk is named rather than hidden: a point covered by another window scrolls what is on top of it.

`dispatchSuccess` is likewise never claimed without events. A zero delta is a no-op reporting `semanticStatus: "noop"`, and a delta that rounds to no whole pixel fails rather than reporting a dispatch that moved nothing.

Which descendant the accessibility rung presses is decided by the advertised action list, not by geometry alone. An element that does not advertise `AXScrollToVisible` cannot perform it, so it is not a candidate however well the delta places it; eligibility filters before ranking rather than breaking its ties. Only a *proved* absence disqualifies: an action list that could not be read is not evidence about the element, and an accessibility query fails transiently often enough — a busy application, an element mid-teardown, a timed-out round trip — that reading silence as a negative would convert those faults into wheel bursts, trading the rung that cannot disturb the wrong window for the one that can. Such a candidate is kept, and the action sent to it answers the question for itself. `click` reads a failed query the opposite way, and deliberately: its semantic rung is an optimization over a pointer press it can always fall back to, while for `scroll` the accessibility rung is the safe one. Measurement is what settles this: Music exposes twelve `AXList` elements advertising the action and Mail one `AXScrollArea`, while Finder, Notes, TextEdit, and System Settings expose none anywhere in their trees. Selecting on placement alone therefore chose an ordinary `AXRow` in Finder and made the app unscrollable by handle, locator, or app target, while deleting the rung outright would regress the apps where it is available, more precise, and immune to occlusion.

An action reported as unsupported is not a refusal, and the difference decides whether the wheel runs. `actionUnsupported` and `attributeUnsupported` mean the element advertised a mechanism it does not implement: nothing declined the scroll because nothing was ever asked to decide, so the wheel rung below is still owed its attempt. Every other `AXError` is the app answering, and a scroll it answered badly is a failed scroll rather than a reason to send global input at the same coordinates. The wheel that follows is aimed at the center of the element the caller named, not at the ranked descendant, so no pointer event is ever posted at an offscreen coordinate; the occlusion risk is the same one the no-descendant fallback already carries.

The consequence to be honest about: the two strategies interpret the delta differently. The wheel honors the documented pixel distance; `AXScrollToVisible` cannot, because the app decides how far to move to reveal the chosen descendant. Unifying that is a tool-vocabulary change, not a bug fix.

## Release Signing

Decision: sign Windows release binaries with Azure Artifact Signing, using a GitHub OIDC federated
credential.

Signing a Windows binary is usually filed under polish — the SmartScreen warning a user clicks
through on first launch. For Axon it is load-bearing, because an automation daemon is structurally
indistinguishable from malware to a behavioral classifier: it registers a scheduled task, relaunches
itself into the interactive session, and serves a pipe. Judged on behavior alone, an unsigned build
is judged badly. Two measurements on the Windows lab machine settled this. Defender's
block-at-first-sight held a freshly built `axon-win.exe` for about 47 seconds before its first
instruction ran, waiting on a cloud verdict for a file it had never seen — the daemon's own stage
log showed 1.46 seconds from process start to ready, so the entire delay preceded the process. And
Defender's machine-learning behavioral detections quarantined an unsigned build outright, mid-run.
A signature does not argue that the behavior is benign; it makes each build another artifact from a
publisher already known rather than a new unknown file, which is the input those systems actually
weigh.

A machine-level antivirus exclusion fixes the lab and nothing else. Every consumer installing Axon
meets the same first-seen friction on their own machine, which is why the exclusion is an operator's
convenience and signing is the deliverable.

Azure Artifact Signing was chosen over the alternatives on operational grounds rather than
technical ones. A hardware OV/EV token means PIN automation in CI and a physical dependency in the
release path. SignPath's open-source tier is free but slower to onboard and issues a certificate
named for the sponsoring foundation rather than the publisher. Azure issues short-lived
certificates from a managed service, which is why every signature must be timestamped: without one
the signature outlives its certificate by days rather than years. Authentication is a federated
OIDC credential scoped to a GitHub environment, so the release path holds no signing secret at all.

macOS already had the equivalent — Developer ID plus notarization — and Linux has no comparable
desktop trust check, so the checksum remains the whole story there.

## Window-less Observations

Decision: an observation states the absence of a window with `note: "no-windows"`, and macOS
capture keeps the application's menu bar in the tree rather than returning nothing.

Field evidence from a 0.3.5 daemon: `look(app: "Safari")` with no Safari window open returned a
tree holding only the menu bar and a 1280x15 screenshot. Every fact in that response was true, and
the one that mattered was unsaid. The agent reading it had to infer "no window is open" from two
absences — no window entry, and a screenshot height too small to be a window — which is the kind of
inference that works until it doesn't.

The tree cannot carry this by itself, and that is the point. Capture falls back to the application's
children when `AXWindows` is empty, so the menu bar becomes a tree root and the snapshot's window
list claims one window that is not one. Keeping that chrome is deliberate rather than accidental:
File > New Window is native, unambiguous, and the recovery path a caller needs precisely in this
state, so removing the root to make the count honest would delete the useful half of the response.
The honest count therefore comes from asking the application directly — `AXWindows`'s value count on
the application element — and is carried on the snapshot as `windowCount`, independent of whichever
capture strategy chose the roots. `windowCount == 0` is what emits the note.

`note` was chosen over a `windows: 0` count because the vocabulary already exists: `look(since:)`
fallbacks carry `note: "baseline-expired"` and `note: "diff-exceeded-threshold"`, stable kebab-case
statements about a response as a whole. A second count field would also have sat awkwardly beside
the Rust envelope's `app.windows` array, which is the same fact in a different shape. One key, one
vocabulary, both surfaces: the note rides on the snapshot itself, so socket clients and `format:
"debug"` see it, and the compact observation envelope copies it up for MCP and CLI callers.

The reach is uneven across backends, and that is recorded rather than smoothed over. The Swift and
Rust macOS backends both produce a window-less observation and both state the note. The Windows
backend roots capture at a matched top-level window and refuses an application that has none, so it
never reaches the state. The Linux backend roots capture at the AT-SPI application object and
presents it as one window whether or not a frame is open, so its window count is never zero. Making
those two answer the same question is a change to what each backend calls a window, which is a
larger piece of work than stating a fact the macOS backends already know.

## Deferred Design Notes

These are not blocking questions. They are details that should be decided when implementation reaches the relevant layer.

- Protocol versioning and compatibility should be designed when the JSON-RPC message schema starts to stabilize.
- Fixture app design should be chosen when integration tests begin, aiming for the best coverage through simplicity: small enough to reason about, rich enough to exercise real AX behavior.
