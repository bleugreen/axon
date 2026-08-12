# Cross-platform support

Axon runs on macOS, Windows, and Linux: one canonical Swift implementation on
macOS, and a sibling Rust workspace carrying the Windows UI Automation and
Linux AT-SPI2 backends. All three implement the same
[platform-neutral contract](platform-spec.md), rather than sharing runtime
code or pretending the operating systems expose one normalized accessibility
API.

What each environment can actually prove today is recorded in the
[support matrix](#support-matrix) below. The support matrix is the claim. Contributor-facing backend architecture and verification machinery live in [Cross-platform internals](../docs/cross-platform-internals.md).

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
| Windows 10+ (UIA) | **Supported with limits** — `InvokePattern` only; the live loop verifies capture, dispatch evidence is dated probes | **Supported with limits** — window-message pixel rung for probe-allowlisted classes (`Button` only); the foreground rung is **refused** (hand-back unproven) | **Refused** — no target-bound rung exists and the foreground rung is withheld | **Supported** — the live loop requires a default PNG observation image bounded to 1280 pixels through Windows Graphics Capture | **Supported with limits** — physical pixels with DPI reconciliation reported as evidence; probe-earned at 100% scaling only | interactive-session scheduled task (live-verified); elevation parity or UIAccess for elevated targets; built-in MSAA activation for WebView2 |
| Linux X11 (EWMH window manager) | **Supported** — the session-independent AT-SPI path the Linux live loop verifies | **Supported with limits** — window-targeted `XSendEvent` pixel rung for Chromium-family targets, bench-verified end to end against Electron 43 (the page reported the click `isTrusted` with the focus and pointer unchanged); every other toolkit **refuses** by name. XTest foreground transaction verified hermetically under Xvfb each PR | **Supported with limits** — window-targeted `XSendEvent` pixel rung for GTK 3 (`owner` variant) and Qt 6 (`targeted`), both bench-verified typing into an unfocused window; Chromium is **refused** because its keystrokes land only once a click already has (AXN-102). Otherwise XTest, and keysyms must exist in the active layout | **Supported** — direct X11 window capture, lossless PNG with a 1280-pixel long-edge bound; bench-verified on fedora | **Supported with limits** — all four rectangle components measured against toolkit ground truth: GTK 3, Qt, WebKitGTK and Chromium agree within four pixels; GTK 4 reports correct sizes at `(0, 0)` origins and is unusable | systemd user unit; AT-SPI enabled; an EWMH manager publishing `_NET_ACTIVE_WINDOW` and `_NET_WM_PID`; the XTEST extension |
| Linux GNOME/Mutter (Wayland) | **Supported** — live loop: capture, resolve, invoke, and verified readback on GNOME Calculator | **Refused (verified)** — the live loop asserts `noDeliveryCandidate` naming Wayland at both policies | **Refused (verified)** — same check | **Not implemented** — portal path designed, unattended authorization unproven | **Supported with limits** — compositor-reported extents; GTK4 descendants report (0,0) origins and are unusable for pointer targeting | AT-SPI bus with accessibility enabled; systemd user unit bound to `graphical-session.target` |
| Linux KWin (Wayland) | **Experimental** | **Refused (expected)** — Wayland classification is verified under Mutter, not KWin | **Refused (expected)** | **Not implemented** | **Experimental** | same as GNOME/Mutter; no KWin runner exists |
| Linux Sway / wlroots (Wayland) | **Experimental** | **Refused (expected)** | **Refused (expected)** | **Not implemented** | **Experimental** | same as GNOME/Mutter; no wlroots runner exists |
| XWayland clients under a Wayland session | **Supported** — X11 clients register on AT-SPI like any application | **Refused (verified)** — the session is classified as Wayland before any X connection; the live runner's session runs XWayland alongside and the refusal is asserted there | **Refused (verified)** | **Not implemented** | **Supported with limits** — the Mutter geometry caveat applies | none beyond the session's; a working XTest conversation with XWayland is not evidence of delivery capability |

### Canonical evidence

These are the only sources that promote or sustain a **Supported** cell.

| evidence | where | what it proves | cadence |
| --- | --- | --- | --- |
| macOS live loop | `.github/workflows/live.yml` `macos` job | capture → resolve → `invoke` `AXPress` → verified Calculator display; complete health-v1 document; Accessibility grant — each asserted against the app bundle the job launched, by process id | every push to `main` |
| macOS grant-carry upgrade verification | `bglab-mac`, measured during the axn/119 v0.3.0 rollout | `daemon install` from `~/.local/lib/axon/0.3.0` repointed the LaunchAgent from 0.2.3 while the unchanged `com.bleugreen.axon` bundle identity carried Accessibility and Screen Recording grants across the upgrade: the daemon returned ready in about one second with all fifteen capabilities usable and no System Settings prompts | manual (2026-08-11); re-run on changes to bundle identity or installation registration |
| Linux live loop | `.github/workflows/live.yml` `linux` job | AT-SPI capture/resolve/invoke with verified readback on GNOME Calculator under GNOME/Mutter Wayland; honest refusal of global input at both policies; systemd-user lifecycle and health-v1, including the session accessibility switch this runner has on | every push to `main` |
| Windows live loop | `.github/workflows/live.yml` `windows` job | the interactive-session daemon serves `look` with a real window root through the DACL-restricted pipe, and the complete health-v1 document — each asserted against the task the job registered, by process id, with the desktop's own registration proved unchanged across the run | every push to `main` |
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
untrustworthy for GTK4 descendants (spike-recorded, dated). Mutter advertises
the RemoteDesktop and ScreenCast portals; nothing about unattended
authorization is proven, so portals keep screenshots and synthetic input out
of the supported columns.

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
- Recording (`save` from live history, global user-input observation): macOS
  only. `serializeHistory` and `observeGlobalInput` are unimplemented on both
  Rust backends.
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
