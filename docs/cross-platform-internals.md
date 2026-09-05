# Cross-platform internals

This contributor reference covers backend architecture, delivery mechanisms, and verification lanes. For user-facing capability claims, see [Cross-platform support](cross-platform.md).

## Evidence, limitations, and claim maintenance

### Canonical evidence

These are the only sources that promote or sustain a **Supported** cell.

| evidence | where | what it proves | cadence |
| --- | --- | --- | --- |
| macOS live loop | `.github/workflows/live.yml` `macos` job | capture → resolve → `invoke` `AXPress` → verified Calculator display; complete health-v1 document; Accessibility grant — each asserted against the app bundle the job launched, by process id | every push to `main` |
| macOS grant-carry upgrade verification | `bglab-mac`, measured during the axn/119 v0.3.0 rollout | `daemon install` from `~/.local/lib/axon/0.3.0` repointed the LaunchAgent from 0.2.3 while the unchanged `com.bleugreen.axon` bundle identity carried Accessibility and Screen Recording grants across the upgrade: the daemon returned ready in about one second with all fifteen capabilities usable and no System Settings prompts | manual (2026-08-11); re-run on changes to bundle identity or installation registration |
| Linux live loop | `.github/workflows/live.yml` `linux` job | AT-SPI capture/resolve/invoke with verified readback on GNOME Calculator under GNOME/Mutter Wayland; honest refusal of global input at both policies; systemd-user lifecycle and health-v1, including the session accessibility switch this runner has on | every push to `main` |
| Windows live loop | `.github/workflows/live.yml` `windows` job | the interactive-session daemon serves `look` through the DACL-restricted pipe; against a probe-owned isolated Edge window targeted by its window-owning process id, Ctrl+L, text, Return, and a page-content click dispatch through the foreground rung and are verified from page state; the complete health-v1 document and the desktop's unchanged registration are also asserted | every push to `main` |
| Hermetic X11 foreground test | `.github/workflows/test.yml` Linux job; `rust/axon-linux/tests/x11_foreground.rs` | the X11 activate/prove/dispatch/restore conversation against a real X server with a miniature EWMH window manager | every pull request |
| Hermetic AT-SPI activation test | `.github/workflows/test.yml` Linux job; `rust/axon-linux/tests/atspi_activation.rs` | that the attributes call is issued against the application root and only once per application, that the bounded wait ends when a withholding provider publishes rather than when the bound expires, and that a provider which never publishes is reported as withheld rather than as empty — against a private session bus and a provider built to withhold the way Chromium does; and, on a second private bus, that the session's accessibility switch is read live rather than remembered and reaches health-v1 as a degraded session | every pull request |
| Windows session-1 probes | `axon-win probe value`, `events`, `timeout`, `pixel-click`, `foreground`; findings recorded in this document | value set and readback, event delivery, provider timeouts, the pixel-click allowlist entry, the foreground hand-back finding | manual; re-run and re-date when the area changes |
| Hermetic X11 pixel test | `.github/workflows/test.yml` Linux job; `rust/axon-linux/tests/x11_pixel.rs` | against a real X server: that the two delivery variants route as the acceptance table assumes — a targeted event reaching only a client that selected it, an owner event reaching the creating client regardless — that a window is bound to the process that owns it and refused when covered at the point, that screen coordinates convert through the window's own geometry, that a chord's modifier state survives the wire, and that none of it moves the real pointer or the X input focus | every pull request |
| Linux toolkit acceptance harness | `scripts/linux-toolkit-acceptance/`; results in `RESULTS.md` and `RESULTS-live-x11.md` | which toolkits act on background `XSendEvent` delivery with the session focus and real pointer unchanged, and whether AT-SPI extents match the toolkit's own rectangles; each row backed by a real-pointer and a focused-keystroke control, each phase re-proving the background before it sends. Its keyboard phase runs after its click phase on the same window, so a keyboard row for a toolkit whose click is accepted is not independent — see the Chromium gap above | manual (2026-08-10, hermetic Xvfb and a live X11 session, GTK 3/4, Qt 6, WebKitGTK, Firefox, Chromium 108/124/150); re-run and re-date on toolkit releases |
| Linux pixel rung bench verification | fedora bench, live Xfce X11 session, recorded in this document | that the implemented rung delivers end to end through the daemon: an Electron 43 (Chromium 150) page reported a click as `isTrusted`, and GTK 3 and Qt 6 typed delivered text into an unfocused window, each with the frontmost window, the X input focus and the real pointer unchanged either side; and that Chromium keystrokes with no prior click are silently dropped | manual (2026-08-10); re-run and re-date when the area changes |
| Linux Chromium activation probe | recorded in [Linux backend](#linux-backend) | that Chromium-family trees are gated by `org.a11y.Status.IsEnabled` and by an attributes or relations call, and not by AT-SPI listener registration; the daemon's before-and-after capture of Chrome. What only real browsers can show — the daemon's own half of the mechanism is gated per pull request by the hermetic AT-SPI test above | manual (2026-08-08); re-run and re-date when the area changes |
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
untrustworthy for GTK4 descendants (spike-recorded, dated). Mutter advertises the RemoteDesktop and ScreenCast portals. AXN-172 measured WINDOW authorization and restore-token behavior, but the stream metadata has no application identity. Axon therefore keeps app-scoped `look` screenshots refused while the distinct `capture_screen` operation returns only an honestly labeled user-authorized source. Tokens are optimistic restoration hints, never global health proof.

One thing about that runner is not a property of GNOME and must not be read as
one: a screen reader runs on it, so its `toolkit-accessibility` is already true
and `org.a11y.Status.IsEnabled` answers true. A stock GNOME session answers
false, and on that session every Chromium-family application is absent from the
AT-SPI bus. Nothing in the live loop depends on the difference, because the loop
exercises GNOME Calculator and GTK providers publish either way — but no cell
above is evidence about a session with accessibility switched off. The loop
asserts the switch in the health document precisely so this paragraph stays
falsifiable: if the runner ever loses its screen reader, the lane goes red here
rather than quietly broadening what green means.

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
- Chromium keystrokes at the Linux pixel rung: refused. Chromium routes
  background key events to a window only once a background click has landed in
  it, and the acceptance harness measures its keyboard phase after its click
  phase on the same window, so the fixture's row for the family records that
  state rather than an independent acceptance. Measuring the phases against
  targets that received nothing else is AXN-102; the entry stays refused until
  then, because the alternative is reporting a successful dispatch for
  keystrokes that reliably do nothing.
- Multi-window applications at the Linux keyboard pixel rung: refused. A
  keyboard request names an application and no element, so the binding is
  unambiguous only while that application has exactly one managed top-level
  window; with more, nothing here can choose between them on the caller's
  behalf, and it says so rather than guessing.
- `drag` on Windows and Linux: not implemented. A drag holds a button across
  the whole gesture and needs its own account of a press held across a failed
  restoration.
- Change observation (`look(since:)`, `wait_for_value`, `wait_for_stability`):
  macOS only. AT-SPI event observation is not wired into the Linux backend;
  UIA event delivery is probe-verified on Windows but excluded from the v1
  surface.
- Recording (`save` from live history, global user-input observation): the
  shipping implementation is macOS-only and lives in the Swift daemon. The
  shared half of the port now lives in `axon-core` — `recording.rs` carries the
  provider-neutral event vocabulary, the `GlobalInputObserver` seam, and v2
  authoring; `postconditions.rs` carries the observed-state model and the rules
  that decide which transitions may be asserted. A platform supplies only the
  evidence it alone can gather, and native handles never cross that boundary, so
  what a recording says about an interface is decided in one place rather than
  per platform. macOS and Windows implement the observer hook — a listen-only
  CGEvent tap with Accessibility reads taken in the callback, and a low-level
  hook pair feeding an enrichment thread that reads UI Automation at event time,
  respectively. Linux does not, which is why `observeGlobalInput` stays unusable
  there and refuses with a typed capability reason rather than a bare error.

  A keystroke burst captured under a sensitive focus is never serialized; the
  rule and the floor each observer owes it are the observer sensitivity contract
  below.
- WebKitGTK renderer accessibility on Linux: the same-bus peer traversal is
  proven only in `axon-spike-linux` and is not in the shipping Linux backend,
  so WebKitGTK page content is still out of reach. Chromium-family activation
  is implemented on both backends — an MSAA touch before capture on Windows
  (spike-verified) and an attributes touch at capture on Linux (probe-verified
  2026-08-08 against real browsers, and gated on every pull request by a
  hermetic AT-SPI provider test) — and a Linux session whose `org.a11y.Status.IsEnabled` is false
  hides those applications from the bus entirely. That session reports itself:
  `status --json` carries `session.accessibilityEnabled` false with reason
  `accessibility-disabled` before anyone has asked for an application, and
  capture names it again for a caller who did.
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
       snapshot model, semantic-name contract, and private retained-handle lifecycle
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

At the public Rust boundary, an element target is exactly `{app, name}`. Raw
snapshot handles and standalone locator objects are rejected before backend work.
The provider uses axon-core's app-scoped semantic-name registry and native locator evidence to
resolve that name against a fresh capture. Retained handles are private cache hints only;
locator scoring is the durable fallback after the interface changes. Missing and ambiguous
names fail closed, and accepting the old target vocabulary as a fallback would create a second,
stale public contract.

The socket-daemon shape stays aligned with macOS: a long-lived process owns
native subscriptions, retained element handles, and caches, while short-lived
MCP stdio facades connect locally. This is architectural parity, not a demand
that installation and lifecycle management be identical across operating
systems.

### The observer sensitivity contract

A keystroke burst captured while a sensitive element held focus is never
serialized. Shared core keeps the step, because the flow needs it, but authors
it as a declared sourceless `secret` argument reference: the characters stay in
the daemon process, and replay asks whoever runs the recording for the value.
That refusal lives in `axon-core` rather than in any backend, because no
platform hook can be trusted to do it — neither Windows low-level keyboard hooks
nor X11 XRecord have an OS gate of any kind, and macOS secure event input is a
system-wide mode that a web password field may never engage.

The refusal is only ever as good as the `sensitive` flag the observer sets on
`RecordedElementEvidence`, so each platform owes a predicate at least this
broad, and owes a unit test that a password-role element is classified sensitive
so the floor cannot silently narrow again:

| platform | at minimum |
| --- | --- |
| macOS | role or subrole naming "secure", or a description naming a password. The subrole is the one that matters: `NSSecureTextField` reports role `AXTextField` with subrole `AXSecureTextField`, so a role-only test misses the ordinary AppKit password field entirely. |
| Windows | `UIA_IsPasswordPropertyId` on the element. |
| Linux | role `ROLE_PASSWORD_TEXT`, or a description naming a password. |

The Linux row named `STATE_PROTECTED` until axn/229 tried to implement it. **AT-SPI has
no such state.** `STATE_PROTECTED` is ATK and MSAA vocabulary; the AT-SPI state set has
no member of that name, and the state AT-SPI does spell `SENSITIVE` means the opposite
of what the word suggests here — it marks a widget as enabled and interactive, so
reading it as "holds a credential" would have marked nearly every element sensitive.

That leaves Linux with a narrower floor than the other two platforms, because AT-SPI
offers no general "this field is concealed" state to stand behind the role, and a
toolkit that conceals a field without reporting `ROLE_PASSWORD_TEXT` is not caught. The
description is tested beside the role for the same reason macOS tests it, and
deliberately not the *name*: on this platform an entry's AT-SPI name is usually its
label, so testing the name would classify the ordinary field beside a "Password" label
as a secret and silently drop what the user typed into it.

The same flag also withholds the element's value from the evidence, so a
provider must never read `AXValue`, the UIA value pattern, or the AT-SPI text
interface of an element it has just classified sensitive.

An observer that additionally has an OS-level signal reports it as
`SecureInputChanged`, which makes shared core drop pending state and discard
events entirely while it is active. macOS has one: `IsSecureEventInputEnabled`
is a real system mode, and while it is on the CGEvent tap genuinely stops being
handed keystrokes, so saying so is describing what happened.

Windows deliberately reports nothing here, and the reason generalizes. Raising
`SecureInputChanged` is not a stronger version of the per-element predicate; it
is a *different outcome*. `UserActionRecorder::consume` returns early for every
event while it is active, so a burst raised this way never reaches `flush_text`,
which is the one place that authors the declared `secret` argument. Mapping
`UIA_IsPasswordPropertyId` onto it would therefore replace the honest shape with
silent dropping — the outcome the recorder's own charter rejects — rather than
add to it. Windows has no system-wide secure-input mode to report either way: a
low-level keyboard hook keeps delivering password-field keystrokes
unconditionally, and the per-element predicate above is the whole defence.

The UAC secure desktop is not an exception to that, because it is not a mode at
all. It is a separate desktop, and a hook installed on the interactive desktop
simply never sees any of its input. There is nothing to detect and nothing to
report; the events do not arrive.

Linux reports nothing here either, and for a third reason again: there is no
system-wide secure-input mode on X11 to report, and an XRecord client is handed
keystrokes unconditionally whatever has focus.

One gap the per-element predicate does not close on any platform: sensitivity is
read when the burst is *flushed*, and a burst is flushed by the next event. Type
a password and then click elsewhere, and the read that decides finds the newly
focused element. Closing it means carrying sensitivity on the keystroke itself,
which is a change to the shared event vocabulary rather than to any observer.

A fourth platform difference matters for the same predicate. macOS and Windows
each have a direct query for the focused element — `AXFocusedUIElement`,
`GetFocusedElement`. **AT-SPI has neither.** The only mechanisms the accessibility
bus offers are the focus event an assistive technology subscribes to, which the
Linux backend's command actor cannot service while it is answering commands, and
asking objects whether they say they are focused. So Linux finds focus by a
bounded depth-first search from the active window, pruned by what a provider says
is on screen, under the same node and depth limits a capture walk uses. A search
that finds nothing reports the focused element as unavailable, which is the same
`None` the other two platforms report when their query fails — and shared core
treats that as a keyboard fallback, so a burst whose focus could not be read is
serialized. That is the cost of the missing query, and it is why the search is
pruned conservatively: a subtree whose state could not be read at all is descended
into rather than skipped.

## One lifecycle vocabulary, three native mechanisms

Every platform exposes the same four verbs — `daemon install`, `daemon uninstall`,
`daemon restart`, and `shutdown` — plus `status --json` and `version`, with the
same exit-code contract. What differs is the mechanism each verb uses, because
start-at-login is a platform-native concern: a LaunchAgent limited to the Aqua
session on macOS, an interactive `ONLOGON` scheduled task on Windows, and a
systemd user unit bound to `graphical-session.target` on Linux.

None of the three copies a binary anywhere, so there is exactly one
registration truth and callers must invoke from a permanent path. Windows
derives and registers the windowless daemon beside the invoking CLI, Linux
registers the *invoking* executable, and macOS registers the enclosing
`Axon.app` when there is one, because that is the only way a privacy grant
binds to the bundle identity instead of to a path that changes every release.
All three treat a successful authenticated health round trip as the readiness
contract; a bound socket or an existing pipe is never taken as evidence that a
daemon is serving.

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
- Foreground keyboard delivery joins the target GUI input queue and proves native
  focus before posting one indivisible batch. Unicode text preserves focused
  controls. The measured Chromium Ctrl+L browser accelerator requires two
  consecutive proofs of active top-level focus across a bounded interval. This
  closes two observed gaps: a renderer child can remain a valid same-process
  focus owner while that accelerator is ignored, and Edge's asynchronous
  first-run sync surface can steal focus after initial activation. Other keys
  retain focused-control semantics until equivalent evidence justifies a
  broader application-accelerator intent. `SendInput`'s returned count
  proves only that Windows accepted records, never that the application consumed
  them.
- Bench traps in the Windows live probe, each paid for once. The default ssh shell is pwsh7;
  `scp` is broken, so files are streamed with `cat | ssh 'cmd /c more > target'`; multi-line
  PowerShell over stdin executes line by line, so every remote body is a `.ps1` or an
  `-EncodedCommand`. And **PowerShell variable names are case-insensitive**: a loop variable named
  `$burst` inside a function whose parameter is `[int] $Burst` is the *same variable*, so binding
  an object to it fails the type conversion rather than the comparison. That cost a live run whose
  measurement had already been taken, which is why the recording diagnostic now emits its payload
  before anything judges it.
- A normally elevated daemon cannot freely cross integrity boundaries. Driving
  elevated windows requires matching elevation or a correctly signed and
  installed UIAccess application. Capability reporting must identify this
  boundary instead of presenting inaccessible elements as missing.
- Global input observation is two threads, and the split is forced rather than
  chosen. `RecordedInputEvent::MouseDown` carries its evidence inside the event,
  and shared core reads that evidence as the interface *before* the click landed;
  but `poll` runs only on `recording.status` and `recording.stop`, so an event may
  wait minutes. The evidence therefore has to be read at event time — and a
  `WH_KEYBOARD_LL` / `WH_MOUSE_LL` callback cannot read it, because Windows
  removes a hook from the chain that exceeds `LowLevelHooksTimeout` (300 ms by
  default) while a cross-process UI Automation read may take the full 1500 ms
  transaction timeout the backend configures. So the hook thread only stamps and
  queues, onto a bounded queue whose overflow is reported rather than swallowed,
  and an enrichment thread reads the interface immediately afterwards through a
  clone of the existing MTA actor's command channel. There is one UI Automation
  client per process and observation does not add a second.
- The daemon must not record its own delivery, and the flag that looks like it
  answers this does not. Every `SendInput` from every process sets
  `LLKHF_INJECTED`, so filtering on it would discard assistive technology,
  remote-desktop input, and the live probe's own helper — leaving the capability
  with no way to be tested at all. Instead each record the daemon posts carries a
  process-owned sentinel in `INPUT.dwExtraInfo`, which arrives at the hook
  verbatim, and the observer drops exactly those. Per-event marking rather than a
  guard held across the posting call, because the hook runs on the observer's
  thread: an interval either releases while events are still in flight or stays
  open long enough to swallow real input. One delivery escapes the stamp —
  `SetCursorPos`, used to place the pointer, has no `dwExtraInfo` — and it is
  harmless only because a bare motion never becomes an action.
- Keystroke text comes from `ToUnicodeEx` against the *foreground* thread's
  layout, with the modifier state rebuilt from the hook stream. Neither half is
  incidental: reading this thread's layout would transcribe a French keyboard as
  an American one, and `GetKeyboardState` on the hook thread answers for that
  thread's own queue rather than the one being typed into.
- A recorded event names its application the way `enumerate` names it: the
  top-level window's UI Automation name. This backend has no durable application
  identity to offer beyond that — it spells one as a process id, which cannot
  outlive the session, and names one by a window title, which lasts only as long
  as the window keeps it — so `bundleIdentifier` is left empty rather than minted
  from something the rest of the daemon could not resolve. A Windows recording is
  consequently only as replayable as its window titles are stable, and scoping a
  session to one application matches on that same name.
- The process must opt into per-monitor DPI awareness before interpreting UIA
  rectangles or dispatching coordinates. All conversion into shared screen,
  window, and screenshot coordinate spaces happens at the backend boundary.
- Window screenshots use Windows Graphics Capture rather than `PrintWindow`.
  Graphics Capture reads the DWM-composited window surface and therefore handles
  modern compositor-backed applications and occluded windows more consistently;
  `PrintWindow` depends on application paint behavior and can return stale or
  blank content. The backend encodes captures as PNG and uses the built-in
  `Windows.Media.Ocr` engine. Public observations are line-level: each line's
  text is paired with the union of its valid word rectangles, matching the
  Vision and Tesseract backends while preserving native geometry. OCR bitmap
  coordinates are scaled independently on each axis into the physical `GetWindowRect` coordinate
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
  startup, `axon-win-daemon.exe` reads the user SID from its process token and installs
  a protected DACL granting pipe access only to that SID; it does not rely on the
  process default security descriptor. `axon-win.exe daemon install` uses the
  Task Scheduler COM API to register an interactive logon task for the current
  user, with an `InteractiveToken` principal, limited run level, and
  `IgnoreNew` multiple-instance policy. Its Exec action names the permanent
  sibling `axon-win-daemon.exe`, and starts it; this is the canonical installation path
  because Task Scheduler launches the daemon in the logged-in desktop session even
  when the command is issued over an SSH session-0 shell. `axon-win daemon restart`
  sends the authenticated `shutdown` RPC and starts the registered task again
  without rewriting it, so a restart issued from a build directory cannot repoint
  a working installation at a path that is about to disappear; `daemon install` is
  the only verb that writes the registration. The daemon acknowledges shutdown with its process
  ID before closing the pipe. Lifecycle commands wait for that process to exit
  after its UIA thread joins and the COM apartment is torn down, avoiding a Task
  Scheduler relaunch race. Busy pipe instances are retried rather than mistaken
  for an absent daemon. `axon-win daemon uninstall` stops the daemon and removes
  the task. All three commands are scriptable and `install`/`restart` wait until
  the daemon answers a health request before returning.
  Registration health reports the daemon path held by Task Scheduler. Short-lived
  `axon-win.exe mcp` processes connect to that pipe, preserving console stdin and stdout.
- The windowless daemon creates the user-restricted pipe before initializing COM and UI
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
- Administrator-created registrations from older installers remain runnable but
  cannot be replaced or deleted by a normal user token. Install and uninstall
  report that migration condition without mutating the old task: the user removes
  it once with the currently installed CLI in Administrator PowerShell, then
  reruns the installer in ordinary PowerShell. New registrations and every
  steady-state lifecycle operation are per-user and unelevated.
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

### Recording: RECORD for the events, AT-SPI for what they hit

Global input observation reads the X11 core input stream through the RECORD
extension, added as a feature of the `x11rb` this crate already depends on rather
than as a new crate or a new system library. RECORD and not XInput2, and the
reason is the modifier state: a core `KeyPressEvent` carries the modifiers held
when it was generated, where an XI2 raw event omits them by design and would leave
the observer rebuilding that state from the key stream. The protocol asks for two
connections and gets them — one to create and later disable the context, one
blocked in `RecordEnableContext` on a listener thread that must keep reading,
because a recording client which stops draining backs the stream up in the server.

Evidence is read on a second thread, not on the listener and not at `poll` time.
That is the same constraint Windows has for the same reason: a `MouseDown` carries
its evidence inside the event and shared core reads it as a picture of the
interface *before* the click landed, but `poll` happens only on `recording.status`
and `recording.stop`, so an event can wait minutes. The enrichment thread holds a
clone of the AT-SPI actor's command sender and asks it at event time. There is one
accessibility-bus connection per process and this does not open a second.

Which application an event belongs to is answered by X11, not by AT-SPI. The
accessibility bus exposes no stacking order and no foreground, so choosing between
two applications whose windows both cover a point would be a guess there; the
enrichment thread reads `_NET_WM_PID` off the window under the point and hands the
actor a process it has already established. From there the actor descends with
`Component.GetAccessibleAtPoint`, which answers with a direct child rather than the
deepest hit, so reaching a leaf means asking repeatedly. Screen coordinates are
asked for first, since that is the frame the event arrived in, and a provider that
answers only in window coordinates is asked again relative to its own frame rather
than being written off.

**Excluding this daemon's own delivery has no per-event channel to use.** Windows
stamps `INPUT.dwExtraInfo` and reads it straight back off the hook. A core X11
event has no equivalent field, and an XTEST-injected event is by design
indistinguishable from a real one once the server has it — that is the whole point
of the extension, and it is why `xdotool` output reaches `xev`. Refusing all
synthetic input instead would discard assistive technology, remote-desktop
sessions, and any live probe's own helper, leaving the capability untestable.

So the exclusion is made by *order*. Every synthetic event this daemon posts goes
through one function, `X11Session::fake_input`, which registers what it is about to
inject before the request is sent; the listener drops the first matching event
while that expectation is outstanding. Registration precedes the request, so an
expectation is always in place before the server can generate the event, and the
match is made on the listener thread rather than during enrichment because the
expectation deadline runs on a wall clock while enrichment can be seconds behind a
burst. What this cannot separate is a genuine user event of the identical kind and
keycode arriving inside one server round trip of ours: the counts stay right and
the attribution of two identical events swaps. A held-open time bracket has the
same failure across a far wider window and in both directions, which is why it is
not one.

Two limitations are vocabulary rather than runtime, and both are stated where they
are felt: AT-SPI has no focused-element query (see the observer sensitivity
contract above), and it has no durable application identity. This backend spells an
application as an AT-SPI identity — a unique bus name and a per-session object path
— and names one by whatever the toolkit publishes. A recording therefore carries
the application *name*, with `bundleIdentifier` left empty rather than minting a
third identity that would resolve against nothing else in the daemon. The same
per-session identity reaches persisted locators through ordinary capture, so a
Linux recording replays reliably within its session and is subject to axn/208 on
the replay side beyond it.

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
- Chromium and everything embedding it — Electron, and Chromium-backed webviews
  — gate their accessibility twice, and neither gate is an AT-SPI listener
  registration. The first gate is `org.a11y.Status.IsEnabled` on the session
  bus, read once at process start and never revisited: while it is false those
  applications are not thin on the bus, they are absent from it, and switching
  it on afterwards does not reach a process that is already running. GTK
  providers are unaffected and publish either way, which is why a session can
  look healthy while every Chromium-family tree is missing. The second gate is
  on-demand: an application that is on the bus publishes an application root and
  a window whose only child is AT-SPI's null reference, and builds the tree
  behind that window only once a client asks some node for its attributes or its
  relations. Both calls reach `AXPlatform::OnExtendedPropertiesUsedInWebContent`
  in Chromium, which is the switch.
- The first gate is a fact about the session rather than about any one
  application, so it is reported as one. The daemon reads
  `org.a11y.Status.IsEnabled` from the session bus when a health request arrives
  and publishes it as `session.accessibilityEnabled`, with reason
  `accessibility-disabled` on a session that answers false. Such a session is
  interactive, graphical, and degraded at the same time — capture works, because
  GTK providers publish either way, while every Chromium-family application is
  absent from the bus — so a consumer reading only the two session booleans
  would call it healthy. The reading is taken per request rather than remembered
  at startup, because an assistive technology can switch accessibility on under
  a running daemon and every application launched afterwards then joins the bus.
- Axon reports that switch and never sets it. Every assistive technology sets
  it, and `at-spi-bus-launcher` accepts the write — but the launcher writes the
  desktop's `toolkit-accessibility` setting when it does, turning accessibility
  on for every application on the session and leaving it on after the last
  listener goes away. That is a persistent, global change to someone's desktop
  made on behalf of one automation run, the same family of side effect as the
  keysym remapping refused below, and it would not even rescue the run that
  provoked it: an application already running never revisits the property.
  Health-v1 names the state, and whoever owns the desktop decides.
- Activation therefore belongs to capture, not to readiness. The trigger is a
  call into one application's own tree, so there is nothing a starting daemon
  could do on behalf of an application that does not exist yet. The first time
  `LinuxBackend` captures an application it asks the application root for its
  attributes, waits — bounded — while the application is still claiming a tree
  it has not published, and then walks once. That is the order the Windows
  backend already uses before capturing a WebView2 target, where the MSAA touch
  precedes a bounded wait for the root web area. The ask is remembered per
  application, keyed by the unique bus name in its AT-SPI identity, because
  activation is a one-way switch inside the application: asking twice buys
  nothing, and an application that ignores the ask must not make every later
  `look` pay the wait. A restarted application owns a different unique name, so
  it is asked again. Every clause of that paragraph crosses the wire, so none of
  it can be held still by a unit test; `rust/axon-linux/tests/atspi_activation.rs`
  holds it against a private session bus and a provider that withholds until it
  is asked, which is what keeps the probe a record of discovery rather than the
  only thing standing between a regression and a release.
- The null reference is `/org/a11y/atspi/null` and means "no object". It
  implements no interfaces, so walking it as an ordinary child fails the whole
  capture rather than yielding an empty branch, and it is dropped from every
  provider's answer, unconditionally. Reporting it and waiting on it are then
  separate decisions. Every dropped reference is reported, as the observation it
  is rather than as a diagnosis of why it was there: a window that published a
  menu bar and withheld everything else must not read as a window that contains
  a menu bar. Waiting is the stricter condition, and only an answer that dropped
  something and published nothing earns it — `Null` is a general sentinel, and a
  provider with an ordinary hole in its child range, a cell not yet instantiated
  or a child destroyed mid-enumeration, will not fill that hole in however long
  anyone waits.
- An incomplete subtree says which kind of incomplete it is, in
  `truncationReason`: the walk hit the node limit, the walk stopped at the depth
  limit and never asked, or the provider returned a null reference in place of a
  child. A node the walk never asked about reports no child count at all rather
  than a count of zero, because a node nobody asked is not a node with no
  children.
- Bounding the walk bounds what is captured, not what describing it costs, and
  those are separate budgets. Naming the elements of an observation once copied
  the whole observation per element — quadratic in tree size, and retained,
  because the semantic registry keeps its records. A bounded 2,000-node capture
  of GNOME Shell therefore took a Linux daemon from 8 MiB to a gigabyte in seven
  seconds and the kernel killed it, with the tree itself never exceeding a few
  megabytes. The path is shared by every backend, so the cost was the same
  everywhere; only a desktop shell was wide enough to make it fatal. The
  invariant is now asserted as scaling rather than as a memory figure in
  `axon-core/tests/observation_memory.rs`: describing an observation costs a
  bounded number of copies of it, and the cost per element does not grow with
  the number of elements. A resident-memory bound would have been a fact about
  one machine's allocator; this one holds anywhere and names the defect when it
  fails.
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
- X11 screenshot pixels also feed runtime-discovered Tesseract OCR without a
  second capture. Axon streams PNG bytes to the executable, parses TSV into
  line-level observations, and converts image rectangles into absolute desktop
  coordinates with independent axis scaling. Missing engines or language data,
  timeouts, malformed output, and execution failures are explicit OCR
  unavailability while semantic AT-SPI remains usable.
- Application screenshots under Wayland remain unavailable because ScreenCast source metadata cannot be bound to an AT-SPI application. `capture_screen` separately requests a user-authorized WINDOW source, persists its restore token immediately after successful Start, and reports timeout, cancellation, or stale restoration as authorization-required. Portal access never gates semantic AT-SPI capture or makes global screenshot health usable.
- A ScreenCast session is closed on every path that ends a capture, not only on
  the successful one. The session is created immediately before an interactive
  wait that races a deadline and a stop signal, so whichever of those wins drops
  the future holding it, and `ashpd`'s session cannot close itself on `Drop`
  because closing is an async D-Bus call. It therefore leaves the negotiation
  through an out-parameter, which is what keeps the single close reachable from
  success, refusal, timeout, and cancellation alike. The handshake is split by
  who is being waited on: reaching the portal and creating a session are
  machine-speed and get their own short bound, so a portal that is not there is
  reported quickly instead of spending the interactive budget; only the source
  chooser waits on a person.
- `save` can still serialize calls already known to Axon, but recording user
  input into a session depends on global observation and may therefore be
  unavailable on Wayland. The capability report must distinguish these facets.

The Chromium-family claims above were probed on `bglab-ub` on 2026-08-08,
against Electron 33.2.1 (Chromium 130) and Chrome for Testing 151.0.7922.77.
Each application was given a private session bus, accessibility bus, and
registry, so that the desktop's own running screen reader could not be mistaken
for the mechanism under test. With a listener registered and nothing else, both
applications stayed absent from the bus, whether they were already running or
launched afterwards. With `IsEnabled` true at startup both appeared as exactly
three nodes — application, window, null reference — and stayed that way whether
or not a listener was registered. One `GetAttributes` on the application root
produced the full tree: 284 nodes for Chrome and 26 for Electron, arriving after
1.12s and 0.09s. Through the daemon, the same Chrome capture answered `operation
accessible proxy failed: atspi: null reference` before this was implemented, and
the complete tree including the `document web` afterwards, at the same cost on
the first `look` as on the third. GNOME Calculator captured 107 nodes at
unchanged latency, because a provider that publishes its tree pays only the ask.

Two details are worth carrying to whoever re-runs that probe. `libatspi` reads
the X root window's `AT_SPI_BUS` property before it consults the session bus, so
an application on the desktop's display silently joins the *desktop's*
accessibility bus unless `AT_SPI_BUS_ADDRESS` is exported — an isolation that
looks airtight and is not. And the folklore about listener registration is not
baseless, just wrong here: upstream `at-spi-bus-launcher` has grown a handler
that flips `IsEnabled` when a client registers an event listener, which would
make registration reach the first gate indirectly. The 2.60.4 build on this
stack contains no such handler, and even where it did, that only puts the
application on the bus — the empty tree behind the window stays empty until
something asks for attributes or relations. It is also not a free action: that
handler writes the desktop's `toolkit-accessibility` setting, turning
accessibility on for every application on the session.

## First integration target: Cairn

The first real-world target is Cairn's own interface: WebView2, backed by
Chromium, on Windows and WebKitGTK on Linux. Accessibility exposure from these
embedded webviews is the load-bearing integration risk. A backend that can
enumerate native controls but cannot obtain the webview content tree does not
meet Cairn's use case.

Early backend work should therefore test provider activation, complete webview
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
| `click` | `semantic` when the element advertises `AXPress`, else `pixel`, else `foreground` | `pixel` for a probe-verified window class, else refused | `pixel` for a Chromium-family target, else `foreground` on X11 with an EWMH window manager, else refused |
| `keyboard` | `pixel` with `app`, else `foreground` | refused | `pixel` for a GTK 3 or Qt 6 target named by `app`, else `foreground` on X11 with an EWMH window manager, else refused |
| `drag` | `pixel` with a semantic-name endpoint, else `foreground` | not implemented | not implemented |

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

On Linux the mechanism is `XSendEvent` against a window the backend resolved, and
it is the only X11 mechanism with the rung's shape: XTest and virtual pointers are
global devices however narrowly aimed, and on Wayland libei has no window
parameter at all, which is why the Wayland refusal is permanent. Relabelling
`XTest` as `pixel` would make the contract's central promise false.

What decides where it may run is a measurement rather than an assumption.
`scripts/linux-toolkit-acceptance/` delivers window-targeted `XSendEvent` input
to a background window per toolkit and reads back whether the target acted, with
a real-pointer click and a focused keystroke as controls so that a silent target
cannot be confused with a misaimed harness. Measured on Fedora 43 in a hermetic
Xvfb lane and again on a live Xfce X11 session: only Chromium acts on a
background click with the focus and pointer unchanged, on all three engine
generations measured; GTK 3, WebKitGTK and Qt act on background keystrokes under
the same conditions; GTK 4 receives neither. Qt also acts on a click while
requesting activation, which the two lanes disagree about precisely because the
live lane's window manager refused the request — an acceptance that depends on
that refusal is not a background delivery. GTK additionally honours a synthetic
click only while the real cursor is already inside the target window, which is why
the mechanism looks available when tried by hand. Chromium's keystrokes are
withheld despite the fixture recording them: they land only once a background
click has already reached that window, and the harness measures its keyboard phase
after its click phase, so the row records that state rather than an independent
acceptance (AXN-102).

That makes the Linux rung the same shape as the Windows one: offered only where a
probe has verified the target, keyed here on the AT-SPI toolkit name and version
the application declares about itself rather than on a window class, and gated by
the table in `rust/axon-linux/src/pixel.rs`. One entry is coarser than that
implies — Chromium reports a constant `1.0` as its version, so an entry authorizes
the whole family — which is why it carries three engine generations of evidence
and an obligation to re-measure when the family releases.

The delivery variant is measured per toolkit and is load-bearing. An event sent
with the matching mask reaches whichever clients selected it on the destination
window; an event sent with an empty mask reaches the client that created the
window whatever it selected. GTK 3 acts only on the second, Chromium and Qt only
on the first, and sending a toolkit the other arrives as silence.

Binding differs by action because the two carry different things. A click resolves
its window by descending from the root to whatever owns the resolved element's
point and requiring that to be one of the target process's own managed top-level
windows, which answers ownership and occlusion together — that descent is this
backend's only hit test, AT-SPI having no portable point-to-element lookup.
Keystrokes name an application rather than an element, so they bind only while the
application has exactly one managed top-level window and refuse the ambiguity
otherwise. Both revalidate immediately before sending, and both read the frontmost
window, the X input focus and the real pointer back afterwards. The focus is read
separately from the frontmost window because they are different facts, and the
harness caught Qt moving one of them while the other stood still.

The pointer reading gates a click and only reports for a keystroke. `XSendEvent`
keyboard events touch no pointing device, so motion around one is the person at
the machine using their own mouse, and failing on it would reject deliveries that
worked on evidence they cannot have caused. A click keeps the clause because an
event that reached the global devices would move the real cursor, and nothing on
this side can tell that from the hand on the mouse, so the fail-safe reading
stands. Which of the two happened is on the wire as `pointerAsserted`.

Unlike the Windows rung, this one has no completion boundary to read those
invariants across: `XSendEvent` hands the events to the X server, and when the
target's own main loop dequeues them is not observable from here. The readings are
taken after a bounded pause instead, and that pause is a backstop rather than the
defence. The defence is the acceptance table, which refuses a toolkit measured to
act while requesting activation instead of delivering to it and watching.

`keyboard` has no pixel rung on Windows and will not grow one in this shape. The
rung is target-bound input derived from verified window geometry; `keyboard`
names an application and an input string, so there is no element, no window to
bind to, and no transform to report. It refuses `backgroundPixelUnsupported`
saying exactly that and falls to the foreground rung. Literal text into a known
field has an honest background home through `type` and UIA `ValuePattern`;
shortcuts and named keys use the explicitly permitted foreground rung.

Linux offers the foreground rung where the session supports it. Windows offers
it in an interactive desktop session where activation can be proved.

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

The hand-back has a stronger Windows constraint than permission alone. A live
Notepad control proved that `SendInput` can return its full inserted-event count
while the target has consumed only a prefix; changing foreground immediately then
redirects the suffix. The identical already-frontmost dispatch landed completely.
Windows exposes no target-consumption fence for this global input stream, and a
trailing sent message is not one because sent messages may run ahead of queued input.

The rung therefore promises only what the backend can prove: activation of the
intended target and exactly one dispatch. Windows leaves the target frontmost after
a dispatch and reports `restored: false` with the input-stream reason; pre-dispatch
exits still restore, and pointer restoration remains guaranteed cleanup work. Other
backends restore after dispatch when their mechanisms provide a safe boundary. This
is deliberately available only under the per-action
`foregroundPermitted` opt-in; `backgroundOnly` remains non-disruptive.

Linux implements the same seams and offers the rung on an X11 session with an
EWMH-capable window manager, withholding it everywhere else. The seams live on
`PlatformBackend` — `supports_foreground_transaction`, `frontmost_application`,
`activate_application`, and, for a mechanism that moves the real cursor,
`pointer_location` and `move_pointer` — while the transaction itself is shared in
`rust/axon-core/src/delivery.rs`. That the two backends implement the same seams
and reach opposite conclusions is the point: the rung is offered on what the
running session can actually prove, not on what the build contains.

What a dispatch at either rung is allowed to *claim* is shared in that same
module. `goal_success` takes the action's verification and the carrying rung's
activation proof and answers with the action's `success`; restoration stays in
the cleanup evidence rather than in that condition. macOS reaches
the same rule through a different shape: `PrimitiveActionResult.unverifiedDispatch`
constructs the delivered-but-unproved result directly, rather than computing it
at each call site.

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

The platform-neutral specification drives a shared conformance suite. Its
fixtures should be language-neutral data wherever possible, with adapters that
run them against Swift and Rust. Schema snapshots verify the public tools;
synthetic trees verify locator behavior; strict target fixtures reject handles and
standalone locators while accepting `{app, name}`; request/response fixtures verify JSON-RPC
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

The `Test` workflow's macOS job also rehearses the live lane's recovery
branches. Because the live workflow has no `pull_request` trigger, its steps
otherwise first execute on a real desktop with nothing having tried them, and
the branches deciding whether that desktop keeps its start-at-login daemon only
run once a probe has already failed. `scripts/test-macos-live-recovery` extracts
those step bodies from the workflow file itself and drives them against stubbed
`launchctl`, `pgrep`, `open`, and Axon commands, asserting the branch and the
message each scenario produces. It runs on the macOS runner rather than a hosted
one so that the shell interpreting it is the same `bash` 3.2 the live lane gets.

The `Test` workflow's Windows job does the same for the Windows lane, whose
stages live in `.github/scripts/windows-live-probe.ps1` rather than in the
workflow file. `scripts/test-windows-live-recovery.ps1` dot-sources those stages
and replaces every function that touches the machine with one that drives a fake
it can inspect afterwards, so a scenario can assert which branch ran, what it
said, and what order it did things in. The probe script keeps those functions
together in a marked region and the harness fails when it finds one it does not
stub, because a seam nobody stubbed is a scenario reaching a real desktop.

The separate `Live desktop verification` workflow is a reporting lane. It runs
only after a push to `main` or an explicit manual dispatch, never for a pull
request. Its self-hosted jobs use dedicated `axon-live-*` labels and serialize
per machine because the same desktops also serve as Cairn executors. A live-lane
failure reports a real integration regression without blocking a pull request:

- macOS builds and Developer-ID-signs the checked-out app, stops the desktop's
  own daemon so the endpoint is free, starts that app under the stable
  Accessibility-approved identity, then captures Calculator, resolves a button,
  invokes `AXPress`, and verifies the display changed — putting the desktop's
  own daemon back afterwards whatever the probe did;
- Linux connects to the logged-in GNOME session's AT-SPI bus and runs the
  hardened Calculator probe, which verifies the expected text transition on the
  same AT-SPI object that was captured before dispatch, then asserts that
  `keyboard` refuses with `noDeliveryCandidate` at both policies because the
  session is Wayland;
- Windows uses a localhost-only, forced-command SSH key to cross from the
  runner's session-0 service into the desktop user's process context, because
  Task Scheduler is what puts a daemon on the logged-in desktop and a
  service-session process can never see one. It crosses that relay four times —
  build, park, probe, restore — rather than once, so the restore is an
  `if: always()` step of its own: a `finally` block inside a single remote call
  cannot run when a cancelled job kills the `ssh` client and the remote shell
  with it. The probe registers a scheduled task of its own name, requires the
  daemon answering `\\\\.\\pipe\\axon-v1` to be the process that task started,
  and reads a real window root off the interactive desktop from an application it
  did not start — the daemon runs as a console process and enumerates its own
  window, which would otherwise let a session with nothing running satisfy the
  assertion.

Every live runner is also somebody's desktop, which is the source of the one
failure mode that would quietly hollow these lanes out. The endpoint is a
rendezvous, not a proof of authorship: only `serve` binds it and every other
subcommand is a client, so a probe that starts its own daemon and then talks to
the endpoint is answered by whichever daemon holds it — routinely the installed
release the desktop user already runs. The freshly built daemon loses the bind,
and when a probe backgrounds it the shell never sees that it exited, so every
assertion afterwards is true of a binary nobody changed.

All three lanes close this. Each stops the desktop's own daemon once for the
whole job rather than once per probe, confirms nothing is answering on the
endpoint before any probe starts, and asserts that the process id in the health
document is the process id it launched. What that pid names differs by platform.
On Linux it is the `serve` process the probe backgrounded. On macOS the app
bundle serves the endpoint from inside its own process — there is no `serve`
child — so it is the pid of the app that `open -n` launched, found by the bundle
executable's path under the workspace, which no installed copy shares, and
required to be the only process running from it. On Windows nothing the job runs
launches the daemon at all: Task Scheduler does, in the logged-in session, and it
reports nothing about the process it started, so the pid is found by the probe
executable's path — outside the workspace, and shared by no installed copy — and
likewise required to be the only process running from it.
`scripts/assert-daemon-under-test` carries the check for the two lanes that run
under `bash`; the Windows stage carries its own, because the relay's environment
is PowerShell in session 0 with no `jq`.

Two properties of the stop matter as much as making one. It has to be performed
by the build under test rather than by the runner's installed CLI, which is
whichever release that desktop last installed and may predate the verb entirely;
the macOS lane called `shutdown` on an installed binary that had no such
subcommand, and `|| true` meant nothing ever reported it. And it must not be
tolerated: `axon shutdown` and `systemctl stop` exit non-zero while anything is
still answering, which is exactly what makes their success the endpoint-is-free
guarantee the probes rest on. What a request that fails means, and what one
means that succeeds after another has already been acknowledged, are different
questions that the exit code does not answer on its own — the Windows park works
both out from the process, described with the rest of that lane's patience below.

A stop also incurs a debt, and a final `if: always()` step pays it. `axon
shutdown` is not a pause — it boots the LaunchAgent out precisely so `KeepAlive`
cannot relaunch the daemon between it acknowledging the request and exiting, and
the agent then stays unloaded for the rest of the login session while the plist
sits on disk still reading as registered. Linux puts its systemd unit back:
contents, enablement, and running state. macOS reloads the agent with `axon
daemon restart`, which bootstraps the plist on disk without rewriting it;
`daemon install` would repoint the desktop's registration at the job's `dist`
directory and is never the restore. Neither lane trusts the restart's exit code,
because whatever starts a daemon reports on starting it: `systemctl start` is a
claim about `exec` under `Type=simple`, and `launchctl bootstrap` is a claim
about loading a job. Both therefore require the restored daemon to answer a
health round trip and to be the process systemd or launchd names, and neither
treats the restart command's own status as the verdict — on macOS that command
includes a readiness wait parsed with the *building* release's decoder, which a
release skew the rest of the step deliberately tolerates could fail on its own.

The macOS probe leaves one thing behind that its Linux counterpart cannot, and
`scripts/stop-probe-app` is what removes it. The two daemons behave differently
when they lose the endpoint: `serve` exits, while the app bundle catches the
socket error, records it in its menu, and keeps running. A probe app that never
bound is therefore a live process answering no health request, which `axon
shutdown` can neither see nor stop, since it stops a daemon by asking it to —
and one that bound and then wedged still holds the advisory lock that makes the
next `serve` refuse. Left alone it outlives its job and survives the next
checkout, because deleting an executable does not change a running process's
arguments. Both the parking and restore steps sweep it by workspace path, which
is what keeps the sweep from ever reaching an installed copy; the Windows job's
`Remove leaked live-probe daemons` is the same measure for the same reason.

Windows carries one rule the other two do not need, because its registration is
a machine-wide object that a security product can act on by name. The daemon
under test runs from a scheduled task of the probe's own, and the machine's
`Axon Windows Daemon` task is read and started but never written — not
unregistered, not repointed, not restored, because nothing touches it.

The earlier lane did write it. It unregistered the desktop's task, registered its
own under the same name at a binary freshly built into `C:\ProgramData\Axon\live`,
and put the original back in a `finally`. On 2026-08-08 Defender classified that
binary as execution and persistence malware and quarantined it between the
install and the restart. A behavioural detection of that kind removes what refers
to the file as well as the file: an earlier detection on the same runner took
`C:\Windows\System32\Tasks\Axon Windows Daemon` and its TaskCache registry keys
with it. Every fresh CI build is a never-seen binary, so a registration that
names one is the ordinary case rather than the unlucky one, and a desktop whose
start-at-login registration names it can lose that registration to a scan it
never ran.

Windows also records its debt where the debt can outlive the job. `$GITHUB_ENV`
dies with the runner, so on macOS and Linux a job whose runner service is killed
outright leaves a desktop stopped with nothing that remembers why. The Windows
park writes what it found to a file on the machine before it stops anything, and
the next park carries an unpaid debt forward rather than overwriting it — without
that, the following run would find no daemon, record that there had never been
one to put back, and let its own restore clear the debt and report success,
turning an outage that a logon would have ended into one that lasts the whole
login session. The restore step is conditioned only on the checkout having
succeeded, and not on this job having parked anything, for the same reason: a
job-scoped sentinel is a second answer to a question the machine already answers,
and it can only subtract — exactly in the case the record exists for, since a run
that fails before its own park is precisely the run that would otherwise walk
past a debt it could have paid.

Three further consequences shape the lane. Each build is executed once — a
`version` call — before anything on the desktop is borrowed, which is where
block-at-first-sight's delay of up to a minute is paid and where a quarantine
costs nothing, since the machine still has its own daemon at that point; it also
keeps that delay out of the daemon's readiness measurement, which had been
reporting 47 seconds for a daemon whose own startup log said 1.46. The probe
re-asserts at the end that the desktop's registration still points where the park
recorded it, so a lane that repointed the machine could not report success. And
the restore needs no Axon binary at all when the build under test has vanished:
Task Scheduler starts the registration at its own path, and the health round trip
that decides the verdict is read through the executable that registration names.

That restore is also patient, and patient in a particular place. The daemon gives
up thirty seconds after failing to get a UI Automation client, which is fail-fast
behaviour worth keeping — and which a desktop under a background servicing
operation can blow while being perfectly healthy four minutes later. So the lane
carries the patience rather than the daemon's bound: when nothing is answering,
the restore starts `Axon Windows Daemon` up to three times, and it reads the
task's state before each start. That read is the part that is easy to leave out.
Task Scheduler discards a start against a task whose previous instance has not
finished, and `schtasks /run` reports success while discarding it, so a fallback
that fires blindly can start nothing at all and leave a poll waiting for a daemon
nobody launched — which is how run 31339688217 ended with a red lane and a
healthy desktop. A running instance is therefore waited out rather than started
over, with the health round trip polled throughout, since `Running` is equally
what a healthy daemon looks like: the registered action is `serve`, so the task
runs for as long as its daemon lives. When the budget expires with nothing
answering, the stage fails exactly as loudly as before, because a desktop that
cannot get its daemon back is a runner that needs a human.

The park is patient in the same way, and the daemon's bound is again what makes
it necessary. `axon-win shutdown` waits ten seconds for the process it asked to
stop, because the acknowledgement is sent before the UI Automation thread joins
and the COM apartment is torn down, and reporting a stop before the process is
gone races whatever runs next; anything slower than that wait it reports as a
failure. On 2026-08-10 the wait expired on a runner that had just finished a
cargo build, the stage failed the lane, and the process exited seconds later
while the `if: always()` restore was already putting the desktop back — a red run
over a healthy desktop. A failed request therefore opens a wait rather than
ending the stage: the park polls the process the health document named, and asks
again up to three times, roughly ninety seconds in all.

What it must not do is believe a later request that reports success. The pipe
goes when a daemon acknowledges the request and the process goes when it has
finished tearing down, so once one request has been acknowledged every request
after it finds no pipe at all and reports exactly that. `no daemon was running`
is a true statement about the pipe that says nothing about the process, and
taking it for one would hand the probe a machine where the daemon this stage set
out to stop is still there — which is the race the command's own wait exists to
prevent, recreated by the lane that was supposed to be patient about it. So the
process is the verdict every time round the loop, and a daemon whose document
names no process id at all is waited for through the health round trip instead,
which is the same tolerance the restore extends to an old enough release. What has not changed is what a stop that never
takes costs: a daemon still running when the budget is gone fails the stage as
loudly as it did before there was one, and it is named rather than killed,
because a daemon this lane kills is a daemon it cannot put back. The debt is
recorded before any of this, so a park that dies in the middle of it still tells
the restore what it owes.

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
allocation with the authorized-key `restrict` option. That file's source is
`.github/scripts/windows-live-relay.cmd`. It lives on the machine rather than
being read from the workspace, so changing what the key dispatches to takes
machine access — but what each stage then runs is the probe script from the
runner's own checkout, so the relay constrains *which stage* runs and not *what
code* runs. The boundary for untrusted changes is the repository's Actions
approval policy for outside contributors, not this file. It accepts only the four
stage names, and it expands the requested one with delayed expansion, because a
value substituted before `cmd` tokenizes the line lets an `&` in it run as a
separate command before the allowlist is ever consulted. A runner whose copy
predates the staged lane refuses every stage with exit code 126, which the
workflow reports by name. Deploy it whenever either file changes. Give the private key only
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

## Rust macOS backend v1

`rust/axon-mac` is the production ApplicationServices implementation of
`axon_core::PlatformBackend`. It captures each selected application's complete
Accessibility window tree, including native `AXRole`/`AXSubrole` vocabulary,
labels, values, identifiers, actions, editability, and screen extents. Its role
semantics deliberately mirror the Swift tables in
`Sources/AxonCore/AXHierarchyBulkCapturer.swift` and
`Sources/AxonCore/AXRoleSemantics.swift`: press is inferred for buttons, links,
check boxes, radio buttons, and menu items, while combo boxes, text areas, and
text fields are editable.

One vocabulary names an application throughout this backend. Resolution matches
an `AppQuery` against the running applications it enumerates: `process_id`
against the pid, `name` case-insensitively against the display name, and
`identifier` against the bundle identifier. That is the meaning `identifier`
carries on Windows and Linux too, where it is likewise the stable identity the
backend publishes in `Application.identifier`, and macOS publishes its bundle
identifier there rather than leaving it null.

A capture driven by a recorded input event queries on one key rather than all
three, following the precedence `RecordedAppIdentity::matches_runtime` already
defines: the process id, else the bundle identifier, else the name. A recorded
identity is only as strong as its strongest key, so constraining the weaker
fields alongside it cannot make the match more certain and can only strand the
evidence for an event that was genuinely observed. Constraining all three is how
every macOS recording once ended with zero actions.

The display name is `NSRunningApplication.localizedName`, falling back to the
application element's `AXTitle`, decided in one place in
`rust/axon-mac/src/global_input.rs` for enumeration, capture, and the recorder
alike. That matches `AppResolver` in `Sources/AxonCore`, which reports and
resolves applications by localized name and bundle identifier and never consults
AXTitle; AXTitle names windows and elements, not applications. Sharing the
decision keeps a recorded artifact calling an application what `look` calls it.

The v1 facade exposes `look`, `find`, `click`, `type`, `keyboard`, `invoke`,
`scroll`, and `run`. `look` derives semantic names through axon-core and actions
resolve the strict `{app,name}` target through the shared registry; ambiguous
names return candidates without dispatch. Element clicks use `AXPress`, typing
uses `AXValue`, invoke uses the requested AX action (defaulting to `AXPress`),
and scrolling uses `AXScrollToVisible`. Global keyboard input has no semantic
Accessibility action and therefore refuses honestly in v1. Pixel and foreground
delivery are likewise unimplemented rather than approximated. Extended
observation, history, permission prompting, and drag tools fail before native
dispatch with capability errors.

Full application observations capture the first Accessibility window through
Core Graphics' synchronous per-window image API, resize its long edge to the
shared observation budget without upscaling, and encode it losslessly with
ImageIO. This deliberately uses `CGWindowListCreateImage` rather than
ScreenCaptureKit: the backend needs one already-resolved window image, while
ScreenCaptureKit would add an Objective-C asynchronous callback bridge and
capture-session lifecycle without improving that result. The direct framework
FFI also preserves the backend's dependency-free native boundary. Core
Foundation values returned under Create/Copy ownership are released exactly
once; borrowed Accessibility array members are retained before they enter an
owned wrapper.

Screenshot health is independent and truthful: the capability is usable only
when `CGPreflightScreenCaptureAccess` reports a Screen Recording grant, and its
restriction names that missing grant otherwise. One owned `CGImage` can feed
ImageIO, native Vision text recognition, or both, so requesting screenshot and
screen text never captures twice. A narrow Objective-C bridge owns Vision
objects, autorelease and exception boundaries; Rust converts Vision's
lower-left normalized boxes into absolute Accessibility coordinates. Capture,
encoding, or OCR failure is returned as named observation unavailability while
the semantic `look` still succeeds. The app-list, change-check, and child-page
carve-outs remain imageless through axon-core's shared screenshot policy.

The daemon resolves the same production endpoint as every Swift client and the
LaunchAgent: `AXON_SOCKET_PATH`, defaulting to `/tmp/axon.sock`. Development,
conformance, and bench probes retain the higher-priority `AXON_MAC_SOCKET`
private-endpoint override so branch builds never need to repoint an installed daemon.
The server owns a lifetime `flock`, reclaims only stale socket nodes, and serves
connections concurrently through one serialized native-backend worker. Health and
shutdown bypass that worker so a long replay or wait cannot hide daemon liveness.
The registered Swift daemon remains unchanged until the deliberate cutover stage.

The durable bglab-mac development identity is packaged by
`scripts/package-macos-rust-bench` at `~/AxonBench/AxonMacDev.app`, with the
stable bundle identifier `dev.axon.mac-bench`. The script replaces and
ad-hoc-signs only the binary inside that stable bundle; it never installs a
daemon or edits TCC. `scripts/probe-macos-rust-bench` starts that binary on a
unique isolated socket and performs a trivial Calculator AX read, which future
builders run before asking for another Accessibility grant. Any live test that
launches a desktop application on a bench machine must quit that application
before handing the machine off. The live lane's clean-desktop guard treats a
leftover application as an occupied session and refuses to run, so cleanup is
part of every live test rather than an optional follow-up.

macOS application enumeration filters process paths to app-bundle main
executables and excludes nested XPC services. XPC helpers can inherit their
host application's AX title (Calculator's ThemeWidget service does), so AXTitle
alone is not an application identity and would make strict app lookup falsely
ambiguous.

