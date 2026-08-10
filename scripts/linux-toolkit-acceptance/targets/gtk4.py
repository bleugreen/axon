#!/usr/bin/env python3
"""GTK 4 target: the same window, on the toolkit whose AT-SPI extents are under suspicion."""

import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("GdkX11", "4.0")
from gi.repository import GdkX11, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import report  # noqa: E402


class Target:
    def __init__(self, application) -> None:
        self.clicks = 0
        self.window = Gtk.ApplicationWindow(application=application, title="Axon harness GTK4")
        self.window.set_default_size(480, 320)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        box.set_margin_top(24)
        box.set_margin_start(24)
        box.set_margin_end(24)
        self.entry = Gtk.Entry()
        self.button = Gtk.Button(label="Target Button")
        self.button.set_size_request(200, 80)
        # The button must not take widget focus: a click landing on it would otherwise move focus
        # off the text field and turn the keyboard phases into a measurement of the button.
        self.button.set_focusable(False)
        self.button.connect("clicked", self.on_click)
        self.entry.connect("changed", self.on_text)
        box.append(self.entry)
        box.append(self.button)
        self.window.set_child(box)
        # Raw arrival, reported separately from the effect, for the reason in the GTK 3 target.
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self.on_raw_key)
        self.window.add_controller(keys)
        clicks = Gtk.GestureClick()
        clicks.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        clicks.connect("pressed", self.on_raw_click)
        self.window.add_controller(clicks)
        self.window.present()
        self.entry.grab_focus()
        self.previous: dict | None = None
        # GTK 4 answers `compute_bounds` before it has laid the widget out, with something small and
        # wrong rather than with an error, so the announcement waits for two identical readings
        # instead of for a fixed delay. A rectangle measured mid-layout would be published as this
        # toolkit's ground truth and quietly become a geometry verdict about the harness's timing.
        GLib.timeout_add(200, self.announce)

    def rectangle(self, widget):
        found, bounds = widget.compute_bounds(self.window)
        if not found:
            return None
        return [
            int(bounds.get_x()),
            int(bounds.get_y()),
            int(bounds.get_width()),
            int(bounds.get_height()),
        ]

    def announce(self) -> bool:
        widgets = {
            name: rectangle
            for name, rectangle in (
                ("button", self.rectangle(self.button)),
                ("entry", self.rectangle(self.entry)),
            )
            if rectangle
        }
        settled = (
            len(widgets) == 2
            and all(rect[2] >= 8 and rect[3] >= 8 for rect in widgets.values())
            and widgets == self.previous
        )
        if not settled:
            self.previous = widgets
            return True
        surface = self.window.get_surface()
        report(
            {
                "kind": "ready",
                "pid": os.getpid(),
                "xid": GdkX11.X11Surface.get_xid(surface) if surface else None,
                "signature": "GTK %d.%d.%d"
                % (Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()),
                "widgets": widgets,
            }
        )
        return False

    def on_raw_key(self, _controller, _keyval, _keycode, _state) -> bool:
        report({"kind": "raw", "event": "key-press"})
        return False

    def on_raw_click(self, _gesture, _count, _x, _y) -> None:
        report({"kind": "raw", "event": "button-press"})

    def on_click(self, _button) -> None:
        self.clicks += 1
        report({"kind": "click", "widget": "button", "count": self.clicks})

    def on_text(self, entry) -> None:
        report({"kind": "text", "widget": "entry", "value": entry.get_text()})


application = Gtk.Application(application_id="dev.axon.harness.gtk4")
application.connect("activate", lambda app: Target(app))
application.run([])
