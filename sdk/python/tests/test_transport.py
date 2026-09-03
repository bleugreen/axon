"""The socket transport against a fake daemon: framing, bounds, and what it refuses to accept."""

from __future__ import annotations

import json
import sys
from typing import Any

import pytest

from axon.errors import AxonTimeoutError, AxonTransportError
from axon.transport import (
    LONG_RUNNING_METHODS,
    JsonRpcRequest,
    SocketTransport,
    default_socket_path,
)

from .daemon import FakeDaemon, ReceivedRequest, ok


def request(method: str = "look", identifier: int = 1) -> JsonRpcRequest:
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": {"app": "Safari"}}


def test_sends_one_newline_terminated_object_per_connection() -> None:
    with FakeDaemon.start(lambda received: ok(received, {"seen": received.method})) as daemon:
        transport = SocketTransport(daemon.path)
        first = transport.send(request("look", 1))
        second = transport.send(request("find", 2))

    assert first["result"] == {"seen": "look"}
    assert second["result"] == {"seen": "find"}
    # One connection per request is the daemon's contract, not an implementation detail.
    assert daemon.connections == 2
    assert [received.method for received in daemon.received] == ["look", "find"]
    assert json.loads(daemon.received[0].text) == request("look", 1)
    assert "\n" not in daemon.received[0].text


def test_raises_when_the_daemon_answers_nothing_before_the_bound() -> None:
    with FakeDaemon.start(lambda _: None) as daemon:
        transport = SocketTransport(daemon.path, timeout_s=0.1)
        with pytest.raises(AxonTimeoutError, match='"look" timed out'):
            transport.send(request("look"))


def test_gives_the_methods_that_wait_on_the_desktop_the_long_bound() -> None:
    # The short bound is what would fire first if `run` were treated as a prompt method.
    assert LONG_RUNNING_METHODS == frozenset({"run", "wait_for_value", "wait_for_stability"})
    with FakeDaemon.start(lambda _: None) as daemon:
        transport = SocketTransport(daemon.path, timeout_s=30.0, long_timeout_s=0.1)
        with pytest.raises(AxonTimeoutError, match="timed out after 0.1s"):
            transport.send(request("run"))


def test_refuses_a_response_past_the_size_cap() -> None:
    def flood(received: ReceivedRequest) -> dict[str, Any]:
        return ok(received, {"blob": "x" * 4096})

    with FakeDaemon.start(flood) as daemon:
        transport = SocketTransport(daemon.path, max_response_bytes=512)
        with pytest.raises(AxonTransportError, match="exceeded the 512-byte limit"):
            transport.send(request())


def test_rejects_a_response_that_is_not_json() -> None:
    with FakeDaemon.start(lambda _: b"not json at all\n") as daemon:
        transport = SocketTransport(daemon.path)
        with pytest.raises(AxonTransportError, match="invalid JSON"):
            transport.send(request())


def test_rejects_a_json_value_that_is_not_a_response_object() -> None:
    with FakeDaemon.start(lambda _: b"[1, 2, 3]\n") as daemon:
        transport = SocketTransport(daemon.path)
        with pytest.raises(AxonTransportError, match="not a response object"):
            transport.send(request())


def test_reports_a_connection_closed_before_the_newline() -> None:
    with FakeDaemon.start(lambda _: b'{"jsonrpc": "2.0", "id": 1') as daemon:
        transport = SocketTransport(daemon.path)
        with pytest.raises(AxonTransportError, match="before returning a newline"):
            transport.send(request())


def test_names_the_endpoint_when_nothing_is_listening() -> None:
    transport = SocketTransport("/tmp/axon-py-test-nothing-here.sock")
    with pytest.raises(AxonTransportError, match="/tmp/axon-py-test-nothing-here.sock"):
        transport.send(request())


def test_default_socket_path_prefers_the_environment_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("AXON_SOCKET_PATH", "/tmp/somewhere-else.sock")
    assert default_socket_path() == "/tmp/somewhere-else.sock"


@pytest.mark.parametrize(
    ("platform", "runtime_dir", "expected"),
    [
        ("darwin", None, "/tmp/axon.sock"),
        ("linux", "/run/user/1000", "/run/user/1000/axon-v1.sock"),
        ("linux", None, "/tmp/axon-v1.sock"),
        ("win32", None, r"\\.\pipe\axon-v1"),
    ],
)
def test_default_socket_path_follows_the_platform(
    monkeypatch: pytest.MonkeyPatch, platform: str, runtime_dir: str | None, expected: str
) -> None:
    monkeypatch.delenv("AXON_SOCKET_PATH", raising=False)
    monkeypatch.setattr(sys, "platform", platform)
    if runtime_dir is None:
        monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    else:
        monkeypatch.setenv("XDG_RUNTIME_DIR", runtime_dir)
    assert default_socket_path() == expected