### macOS Accessibility trust is per-process, and behaviour is the truthful source

**Measured.** `AXIsProcessTrusted()` answers with a verdict HIServices resolves
once per process and does not revisit. Measured on bglab-mac (2026-09-03)
against a running daemon while the user toggled its Accessibility row, it is
frozen in both directions: a daemon trusted at launch kept reporting trusted
after the grant was revoked, and a daemon that started untrusted kept reporting
untrusted after it was restored. In the same run, AX reads *did* fail on the
still-trusted-looking process while its cached verdict said trusted — that is
how `look` came to report `application not found` for an application that was
running and visible. So the cached verdict and the API's actual behaviour
disagree, and the cached verdict is the one that is wrong. On the build that
made those measurements, which gated every AX call on the cached verdict, a
re-granted daemon had to be restarted before it recovered.

The design that follows from this is that behaviour, not the cached verdict, is
the truthful source. `rust/axon-mac/src/accessibility.rs` is the one place that
answers "can this process use Accessibility right now": it asks the API to do a
trivial piece of work and classifies the `AXError`, falling back to the cached
verdict only when the status does not settle the question. Every other module
delegates to it.

The classification ladder is deliberately asymmetric. `kAXErrorNoValue` and
`kAXErrorAttributeUnsupported` mean the call was *served*, so a session with
nothing focused does not read as denied. `kAXErrorCannotComplete` is ambiguous
between an unresponsive target and a denial, so it defers to the cached verdict
rather than flipping it. Only `kAXErrorAPIDisabled` (-25211) makes a
trusted-looking process denied. That asymmetry is a safety property: in the
granted case the probe can only answer granted or unknown, and both preserve
whatever the cached verdict already said, so the probe cannot invent a denial.
It earns its keep immediately — measured in a non-interactive build slot that
*holds* the grant but has no focused application, the system-wide read returns
`kAXErrorCannotComplete` and the fallback preserves the granted answer.

