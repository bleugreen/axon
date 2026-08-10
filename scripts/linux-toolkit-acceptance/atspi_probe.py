#!/usr/bin/env python3
"""What AT-SPI says about one process's window and its widgets.

The pixel rung would take its coordinates from here, so whether these extents agree with where the
widgets actually are decides whether the rung has a usable input at all. `rust/SPIKE-FINDINGS.md`
records GTK 4 trees reporting correct sizes at (0, 0) origins; this is how that is measured against
ground truth rather than eyeballed.

Run as its own process so a withholding or slow accessibility bus costs one reading rather than the
whole measurement.
"""

from __future__ import annotations

import argparse
import json
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

# The widget each role stands in for, so a result can be compared against what the target reported.
ROLES = {
    "push button": "button",
    "button": "button",
    "entry": "entry",
    "text": "entry",
    "password text": "entry",
}


def extents(node) -> list | None:
    try:
        rectangle = Atspi.Component.get_extents(node, Atspi.CoordType.SCREEN)
    except Exception:
        return None
    if rectangle is None:
        return None
    return [rectangle.x, rectangle.y, rectangle.width, rectangle.height]


def walk(node, depth: int, out: list) -> None:
    if depth > 12:
        return
    try:
        count = node.get_child_count()
    except Exception:
        return
    for index in range(count):
        try:
            child = node.get_child_at_index(index)
        except Exception:
            continue
        if child is None:
            continue
        try:
            role = child.get_role_name()
            name = child.get_name()
        except Exception:
            continue
        record = {
            "role": role,
            "name": name,
            "extents": extents(child),
        }
        widget = ROLES.get(role)
        if widget:
            record["widget"] = widget
        out.append(record)
        walk(child, depth + 1, out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Read one application's AT-SPI geometry.")
    parser.add_argument("--pid", type=int, required=True)
    arguments = parser.parse_args()

    Atspi.set_timeout(2000, 8000)
    Atspi.init()
    desktop = Atspi.get_desktop(0)

    for index in range(desktop.get_child_count()):
        application = desktop.get_child_at_index(index)
        if application is None:
            continue
        try:
            pid = application.get_process_id()
        except Exception:
            continue
        if pid != arguments.pid:
            continue
        nodes: list = []
        walk(application, 0, nodes)
        frames = [node for node in nodes if node["role"] in ("frame", "window")]
        print(
            json.dumps(
                {
                    "found": True,
                    "application": application.get_name(),
                    "frame": frames[0] if frames else None,
                    "widgets": [node for node in nodes if node.get("widget")],
                    "nodeCount": len(nodes),
                    "framelessNodes": sum(1 for node in nodes if node["extents"] is None),
                }
            )
        )
        return 0

    print(json.dumps({"found": False, "error": f"no AT-SPI application for pid {arguments.pid}"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
