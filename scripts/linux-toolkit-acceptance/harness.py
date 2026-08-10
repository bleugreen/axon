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

        # The decoy holds the focus and the pointer is parked in the far corner, so the target is in
        # the background under both meanings of the word for the whole background phase.
        session.take_focus(decoy)
        session.warp(2, 2)
        time.sleep(0.2)
        before = {"pointer": list(session.pointer()), "focus": session.focus()}
        result["before"] = before
        if before["focus"] == window.id:
            result["status"] = "failed"
            result["detail"] = "the target held the focus, so nothing measured here is a background"
            return result

        origin = session.origin(window)
        button = widgets["button"]
        point = (button[0] + button[2] // 2, button[1] + button[3] // 2)
        root_point = (origin[0] + point[0], origin[1] + point[1])

        result["background"] = {
            "click": _background_click(session, reports, window, point, root_point),
            "text": _background_text(session, reports, window),
        }
        result["invariants"] = {
            "pointerUnchanged": list(session.pointer()) == before["pointer"],
            "focusUnchanged": session.focus() == before["focus"],
            "pointerAfter": list(session.pointer()),
        }

        result["geometry"] = compare_geometry(widgets, read_atspi(pid), origin)

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
    for variant in VARIANTS:
        destination = window
        if variant == "child":
            child = session.child_at(window, point[0], point[1])
            if child is None:
                continue
            destination = child
        session.send_click(destination, point, root_point, variant)
        reaction = reports.wait_for("click", REACTION_TIMEOUT)
        if reaction:
            return {
                "accepted": True,
                "variant": variant,
                "at": list(root_point),
                "reaction": reaction,
            }
    return {
        "accepted": False,
        "variant": None,
        "at": list(root_point),
        "triedVariants": list(VARIANTS),
    }


def _background_text(session: Session, reports: Reports, window) -> dict:
    for variant in ("targeted", "owner"):
        if not session.send_text(window, TYPED_TEXT, variant):
            return {
                "accepted": False,
                "variant": None,
                "error": "this layout cannot type the probe text",
            }
        reaction = reports.wait_for("text", REACTION_TIMEOUT)
        if reaction:
            return {"accepted": True, "variant": variant, "reaction": reaction}
    return {"accepted": False, "variant": None, "triedVariants": ["targeted", "owner"]}


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
