# Linux toolkit acceptance harness

Measures, per toolkit, whether a **background** window acts on input delivered to it with
`XSendEvent`, and whether AT-SPI reports usable on-screen geometry for that window's widgets.

Those two facts decide whether Linux can have a `pixel` delivery rung at all. `docs/platform-spec.md`
only permits a backend to classify a mechanism as `pixel` when it is bound to a verified target
window, derives its coordinates from resolved window geometry, and leaves the frontmost application
and the real pointer unchanged. On X11 exactly one mechanism has that shape — `XSendEvent` against a
window the backend resolved — and every event it delivers is flagged `send_event = True`, which a
toolkit is free to ignore. `XSendEvent` reports success as soon as the X server accepts the request,
so nothing on the sending side can tell acceptance from silence. Only the target's own behaviour can.

The harness exists because there is no honest runtime alternative. A pre-flight probe that produces
no observable effect proves nothing, and one that produces an effect has already mutated the user's
window. Inferring acceptance from `WM_CLASS` or from loaded libraries is a guess wearing a probe's
clothes. So the fact is measured once, here, and committed.

## Running it

```sh
scripts/linux-toolkit-acceptance/run                 # hermetic: brings up its own Xvfb
scripts/linux-toolkit-acceptance/run --only gtk3,gtk4
scripts/linux-toolkit-acceptance/run --current-display   # measure a real session on $DISPLAY
```

It needs `Xvfb`, `dbus-run-session`, the AT-SPI 2 stack, and whichever toolkits are to be measured.
A toolkit that is not installed is recorded as `unavailable` rather than silently dropped, so a
result table always says what it did and did not see.

The measurement is written to `results.json` and rendered into `RESULTS.md`. Both are committed:
the point of the harness is that the table is reviewable and re-runnable rather than folklore.

## How a target is measured

Each target is a small application with one text field and one button that reports every event it
receives back to the harness over HTTP. For each one the harness runs three phases:

| phase | what it does | what it proves |
| --- | --- | --- |
| `background` | Focus is held by a decoy window and the pointer is parked away from the target. `ButtonPress`/`ButtonRelease` and `KeyPress`/`KeyRelease` are sent to the target's window with `XSendEvent`. | The measurement itself: whether a background, target-bound synthetic event is acted on. |
| `pointerControl` | An `XTest` click with the real pointer over the same coordinates. | The coordinates and the widget are right. Without this, a silent target is ambiguous between "the toolkit rejected `send_event`" and "the harness aimed at nothing". |
| `focusControl` | An `XTest` keystroke with the target focused. | The text field is reachable at all. |

The background phase tries each delivery variant in turn and records which one, if any, was honoured:

- `targeted` — sent to the toplevel window with the matching event mask;
- `owner` — sent with an empty event mask, which the X server routes to the client that created the
  window regardless of what it selected;
- `child` — sent to the deepest child window containing the point, for toolkits that still put
  widgets in their own X windows.

After the background phase the harness proves the two invariants the contract requires of the pixel
rung: the real pointer did not move, and the X input focus did not change.

## The geometry half

The same run answers a second question the pixel rung depends on. Each target reports its own widget
rectangles from inside the toolkit, which is ground truth, and the harness reads the same widgets
back through AT-SPI. Comparing them says whether AT-SPI `Component` extents are usable as the
coordinate source a pixel rung would need — the concrete form of the GTK 4 `(0, 0)` origins recorded
in `rust/SPIKE-FINDINGS.md`.

## What the first run measured, and what it decided

Measured 2026-08-10 on Fedora 43 (X.Org 21.1) against GTK 3.24.51, GTK 4.20.3, Qt 6.11, WebKitGTK
2.50.4, Electron 43 (Chromium 150) and Firefox 147 — once in the hermetic Xvfb lane
([`RESULTS.md`](RESULTS.md)) and again on a live Xfce X11 session
([`RESULTS-live-x11.md`](RESULTS-live-x11.md)). Both lanes agree on every row.

**Pointer input is refused nearly everywhere.** GTK 3, GTK 4, WebKitGTK and Firefox never receive a
window-targeted synthetic button event at all. Qt receives one and acts on it, but asks to be
activated while doing so — on the lane with no window manager the session focus moved to the Qt
window, and on the live lane only the window manager's focus-stealing prevention stopped it. An
acceptance that depends on a window manager declining to honour the application is not one a pixel
rung may be built on. Chromium is the single exception: it acts on the click with the focus and the
real pointer provably unchanged, and reports the event to the page as `isTrusted`.

**Keyboard input is accepted more widely.** GTK 3 (and therefore WebKitGTK), Firefox and Chromium all
typed the delivered text into their focused field while the window did not hold the X input focus,
the session focus did not move, and the pointer did not move. GTK 4 never receives the event.

**A synthetic click is honoured by GTK only when the real cursor is already inside the target
window.** The boundary is the window's own edge: at (479, 319) of a 480x320 window the click lands,
at (481, 319) nothing arrives. This is why a hand experiment concludes that `XSendEvent` works — the
experimenter's cursor is over the window they are testing. Arranging that condition means moving the
user's pointer, which is the foreground rung by definition, so the harness parks the pointer clear of
the target and measures the condition separately as `pointerOverTarget`.

**AT-SPI geometry is usable everywhere except GTK 4.** For GTK 3, Qt, WebKitGTK and Chromium the
extents match the toolkit's own rectangles to the pixel. GTK 4 reports correct sizes at `(0, 0)`
origins, which confirms the finding in `rust/SPIKE-FINDINGS.md` against ground truth and settles it as
a toolkit fact rather than a compositor one. Firefox publishes no AT-SPI application at all.

### The decision

The pixel rung is real on Linux, and it is narrow. It should be offered only where this table says
the toolkit accepts, keyed on the AT-SPI toolkit name and version — what the application declares
about itself over the accessibility bus, which is the same fact a backend can read at dispatch time,
and not an inference from `WM_CLASS` or from loaded libraries:

| action | offered for | refused for |
| --- | --- | --- |
| `click` | `Chromium` | everything else, `backgroundPixelUnsupported` naming the toolkit |
| `keyboard` | `gtk` 3.x, `Chromium` | everything else, likewise |

Firefox is excluded despite accepting keys: it publishes no AT-SPI application, so the backend cannot
identify the target, convert coordinates through resolved geometry, or revalidate before dispatch —
every precondition the contract puts on the rung fails before delivery is even reached.

This harness is the evidence that table is written against, and it is the Linux counterpart of the
Windows window-class allowlist earned by `axon-win probe pixel-click`. It is run and re-dated when
the area changes rather than wired into the pull-request gate, because it needs five toolkits and a
browser runtime installed and its answer changes on toolkit releases, not on this repository's
commits.
