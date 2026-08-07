# Cross-platform Axon design

Axon expands beyond macOS as a sibling Rust implementation with native
backends. The existing Swift implementation remains the canonical macOS
implementation. Both implement the same [platform-neutral contract](platform-spec.md),
rather than sharing runtime code or pretending the operating systems expose one
normalized accessibility API.

Windows UI Automation is the first backend. Linux AT-SPI2 follows after the
Windows implementation proves the shared core and backend boundary.

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
| `click` | `semantic` when the element advertises `AXPress`, else `pixel`, else `foreground` | refused | `foreground` on X11 with an EWMH window manager, else refused |
| `keyboard` | `pixel` with `app`, else `foreground` | refused | `foreground` on X11 with an EWMH window manager, else refused |
| `drag` | `pixel` with an app or handle endpoint, else `foreground` | not implemented | not implemented |

No backend reports `pixel` for a mechanism it cannot bind to a verified target.
On Windows, HWND-targeted client-coordinate delivery is not implemented; on
Linux, neither X11 window-targeted delivery nor a Wayland portal path is
implemented. Both refuse with `backgroundPixelUnsupported` and a message naming
what is missing, because relabelling `SendInput` or `XTest` as `pixel` would make
the contract's central promise false.

Windows does not offer the foreground rung, which is why pointer and keyboard
actions refuse outright there. It has `SendInput`, but the foreground rung is
global input that hands the session back, and this backend cannot yet capture the
prior foreground, activate the target, prove it came forward, and restore.
Dispatching unrestored global input while reporting `delivery: "foreground"`
would claim a guarantee it does not keep, and the unrestored focus theft is the
very behavior the contract exists to prevent.

The seams live on `PlatformBackend` — `supports_foreground_transaction`,
`frontmost_application`, `activate_application`, and, for a mechanism that moves
the real cursor, `pointer_location` and `move_pointer` — while the transaction
itself is shared in `rust/axon-core/src/delivery.rs`. Linux implements them and
offers the rung where the session supports it; Windows implements none of them
yet.

### Windows session and integrity constraints

`SendInput` is the foreground rung and needs the explicit opt-in. It also needs a
session that can reach the global input devices at all. Session 0, a
noninteractive window station, and an integrity or elevation boundary between the
daemon and the target all present as an unusable `pointerInput` or
`keyboardInput` capability in the health document, and the same overlay feeds the
dispatch decision. When the capability is unusable the refusal is
`noDeliveryCandidate`, not `foregroundNotPermitted`, at either policy — opting in
cannot conjure a device.

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