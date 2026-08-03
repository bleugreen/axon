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
- Windows 10 and later support `AF_UNIX`, so the local Unix-domain socket
  transport and MCP-facade topology can carry over. Installation must still use
  Windows-native access controls and lifecycle management.
- The implemented Windows daemon uses `\\.\pipe\axon-v1` instead of `AF_UNIX`.
  Named pipes allow the interactive-session process to reject remote clients. At
  startup, `axon-win serve` reads the user SID from its process token and installs
  a protected DACL granting pipe access only to that SID; it does not rely on the
  process default security descriptor. `axon-win daemon install` registers an
  interactive `ONLOGON` scheduled task for the current user and starts it; this
  is the canonical installation path because Task Scheduler launches `serve` in
  the logged-in desktop session even when the command is issued over an SSH
  session-0 shell. `axon-win daemon restart` sends the authenticated `shutdown`
  RPC, updates the task to the current executable, and relaunches it. The daemon
  acknowledges shutdown with its process ID before closing the pipe. Lifecycle
  commands wait for that process to exit after its UIA thread joins and the COM
  apartment is torn down, avoiding a Task Scheduler relaunch race. Busy pipe
  instances are retried rather than mistaken for an absent daemon. `axon-win daemon
  uninstall` stops the daemon and removes the task. All three commands are
  scriptable and `install`/`restart` wait until the pipe is ready before returning.
  Short-lived `axon-win mcp` processes connect to that pipe.
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
- Under X11, XTest provides the practical synthetic-input fallback and global
  observation is feasible.
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

## Keeping implementations aligned

The platform-neutral specification will drive a shared conformance suite. Its
fixtures should be language-neutral data wherever possible, with adapters that
run them against Swift and Rust. Schema snapshots verify the public tools;
synthetic trees verify locator behavior; request/response fixtures verify JSON-RPC
and MCP envelopes; `.axn` fixtures verify parsing and traces; backend harnesses
verify capability and honest-result semantics.

Native integration tests remain necessary because no fixture can prove UIA or
AT-SPI exposure. Conformance establishes that implementations mean the same
thing; native tests establish that each backend can deliver it.

## Continuous integration lanes

The hosted `Test` workflow is the merge gate. It runs deterministic Swift and
Rust tests on GitHub-hosted machines for pull requests and pushes to `main`.

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
  same AT-SPI object that was captured before dispatch;
- Windows rebuilds `axon-win`, restarts its scheduled interactive-session daemon
  from the runner's session-0 service, sends `look` through
  `\\.\pipe\axon-v1`, and requires a real window root.

The repository's Actions policy requires approval for every outside
contributor's workflow runs. This is defense in depth: the live workflow's lack
of a `pull_request` trigger is the boundary that prevents fork code from reaching
the self-hosted desktops.

### Re-enrolling a live runner

Remove the offline runner in **Settings > Actions > Runners**, then stop and
uninstall its local runner service. Download the current runner package from the
repository's **New self-hosted runner** page, request a fresh registration token,
and configure the replacement as the desktop user with exactly one dedicated
label: `axon-live-mac`, `axon-live-linux`, or `axon-live-windows`. Install and
start it with the runner package's platform service command (`svc.sh install`
and `svc.sh start` on macOS/Linux, `svc.cmd install` and `svc.cmd start` on
Windows). Confirm the runner is online and carries `self-hosted`, its operating
system and architecture labels, and its dedicated `axon-live-*` label before
dispatching the workflow.

Registration tokens are short-lived secrets. Generate one immediately before
configuration with:

```sh
gh api repos/bleugreen/axon/actions/runners/registration-token -X POST --jq .token
```