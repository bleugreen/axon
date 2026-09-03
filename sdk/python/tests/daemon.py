"""
A stand-in for the Axon daemon that speaks the real socket protocol: one request and one response
per connection, each newline-terminated. Tests assert against what it received.

Its canned responses come from ``sdk/fixtures/``, which holds recordings of a live daemon. A fake
that replays a facade document instead agrees with a wrong client rather than failing it.
"""

from __future__ import annotations

import itertools
import json
import os
import socket
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SOCKET_FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
SCHEMA_FIXTURES = Path(__file__).resolve().parents[3] / "schema" / "fixtures"

_counter = itertools.count()


def socket_fixture(name: str) -> dict[str, Any]:
    """A response recorded from a live daemon over the socket, shared with the TypeScript SDK."""
    return json.loads((SOCKET_FIXTURES / name).read_text(encoding="utf-8"))


def schema_fixture(name: str) -> dict[str, Any]:
    """A shared example under ``schema/fixtures/``, which both implementations are checked against."""
    return json.loads((SCHEMA_FIXTURES / name).read_text(encoding="utf-8"))


def socket_health(**overrides: Any) -> dict[str, Any]:
    """
    A healthy macOS daemon's answer to ``health``, recorded from a live 0.3.6 daemon.

    The socket returns ``DaemonReport`` (``Sources/AxonCore/HealthStatus.swift``), which is flat.
    It is not the ``health-v1`` document under ``schema/fixtures/health/``: that one is what the
    CLI's ``status --json`` synthesizes.
    """
    return {**socket_fixture("socket-health-macos.json"), **overrides}


@dataclass
class ReceivedRequest:
    method: str
    params: dict[str, Any]
    id: Any
    jsonrpc: Any
    text: str


Responder = Callable[[ReceivedRequest], Any]
"""
What a fake daemon does with one request. Returning a mapping sends it as the JSON-RPC response;
returning bytes writes those exact bytes; returning ``None`` answers nothing, which is how a hung
daemon is modelled.
"""


class FakeDaemon:
    def __init__(self, path: str, server: socket.socket, responder: Responder) -> None:
        self.path = path
        self.received: list[ReceivedRequest] = []
        self.connections = 0
        self._server = server
        self._responder = responder
        self._open: list[socket.socket] = []
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    @classmethod
    def start(cls, responder: Responder) -> FakeDaemon:
        # Short path: a Unix socket address is capped near 100 bytes, well under a typical TMPDIR.
        path = f"/tmp/axon-py-test-{os.getpid()}-{next(_counter)}.sock"
        _unlink(path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        daemon = cls(path, server, responder)
        daemon._thread.start()
        return daemon

    def __enter__(self) -> FakeDaemon:
        return self

    def __exit__(self, *_: object) -> None:
        self.stop()

    @property
    def only(self) -> ReceivedRequest:
        """The single request received, asserted to be the only one."""
        with self._lock:
            if len(self.received) != 1:
                raise AssertionError(f"expected exactly one request, saw {len(self.received)}")
            return self.received[0]

    def last(self, method: str) -> ReceivedRequest:
        with self._lock:
            for request in reversed(self.received):
                if request.method == method:
                    return request
        raise AssertionError(f"no {method} request was received")

    def methods(self) -> list[str]:
        with self._lock:
            return [request.method for request in self.received]

    def stop(self) -> None:
        self._server.close()
        # A connection this daemon deliberately never answered would otherwise outlive the test.
        for connection in self._open:
            try:
                connection.close()
            except OSError:
                pass
        self._thread.join(timeout=2)
        _unlink(self.path)

    def _serve(self) -> None:
        while True:
            try:
                connection, _ = self._server.accept()
            except OSError:
                return
            with self._lock:
                self.connections += 1
                self._open.append(connection)
            threading.Thread(target=self._handle, args=(connection,), daemon=True).start()

    def _handle(self, connection: socket.socket) -> None:
        try:
            buffer = bytearray()
            while b"\n" not in buffer:
                chunk = connection.recv(65536)
                if not chunk:
                    return
                buffer += chunk
            text = bytes(buffer).split(b"\n", 1)[0].decode("utf-8")
            parsed: dict[str, Any] = json.loads(text)
            request = ReceivedRequest(
                method=str(parsed.get("method")),
                params=parsed.get("params") or {},
                id=parsed.get("id"),
                jsonrpc=parsed.get("jsonrpc"),
                text=text,
            )
            with self._lock:
                self.received.append(request)
            reply = self._responder(request)
            if reply is None:
                return
            payload = (
                bytes(reply)
                if isinstance(reply, (bytes, bytearray))
                else (json.dumps(reply) + "\n").encode("utf-8")
            )
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def ok(request: ReceivedRequest, result: dict[str, Any]) -> dict[str, Any]:
    """A JSON-RPC success envelope around a tool result."""
    return {"jsonrpc": "2.0", "id": request.id, "result": result}


def rpc_error(request: ReceivedRequest, code: int, message: str) -> dict[str, Any]:
    """A JSON-RPC error envelope: the request never reached its tool."""
    return {"jsonrpc": "2.0", "id": request.id, "error": {"code": code, "message": message}}


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass
