#!/usr/bin/env python3
"""WebKitGTK target: a GTK window whose content is a web engine.

The engine matters separately from the toolkit. GTK may hand the event on and the engine above it
still decide a synthetic event is not a user gesture.
"""

import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GdkX11", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import GdkX11, GLib, Gtk, WebKit2  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import report  # noqa: E402


class Target:
    def __init__(self) -> None:
        self.window = Gtk.Window(title="Axon harness WebKitGTK")
        self.window.set_default_size(480, 360)
        self.window.connect("destroy", Gtk.main_quit)
        self.view = WebKit2.WebView()
        self.window.add(self.view)
        self.window.show_all()
        self.view.connect("load-changed", self.on_load)
        self.view.load_uri(os.environ["AXON_HARNESS_PAGE"])

    def on_load(self, _view, event) -> None:
        if event != WebKit2.LoadEvent.FINISHED:
            return
        GLib.timeout_add(400, self.announce)

    def announce(self) -> bool:
        translated = self.view.translate_coordinates(self.window, 0, 0)
        offset = [translated[-2], translated[-1]] if translated else [0, 0]
        report(
            {
                "kind": "ready",
                "pid": os.getpid(),
                "xid": GdkX11.X11Window.get_xid(self.window.get_window()),
                "signature": "WebKitGTK %d.%d.%d"
                % (
                    WebKit2.get_major_version(),
                    WebKit2.get_minor_version(),
                    WebKit2.get_micro_version(),
                ),
                "viewportOffset": offset,
            }
        )
        return False


Target()
Gtk.main()