Application enumeration folds the same statuses from the `AXTitle` read it makes
on each candidate process. When that fold says denied, `look` refuses with the
typed `accessibility-denied` capability error instead of the misleading
`application not found` an empty list otherwise produces. This path does not
depend on a focused application, so it is the one that stays measurable in any
session.

**Pending measurement.** Three questions are open until the live revoke/re-grant
run on bglab-mac, and none of the code above asserts an answer to them:

- Which `AXError` a withdrawn grant actually produces. The typed refusal fires
  only on `kAXErrorAPIDisabled`; if the real status is `kAXErrorCannotComplete`,
  the fold reads unknown and `look` keeps reporting `application not found`.
- Whether the system-wide probe moves at all across a toggle, or is inert in the
  same way the cached verdict is.
- Whether a re-granted daemon now recovers without a restart. The restart
  requirement above was measured against a build that never reached an AX call
  once its cached verdict said no; it is not established for this one.

`axon-mac probe trust [--pid N] [--interval-ms N] [--count N]` is the harness
that answers them, following the `axon-win probe <name>` convention. It emits
one JSON object per sample carrying `axIsProcessTrusted`,
`axIsProcessTrustedWithOptions`, the raw `systemWideStatus`, the raw `pidStatus`
from the read enumeration actually makes, and the verdict the build would act
on. Those columns beside each other across a toggle separate "the verdict is
cached" from "the API is disabled" without any inference; `pidStatus` is the one
the typed `look` refusal depends on. Update this section with the dated result
once the run happens.

