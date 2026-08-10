#!/usr/bin/env python3
"""Measure, per toolkit, whether a background window acts on window-targeted XSendEvent input.

See README.md for what this measures and why it has to be measured rather than inferred. This module
is the orchestration: it holds the focus in a decoy window, launches each target, sends the events,
collects what the target reports back, runs the two controls, and proves the invariants.

Nothing here decides whether a result is good. It records what happened.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from Xlib import X, XK, Xatom, display
from Xlib.ext import xtest
from Xlib.protocol import event as xevent

HERE = Path(__file__).resolve().parent
TARGETS = HERE / "targets"

# A toolkit that is going to act on an event acts on it in milliseconds. This bound is for a loaded
# machine, not for a toolkit taking its time to decide.
REACTION_TIMEOUT = 2.0
READY_TIMEOUT = 40.0
TYPED_TEXT = "axon"


class Reports:
    """Everything the targets say about themselves, in arrival order.

    A target reports its own state rather than the harness inferring it: the harness can see that an
    event was sent, and only the application can see that it was acted on.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: list[dict] = []

    def add(self, item: dict) -> None:
        with self._lock:
            self._items.append(item)

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self._items)

    def clear(self) -> None:
        with self._lock:
            self._items.clear()

    def of_kind(self, kind: str) -> list[dict]:
        return [item for item in self.snapshot() if item.get("kind") == kind]

    def wait_for(self, kind: str, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = self.of_kind(kind)
            if found:
                return found[-1]
            time.sleep(0.02)
        return None


class _ReportHandler(BaseHTTPRequestHandler):
    reports: Reports
    page: bytes

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler naming
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b"{}"
        try:
            item = json.loads(body)
        except ValueError:
            item = {"kind": "malformed", "raw": body.decode(errors="replace")}
        type(self).reports.add(item)
        self._no_content()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler naming
        if self.path.startswith("/page"):
            body = type(self).page
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._no_content()

    def _no_content(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args) -> None:
        return


@dataclass
class Spec:
    """One toolkit under measurement."""

    name: str
    argv: list[str]
    env: dict[str, str] = field(default_factory=dict)
    unavailable: str | None = None


class Session:
    """The X11 half: window discovery, geometry, synthetic delivery, and the session invariants."""

    def __init__(self) -> None:
        self.display = display.Display()
        self.screen = self.display.screen()
        self.root = self.screen.root
        self.net_wm_pid = self.display.intern_atom("_NET_WM_PID")
        self._clock = int(time.time() * 1000) & 0xFFFFFFFF

    # -- session facts ------------------------------------------------------------------------

    def pointer(self) -> tuple[int, int]:
        reply = self.root.query_pointer()
        return (reply.root_x, reply.root_y)

    def focus(self) -> int:
        window = self.display.get_input_focus().focus
        return window if isinstance(window, int) else window.id

    def park_away_from(self, origin: tuple, size: tuple) -> tuple:
        """Puts the pointer somewhere provably outside a window's rectangle, and says where.

        Below and to the right of the window when the screen allows it, because a window an X server
        places at the origin covers the corner a naive "park it at 0, 0" would choose.
        """
        width = self.screen.width_in_pixels
        height = self.screen.height_in_pixels
        below = origin[1] + size[1] + 40
        right = origin[0] + size[0] + 40
        if below < height:
            point = (min(right, width - 1), height - 1)
        else:
            point = (width - 1, max(0, origin[1] - 40))
        self.warp(*point)
        return point

    def warp(self, x: int, y: int) -> None:
        self.root.warp_pointer(x, y)
        self.display.sync()

    # -- windows ------------------------------------------------------------------------------

    def decoy(self):
        """A window to hold the focus, so the target is genuinely in the background.

        Focus is what makes the measurement mean anything. A target that happens to be focused would
        receive ordinary input through the same paths the pixel rung is forbidden to rely on.
        """
        window = self.root.create_window(
            8,
            8,
            160,
            120,
            1,
            self.screen.root_depth,
            X.InputOutput,
            X.CopyFromParent,
            background_pixel=self.screen.white_pixel,
            event_mask=X.KeyPressMask | X.ButtonPressMask | X.StructureNotifyMask,
        )
        window.set_wm_name("axon-harness-decoy")
        window.map()
        self.display.sync()
        return window

    def take_focus(self, window) -> None:
        self.display.set_input_focus(window, X.RevertToParent, X.CurrentTime)
        self.display.sync()

    def windows_for_pid(self, pid: int) -> list:
        """Every window this process owns, found through the property the application sets itself.

        `_NET_WM_PID` is published by the application, not by a window manager, so this works on a
        bare X server with no manager running — which is what the hermetic lane is.
        """
        found: list = []

        def walk(window) -> None:
            try:
                children = window.query_tree().children
            except Exception:
                return
            for child in children:
                try:
                    prop = child.get_full_property(self.net_wm_pid, Xatom.CARDINAL)
                except Exception:
                    prop = None
                if prop and prop.value and int(prop.value[0]) == pid:
                    found.append(child)
                walk(child)

        walk(self.root)
        return found

    def toplevel_for_pid(self, pid: int, timeout: float):
        """The process's largest viewable window: its real toplevel.

        Toolkits also own small utility and input-only windows, and a synthetic event aimed at one of
        those would measure nothing.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            best = None
            best_area = 0
            for window in self.windows_for_pid(pid):
                try:
                    if window.get_attributes().map_state != X.IsViewable:
                        continue
                    geometry = window.get_geometry()
                except Exception:
                    continue
                area = geometry.width * geometry.height
                if area > best_area:
                    best, best_area = window, area
            if best is not None and best_area >= 100 * 100:
                return best
            time.sleep(0.1)
        return None

    def origin(self, window) -> tuple[int, int]:
        reply = self.root.translate_coords(window, 0, 0)
        return (reply.x, reply.y)

    def child_at(self, window, x: int, y: int):
        """The child window of `window` containing a point in its coordinates, if any."""
        try:
            reply = window.translate_coords(window, x, y)
        except Exception:
            return None
        child = getattr(reply, "child", None)
        return child if child and child != X.NONE else None

    # -- synthetic delivery -------------------------------------------------------------------

    def _tick(self) -> int:
        self._clock = (self._clock + 10) & 0xFFFFFFFF
        return self._clock

    def send_click(self, window, point, root_point, variant: str) -> None:
        """A window-targeted press and release. Every event carries send_event = True."""
        press_mask, release_mask = X.ButtonPressMask, X.ButtonReleaseMask
        if variant == "owner":
            # An empty mask makes the server deliver to the client that created the window, whatever
            # that client selected for.
            press_mask = release_mask = 0
        for kind, mask, state in (
            (xevent.ButtonPress, press_mask, 0),
            (xevent.ButtonRelease, release_mask, X.Button1Mask),
        ):
            window.send_event(
                kind(
                    time=self._tick(),
                    root=self.root,
                    window=window,
                    child=X.NONE,
                    root_x=root_point[0],
                    root_y=root_point[1],
                    event_x=point[0],
                    event_y=point[1],
                    state=state,
                    detail=1,
                    same_screen=1,
                ),
                event_mask=mask,
                propagate=False,
            )
        self.display.sync()

    def send_text(self, window, text: str, variant: str) -> bool:
        """Types literal text into whatever the target focuses internally.

        Returns False when this layout cannot produce the text at all, which is a harness fault
        rather than a measurement.
        """
        press_mask, release_mask = X.KeyPressMask, X.KeyReleaseMask
        if variant == "owner":
            press_mask = release_mask = 0
        for character in text:
            keycode = self.display.keysym_to_keycode(XK.string_to_keysym(character))
            if not keycode:
                return False
            for kind, mask in ((xevent.KeyPress, press_mask), (xevent.KeyRelease, release_mask)):
                window.send_event(
                    kind(
                        time=self._tick(),
                        root=self.root,
                        window=window,
                        child=X.NONE,
                        root_x=0,
                        root_y=0,
                        event_x=0,
                        event_y=0,
                        state=0,
                        detail=keycode,
                        same_screen=1,
                    ),
                    event_mask=mask,
                    propagate=False,
                )
            self.display.sync()
        return True

    # -- controls -----------------------------------------------------------------------------

    def xtest_click(self, root_point: tuple[int, int]) -> None:
        """A real click through the global pointer device. This moves the cursor, by construction."""
        xtest.fake_input(self.display, X.MotionNotify, x=root_point[0], y=root_point[1])
        self.display.sync()
        time.sleep(0.05)
        xtest.fake_input(self.display, X.ButtonPress, 1)
        xtest.fake_input(self.display, X.ButtonRelease, 1)
        self.display.sync()

    def xtest_text(self, text: str) -> bool:
        for character in text:
            keycode = self.display.keysym_to_keycode(XK.string_to_keysym(character))
            if not keycode:
                return False
            xtest.fake_input(self.display, X.KeyPress, keycode)
            xtest.fake_input(self.display, X.KeyRelease, keycode)
            self.display.sync()
            time.sleep(0.02)
        return True


# -- geometry ---------------------------------------------------------------------------------


def read_atspi(pid: int) -> dict:
    """What AT-SPI says about this process's window and widgets.

    Run out of process on purpose: a stuck accessibility bus should cost this one reading, not the
    whole measurement.
    """
    try:
        completed = subprocess.run(
            [sys.executable, str(HERE / "atspi_probe.py"), "--pid", str(pid)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"error": "the AT-SPI probe did not answer within 30s"}
    if completed.returncode != 0:
        return {"error": completed.stderr.strip()[-400:] or "the AT-SPI probe failed"}
    try:
        return json.loads(completed.stdout)
    except ValueError:
        return {"error": "the AT-SPI probe did not produce JSON"}


def compare_geometry(truth: dict, atspi: dict, origin: tuple[int, int]) -> dict:
    """Whether AT-SPI extents agree with the toolkit's own idea of where its widgets are.

    The target reports rectangles in its window's coordinates, which is ground truth from inside the
    toolkit. Adding the window's origin gives the screen rectangle a pixel rung would have to hit.
    AT-SPI reports the same widgets in screen coordinates. Where the two disagree, AT-SPI extents
    cannot be the coordinate source for a pixel rung on that toolkit.
    """
    comparison: dict = {"origin": list(origin), "widgets": {}}
    nodes = {node.get("widget"): node for node in atspi.get("widgets", []) if node.get("widget")}
    if atspi.get("error"):
        comparison["error"] = atspi["error"]
    usable = None
    for widget, rect in sorted(truth.items()):
        expected = [rect[0] + origin[0], rect[1] + origin[1], rect[2], rect[3]]
        node = nodes.get(widget)
        measured = node.get("extents") if node else None
        entry: dict = {"expected": expected, "atspi": measured}
        if measured is None:
            entry["agrees"] = None
        else:
            # A few pixels of disagreement is toolkit padding, not a broken coordinate source.
            entry["offsetBy"] = [measured[0] - expected[0], measured[1] - expected[1]]
            entry["agrees"] = abs(entry["offsetBy"][0]) <= 4 and abs(entry["offsetBy"][1]) <= 4
            usable = entry["agrees"] if usable is None else (usable and entry["agrees"])
        comparison["widgets"][widget] = entry
    comparison["extentsUsable"] = usable
    return comparison


# -- one target -------------------------------------------------------------------------------


VARIANTS = ("targeted", "owner", "child")


def measure(spec: Spec, session: Session, reports: Reports, decoy, port: int) -> dict:
    result: dict = {"target": spec.name}
    if spec.unavailable:
        result["status"] = "unavailable"
        result["detail"] = spec.unavailable
        return result

    reports.clear()
    environment = dict(os.environ)
    environment.update(spec.env)
    environment["AXON_HARNESS_REPORT"] = f"http://127.0.0.1:{port}/report"
    environment["AXON_HARNESS_PAGE"] = f"http://127.0.0.1:{port}/page.html"

    process = subprocess.Popen(
        spec.argv,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        ready = reports.wait_for("ready", READY_TIMEOUT)
        if ready is None:
            result["status"] = "failed"
            result["detail"] = "the target never reported itself ready"
            result["output"] = _drain(process)
            return result

        pid = int(ready.get("pid") or process.pid)
        result["signature"] = ready.get("signature", spec.name)
        widgets = _widget_rectangles(ready, reports)
        if not widgets:
            result["status"] = "failed"
            result["detail"] = "the target reported no widget geometry to aim at"
            return result

        window = session.toplevel_for_pid(pid, timeout=15)
        if window is None:
            result["status"] = "failed"
            result["detail"] = f"no viewable toplevel window found for pid {pid}"
            return result
        result["window"] = {"xid": window.id, "reportedXid": ready.get("xid")}

        origin = session.origin(window)
        geometry = window.get_geometry()
        button = widgets["button"]
        point = (button[0] + button[2] // 2, button[1] + button[3] // 2)
        root_point = (origin[0] + point[0], origin[1] + point[1])

        # The decoy holds the focus and the pointer is parked outside the target's rectangle, so the
        # target is in the background under both meanings of the word for the whole background phase.
        #
        # Parking it *outside* is load-bearing rather than tidy. GTK only acts on a synthetic button
        # event when the real cursor is already inside the target window, so a pointer left over the
        # target turns this into a measurement of something the pixel rung may not do.
        session.take_focus(decoy)
        parked = session.park_away_from(origin, (geometry.width, geometry.height))
        time.sleep(0.2)
        before = {"pointer": list(session.pointer()), "focus": session.focus()}
        before["pointerOverTarget"] = False
        result["before"] = before
        if before["focus"] == window.id:
            result["status"] = "failed"
            result["detail"] = "the target held the focus, so nothing measured here is a background"
            return result
        if list(parked) != before["pointer"]:
            result["status"] = "failed"
            result["detail"] = "the pointer would not park clear of the target window"
            return result

        click = _background_click(session, reports, window, point, root_point)
        click["invariants"] = _invariants(session, before)
        text = _background_text(session, reports, window)
        text["invariants"] = _invariants(session, before)
        result["background"] = {"click": click, "text": text}
        result["invariants"] = _invariants(session, before)

        # Deliberately after the invariants: this one moves the pointer.
        result["pointerOverTarget"] = _pointer_over(session, reports, window, point, root_point)

        reading = read_atspi(pid)
        result["atspiToolkit"] = reading.get("toolkit")
        result["geometry"] = compare_geometry(widgets, reading, origin)

        # Controls last: both of them move the session's pointer or focus, so they would invalidate
        # the background measurement if they ran before it.
        result["controls"] = _controls(session, reports, window, root_point)
        result["status"] = "measured"
        return result
    finally:
        _stop(process)


def _widget_rectangles(ready: dict, reports: Reports) -> dict:
    """Widget rectangles in the toplevel's coordinates.

    A native target measures its own widgets. A web target reports the offset of its content area and
    the page reports the elements, because only the page knows where they ended up.
    """
    if ready.get("widgets"):
        return {name: list(map(int, rect)) for name, rect in ready["widgets"].items()}
    page = reports.wait_for("page", REACTION_TIMEOUT * 4)
    if not page or not page.get("widgets"):
        return {}
    offset = ready.get("viewportOffset") or [0, 0]
    return {
        name: [rect[0] + offset[0], rect[1] + offset[1], rect[2], rect[3]]
        for name, rect in page["widgets"].items()
    }


def _background_click(session: Session, reports: Reports, window, point, root_point) -> dict:
    arrivals: dict = {}
    for variant in VARIANTS:
        destination = window
        if variant == "child":
            child = session.child_at(window, point[0], point[1])
            if child is None:
                continue
            destination = child
        reports.clear()
        session.send_click(destination, point, root_point, variant)
        reaction = reports.wait_for("click", REACTION_TIMEOUT)
        arrivals[variant] = _raw(reports, "button-press")
        if reaction:
            return {
                "accepted": True,
                "variant": variant,
                "at": list(root_point),
                "reaction": reaction,
                "reachedToolkit": arrivals,
            }
    return {
        "accepted": False,
        "variant": None,
        "at": list(root_point),
        "triedVariants": list(VARIANTS),
        "reachedToolkit": arrivals,
    }


def _background_text(session: Session, reports: Reports, window) -> dict:
    arrivals: dict = {}
    for variant in ("targeted", "owner"):
        reports.clear()
        if not session.send_text(window, TYPED_TEXT, variant):
            return {
                "accepted": False,
                "variant": None,
                "error": "this layout cannot type the probe text",
            }
        reaction = reports.wait_for("text", REACTION_TIMEOUT)
        arrivals[variant] = _raw(reports, "key-press")
        if reaction:
            return {
                "accepted": True,
                "variant": variant,
                "reaction": reaction,
                "reachedToolkit": arrivals,
            }
    return {
        "accepted": False,
        "variant": None,
        "triedVariants": ["targeted", "owner"],
        "reachedToolkit": arrivals,
    }


def _pointer_over(session: Session, reports: Reports, window, point, root_point) -> dict:
    """Whether the same synthetic click is honoured with the real cursor already over the target.

    This is not a contract-legal delivery, and it is not offered as one: arranging it means moving
    the user's pointer, which is the foreground rung by definition. It is measured because it is the
    whole difference between "this toolkit rejects send_event" and "this toolkit accepts send_event
    only where the pixel rung may not go". Without it, the next person to try XSendEvent by hand,
    with a cursor that happens to be sitting over the window, concludes the rung was available all
    along.
    """
    reports.clear()
    session.warp(*root_point)
    time.sleep(0.3)
    session.send_click(window, point, root_point, "owner")
    reaction = reports.wait_for("click", REACTION_TIMEOUT)
    return {
        "accepted": reaction is not None,
        "reachedToolkit": _raw(reports, "button-press"),
        "pointerAt": list(root_point),
        "focusUnchanged": session.focus() != window.id,
    }


def _invariants(session: Session, before: dict) -> dict:
    """The two things the contract requires a pixel-rung dispatch to leave alone.

    Read after each phase rather than once at the end: a mechanism that delivers a click and takes
    the session focus while doing it has failed on the click, and a single reading taken after every
    phase cannot say which phase moved what.
    """
    pointer = list(session.pointer())
    focus = session.focus()
    return {
        "pointerUnchanged": pointer == before["pointer"],
        "focusUnchanged": focus == before["focus"],
        "pointerAt": pointer,
        "focusWindow": focus,
    }


def _raw(reports: Reports, event: str) -> int:
    """How many raw arrivals of this kind the target reported.

    This is the difference between a toolkit that never received the event and one that received it
    and declined to act. Only the second is a statement about `send_event`.
    """
    return sum(1 for item in reports.of_kind("raw") if item.get("event") == event)


def _controls(session: Session, reports: Reports, window, root_point) -> dict:
    """Proof that the harness aimed at a real widget, and that the text field is reachable.

    A background refusal only means something if these pass. If the click control fails, the
    coordinates were wrong and the background result says nothing about the toolkit.
    """
    reports.clear()
    session.xtest_click(root_point)
    pointer_click = reports.wait_for("click", REACTION_TIMEOUT) is not None

    reports.clear()
    session.take_focus(window)
    time.sleep(0.3)
    session.xtest_text(TYPED_TEXT)
    focused_text = reports.wait_for("text", REACTION_TIMEOUT) is not None
    return {"pointerClick": pointer_click, "focusedText": focused_text}


def _drain(process: subprocess.Popen) -> str:
    try:
        return (process.stdout.read() if process.stdout else "")[-2000:]
    except Exception:
        return ""


def _stop(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(process.pid), 15)
    except Exception:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(process.pid), 9)
        except Exception:
            process.kill()


# -- targets ----------------------------------------------------------------------------------


def _importable(statement: str) -> bool:
    return subprocess.run([sys.executable, "-c", statement], capture_output=True).returncode == 0


def specs() -> list[Spec]:
    """Every toolkit this harness knows how to measure, present or not.

    A missing toolkit is recorded as unavailable rather than dropped: a result table has to say what
    it did not see, or a reader will take the absence for a verdict.
    """
    def python_target(name: str, script: str, requirement: str, note: str) -> Spec:
        return Spec(
            name=name,
            argv=[sys.executable, str(TARGETS / script)],
            unavailable=None if _importable(requirement) else note,
        )

    electron = TARGETS / "electron"
    return [
        python_target(
            "gtk3",
            "gtk3.py",
            "import gi; gi.require_version('Gtk', '3.0')",
            "GTK 3 GObject introspection is not installed",
        ),
        python_target(
            "gtk4",
            "gtk4.py",
            "import gi; gi.require_version('Gtk', '4.0')",
            "GTK 4 GObject introspection is not installed",
        ),
        python_target(
            "qt6",
            "qt6.py",
            "import PyQt6.QtWidgets",
            "neither PyQt6 nor PySide6 is installed",
        )
        if _importable("import PyQt6.QtWidgets") or _importable("import PySide6.QtWidgets")
        else Spec("qt6", [], unavailable="neither PyQt6 nor PySide6 is installed"),
        python_target(
            "webkitgtk",
            "webkitgtk.py",
            "import gi; gi.require_version('WebKit2', '4.1')",
            "WebKitGTK GObject introspection is not installed",
        ),
        Spec(
            name="electron",
            argv=["node", str(electron / "launch.js")],
            unavailable=None
            if (electron / "node_modules" / "electron").is_dir()
            else "electron is not installed; run scripts/linux-toolkit-acceptance/install-electron",
        ),
        Spec(
            name="firefox",
            argv=[sys.executable, str(TARGETS / "firefox.py")],
            unavailable=None if shutil.which("firefox") else "firefox is not installed",
        ),
    ]


# -- rendering --------------------------------------------------------------------------------


def _verdict(phase: dict | None) -> str:
    if not phase:
        return "-"
    if phase.get("accepted"):
        return f"accepted ({phase.get('variant')})"
    return "ignored"


def render(document: dict) -> str:
    lines = [
        "# Measured toolkit acceptance of background XSendEvent delivery",
        "",
        "Generated by `scripts/linux-toolkit-acceptance/run`. Do not edit by hand: re-run it.",
        "",
        f"- Measured: {document['measuredAt']}",
        f"- Session: {document['session']}",
        f"- X server: {document['xServer']}",
        "",
        "| toolkit | signature | background click | background text | pointer control |"
        " focus control | AT-SPI extents |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for result in document["results"]:
        if result.get("status") != "measured":
            lines.append(
                f"| `{result['target']}` | — | {result.get('status')} |"
                f" {result.get('detail', '')} | — | — | — |"
            )
            continue
        background = result.get("background", {})
        controls = result.get("controls", {})
        geometry = result.get("geometry", {})
        usable = geometry.get("extentsUsable")
        lines.append(
            f"| `{result['target']}` | {result.get('signature', '')} |"
            f" {_verdict(background.get('click'))} | {_verdict(background.get('text'))} |"
            f" {'reacted' if controls.get('pointerClick') else 'no reaction'} |"
            f" {'reacted' if controls.get('focusedText') else 'no reaction'} |"
            f" {'usable' if usable else ('unusable' if usable is False else 'not reported')} |"
        )
    lines += [
        "",
        "The controls are what make a refusal mean something. `pointer control` clicks the same",
        "coordinates with the real pointer through XTest, and `focus control` types into the target",
        "while it holds the focus. A toolkit that reacts to both and ignores the background phase",
        "rejected `send_event`; one that reacts to neither was not aimed at properly, and its",
        "background row says nothing.",
        "",
        "`AT-SPI extents` compares what AT-SPI reports for the same widgets against the toolkit's own",
        "rectangles. `unusable` means a pixel rung could not get its coordinates from AT-SPI on that",
        "toolkit even if delivery were accepted.",
        "",
        "Full detail, including which delivery variant was honoured and the exact rectangles, is in",
        "`results.json`.",
        "",
    ]
    return "\n".join(lines)


def _x_server() -> str:
    try:
        connection = display.Display()
        setup = connection.display
        return f"{setup.info.vendor} release {setup.info.release_number}"
    except Exception:
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure toolkit acceptance of XSendEvent input.")
    parser.add_argument("--only", default="", help="comma-separated target names to measure")
    parser.add_argument("--output", default=str(HERE / "results.json"))
    parser.add_argument("--markdown", default=str(HERE / "RESULTS.md"))
    arguments = parser.parse_args()

    reports = Reports()
    _ReportHandler.reports = reports
    _ReportHandler.page = (HERE / "page.html").read_bytes()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _ReportHandler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    session = Session()
    decoy = session.decoy()
    session.take_focus(decoy)

    wanted = {name.strip() for name in arguments.only.split(",") if name.strip()}
    results = []
    for spec in specs():
        if wanted and spec.name not in wanted:
            continue
        print(f"== {spec.name}", flush=True)
        try:
            result = measure(spec, session, reports, decoy, port)
        except Exception as error:  # a broken target must not cost the other measurements
            result = {
                "target": spec.name,
                "status": "failed",
                "detail": f"{type(error).__name__}: {error}",
            }
        results.append(result)
        print(json.dumps(result, indent=2), flush=True)

    document = {
        "measuredAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "session": os.environ.get("AXON_HARNESS_SESSION", "hermetic Xvfb"),
        "display": os.environ.get("DISPLAY", ""),
        "xServer": _x_server(),
        "results": results,
    }
    Path(arguments.output).write_text(json.dumps(document, indent=2) + "\n")
    Path(arguments.markdown).write_text(render(document))
    print(f"wrote {arguments.output} and {arguments.markdown}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
