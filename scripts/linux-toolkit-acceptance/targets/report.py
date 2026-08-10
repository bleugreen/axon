"""How every native target tells the harness what it received.

The application reports its own state rather than the harness inferring it: the harness can only see
that an event was sent, and only the application can see that it was acted on.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import urllib.request


def report(payload: dict) -> None:
    """Posts one report, off the toolkit's main loop so a slow socket cannot stall the widget."""
    url = os.environ.get("AXON_HARNESS_REPORT")
    if not url:
        print(json.dumps(payload), flush=True)
        return
    body = json.dumps(payload).encode()

    def send() -> None:
        request = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}
        )
        try:
            urllib.request.urlopen(request, timeout=5).read()
        except Exception as error:
            print(f"report failed: {error}", file=sys.stderr, flush=True)

    threading.Thread(target=send, daemon=True).start()