### Permissions are reported per TCC row; capabilities compose them

`kTCCServiceAccessibility` and `kTCCServiceScreenCapture` are separate rows a
user toggles separately, and the health report's `permissions` block says so:
each `PermissionState` reports only its own grant. Capabilities are free to
compose the two, and `screenshot` does — but deriving the `screenRecording`
permission field back out of that composed capability made a
denied-Accessibility daemon claim Screen Recording was ungranted while its TCC
row read granted the whole time. `MacPermissions` in
`rust/axon-mac/src/platform.rs` reads the two independently; `capability_report`
is a pure function of them, and health uses both rather than deriving one from
the other.

The Rust backend's `screenshot` capability is unusable without Accessibility
even when Screen Recording is granted, because this backend names the window to
capture by resolving the application through the Accessibility API. The Swift
daemon resolves applications through NSWorkspace and so does not share that
restriction; `Tests/AxonCoreTests/HealthStatusTests.swift` and
`schema/fixtures/health/macos-accessibility-denied.json` describe that
implementation, not this one. Both are right about themselves. Once `axon-mac`
becomes the shipping macOS daemon this needs a decision: either the Rust backend
grows a non-Accessibility application resolution path, or the shared fixture
stops claiming to describe both implementations.

### Recording refuses on capability before a session exists

