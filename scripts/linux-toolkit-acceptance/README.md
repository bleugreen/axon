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
