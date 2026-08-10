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
