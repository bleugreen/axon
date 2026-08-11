# Windows UI Automation spike findings

Tested on `bglab-win` on 2026-08-02. The Rust workspace location is the recommended monorepo shape from AXN-25, but it is not yet settled.

## Interactive desktop access

SSH ran as `bglab-win\mitch` in Windows session 0. `WTSGetActiveConsoleSessionId()` returned 1, and `qwinsta` reported session 1 as the active console session for the same user. Explorer and Edge processes ran in session 1.

UI Automation initialized in session 0, but the desktop root had exactly zero children. The same binary, launched by the user from PowerShell in session 1, enumerated 11 top-level elements. The Windows Axon daemon must therefore start in the logged-in user's session, with remote agents connecting over a named pipe. A service-session workaround is neither needed nor appropriate.

## Crate assessment

The spike uses `uiautomation` 0.25.0. It made enumeration, property access, control-view walking, and typed `InvokePattern` dispatch concise enough to validate the core loop quickly.

Feature selection exposed rough edges. Building with only `pattern` failed because core imports the feature-gated input module. Adding `input` alone then failed because a transitive Windows API feature was not enabled. The supported default feature set compiled, but pulls in more than this spike needs.

For the real daemon, provisionally prefer evaluating direct `windows` crate COM
bindings for Axon's narrow UI Automation surface. They are more verbose, but
would make COM initialization, cache requests, HRESULT handling, timeouts, and
Windows features explicit. This spike did not implement that alternative, so a
direct-binding prototype covering cache requests and timeout behavior is still
needed before making the architectural choice. The wrapper remains useful as
executable reference material.

## Notepad capture

The session-1 run captured 46 nodes from modern Notepad at depth 6, with control type, name, AutomationId, and bounding rectangle. The semantic tree included:

- `Document` / `Text editor`
- tabs with `Tabs`, `TabListView`, `CloseButton`, and `AddButton`
- File, Edit, and View `MenuItem` controls with matching AutomationIds
- named formatting and settings buttons
- cursor position, character count, line-ending, and encoding status text
- title-bar Minimize, Maximize, and Close buttons

First-substring window matching initially selected a terminal title containing “cairn” before the exact app title. The spike now ranks an exact case-insensitive title above a contains match. The real locator scorer must similarly rank exact evidence above partial evidence.

## Invoke dispatch and verification

The locator `control type = MenuItem` plus `name contains = File` resolved the Notepad File menu item. `InvokePattern::Invoke` reported:

    dispatch_success=true

After 500 ms, an independent recapture observed the tree grow from 61 to 91
nodes, evidence consistent with the menu opening:

    verified_outcome=true
    verification=bounded_tree_changed before_nodes=61 after_nodes=91

This proves dispatch and a coarse independent change signal can be represented
separately. Whole-tree inequality does not prove action-specific goal success:
an unrelated UI mutation could satisfy it. Real actions need action-specific
predicates and bounded waits rather than a fixed sleep.

## WebView2 observation

Cairn's exact `cairn` window was reachable, but an unactivated WebView2 subtree was
poor. At depth 12 it contained 23 nodes: native window chrome plus nested anonymous
`Pane` elements. It had no web document, page control, or page text. This confirms
that merely creating a UI Automation client did not activate Chromium renderer
accessibility.

The spike's `--activate-msaa` mode calls `AccessibleObjectFromWindow` for
`OBJID_CLIENT` on the selected top-level HWND and every child HWND, releases each
returned `IAccessible`, and waits 1.5 seconds before the UI Automation capture. All
six queries against Cairn returned an accessible object. At depth 12, the next UIA
capture gained a `Document` named `cairn` with `AutomationId=RootWebArea`. This is
direct evidence that the MSAA touch activated Chromium's renderer accessibility.

The root web document was exactly at the depth-12 boundary, so a depth-30 capture
was necessary to test semantic descendants. That capture contained 49 nodes, of
which 32 had names and three had AutomationIds. Its control-type histogram was:

    Button:13, Document:1, Group:4, MenuBar:1, MenuItem:1,
    Pane:16, Text:11, TitleBar:1, Window:1

The WebView2 subtree included real application semantics:

- `Document` / `cairn` / `RootWebArea`
- `Group` / `Navigation sidebar`
- buttons named `Collapse sidebar`, `Go back`, `Go forward`, and
  `Open command palette`
- project navigation buttons named `Expand project Workspace`, `Workspace`, and
  `Open settings for Workspace`
- page text including `Welcome to Cairn`, `Backend Providers`, `Claude`, and
  `Codex`