`recording.start` and `editor.recordFromHere` ask `global_input_observer()`
before dispatching to the daemon. That seam is the one place that knows whether
this process can watch input, and asking first means a denied start never opens
a recording it then has to abandon. It also matches the backend's established
convention of refusing on capability before validating parameters. The refusal
carries `-32004` with `kind: capability-unavailable` and the stable
`code: accessibility-denied`, matching `look`.


## macOS browser Automation attribution

The Swift daemon sends Safari and Google Chrome events directly through
`NSAppleScript.executeAndReturnError`; it does not launch `osascript`. Authorization is split by who
is asking. Agent-facing verbs call `AEDeterminePermissionToAutomateTarget` with
`askUserIfNeeded: false` and refuse on anything but `noErr`: the prompting call blocks its thread
until a person dismisses the dialog, and browser verbs run synchronously on the socket-handling
thread, so prompting from there would stall an agent's call indefinitely on a dialog nobody asked
for. The prompting leg belongs to one deliberate gesture — the daemon menu's Browser Automation item,
which requests consent off the main thread for each supported browser that is running. That item
exists only when the gesture has something to do: it is built from a non-prompting reading of the
same per-process answer ledger, and a denial keeps it (the gesture is then the only surface carrying
the remediation) while an all-allowed reading retires it. The reading happens as the menu opens
rather than on the menu's two-second refresh, because a determination is not free — it costs a TCC
round trip, and it is what makes the process start holding macOS's answer, which must not happen
earlier than a person's own use of Axon would cause it. The item therefore returns for a browser this
process has no answer for, and not for a grant reset behind an answer it already holds: the ledger
has the same lifetime as the process-held answer it mirrors, and a reset is visible only after a
restart. An executed-leg denial is the one answer a later preflight cannot overwrite — it is the
answer that proved the preflight wrong for that target — so neither a browser verb nor the consent
gesture can retire the item on the strength of a `noErr` that contradicts a refused event. The intended
sender is `Axon.app/Contents/MacOS/Axon`, registered in launchd's `gui/<uid>` domain with
`LimitLoadToSessionType=Aqua`; the daemon bundle also carries `NSAppleEventsUsageDescription`.

