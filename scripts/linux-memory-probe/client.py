#!/usr/bin/env python3
"""Sends one JSON-RPC request to an Axon daemon socket and reports how it went.

Deliberately prints a summary rather than the reply. A `look` at gnome-shell is megabytes of
JSON, and the question this answers during a memory probe is only ever whether the daemon
answered, how long it took, and how much it said -- printing the tree would bury the run log and
charge the probe's own memory for it.
"""

import argparse
import json
import socket
import sys
import time


def request(path: str, method: str, params: dict, timeout: float) -> tuple[str, float, int]:
    """Returns (outcome, seconds, reply bytes). One connection carries one request."""
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    ).encode()
    started = time.monotonic()
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    try:
        connection.connect(path)
        connection.sendall(payload + b"\n")
        chunks = []
        while True:
            chunk = connection.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
            if chunks[-1].endswith(b"\n"):
                break
    except OSError as error:
        return (f"transport-error: {error}", time.monotonic() - started, 0)
    finally:
        connection.close()

    body = b"".join(chunks)
    elapsed = time.monotonic() - started
    if not body:
        return ("no-reply", elapsed, 0)
    try:
        parsed = json.loads(body.decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ("unparseable-reply", elapsed, len(body))
    if "error" in parsed:
        error = parsed["error"]
        return (f"error {error.get('code')}: {error.get('message')}", elapsed, len(body))
    return ("ok", elapsed, len(body))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--method", required=True)
    parser.add_argument("--params", default="{}")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--label", default=None)
    arguments = parser.parse_args()

    outcome, elapsed, size = request(
        arguments.socket, arguments.method, json.loads(arguments.params), arguments.timeout
    )
    label = arguments.label or arguments.method
    print(f"[{time.strftime('%H:%M:%S')}] {label}: {outcome} in {elapsed:.3f}s ({size} bytes)")
    return 0 if outcome == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