- buttons named `Install Claude`, `Install Codex`, and `Continue`

The activation test therefore produced a usable semantic UIA tree without
restarting Cairn or forcing renderer accessibility through a WebView2 environment
variable. AutomationIds remain sparse; activation exposes the identifiers supplied
by Chromium and the page but cannot manufacture developer identifiers absent from
the markup.

The real Windows backend should MSAA-touch the selected target HWND and all of
its descendant HWNDs before capturing WebView2 content. It should then poll UI Automation for the
`RootWebArea` document, within a bounded deadline, instead of copying the spike's
fixed sleep. Capture must also avoid a shallow global depth limit: Cairn's document
started twelve control-view edges below the native window. A targeted subtree walk
or cache request rooted at the web document is preferable once it appears.

Because client-side MSAA activation yielded a usable semantic tree for the tested
Cairn page and runtime, the more intrusive restart-time
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` experiments and an MSAA/IA2 capture
fallback were not necessary. UI Automation is sufficient for this WebView2 runtime
once renderer accessibility is activated.

## Conclusion

The core Windows loop is viable in Rust when it runs in the interactive user
session. UI Automation gives a strong native Notepad tree, locator resolution is
straightforward, and Invoke dispatch can be measured separately from a
post-dispatch state signal. WebView2 also exposes Cairn's semantic page tree after
an MSAA `OBJID_CLIENT` activation touch. The implementation-shaping requirements
are now concrete: the daemon must run per user session, activate Chromium-backed
window subtrees before capture, wait boundedly for `RootWebArea`, and capture deep
enough to reach the web document.


## Binding evaluation: direct `windows` COM

AXN-29 added the experimental `uia-binding-eval` workspace crate and tested
`windows` 0.62.2 directly on `bglab-win` in interactive session 1. The crate
uses an explicit feature set rather than `uiautomation`'s coupled defaults. It
initializes an MTA, configures UIA provider timeouts, performs the proven MSAA
activation, polls for `RootWebArea`, and exposes benchmark, pattern, and event
probes.

### Capture and search measurements

A Cairn `RootWebArea` capture returned 26 descendants (27 nodes including the
root). One interactive run measured:

    FindAll + four Current property reads:       18.230 ms
    FindAllBuildCache + four Cached reads:        9.787 ms
    manual ControlView TreeWalker (no properties): 13.261 ms

The cached path fetched ControlType, Name, AutomationId, and BoundingRectangle in
one build-cache operation and was 46% faster than the equivalent uncached
property path on this small tree. The difference should grow with tree size and
provider-process boundaries. The manual walker number is not directly comparable
because it intentionally reads no properties; it demonstrates that recursion is
already slower than condition-based bulk search before adding property round
trips.

The wrapper's existing bounded depth-30 capture took 1954.954 ms end to end for
49 nodes. That includes its fixed 1500 ms post-MSAA sleep, leaving roughly 455 ms
for capture and printing, so it is code-shape and end-to-end context rather than
a same-workload performance comparison. The wrapper spike has no public bulk
cache path equivalent; a production benchmark must use identical roots, nodes,
properties, and timing boundaries.

A subtle COM semantic matters: the cache request passed to
`FindAllBuildCache` must use `TreeScope_Element` to populate each returned
match. `TreeScope_Descendants` asks for each match's descendants instead;
attempting `CachedControlType` on the match then fails with `E_INVALIDARG`.
Direct bindings expose this precisely, but require tests around cache shape.

`CreatePropertyCondition` plus `FindFirst` found `RootWebArea` during a
bounded poll and found a named Cairn control for pattern testing.
`CreateTrueCondition` plus `FindAll` supplied bulk capture. For known
properties and bounded subtrees this is both clearer and faster than recursive
`TreeWalker`; retain the walker only where hierarchy reconstruction requires
parent/child edges.

### Pattern ergonomics

On Cairn's `Collapse sidebar` control, typed
`GetCurrentPatternAs<T>` calls reported:

    Invoke=true, Value=false, ScrollItem=true
    ScrollIntoView succeeded
    Invoke succeeded

Unsupported patterns arrive as failed typed interface queries and are mapped to
an `Unsupported` operation error when the requested action requires one. Value
set is implemented by the evaluator but was not issued against Cairn because the
chosen control correctly lacked ValuePattern and changing an arbitrary editable
field would be destructive. Value get/set remains a backend integration-test
requirement. Compared with the wrapper, direct pattern dispatch
adds a generic interface query and explicit HRESULT mapping; the resulting code
is still small and makes unsupported-pattern behavior unambiguous.

### Events and threading

A focus-changed handler was registered and removed from an MTA owner thread for
20 seconds while the user clicked in the interactive desktop. Seven callbacks
arrived. One callback ran on the registration thread and six ran on another COM
callback thread.

The daemon must therefore own UIA clients, elements, cache requests, and patterns
on a dedicated MTA thread, but must not assume callbacks run there. Handler
implementations must do no blocking work and no UIA re-entry. They should copy
the minimal event data into owned records and enqueue those records to the
daemon. Registration lifetime and explicit removal remain the owner's
responsibility. Automation-event and structure-changed handlers have the same
generated ownership shape, but live registration and delivery were only
observed for focus changes. The real backend must integration-test all three.

### Timeouts, cancellation, and typed errors

The evaluator queries `IUIAutomation2` and sets both connection and transaction
timeouts to 1000 ms. These are UIA's controls for disconnected or non-responsive
providers, but this evaluation did not have a controlled hung provider and did
not observe their elapsed-time behavior. The `RootWebArea` activation poll has
a five-second operation deadline and checks it between calls. The prototype
does not cancel an individual in-flight COM call. The real backend should
combine these provider timeouts with operation deadlines and cancellation checks
between calls, rather than moving UIA interfaces across worker threads.

The prototype maps element-unavailable HRESULTs to
`ProviderUnavailable`, deadline expiry to `Timeout`, absent patterns to
`Unsupported`, and lookup misses to `NotFound`. Other native failures become
a typed `Native` operation error with the Windows message retained only as
diagnostic detail. No HRESULT is part of the public error category, matching the
cross-platform contract.

### Decision

**Use direct `windows` crate COM bindings for the real Windows backend.**

The decisive reasons are the public `CacheRequest` bulk path, explicit
`IUIAutomation2` timeout control, transparent apartment and callback ownership,
precise typed pattern queries, and freedom from `uiautomation` 0.25.0's default
feature coupling. The direct path is more verbose and unsafe at generated call
sites, but the backend's surface is narrow enough to contain that cost in one
adapter.

That adapter must rebuild the wrapper conveniences deliberately: COM apartment
RAII, exact-then-contains window selection, property and control-type conversion,
cache-request construction, bounded condition search, hierarchy reconstruction,
typed pattern lookup, event-handler lifetime management, and HRESULT-to-domain
error mapping. These are backend policy rather than generic convenience, so
owning them is preferable to accepting a wider wrapper boundary whose caching,
timeouts, features, and threading behavior Axon cannot control.


# Linux AT-SPI spike findings

Tested on `bglab-ub` on 2026-08-03.

## Interactive desktop and session topology

The executor has a real interactive Ubuntu GNOME desktop. `loginctl` reported:

    session 6:   user=dev seat=seat0 type=wayland remote=no active=yes
    session 453: user=dev            type=tty     remote=yes active=yes

The executor command ran in remote TTY session 453, not in the graphical
session. GNOME Shell PID 4357 and `gdm-wayland-session` ran in session 6.
The desktop used `WAYLAND_DISPLAY=wayland-0`; `/run/user/1000/wayland-0`
existed, and GNOME also supplied Xwayland on `DISPLAY=:0`.

Unlike the Windows session-0 boundary, the SSH/executor shell and desktop were
owned by the same uid and user systemd manager. The shell already inherited:

    XDG_RUNTIME_DIR=/run/user/1000
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

It did not inherit `WAYLAND_DISPLAY`, but AT-SPI does not require that display
variable. The user D-Bus owned `org.a11y.Bus`; `GetAddress` returned:

    unix:path=/run/user/1000/at-spi/bus,guid=bdc28049d1addc1f27e9d8df6a6bba08

The matching socket, `at-spi-bus-launcher`, accessibility-bus
`dbus-daemon`, and `at-spi2-registryd` were all live. A daemon launched by
the same user manager can therefore reach this desktop's accessibility bus
directly. A daemon launched as another uid, or without the desktop user's
runtime directory and session-bus address, would not have the measured
topology.

At the start, `org.a11y.Status.IsEnabled=false` and
`ScreenReaderEnabled=false`, despite the AT-SPI bus and registry running.
The registry still listed four native application roots before any spike apps
were launched.

## Crate assessment

The spike uses `atspi` 0.30.0 with its `connection`, `proxies`, and
`tokio` features. This is the current pure-Rust, zbus-based facade over
`atspi-connection`, `atspi-proxies`, and `atspi-common`. It was preferable
to handwritten zbus calls for the spike because the generated proxies encode
AT-SPI object-reference pairs, interface names, enum wire values, and the
Action/Component method signatures while retaining direct access to the zbus
connection.

The API was concise for connecting, obtaining application roots, walking
children, reading role/name/state/text, acquiring optional Component and
Action interfaces, and dispatching `DoAction`. Calls are still individual
D-Bus round trips. The production backend must evaluate AT-SPI cache and
Collection paths, bounded per-provider calls, stale object references, and
embedded-application peers rather than copying this breadth-first probe.

## Native capture

With accessibility status enabled, GNOME Calculator exposed a bounded tree of
107 nodes at depth 20. The capture included role, name, states, screen-coordinate
extents when Component was available, and text when Text was available. It
contained:

- an application root and `Calculator` window;
- editable and read-only text boxes;
- digit, arithmetic, clear, backspace, history, and window controls;
- named digit buttons `0` through `9`;
- state flags such as Focusable, Sensitive, Showing, Visible, Editable, and
  ReadOnly.

Observed full 107-node capture times varied from 582.028 ms to 1042.612 ms.
The verified action run measured 671.931 ms before dispatch and 686.264 ms
after dispatch. This sequential property-by-property walker is evidence of
correctness, not a performance design: each node can incur children, role,
name, state, interface, Component, and Text D-Bus calls.

A geometry sharp edge appeared under GNOME's Wayland session. Cairn's GTK3
native shell returned plausible absolute rectangles, including a
`1252x899` frame and title-bar buttons. GNOME Calculator's GTK4 tree returned
the correct sizes but `(0, 0)` for nearly every descendant. AT-SPI Component
geometry therefore cannot yet be assumed to provide usable screen positions
for pointer targeting on this stack.

> **Settled 2026-08-10.** This is a toolkit fact, not a compositor one, and it is
> now measured against ground truth rather than inferred from one application.
> `scripts/linux-toolkit-acceptance/` has each target report its own widget
> rectangles from inside the toolkit and compares them with what AT-SPI publishes
> for the same widgets. On X11, GTK 3, Qt 6, WebKitGTK and Chromium agree with
> AT-SPI to the pixel; GTK 4 reports correct sizes at `(0, 0)` origins, exactly as
> recorded here. A GTK 4 target therefore has no usable AT-SPI coordinate source
> for pointer targeting under either session type, and needs a different position
> source if it is ever to have one.

## Action dispatch and independent verification

The locator `role=button, name contains=1` resolved Calculator's `1` button.
Its Action interface reported:

    Action { name: "Click", description: "Clicks the button", keybinding: ";;" }

The probe resolved the reported `Click` action by name (index 0 for this control) and
`DoAction(0)` returned:

    dispatch_success=true

After 500 ms, a new bounded capture still contained 107 nodes but the editable
text object's content had changed:

    before text="1"
    after  text="11"
    verified_outcome=true

This is action-specific evidence that AT-SPI dispatched a real control action
and the application processed it. It is stronger than node-count or whole-tree
inequality alone. The executable exits unsuccessfully if dispatch is rejected, no Click/Activate
action exists, or the explicitly expected before/after values are not observed
on the same AT-SPI object reference. A final hardened-probe run verified
`"111"` to `"1111"` on Calculator object
`/org/gnome/Calculator/a11y/a6c5a1b4_fe9b_4a78_9414_0085d7c09a7c`. Dispatch success and observed outcome remain separate facts;
the real backend needs a bounded, action-specific postcondition rather than
the spike's fixed delay.

## Cairn WebKitGTK activation observation

The installed desktop Cairn is a GTK3/WebKitGTK 4.1 application. Launched with
accessibility disabled, it exposed 14 nodes: application, frame, native layout,
title, and Minimize/Maximize/Close controls. No web document, page text, or web
controls appeared.

The following activation attempts all left the capture at the same 14 native
nodes, including at depth 30 and a 1000-node bound:

1. set `org.a11y.Status.IsEnabled=true` while Cairn was running and wait three
   seconds;
2. restart Cairn with `ACCESSIBILITY_ENABLED=1` while IsEnabled was true;
3. set both `IsEnabled=true` and `ScreenReaderEnabled=true`, then restart
   with `ACCESSIBILITY_ENABLED=1`.

During traversal after activation, the client repeatedly reported:

    Failed to create peer for Some(":1.19"): Invalid address string

The honest result is that WebKit activation was **not proven**. The evidence
suggests that the native tree contains an embedded WebKit AT-SPI peer which
the current `atspi` connection path fails to follow because `:1.19` is a
D-Bus unique name, not a complete bus address. The follow-up backend work must
investigate AT-SPI Socket/Plug peer connections and compare against libatspi
before deciding whether this is an `atspi` crate limitation, a WebKitGTK
provider defect, or missing peer-address discovery. The three flags above
must not be presented as a working activation recipe for this runtime.

## Wayland evidence

Semantic AT-SPI capture and Action dispatch worked from the non-graphical SSH
session without X11 or Wayland input access. That establishes that ordinary
control actions should prefer AT-SPI interfaces over synthesized pointer
events.

The desktop is GNOME Shell/Mutter on Wayland. Its session D-Bus advertises
`org.gnome.Mutter.RemoteDesktop`, `org.gnome.Mutter.ScreenCast`, and the
freedesktop desktop portal. Those are evidence for portal/compositor-mediated
pointer and screenshot paths; they are not proof that Axon can use them
unattended. The spike did not synthesize a pointer or capture a screenshot.
Together with Calculator's unusable descendant origins, this leaves the
pointer and screenshot question open and makes an X11-style global-coordinate
fallback inappropriate to assume.

## Conclusion

The Linux core loop is viable in Rust on the real Ubuntu executor: a daemon
running as the desktop user can connect from an SSH-originated process to the
user's AT-SPI bus, capture a bounded semantic native tree, invoke a real Action,
and verify the application-specific effect by recapture.

The implementation-shaping facts are now concrete: run in the desktop user's
D-Bus/runtime context, treat capture as asynchronous cross-process work,
optimize beyond sequential property calls, keep semantic actions separate from
Wayland pointer mechanisms, and explicitly solve embedded WebKit AT-SPI peer
traversal before claiming web-content support. The spike intentionally does
not implement `PlatformBackend`.


## WebKitGTK embedded-peer traversal

Follow-up testing on `bglab-ub` on 2026-08-04 resolved the unproven WebKitGTK boundary. With Cairn running under the activation conditions already described above, the original `atspi` facade walk still captured exactly 14 native nodes. A libatspi 2.60.4 walk through the GObject introspection `Atspi.get_desktop` API captured 39 nodes from the same application. Its tree crossed from the GTK socket into a WebKit scroll pane and a `document web` named `cairn`, then exposed 22 semantic descendants including `Collapse sidebar`, `Navigation sidebar`, `Welcome to Cairn`, `Backend Providers`, `Claude`, `Codex`, `Install Codex`, and `Continue`.

The boundary is a same-accessibility-bus plug/socket handoff, not a separate D-Bus transport. GTK object `/org/a11y/atspi/accessible/2` implements `org.a11y.atspi.Socket`. Its `org.a11y.atspi.Accessible.GetChildren` reply contains a pair whose first field is a WebKit well-known bus name and whose second field is an `/org/a11y/webkit/accessible/...` object path. The well-known name resolves through `org.freedesktop.DBus.GetNameOwner` to the WebKit web process's unique name. Subsequent `org.a11y.atspi.Accessible`, `Component`, and `Text` calls succeed when sent to that unique destination over the existing `unix:path=/run/user/1000/at-spi/bus` connection.

`axon-spike-linux --same-bus` encodes that mechanism. It decodes `GetChildren` as an unconstrained string/object-path pair, resolves well-known destinations through the accessibility bus daemon, constructs the remaining proxies with an explicit destination, and never treats a unique name as a socket address. The Rust walk then captured the same 39 nodes as libatspi in 387.908 ms, compared with 14 nodes in 122.049 ms for the facade path in adjacent runs. The successful Rust tree contained the WebKit document, all semantic controls listed above, text, states, and plausible screen rectangles.

This exposes two coupled `atspi` 0.30.0 sharp edges. Its object-reference model requires a D-Bus unique name even though WebKit's socket child reply uses a well-known name, so generated `GetChildren` cannot represent the boundary reply. Separately, peer initialization calls WebKit's `GetApplicationBusAddress`, receives a same-bus unique name such as `:1.4`, and attempts to parse that name as a transport address, producing `Invalid address string`. The initialization warning can still be printed in `--same-bus` mode, but traversal no longer depends on the failed peer entry. The real backend should preserve this explicit-destination path, cache well-known-name resolution with owner-change invalidation, and test stale web-process references.

The activation dispatch and traversal outcome remain separate facts. Setting the accessibility status and launching with `ACCESSIBILITY_ENABLED=1` preceded this successful capture, but this experiment did not isolate which activation input is necessary. What is proven is the observed outcome: under those conditions both libatspi and the Rust same-bus path captured the 39-node web-content tree. This does not retroactively establish any individual flag as a sufficient activation recipe.

### Correction, 2026-08-08

The `Invalid address string` warning above was attributed to WebKit returning a same-bus unique name from `GetApplicationBusAddress`. Live diagnosis on `bglab-ub` for AXN-81 found a different cause. `atspi`'s peer initialization asks *every* registry application for a bus address, and the failure came from a participant that answers with an empty string rather than from WebKit and rather than from a unique name. Asking each peer directly returned real `unix:path=.../at-spi2-*/socket` addresses for `gnome-shell`, `evolution-alarm-notify`, `ibus-extension-gtk3`, `gjs`, and `xdg-desktop-portal-gtk`, and `""` for `orca`, the screen reader. The unique name in the message is the *application's* name, not the address it returned, which is what made the earlier reading plausible.

The traversal conclusion is unaffected and now stronger: explicit destinations over the shared accessibility-bus connection remain the mechanism, and the production backend opens that connection itself instead of through `AccessibilityConnection`, so peer initialization never runs at all. The failing peer was never missing from capture either — the daemon enumerates and captures `orca` exactly as it does every other registry child, and a screen reader's complete tree is a bare application root with no children.


## Chromium-family activation on Linux, 2026-08-08

Run on `bglab-ub` for AXN-84, to settle a claim `docs/cross-platform.md` had been
carrying without evidence: that Chromium and Electron withhold their trees until
an AT-SPI listener registers, making registration part of backend readiness. The
claim is wrong in both halves, and what replaces it is two separate gates.

The desktop could not answer the question. It runs Orca with
`org.a11y.Status.IsEnabled` already true, so every Chromium tree on it is awake
for reasons unrelated to Axon. Each application under test was therefore given a
private session bus, a private accessibility bus, and a private registry, with
`GSETTINGS_BACKEND=memory` so `at-spi-bus-launcher` could not write
`toolkit-accessibility` into the real user's dconf. Every phase also read the
desktop's own bus, so an application that woke up somewhere else could not be
misread as one that never woke up. That check earned its place: `libatspi`
consults the X root window's `AT_SPI_BUS` property before the session bus, so an
application on the desktop's display joins the desktop's accessibility bus
unless `AT_SPI_BUS_ADDRESS` is exported, and the first run of this probe was
measuring the wrong bus without saying so.

Subjects were Electron 33.2.1 (Chromium 130) and Chrome for Testing
151.0.7922.77, each a self-contained download rather than an installed package,
run against a page carrying known markers.

| condition | result |
| --- | --- |
| `IsEnabled` false, no listener | application absent from the bus |
| `IsEnabled` false, listener registered, application already running | absent; `IsEnabled` unchanged |
| `IsEnabled` false, listener registered, application relaunched | still absent |
| `IsEnabled` set true while the application runs | no effect on that application |
| `IsEnabled` true at startup, no listener | application, window, and the null reference: 3 nodes |
| `IsEnabled` true at startup, listener registered | identical, 3 nodes |
| the above, then `GetAttributes` or `GetRelationSet` on the application root | Chrome 284 nodes after 1.12s, Electron 26 nodes after 0.09s, both with `document web` |
| `--force-renderer-accessibility` (application-side flag) | full tree with no client action |

GNOME Calculator, a GTK4 provider, registered on the bus with `IsEnabled` false,
so the first gate is specific to the Chromium family rather than a property of
the session.

The mechanism behind the second gate is named in Chromium's own source:
`AtkRefRelationSet` and `AtkGetAttributes` both call
`AXPlatform::OnExtendedPropertiesUsedInWebContent()`, commented as a signal that
Orca in particular produces. One `GetAttributes` on the application root is
enough; the window does not need to be touched.

The listener folklore has a real source. Upstream `at-spi-bus-launcher` has
grown a handler that flips `IsEnabled` when a client registers an event
listener, which would let registration reach the first gate indirectly — and
would also write the desktop's `toolkit-accessibility` setting as a side effect.
The 2.60.4 build on this stack contains no such handler (`strings` finds
`toolkit-accessibility` and no `EventListenerRegistered`), and even where it
does, the second gate is untouched by it.

Through the daemon rather than the raw probe, `look Chrome` answered `operation
accessible proxy failed: atspi: null reference` before AXN-84, because
`/org/a11y/atspi/null` implements no interfaces and the walk asked it for a role.
After AXN-84 the same capture returned 284 nodes including the web document, and
GNOME Calculator still returned 107 nodes at unchanged latency, since a provider
that publishes its tree is never asked to.

### Re-running this

The rig is four pieces and no installed software beyond the desktop's own:
start `dbus-daemon --session --print-address --fork` with a private
`XDG_RUNTIME_DIR`; start `/usr/libexec/at-spi-bus-launcher --launch-immediately`
against it with `GSETTINGS_BACKEND=memory`; export `AT_SPI_BUS_ADDRESS` for the
application under test so the X property cannot redirect it; then drive
`org.a11y.Status.IsEnabled`, `org.a11y.atspi.Registry.RegisterEvent` (held open
by a live connection, since the launcher watches the sender's name), and
`org.a11y.atspi.Accessible.GetAttributes` while walking
`/org/a11y/atspi/accessible/root`. Re-date the claim in
`docs/cross-platform.md` when the backend area or the browser generation changes.


# macOS ApplicationServices spike findings, 2026-08-10

Tested on `bglab-mac` against Calculator on macOS from the SSH-originated Cairn executor session. The probe is `rust/axon-spike-mac`; it links ApplicationServices and CoreFoundation directly and declares only the AX and Core Foundation C functions it uses. It has no wrapper-crate or Objective-C dependency and does not implement `PlatformBackend`.

## Verdicts

1. **AX capture from Rust: viable.** A direct `AXUIElementCreateApplication` / `AXUIElementCopyAttributeValue` walk captured Calculator's real semantic tree. The bounded full application walk returned 201 nodes in 136.109 ms. It included the application, the 35-node window subtree, and 165 menu-bar descendants. The installed 0.2.3 Swift daemon's adjacent `look Calculator --json` returned exactly the same 35-node window subtree; it deliberately starts at `AXWindows` and omits the application and menu bar. Roles, hierarchy, names, and the displayed `AXStaticText` value `U+200E + "0"` agreed, including all 20 keypad buttons, toolbar controls, and window controls. A subsequent full Rust capture took 105.326 ms. These are correctness measurements from an unoptimized sequential walker, not a production latency target.
2. **One real action from Rust: viable and independently verified.** The probe resolved `role=AXButton, name contains=1`, called `AXUIElementPerformAction(..., "AXPress")`, and received `kAXErrorSuccess` (0). After 500 ms, the retained Calculator display element that held `U+200E + "0"` before dispatch held `U+200E + "1"`. The measured run reported `verified=true`; dispatch, wait, and readback took 594.128 ms. The hardened probe requires exactly one before-value element, rejects an after value already present before dispatch, and reads the after value from that same retained AX element. It exits unsuccessfully if any condition fails.
3. **TCC grant carry for a Rust main executable: mechanically supported, but the Developer ID case remains unproven in this session.** The installed app has bundle identifier `com.bleugreen.axon`, Team ID `JBS95V8M7P`, and the stable Developer ID designated requirement recorded below. Its existing bundle-keyed Accessibility and Screen Recording rows remain `client_type=0, auth_value=2`, and `axon health` reports both granted. A Rust build could not be signed to that requirement over SSH: the identity was visible, but `codesign` failed with `errSecInternalComponent`, re-confirming AXN-39 and AXN-93. Therefore this spike does **not** claim that a newly built Rust main executable carried the real grants. The residual is one release/CI measurement: sign a bundle whose unchanged identity is `com.bleugreen.axon` and whose Rust binary is `CFBundleExecutable`, verify it satisfies the requirement below, launch it from a new path, and confirm both preflights are granted with zero TCC-row change.

    designated => identifier "com.bleugreen.axon" and anchor apple generic
      and Developer ID intermediate and Developer ID Application leaf
      and certificate leaf[subject.OU] = JBS95V8M7P

Direct bindings are the recommendation. The exercised surface is small, the ownership rules are visible, and no wrapper demonstrated compensating value. One bug found while hardening the spike is worth carrying forward: values returned from AX arrays are borrowed. Queued elements and retained action targets must be `CFRetain`ed before the source array is released. Failed attribute calls must also not construct an owning wrapper around null.

## TCC measurements and session attribution

The first direct run of the ad-hoc `com.bleugreen.axon.spike109` bundle returned only a blank application placeholder, one node in 20.948 ms, behavior consistent with an untrusted Accessibility client. The probe discarded raw AX errors and did not call `AXIsProcessTrusted`, so this run alone does not prove TCC denial rather than another AX failure. After desktop approvals during the session, the same unchanged executable captured 201 nodes. No `com.bleugreen.axon.spike109` row was created, while new Terminal and sshd-keygen-wrapper rows appeared during approval. That sequence is strong evidence consistent with macOS assigning responsibility to command hosts, but the spike did not inspect audit tokens or responsible-process metadata and therefore does not claim direct attribution proof.

The rows relevant to Axon after the measurement were:

    kTCCServiceAccessibility|com.bleugreen.axon|0|2|csreq 160 bytes
    kTCCServiceAccessibility|com.bleugreen.axon.issue93|0|0|csreq 40 bytes
    kTCCServiceScreenCapture|com.bleugreen.axon|0|2|csreq 160 bytes

That filtered set was unchanged at three rows: the spike added zero `com.bleugreen.axon*` rows and zero Screen Recording rows. The broader recent Accessibility query showed two approvals made during this session:

    kTCCServiceAccessibility|com.apple.Terminal|0|2|csreq 48 bytes
    kTCCServiceAccessibility|/usr/libexec/sshd-keygen-wrapper|1|2|csreq 60 bytes

Those two rows are granted strays, not denied strays and not part of Axon's intended identity. They are removable with the minus button in System Settings. The pre-existing AXN-93 rows remained, including `com.bleugreen.axon.issue93|0|0` and the path-keyed issue-93 helper row. Test artifacts were `/private/tmp/AxonSpike109.app`, `/private/tmp/AxonSpike109-devid.app`, and `/private/tmp/axon-spike109-*.txt`.

This result sharpens the TCC acceptance rule: merely placing a Rust executable at a bundle's main-executable path is insufficient evidence. The process must be attributed to that bundle and satisfy the existing row's code-signing requirement. An ad-hoc signature has a cdhash designated requirement and cannot model Developer ID upgrade carry.

## Extended capability feasibility

The unimplemented convergence surface remains feasible through direct system APIs, but was not exercised here:

- `observeChanges`: `AXObserverCreate`, notification registration, and a CFRunLoop source; production work must make callback lifetime, run-loop ownership, and stale-element handling explicit.
- `observeGlobalInput`: `CGEventTapCreate` plus a run-loop source; this remains subject to Input Monitoring/TCC behavior and tap-disable recovery.
- `serializeHistory`: feasible in Rust once the observer and global-input event streams feed the core's history model; serialization itself is an Axon concern rather than a separate macOS provider API.

## Machine health and cleanup note

The LaunchAgent registration was never changed and no daemon install command was run. The installed app main executable was never invoked with CLI arguments. At the end of measurement, `axon health` reported version 0.2.3, `ready=true`, graphical and interactive session true, Accessibility and Screen Recording granted, and every advertised capability usable, including `observeChanges`, `observeGlobalInput`, and `serializeHistory`. `axon doctor` reported `Accessibility: trusted`.

The requested literal check, `axon status --json`, did **not** produce JSON on installed 0.2.3; it printed `Axon.app: running`, `Socket: /tmp/axon.sock`, and `Accessibility: unknown`. The machine is healthy according to the daemon's machine-readable `health` response, but the status command's ignored `--json` flag and unknown permission display are a separate CLI defect and must not be reported as passing.


### Cleanup verification, 2026-08-10 20:42 EDT

Scoped `tccutil reset Accessibility <client>` removed the bundle-keyed Terminal row and found no spike-bundle row, but neither the bundle-like name nor the exact path could remove the path-keyed `/usr/libexec/sshd-keygen-wrapper` row. **`tccutil reset` cannot address this `client_type=1` row on this machine.** With explicit authorization, the database was backed up first to:

    /Library/Application Support/com.apple.TCC/TCC.db.axn109-20260810-2042.bak

An exact pre-delete query matched one row and only one row:

    service=kTCCServiceAccessibility
    client=/usr/libexec/sshd-keygen-wrapper
    client_type=1 auth_value=2 auth_reason=4 auth_version=1
    csreq=FADE0C000000003C0000000100000006000000020000001D636F6D2E6170706C652E737368642D6B657967656E2D7772617070657200000000000003
    policy_id=NULL indirect_object_identifier_type=0
    indirect_object_identifier=UNUSED indirect_object_code_identity=NULL
    flags=0 last_modified=1786408390 pid=NULL pid_version=NULL
    boot_uuid=UNUSED last_reminded=1786408390

The delete used the identical two-column predicate, `tccd` was restarted, and the post-delete count was zero. Three pre/post fingerprints over every `com.bleugreen.axon%` row were byte-identical (`pre=3 post=3 byte_identical=true`). The Terminal, sshd-keygen-wrapper, and spike-bundle Accessibility rows are all absent. All throwaway bundles and output files were removed. The dated TCC backup remains intentionally for rollback. After cleanup, `axon health` again reported `ready=true`, both permissions granted, and all 15 capabilities usable. `axon status --json` still exhibited the separate non-JSON / `Accessibility: unknown` defect described above.
