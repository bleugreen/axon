# Cross-platform Axon design

Axon runs on macOS, Windows, and Linux: one canonical Swift implementation on
macOS, and a sibling Rust workspace carrying the Windows UI Automation and
Linux AT-SPI2 backends. All three implement the same
[platform-neutral contract](platform-spec.md), rather than sharing runtime
code or pretending the operating systems expose one normalized accessibility
API.

What each environment can actually prove today is recorded in the
[support matrix](#support-matrix) below. Everything after it is design and
mechanism; the matrix is the claim, and the rest is the how.

## Support matrix

This matrix separates what is proven from what is implemented or merely
expected. A cell earns **Supported** only from canonical live evidence —
named in the cell or its environment note — that exercises application- or
desktop-owned state: a real application's accessibility tree, a real
foreground window, a real X server. Anything less is labeled honestly.

### Tiers

| tier | meaning |
| --- | --- |
| **Supported** | Canonical live evidence backs the claim today: a check in the `Test` or `Live desktop verification` workflow, or a dated probe run recorded in this document or `rust/SPIKE-FINDINGS.md`. |
| **Supported with limits** | Supported, with a named restriction that is itself part of the verified behavior — an allowlist, a permission gate, a session boundary. |
| **Experimental** | Implemented, or strongly expected from design and unit evidence, but with no canonical live verification. The note names what would promote it. |
| **Refused** / **Not implemented** | An explicit gap, not a tier. The backend declines the capability by name at runtime rather than pretending, and the cell records that. |

"Canonical live evidence" is deliberately narrow. Unit tests with fakes prove
decision logic, not delivery: they cannot show that a compositor accepted a
client message or that a window procedure acted on one. Daily use through
Cairn's executor is encouraging, but it cannot be re-run from this
repository, so it does not promote a cell.

### The matrix

The pointer and keyboard columns describe synthetic-input delivery; the
semantic rung never moves the real pointer or posts global keys. Rungs are
defined in [`platform-spec.md`](platform-spec.md) and the per-action ladders
in the [delivery matrix](#delivery-matrix) below.

| environment | semantic delivery | pointer | keyboard | screenshots | coordinates | required helpers |
| --- | --- | --- | --- | --- | --- | --- |
| macOS 14+ (Aqua) | **Supported** — live loop verifies `invoke` (`AXPress`) against Calculator's display | **Experimental** — `CGEventPostToPid` pixel and the CGEvent foreground transaction are unit-verified only | **Experimental** — same evidence state as pointer | **Experimental** — ScreenCaptureKit, gated on the Screen Recording grant; no live capture probe | **Experimental** for pointer dispatch — AX frames and space conversion are unit-verified; the verified semantic path needs none | Accessibility grant (live-verified); Screen Recording grant for screenshots; LaunchAgent |
| Windows 10+ (UIA) | **Supported with limits** — `InvokePattern` only; the live loop verifies capture, dispatch evidence is dated probes | **Supported with limits** — window-message pixel rung for probe-allowlisted classes (`Button` only); the foreground rung is **refused** (hand-back unproven) | **Refused** — no target-bound rung exists and the foreground rung is withheld | **Experimental** — Graphics Capture and OCR are implemented but absent from the live loop | **Supported with limits** — physical pixels with DPI reconciliation reported as evidence; probe-earned at 100% scaling only | interactive-session scheduled task (live-verified); elevation parity or UIAccess for elevated targets; built-in MSAA activation for WebView2 |
| Linux X11 (EWMH window manager) | **Supported** — the session-independent AT-SPI path the Linux live loop verifies | **Supported with limits** — XTest foreground transaction verified hermetically under Xvfb each PR; no pixel rung (**refused**); no full-desktop X11 lane | **Supported with limits** — XTest; keysyms must exist in the active layout | **Not implemented** — refused with `portal-authorization-required` | **Experimental** — AT-SPI screen extents are expected valid under X11; no live geometry check | systemd user unit; AT-SPI enabled; an EWMH manager publishing `_NET_ACTIVE_WINDOW` and `_NET_WM_PID`; the XTEST extension |
| Linux GNOME/Mutter (Wayland) | **Supported** — live loop: capture, resolve, invoke, and verified readback on GNOME Calculator | **Refused (verified)** — the live loop asserts `noDeliveryCandidate` naming Wayland at both policies | **Refused (verified)** — same check | **Not implemented** — portal path designed, unattended authorization unproven | **Supported with limits** — compositor-reported extents; GTK4 descendants report (0,0) origins and are unusable for pointer targeting | AT-SPI bus with accessibility enabled; systemd user unit bound to `graphical-session.target` |
| Linux KWin (Wayland) | **Experimental** | **Refused (expected)** — Wayland classification is verified under Mutter, not KWin | **Refused (expected)** | **Not implemented** | **Experimental** | same as GNOME/Mutter; no KWin runner exists |
| Linux Sway / wlroots (Wayland) | **Experimental** | **Refused (expected)** | **Refused (expected)** | **Not implemented** | **Experimental** | same as GNOME/Mutter; no wlroots runner exists |
| XWayland clients under a Wayland session | **Supported** — X11 clients register on AT-SPI like any application | **Refused (verified)** — the session is classified as Wayland before any X connection; the live runner's session runs XWayland alongside and the refusal is asserted there | **Refused (verified)** | **Not implemented** | **Supported with limits** — the Mutter geometry caveat applies | none beyond the session's; a working XTest conversation with XWayland is not evidence of delivery capability |

### Canonical evidence

These are the only sources that promote or sustain a **Supported** cell.

| evidence | where | what it proves | cadence |
| --- | --- | --- | --- |
| macOS live loop | `.github/workflows/live.yml` `macos` job | capture → resolve → `invoke` `AXPress` → verified Calculator display; complete health-v1 document; Accessibility grant | every push to `main` |
| Linux live loop | `.github/workflows/live.yml` `linux` job | AT-SPI capture/resolve/invoke with verified readback on GNOME Calculator under GNOME/Mutter Wayland; honest refusal of global input at both policies; systemd-user lifecycle and health-v1 | every push to `main` |
| Windows live loop | `.github/workflows/live.yml` `windows` job | the interactive-session daemon serves `look` with a real window root through the DACL-restricted pipe | every push to `main` |
| Hermetic X11 foreground test | `.github/workflows/test.yml` Linux job; `rust/axon-linux/tests/x11_foreground.rs` | the X11 activate/prove/dispatch/restore conversation against a real X server with a miniature EWMH window manager | every pull request |
| Windows session-1 probes | `axon-win probe value`, `events`, `timeout`, `pixel-click`, `foreground`; findings recorded in this document | value set and readback, event delivery, provider timeouts, the pixel-click allowlist entry, the foreground hand-back finding | manual; re-run and re-date when the area changes |
| Platform spikes | `rust/SPIKE-FINDINGS.md` | session topology, WebView2 and WebKitGTK activation and traversal, the Mutter geometry caveat, verified invoke dispatch | dated snapshots (2026-08-02 through 2026-08-04) |

### Environment notes

**macOS.** The live loop covers the semantic rung end to end. The pointer,
keyboard, and screenshot cells are this audit's most surprising finding:
macOS is the most-used platform, and its pixel and foreground paths are
covered by an extensive deterministic suite (`DeliveryRoutingTests`,
`ForegroundEscalationTests`, `PointerTargetValidationTests`,
`DragEventPathTests`) but by no live probe. The promotion path is to extend
the macOS live loop with a click that falls to the pixel rung and a
screenshot capture.

**Windows.** Mechanism and probe findings are in
[Windows backend](#windows-backend). Two restrictions are deliberately not
rows in the matrix because they are per-session and per-target facts rather
than environments: a daemon in a service session reports global input
unusable in health-v1, and an elevated target refuses by name at dispatch
time.

**Linux X11.** The hermetic test proves the protocol conversation against a
real X server; what it cannot prove is a full desktop's window manager, and
the fleet has no X11 desktop. Enrolling one, or recording a dated probe
against one, is the promotion path for the limits above. On every Linux
environment `scroll` is refused — AT-SPI has no portable delta-scroll
operation, and it is never silently replaced with global wheel input.

**GNOME/Mutter (Wayland).** The project's one real Linux desktop, so it
carries the Linux live loop alone. Its two compositor-specific findings are
separate claims with separate evidence: synthetic input is refused because
the compositor forbids it (live-verified), and AT-SPI Component geometry is
untrustworthy for GTK4 descendants (spike-recorded, dated). Mutter advertises
the RemoteDesktop and ScreenCast portals; nothing about unattended
authorization is proven, so portals keep screenshots and synthetic input out
of the supported columns.

**KWin and Sway/wlroots.** Neither has ever run Axon. The expectations in
their rows follow from the Wayland session classification and toolkit AT-SPI
support, but expectation is not evidence: both rows stay **Experimental**
until a runner or a dated probe says otherwise. A Sway session may run no X
server at all, in which case nothing in the X11 row applies to it.

**XWayland.** The trap worth naming, and the reason Wayland is classified
before any X connection is attempted: Mutter publishes EWMH properties for
X11 clients and injects XTest globally, so a backend could activate an X11
window, prove it came forward, and dispatch — while a Wayland-native
application held a focus X11 can neither see nor give back. Semantic capture
of X11-client applications works because they register on the AT-SPI bus
like any other application.

### Known gaps

Gaps are listed rather than omitted, because a caller can discover each one
at runtime through a typed refusal or a health-v1 capability entry; each
should be discoverable here first.

- `scroll` on Linux (every environment): refused — AT-SPI has no portable
  delta-scroll operation.
- `drag` on Windows and Linux: not implemented. A drag holds a button across
  the whole gesture and needs its own account of a press held across a failed
  restoration.
- Change observation (`look(since:)`, `wait_for_value`, `wait_for_stability`):
  macOS only. AT-SPI event observation is not wired into the Linux backend;
  UIA event delivery is probe-verified on Windows but excluded from the v1
  surface.
- Recording (`save` from live history, global user-input observation): macOS
  only. `serializeHistory` and `observeGlobalInput` are unimplemented on both
  Rust backends.
- Chromium-family renderer accessibility: WebView2 activation is built into
  the Windows backend and spike-verified; the WebKitGTK same-bus peer
  traversal is proven only in `axon-spike-linux` and is not yet in the
  shipping Linux backend, and no AT-SPI event listener registration exists
  there to wake Chromium-family renderers.
- macOS pixel, foreground, and screenshot paths: implemented and
  unit-verified, with no live probe (see the macOS note above).

### Maintaining these claims

1. A cell keeps **Supported** only while its named evidence is current: the
   lane green on `main`, or the probe's recorded date recent for the area it
   covers.
2. A live-lane failure demotes the cell in the same change that fixes the
   backend or the lane. A red lane under a green matrix is a documentation
   bug.
3. Probe-backed cells carry their date; re-run the probe and re-date the cell
   when its backend area changes.
4. New environments enter as **Experimental**. Promotion requires a named
   live check (preferred) or a dated probe run recorded in the environment's
   note.
5. Refusals and unimplemented capabilities are documented with the same
   vocabulary the runtime uses — the refusal reasons in
   [`platform-spec.md`](platform-spec.md) and the health-v1 reason codes in
   [`embedding.md`](embedding.md).
6. The machine-readable analogue of this matrix is `status --json`: the same
   per-session verdicts, as data. A claim here that the health document
   contradicts is wrong in one of the two places; fix the one that is lying.

## Native concept map

This table is an architectural map, not a claim that the APIs are behaviorally
identical. Locator values remain native vocabulary.

| Concept | macOS Accessibility (AX) | Windows UI Automation (UIA) | Linux AT-SPI2 |
| --- | --- | --- | --- |
| Element kind | AX role and subrole, such as `AXButton` | control type, such as `Button` | accessible role |
| Default semantic activation | `AXPress` | `InvokePattern.Invoke` | exposed AT-SPI action, commonly click/press |
| Stable developer identity | `AXIdentifier` | `AutomationId` | `accessible-id` |
| Read/set editable value | settable `AXValue` | `ValuePattern` | value/text/editable-text interfaces |
| Change observation | `AXObserver` notifications | UIA event handlers | AT-SPI event listeners over D-Bus |
| Synthetic input fallback | Core Graphics events (`CGEvent`) | `SendInput` | X11 `XTest`; Wayland `libei`/portals when available |

The backend translates native objects into the shared snapshot model and native
results into the shared honest-result model. It does not translate native role
or action names into a universal taxonomy.

## Rust architecture

The Rust sibling has one platform-neutral core and narrow native backends:

```text
MCP stdio facade
  -> JSON-RPC router
    -> shared core
       snapshot model and retained-handle lifecycle
       locator filtering, scoring, confidence, and explanations
       .axn parser, parameter binding, runner, and traces
       capability model and honest result envelopes
    -> PlatformBackend
       capture and application/window enumeration
       semantic action dispatch and value access
       observation and waiting
       pointer/keyboard fallback and screenshots
       recording and permission/capability discovery
  -> user-session socket daemon
```

The backend trait should expose capabilities alongside capture, dispatch,
observation, and recording operations. Platform-specific permission failures and
API restrictions cross the boundary as typed capability or operation errors;
they do not leak arbitrary native status codes into the public protocol. Native
diagnostic details may be retained as supplemental information.

The socket-daemon shape stays aligned with macOS: a long-lived process owns
native subscriptions, retained element handles, and caches, while short-lived
MCP stdio facades connect locally. This is architectural parity, not a demand
that installation and lifecycle management be identical across operating
systems.

## One lifecycle vocabulary, three native mechanisms

Every platform exposes the same four verbs — `daemon install`, `daemon uninstall`,
`daemon restart`, and `shutdown` — plus `status --json` and `version`, with the
same exit-code contract. What differs is the mechanism each verb uses, because
start-at-login is a platform-native concern: a LaunchAgent limited to the Aqua
session on macOS, an interactive `ONLOGON` scheduled task on Windows, and a
systemd user unit bound to `graphical-session.target` on Linux.

All three register the *invoking* executable rather than copying a binary
anywhere, so there is exactly one registration truth and callers must invoke
from a permanent path. All three treat a successful authenticated health round
trip as the readiness contract; a bound socket or an existing pipe is never
taken as evidence that a daemon is serving.

Status is one versioned document, `health-v1`, described by
`schema/health-v1.schema.json` and modelled in both Swift (`AxonCore`) and Rust
(`axon-core::health`) against the same shared fixtures. Degradation is data:
a daemon that is not running, a Windows service session, a Linux greeter with
no AT-SPI bus, and a denied macOS grant are all schema-valid documents that exit
0. The consumer contract is [Embedding Axon](embedding.md).

## Linux lifecycle

`axon-linux daemon install` writes `~/.config/systemd/user/axon.service` with
`ExecStart=<invoking executable> serve`, reloads the user manager, and enables
the unit. The unit is `PartOf`/`WantedBy` `graphical-session.target` rather than
login, because AT-SPI only exists once a desktop is up; a daemon started at the
greeter would have nothing to talk to. It uses `Type=simple` because Axon does
not implement `sd_notify` readiness, so systemd's notion of "started" is earlier
than Axon can serve and the CLI's health round trip is the real readiness signal.

On a host with no graphical session the unit is enabled but deliberately not
started, and install says so and exits 0. Blocking for a readiness that cannot
arrive until someone logs in would report a timeout for work that was done.

The daemon serves `health` and `shutdown` as ordinary JSON-RPC methods on the
mode-0600 `$XDG_RUNTIME_DIR/axon-v1.sock`, so a lifecycle command learns which
process it stopped from the reply. Session facts are detected independently —
user manager, display, session bus — so a host can report an honest partial
state instead of one collapsed guess. Synthetic pointer and keyboard input are
reported per session rather than per build, because the same binary can deliver
them on an X11 session with a window manager and cannot on a Wayland one, and the
same answer feeds both `status` and the dispatch ladder.

Nothing a client does ends the daemon. A hang-up before the request, partway
through it, or between the request and its answer ends that connection alone,
and a request deadline bounds a client that connects and then says nothing,
since the daemon answers one connection at a time. That loop lives in the
`axon-linux` library rather than in the binary precisely so a test can drive
hostile clients against it without a desktop or an accessibility bus.

## Windows backend

Windows is first because UIA provides strong semantic capture, patterns, and
events with a close conceptual fit to AX.

- The daemon must run in the interactive user's session, normally as a tray
  application started at login. Windows session-0 isolation prevents a service
  from reliably observing or driving the user's UI through UIA or `SendInput`.
- A normally elevated daemon cannot freely cross integrity boundaries. Driving
  elevated windows requires matching elevation or a correctly signed and
  installed UIAccess application. Capability reporting must identify this
  boundary instead of presenting inaccessible elements as missing.
- The process must opt into per-monitor DPI awareness before interpreting UIA
  rectangles or dispatching coordinates. All conversion into shared screen,
  window, and screenshot coordinate spaces happens at the backend boundary.
- Window screenshots use Windows Graphics Capture rather than `PrintWindow`.
  Graphics Capture reads the DWM-composited window surface and therefore handles
  modern compositor-backed applications and occluded windows more consistently;
  `PrintWindow` depends on application paint behavior and can return stale or
  blank content. The backend encodes captures as PNG and uses the built-in
  `Windows.Media.Ocr` engine for word rectangles. OCR bitmap coordinates are
  scaled independently on each axis into the physical `GetWindowRect` coordinate
  space before UIA hit testing or `SendInput` dispatch.
- Windows text-location resolution follows the shared ordering: UIA text and
  retained element identity first, then screenshot OCR only when requested or
  when automatic UIA resolution is missing. Both paths fail closed on ambiguity.
  UIA candidates retain the existing immediate `ElementFromPoint` identity
  check; OCR candidates require the hit element to remain inside the target
  window's UIA ancestry, so a covering window cannot turn OCR into an unguarded
  raw point.
- Windows 10 and later support `AF_UNIX`, so the local Unix-domain socket
  transport and MCP-facade topology can carry over. Installation must still use
  Windows-native access controls and lifecycle management.
- The implemented Windows daemon uses `\\.\pipe\axon-v1` instead of `AF_UNIX`.
  Named pipes allow the interactive-session process to reject remote clients. At
  startup, `axon-win serve` reads the user SID from its process token and installs
  a protected DACL granting pipe access only to that SID; it does not rely on the
  process default security descriptor. `axon-win daemon install` registers an
  interactive `ONLOGON` scheduled task for the current user pointing at the
  invoking executable, and starts it; this is the canonical installation path
  because Task Scheduler launches `serve` in the logged-in desktop session even
  when the command is issued over an SSH session-0 shell. `axon-win daemon restart`
  sends the authenticated `shutdown` RPC, updates the task to the current
  executable, and relaunches it. The daemon acknowledges shutdown with its process
  ID before closing the pipe. Lifecycle commands wait for that process to exit
  after its UIA thread joins and the COM apartment is torn down, avoiding a Task
  Scheduler relaunch race. Busy pipe instances are retried rather than mistaken
  for an absent daemon. `axon-win daemon uninstall` stops the daemon and removes
  the task. All three commands are scriptable and `install`/`restart` wait until
  the daemon answers a health request before returning.
  Short-lived `axon-win mcp` processes connect to that pipe.
- `serve` creates the user-restricted pipe before initializing COM and UI
  Automation, making the stalled stage observable, but lifecycle readiness still
  requires a successful health RPC after initialization. Backend startup is
  bounded to 30 seconds so a hung native initialization fails loudly instead of
  leaving an indefinitely half-started daemon. It records timestamped stages in
  `%ProgramData%\Axon\axon-win-startup.log`, including DPI setup, COM apartment
  creation, UI Automation client creation, provider-timeout setup, and pipe bind.
  Per-monitor DPI awareness improves coordinate accuracy but is not required to
  serve; contexts where Windows rejects changing it emit a warning and continue.
  Lifecycle shutdown RPCs are bounded as well; restart asks Task Scheduler to end
  an unresponsive half-started task before relaunching it.
- Run the session-1 integration probes from a logged-in desktop with exactly:
  `axon-win probe value <app-query>`, `axon-win probe events <app-query> [seconds]`,
  and `axon-win probe timeout [app-query] [milliseconds]`. Each command emits JSON;
  the events probe expects the user to edit, restructure, and focus UI during its
  bounded wait.
- Chromium renderer accessibility may remain disabled even after a UI Automation
  client starts. Before capturing a WebView2 target, the backend must query
  `OBJID_CLIENT` through MSAA on the selected target HWND and all of its descendant
  HWNDs, then wait boundedly for
  UI Automation to expose the `RootWebArea` document. Testing against Cairn's
  WebView2 runtime established that this client-side activation exposes a usable
  semantic page subtree without requiring application restart flags.

## Linux backend

Linux capture and semantic actions use AT-SPI2 over the accessibility D-Bus.
The backend must expect differences among desktop environments, widget
toolkits, compositors, and application accessibility implementations rather
than equating “Linux” with one uniform tree.

- The backend opens the accessibility bus itself and addresses every object by
  explicit destination on that single connection. `atspi`'s
  `AccessibilityConnection` is deliberately not used, and `atspi-connection` is
  not among the backend's dependencies: that constructor is inseparable from a
  peer-to-peer subsystem
  which asks every registered application for a private socket address, opens a
  second D-Bus connection to each one that answers, and repeats that on every
  name-owner change. Axon never reads a peer — explicit destinations on the
  shared bus are what cross embedded-application boundaries — so the subsystem
  bought nothing and cost a round trip per application plus a loud failure for
  every participant that answers with an empty address, a running screen reader
  among them.
- Chromium and Electron applications may not expose their accessibility trees
  until an AT-SPI listener registers. Listener registration is therefore part
  of backend readiness, not an optional optimization.
- Under X11, XTest is the practical synthetic-input mechanism and global
  observation is feasible. Reaching either requires an X11 client layer in the
  backend, separate from the AT-SPI connection that carries capture and the
  semantic rung. The two halves meet at the process id: AT-SPI knows applications
  by bus name and EWMH knows windows by `_NET_WM_PID`, and the process is the
  only fact both understand.
- A keysym the active layout does not contain is refused by name rather than
  reached by temporarily remapping a spare keycode. Remapping the keyboard is a
  global side effect visible to every other X client, it races them, and no
  transaction can guarantee undoing it.
- Wayland intentionally blocks unrestricted synthetic pointer input and global
  input observation. libei and desktop portals are the escape hatches when the
  compositor supports and authorizes them. The backend must otherwise declare
  pointer fallback and global user-input observation unavailable rather than
  bypassing Wayland's security model.
- Screenshots under Wayland require the screenshot or ScreenCast portal and user
  authorization. Lack of portal access must not prevent semantic AT-SPI capture,
  but it restricts screenshot and screenshot-coordinate capabilities.
- `save` can still serialize calls already known to Axon, but recording user
  input into a session depends on global observation and may therefore be
  unavailable on Wayland. The capability report must distinguish these facets.

## First integration target: Cairn

The first real-world target is Cairn's own interface: WebView2, backed by
Chromium, on Windows and WebKitGTK on Linux. Accessibility exposure from these
embedded webviews is the load-bearing integration risk. A backend that can
enumerate native controls but cannot obtain the webview content tree does not
meet Cairn's use case.

Early backend work should therefore test listener activation, complete webview
subtree capture, stable developer identifiers, native activation, editable
values, event delivery, and coordinate conversion against Cairn before broad
desktop coverage. KVM access to each executor allows the semantic result to be
checked against the visible interface as well as the API response.

## Delivery matrix

The delivery contract in [`platform-spec.md`](platform-spec.md) is one vocabulary
across all three backends, but the rungs each backend can actually offer differ.
This table is what a caller can rely on today; anything absent from it refuses
rather than falling through to a louder mechanism.

| action | macOS | Windows | Linux |
| --- | --- | --- | --- |
| `invoke` | `semantic` (`AXUIElementPerformAction`, any named action) | `semantic` (UIA `InvokePattern` only) | `semantic` (AT-SPI `Action.DoAction`, any named action) |
| `type` | `semantic` (`AXValue` + readback), then `pixel`, then `foreground` | `semantic` (UIA `ValuePattern` + readback) | `semantic` (AT-SPI `EditableText.SetTextContents` + readback) |
| `scroll` | `semantic` (`AXScrollToVisible`); wheel bursts ride `pixel` then `foreground` | `semantic` (UIA `ScrollItemPattern`) | `semantic` (AT-SPI `Component.ScrollTo`) |
| `click` | `semantic` when the element advertises `AXPress`, else `pixel`, else `foreground` | `pixel` for a probe-verified window class, else refused | `foreground` on X11 with an EWMH window manager, else refused |
| `keyboard` | `pixel` with `app`, else `foreground` | refused | `foreground` on X11 with an EWMH window manager, else refused |
| `drag` | `pixel` with an app or handle endpoint, else `foreground` | not implemented | not implemented |

No backend reports `pixel` for a mechanism it cannot bind to a verified target.

On Windows the mechanism exists. A click resolves the leaf window through the
resolved element's UIA ancestry, proves that window sits inside the top-level
window the caller actually captured, refuses across an integrity boundary,
reconciles the target's DPI awareness with the daemon's, and reports the
client-coordinate transform as evidence. What gates it is the class allowlist in
`rust/axon-win/src/pixel.rs`: a window class enters that table only after
`axon-win probe pixel-click` observed a real state change inside the target with
the foreground window and the cursor position both unchanged.

The messages are delivered synchronously rather than posted, and that choice is
load-bearing rather than incidental. A posted message only enters the target's
queue, so reading the foreground and the cursor immediately afterwards samples a
moment before the handler runs — a window procedure that activated its
application or moved the pointer while handling the click would do so after the
daemon had already reported both invariants intact. `SendMessageTimeoutW` does
not return until the window procedure has processed the message, which gives the
delivery an explicit end for the invariant checks to straddle. It is bounded, and
a timeout is reported as a failure to deliver rather than as a delivery.

The table currently holds one class, `Button`, earned against Character Map's
"Advanced view" checkbox: the dialog expanded from 437 to 586 pixels and gained
nine controls, with `GetForegroundWindow` and `GetCursorPos` identical before and
after and the reported transform reconstructing the screen point exactly. Because
the foreground rung is withheld below it, that entry is also the only way a
Windows click is delivered at all today; every other class refuses, naming
itself.

A short allowlist is the intended resting state rather than an oversight, and the
same probe run shows why. A window procedure that examines a click and does
nothing returns from it exactly like one that acts on it:
`Windows.UI.Core.CoreWindow`, the class hosting every UWP and WinUI surface, took
the whole sequence and Calculator's display never left zero. Delivery proves the
handler ran and never proves it did anything, and the allowlist is the only thing
keeping "the message was processed" from quietly standing in for "the control was
clicked".

One caveat travels with the current entry: it was earned at 100% display scaling
against a per-monitor-aware window, so the coordinate reconciliation that a
DPI-unaware target needs was a no-op in that run. The probe reports
`dpiAwareness` for exactly this reason — an entry earned where the transform had
no work to do is a narrower claim than one earned where it did.

On Linux, neither X11 window-targeted delivery nor a Wayland portal path is
implemented, so it refuses with `backgroundPixelUnsupported` naming what is
missing. Relabelling `SendInput` or `XTest` as `pixel` would make the contract's
central promise false.

`keyboard` has no pixel rung on Windows and will not grow one in this shape. The
rung is target-bound input derived from verified window geometry; `keyboard`
names an application and an input string, so there is no element, no window to
bind to, and no transform to report. It refuses `backgroundPixelUnsupported`
saying exactly that and falls to the foreground rung. Key delivery gets an honest
home later as a `type` fallback below `ValuePattern`, once the pointer path is
proven against real targets.

Linux offers the foreground rung where the session supports it; Windows withholds
it everywhere.

On Windows every seam is implemented and all but one of them is proved on a real
desktop. `frontmost_application` reports the foreground window's process id — the
same vocabulary `capture` records as the application identifier, so the
transaction's identity comparison can actually succeed — and
`activate_application` brings the target forward with the `AttachThreadInput`
assist that `SetForegroundWindow` requires of a background process.
`pointer_location` and `move_pointer` hand the real cursor back, which
matters because `SendInput` moves it. `axon-win probe foreground` shows
activation proved, the dispatch running once, and the pointer returning to where
it started.

What fails is the hand-back, and the asymmetry is the whole finding: the daemon
can take the foreground and cannot give it back. `axon-win probe foreground`
activates Character Map away from Notepad, proves it, restores the cursor exactly
— and then `SetForegroundWindow` aimed back at Notepad's own window returns
false, with Character Map still holding the foreground a full second later. The
second reading is what makes that a refusal rather than an activation that had
not landed yet, and the two are worth keeping apart, because a refusal is a
permission problem and latency is a waiting problem.

The rung is global input that hands the session back, so one that reliably takes
the foreground and reliably reports failure would give a caller the side effect
without the guarantee. It stays closed, the seams stay — they are what the probe
exercises and what a fix will need — and the probe is how anyone knows when that
changes.

Linux implements the same seams and offers the rung on an X11 session with an
EWMH-capable window manager, withholding it everywhere else. The seams live on
`PlatformBackend` — `supports_foreground_transaction`, `frontmost_application`,
`activate_application`, and, for a mechanism that moves the real cursor,
`pointer_location` and `move_pointer` — while the transaction itself is shared in
`rust/axon-core/src/delivery.rs`. That the two backends implement the same seams
and reach opposite conclusions is the point: the rung is offered on what the
running session can actually prove, not on what the build contains.

### Windows session and integrity constraints

`SendInput` is the foreground rung and needs the explicit opt-in. It also needs a
session that can reach the global input devices at all. Session 0 and a
noninteractive window station present as an unusable `pointerInput` and
`keyboardInput` capability in the health document, and the same overlay feeds the
dispatch decision: the backend derives both from the session it actually
occupies, classified in `rust/axon-win/src/lifecycle.rs`. This matters because UI
Automation keeps answering in those sessions while `SendInput` posts to a desktop
nobody is looking at, so nothing else in the daemon notices. When the capability
is unusable the refusal is `noDeliveryCandidate`, not `foregroundNotPermitted`,
at either policy — opting in cannot conjure a device.

An integrity or elevation boundary between the daemon and the target is answered
per target rather than per session, because it depends on which window is being
addressed. The pixel planner reads the target process's mandatory integrity level
and refuses when it sits above the daemon's. That obstacle closes the foreground
rung as well: UIPI discards posted messages and `SendInput` alike from a
lower-integrity process, so leaving the loud rung open would answer an elevated
window with an invitation to opt in to a dispatch Windows had already decided to
throw away.

UIA exposes `InvokePattern` rather than an open-ended named-action vocabulary, so
the Windows backend performs `Invoke` and says so instead of claiming a name it
cannot honour.

### Linux compositor and toolkit overlays

Under X11 the foreground rung is `XTest`, gated on the opt-in and on a window
manager that publishes `_NET_ACTIVE_WINDOW` and `_NET_WM_PID`. Those two
properties are the whole transaction: the first is how the foreground is read and
set, and the second is what ties a window back to an application. Without a
manager honouring them there is nothing to activate through, so `pointerInput`
and `keyboardInput` are unusable with reason `no-window-manager`. The XTEST
extension itself is probed rather than assumed: a server started without it
answers every other question about the session normally, and advertising input on
the strength of a window manager alone would report the capability usable and
discover otherwise only at the moment of dispatch.

A keystroke aimed at an application is resolved to the backend's own AT-SPI
identity before the transaction begins, because that is the string
`frontmost_application` answers with and `activate_application` raises. An
application that cannot be resolved refuses with `targetIdentityUnavailable`
rather than falling through to whatever holds the foreground, which would post
keystrokes into work the caller never named.

Under Wayland they are unusable whatever else is true. The compositor refuses
synthetic input from an ordinary client, and X11 cannot read or set the Wayland
foreground. XWayland is the trap worth naming: Mutter publishes EWMH properties
for X11 clients and injects XTest events globally, so a backend could activate an
X11 window, prove it came forward, and dispatch — while a Wayland-native
application held the focus it could neither see nor give back. A mechanism that
works while its proof quietly does not is precisely what this contract refuses,
so the session is classified as Wayland before any X connection is attempted, and
every pointer or keyboard action refuses with `noDeliveryCandidate` carrying that
reason.

Because XTest moves the real cursor, a Linux `click` captures the pointer before
dispatch and warps it home afterwards, ahead of returning the prior window, and
reports the outcome as `pointerRestored`. `keyboard` does not move it, and
reports null rather than claiming a restoration that never happened.

AT-SPI paths are unaffected by any of this, because they mutate the accessibility
tree rather than the session. AT-SPI identities carry the bus name alongside the
object path, since every application's root object sits at the same path and the
path alone would name several applications at once.

`drag` remains unimplemented on Linux. It holds a button down across the whole
gesture, so it needs its own capability and its own account of a press held
across a failed restoration, and has neither.

AT-SPI value setting no longer takes focus first. Focus is a system-wide side
effect, and an action that changes it is foreground however it finally mutates
the target, so the semantic rung sets the value directly and reads it back.

## Keeping implementations aligned

The platform-neutral specification will drive a shared conformance suite. Its
fixtures should be language-neutral data wherever possible, with adapters that
run them against Swift and Rust. Schema snapshots verify the public tools;
synthetic trees verify locator behavior; request/response fixtures verify JSON-RPC
and MCP envelopes; `.axn` fixtures verify parsing and traces; backend harnesses
verify capability and honest-result semantics. `schema/fixtures/delivery` holds
the delivery vocabulary and result shapes, read by both
`Tests/AxonCoreTests/SharedDeliveryConformanceTests.swift` and
`rust/axon-core/tests/delivery.rs`, so a rung or refusal reason cannot be renamed
on one side alone.

Native integration tests remain necessary because no fixture can prove UIA or
AT-SPI exposure. Conformance establishes that implementations mean the same
thing; native tests establish that each backend can deliver it.

## Continuous integration lanes

The `Test` workflow is the merge gate. Its deterministic Swift and Rust jobs run
for pull requests and pushes to `main` on the enrolled macOS, Linux, and Windows
self-hosted runners. Each job selects both `self-hosted` and the runner's
dedicated `axon-live-*` label, so GitHub cannot silently route it to a hosted
machine or to the wrong operating system.

The Linux job also runs the hermetic X11 foreground test under `Xvfb`. That test
brings its own miniature EWMH window manager rather than depending on an
installed desktop, so it needs only the `Xvfb` binary and behaves the same on
every run. It gates pull requests deliberately: the project's only real Linux
desktop is a GNOME Wayland session, which is the worst possible place to verify
X11 activation, and the live lane asserts the opposite property there — that
global input stays withheld at both policies with a reason naming Wayland.

The separate `Live desktop verification` workflow is a reporting lane. It runs
only after a push to `main` or an explicit manual dispatch, never for a pull
request. Its self-hosted jobs use dedicated `axon-live-*` labels and serialize
per machine because the same desktops also serve as Cairn executors. A live-lane
failure reports a real integration regression without blocking a pull request:

- macOS builds and Developer-ID-signs the checked-out app, starts that app under
  the stable Accessibility-approved identity, then captures Calculator, resolves
  a button, invokes `AXPress`, and verifies the display changed;
- Linux connects to the logged-in GNOME session's AT-SPI bus and runs the
  hardened Calculator probe, which verifies the expected text transition on the
  same AT-SPI object that was captured before dispatch, then asserts that
  `keyboard` refuses with `noDeliveryCandidate` at both policies because the
  session is Wayland;
- Windows uses a localhost-only, forced-command SSH key to cross from the
  runner's session-0 service into the desktop user's process context. The fixed
  probe rebuilds `axon-win`, snapshots and temporarily replaces the scheduled
  interactive-session daemon, sends `look` through `\\\\.\\pipe\\axon-v1`,
  requires a real window root, and restores the prior task and running state in
  a `finally` block.

Every live runner is also somebody's desktop, which is the source of the one
failure mode that would quietly hollow these lanes out. The endpoint is a
rendezvous, not a proof of authorship: only `serve` binds it and every other
subcommand is a client, so a probe that starts its own daemon and then talks to
the endpoint is answered by whichever daemon holds it — routinely the installed
release the desktop user already runs. The freshly built daemon loses the bind,
and when a probe backgrounds it the shell never sees that it exited, so every
assertion afterwards is true of a binary nobody changed.

Only the Linux lane currently closes this. It parks the desktop's systemd
registration once for the whole job rather than once per probe, confirms nothing
is answering on the endpoint before any probe starts, and has each probe assert
that the process id in the health document is the process id it spawned
(`scripts/assert-daemon-under-test`). A final step restores the parked
registration — contents, enablement, and running state — whatever the probes did
to the machine, and requires the restored daemon to answer for itself rather
than accepting `systemctl start`, which this unit's `Type=simple` makes a claim
about `exec` rather than about readiness.

macOS and Windows narrow the window without closing it. macOS shuts the
installed daemon down before launching the build under test, which boots its
LaunchAgent out so `KeepAlive` cannot bring it back mid-step; what remains open
is the same-version case, since the only assertion tying the health document to
the checkout is a version comparison that an installed daemon built from this
repository satisfies just as well. Windows snapshots and replaces the scheduled
interactive-session daemon for the duration of its probe. A lane without an
authorship check reports that some daemon on the machine works, which is worse
than having no lane, because the lane is trusted.

The repository's Actions policy requires approval for every outside
contributor's workflow run before pull-request code can reach the self-hosted
desktops. The live workflow still has no `pull_request` trigger because its
interactive probes alter desktop state and should run only from trusted `main`
or a manual dispatch.

### Re-enrolling a live runner

Remove the offline runner in **Settings > Actions > Runners**, then stop and
uninstall its local runner service. Download the current runner package from the
repository's **New self-hosted runner** page, request a fresh registration token,
and configure the replacement as the desktop user with exactly one dedicated
label: `axon-live-mac`, `axon-live-linux`, or `axon-live-windows`. Install and
start it with the runner package's platform service command (`svc.sh install`
and `svc.sh start` on macOS/Linux). On Windows, run `config.cmd` from an
elevated prompt and select service mode, or pass `--runasservice` during
unattended configuration. Confirm the runner is online and carries `self-hosted`, its operating
system and architecture labels, and its dedicated `axon-live-*` label before
dispatching the workflow.

The Windows service remains under `NETWORK SERVICE`. Re-enrollment also
requires recreating its localhost SSH key and installing that public key for the
desktop user with a forced command that runs only
`C:\\ProgramData\\Axon\\live-probe.cmd`; disable forwarding and pseudo-terminal
allocation with the authorized-key `restrict` option. Give the private key only
to `NETWORK SERVICE` and `SYSTEM`, pin the localhost host key in the runner's
`known_hosts`, and verify an arbitrary SSH command is rejected before enabling
the runner. This narrow relay is necessary because Windows services run in
session 0 while UI Automation and the daemon's scheduled task must run as the
logged-in desktop user.

Registration tokens are short-lived secrets. Generate one immediately before
configuration with:

```sh
gh api repos/bleugreen/axon/actions/runners/registration-token -X POST --jq .token
```