Every decision names the leg that produced it — `checked`, `prompted`, or `executed` — in the
JSON-RPC error's `data.leg` and in one stderr line per decision, which the LaunchAgent routes to
`~/Library/Logs/Axon/daemon.err.log`. A field report should be readable without a bench protocol.

An Automation trial must restart the daemon after resetting a grant. macOS resolves an authorization
inside the sending process once that process holds an answer for a sender/target pair, and `tccutil
reset` rewrites the TCC database without reaching into a running process. The 2026-08-14 trial ran
denial, reset, and retry against a daemon that never restarted (`launchctl print` reported `runs = 1`
and a single `exec` throughout), so the retry could not have consulted tccd; the absence of any
`kTCCServiceAppleEvents` request for Axon in that window is what an answer resolved inside the
process looks like, not evidence of a suppressed prompt. The daemon therefore records, per process
lifetime, the answer it holds for each target — from either leg, since it was a silent-leg answer
that got reused — and a repeat denial names a daemon restart as the remediation instead of pointing
at System Settings. Keeping the answer and not merely the fact of one is what lets a surface that
must not prompt, the menu, read a grant Axon has already seen.

What remains unverified is whether the consent dialog appears at all for this launchd-started
process. The menu-bar gesture is the discriminating test, on a machine whose daemon has restarted
since the reset. If no dialog appears there, the next evidence is `launchctl procinfo <pid>` for the
responsible-process attribution — the job is `trampolined`, started via `xpcproxy`, which is a
platform binary — and the candidate fix is registering the bundle with `SMAppService.mainApp` so
LaunchServices starts the app rather than launchd exec'ing the binary. If prompting proves
impossible from this context, the honest answer is that browser Automation needs an MDM PPPC profile
(`kTCCServiceAppleEvents` with `AEReceiverIdentifier` per browser) on managed Macs and is
unavailable elsewhere, reported as a capability restriction rather than a permission the user can
fix.

Apple Events TCC evidence must be attributed by client bundle identifier, indirect target bundle
identifier, and the code-signing requirement stored in the row. A path or PID alone is not identity.
Live probes must launch a signed bundle main executable through a private GUI-domain launchd label
and socket, assert the answering PID and executable, and reset only the throwaway bundle's Apple
Events grant. Existing daemon and browser state must be restored unconditionally. Since TCC stores
the granting-time code requirement, upgrade persistence is meaningful only when both trial bundles
use the same stable bundle identifier and designated requirement; ad-hoc signatures cannot establish
that claim. The Rust macOS backend must preserve this attribution model when it adopts browser
operations.
