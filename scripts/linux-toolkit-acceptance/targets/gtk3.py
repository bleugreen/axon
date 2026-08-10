#!/usr/bin/env python3
"""GTK 3 target: one text field, one button, and an honest account of what arrives."""

import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import GdkX11, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import report  # noqa: E402


class Target:
    def __init__(self) -> None:
        self.clicks = 0
        self.window = Gtk.Window(title="Axon harness GTK3")
        self.window.set_default_size(480, 320)
        self.window.connect("destroy", Gtk.main_quit)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        box.set_border_width(24)
        self.entry = Gtk.Entry()
        self.button = Gtk.Button(label="Target Button")
        self.button.set_size_request(200, 80)
        self.button.connect("clicked", self.on_click)
        self.entry.connect("changed", self.on_text)
        box.pack_start(self.entry, False, False, 0)
        box.pack_start(self.button, False, False, 0)
        self.window.add(box)
        self.window.show_all()
        self.entry.grab_focus()
        GLib.timeout_add(400, self.announce)

    def rectangle(self, widget) -> list:
        allocation = widget.get_allocation()
        translated = widget.translate_coordinates(self.window, 0, 0)
        x, y = (translated[-2], translated[-1]) if translated else (allocation.x, allocation.y)
        return [x, y, allocation.width, allocation.height]

    def announce(self) -> bool:
        report(
            {
                "kind": "ready",
                "pid": os.getpid(),
                "xid": GdkX11.X11Window.get_xid(self.window.get_window()),
                "signature": "GTK %d.%d.%d"
                % (Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()),
                "widgets": {
                    "button": self.rectangle(self.button),
                    "entry": self.rectangle(self.entry),
                },
            }
        )
        return False

    def on_click(self, _button) -> None:
        self.clicks += 1
        report({"kind": "click", "widget": "button", "count": self.clicks})

    def on_text(self, entry) -> None:
        report({"kind": "text", "widget": "entry", "value": entry.get_text()})


Target()
Gtk.main()
