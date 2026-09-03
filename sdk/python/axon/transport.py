"""
JSON-RPC 2.0 over the Axon daemon's local socket.

The daemon serves one request per connection: connect, write one JSON object and a newline, read
one newline-terminated response, close. ``Sources/AxonCore/SocketClient.swift`` is the reference
for that framing, and nothing here keeps a connection alive between calls.

Every call blocks. An asyncio program can wrap one in :func:`asyncio.to_thread`; shipping a second
async implementation would be two clients to keep true instead of one.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from typing import IO, Any, Literal, NotRequired, Protocol, TypedDict, cast

from .errors import AxonTimeoutError, AxonTransportError

__all__ = [
    "DEFAULT_TIMEOUT_S",
    "LONG_RUNNING_METHODS",
    "LONG_TIMEOUT_S",
    "MAX_RESPONSE_BYTES",
    "JsonRpcError",
    "JsonRpcRequest",
    "JsonRpcResponse",
    "SocketTransport",
    "Transport",
    "default_socket_path",
]

DEFAULT_TIMEOUT_S = 30.0
"""How long a tool that answers promptly may stay silent before the call is abandoned."""

LONG_TIMEOUT_S = 300.0
"""The bound for the methods the daemon may deliberately hold open while it waits."""

MAX_RESPONSE_BYTES = 64 * 1024 * 1024
"""An observation with a screenshot is large; a response past this is a daemon in trouble."""

WINDOWS_PIPE = r"\\.\pipe\axon-v1"

LONG_RUNNING_METHODS: frozenset[str] = frozenset({"run", "wait_for_value", "wait_for_stability"})
"""
The methods that wait on the desktop rather than on themselves, which the reference Swift client
(``Sources/AxonCore/CommandHandling.swift``) gives the long bound. Anything else answers promptly
or is in trouble.
"""

_CHUNK_BYTES = 64 * 1024


class JsonRpcRequest(TypedDict):
    jsonrpc: Literal["2.0"]
    id: int | str
    method: str
    params: NotRequired[dict[str, Any]]


class JsonRpcError(TypedDict):
    code: int
    message: str
    data: NotRequired[Any]


class JsonRpcResponse(TypedDict, total=False):
    jsonrpc: str
    id: int | str | None
    result: dict[str, Any]
    error: JsonRpcError


class Transport(Protocol):
    """One request in, one response out. Tests substitute their own; the client never assumes more."""

    def send(self, request: JsonRpcRequest) -> JsonRpcResponse: ...


def default_socket_path() -> str:
    """Where the daemon listens on this platform, unless ``AXON_SOCKET_PATH`` says otherwise."""
    override = os.environ.get("AXON_SOCKET_PATH")
    if override:
        return override
    if sys.platform == "win32":
        return WINDOWS_PIPE
    if sys.platform.startswith("linux"):
        return f"{os.environ.get('XDG_RUNTIME_DIR') or '/tmp'}/axon-v1.sock"
    return "/tmp/axon.sock"


class SocketTransport:
    """The real transport: a fresh connection to the daemon's endpoint for every request."""

    def __init__(
        self,
        socket_path: str | None = None,
        *,
        timeout_s: float | None = None,
        long_timeout_s: float | None = None,
        max_response_bytes: int | None = None,
    ) -> None:
        self.socket_path = socket_path or default_socket_path()
        self.timeout_s = DEFAULT_TIMEOUT_S if timeout_s is None else timeout_s
        self.long_timeout_s = LONG_TIMEOUT_S if long_timeout_s is None else long_timeout_s
        self.max_response_bytes = (
            MAX_RESPONSE_BYTES if max_response_bytes is None else max_response_bytes
        )

    def send(self, request: JsonRpcRequest) -> JsonRpcResponse:
        method = request["method"]
        timeout = self.long_timeout_s if method in LONG_RUNNING_METHODS else self.timeout_s
        payload = (json.dumps(request) + "\n").encode("utf-8")
        line = (
            self._over_pipe(payload)
            if self.socket_path.startswith("\\\\")
            else self._over_socket(payload, timeout, method)
        )
        try:
            response = json.loads(line)
        except ValueError as error:
            raise AxonTransportError(f"Axon returned invalid JSON: {error}") from error
        if not isinstance(response, dict):
            raise AxonTransportError("Axon returned a JSON value that is not a response object")
        return cast(JsonRpcResponse, response)

    def _over_socket(self, payload: bytes, timeout: float, method: str) -> bytes:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            # A timeout on the socket bounds each read rather than the exchange, which is what a
            # daemon that has gone quiet looks like from here.
            connection.settimeout(timeout)
            try:
                connection.connect(self.socket_path)
                connection.sendall(payload)
                return self._read_line(connection.recv)
            except TimeoutError as error:
                raise AxonTimeoutError(
                    f'Axon request "{method}" timed out after {timeout}s'
                ) from error
            except OSError as error:
                raise AxonTransportError(
                    f"Could not communicate with the Axon daemon at {self.socket_path}: {error}"
                ) from error
        finally:
            connection.close()

    def _over_pipe(self, payload: bytes) -> bytes:
        """
        The Windows endpoint is a named pipe, which opens as a file rather than as a socket.

        Two things follow from that and are stated rather than hidden. A file object carries no
        timeout, so this path is bounded by the daemon answering rather than by
        :data:`DEFAULT_TIMEOUT_S`; enforcing one needs the Win32 overlapped-I/O API and a
        dependency this package does not take. And a pipe that is already serving another client
        raises immediately instead of queueing.
        """
        try:
            with open(self.socket_path, "r+b", buffering=0) as pipe:
                pipe.write(payload)
                return self._read_line(cast(IO[bytes], pipe).read)
        except OSError as error:
            raise AxonTransportError(
                f"Could not communicate with the Axon daemon at {self.socket_path}: {error}"
            ) from error

    def _read_line(self, read: Any) -> bytes:
        """Reads until the newline that ends the response, refusing one that never ends."""
        line = bytearray()
        while True:
            chunk: bytes = read(_CHUNK_BYTES)
            if not chunk:
                raise AxonTransportError(
                    "Axon closed the connection before returning a newline-terminated response"
                )
            newline = chunk.find(b"\n")
            piece = chunk if newline < 0 else chunk[:newline]
            if len(line) + len(piece) > self.max_response_bytes:
                raise AxonTransportError(
                    f"Axon response exceeded the {self.max_response_bytes}-byte limit"
                )
            line += piece
            if newline >= 0:
                return bytes(line)
