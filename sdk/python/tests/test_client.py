"""The handle-state layer: connecting, what it warns about, and the params each wrapper sends."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest

from axon import Axon, AxonError, AxonRpcError, AxonWarning, SocketTransport
from axon._generated import SCHEMA_PRODUCT_VERSION
from axon.client import RawAxonClient

from .daemon import FakeDaemon, ReceivedRequest, ok, rpc_error, schema_fixture, socket_health

Result = dict[str, Any]
Route = Callable[[ReceivedRequest], Result]


def connect_to(
    health: Result,
    route: Route | None = None,
    warn: Callable[[str], None] | None = None,
) -> tuple[FakeDaemon, Axon]:
    """A daemon that answers ``health`` from a recording and routes tools through ``route``."""
    answer: Route = route or (lambda _: {})
    daemon = FakeDaemon.start(
        lambda received: ok(received, health if received.method == "health" else answer(received))
    )
    return daemon, Axon.connect(
        transport=SocketTransport(daemon.path), warn=warn or (lambda _: None)
    )


def snapshot(identifier: str, pid: int = 4210) -> Result:
    return {
        "snapshot": {
            "id": identifier,
            "app": {
                "bundleIdentifier": "com.apple.Safari",
                "name": "Safari",
                "processIdentifier": pid,
            },
            "indexedNodes": [],
        }
    }


class TestConnect:
    def test_reports_the_version_and_platform_after_a_health_handshake(self) -> None:
        daemon, axon = connect_to(socket_health(version=SCHEMA_PRODUCT_VERSION))
        try:
            assert daemon.only.method == "health"
            assert axon.version == SCHEMA_PRODUCT_VERSION
            assert axon.health["platform"] == "macos"
        finally:
            daemon.stop()

    def test_warns_without_failing_when_the_daemon_version_differs(self) -> None:
        warnings: list[str] = []
        daemon, axon = connect_to(socket_health(version="0.0.1"), warn=warnings.append)
        try:
            assert axon.version == "0.0.1"
            assert len(warnings) == 1
            assert SCHEMA_PRODUCT_VERSION in warnings[0]
            assert "0.0.1" in warnings[0]
        finally:
            daemon.stop()

    def test_warns_through_its_own_category_by_default(self) -> None:
        daemon = FakeDaemon.start(
            lambda received: ok(received, socket_health(version="0.0.1"))
        )
        try:
            with pytest.warns(AxonWarning, match=SCHEMA_PRODUCT_VERSION):
                Axon.connect(transport=SocketTransport(daemon.path))
        finally:
            daemon.stop()

    def test_refuses_a_client_when_the_daemon_reports_itself_unready(self) -> None:
        unready = socket_health(
            ready=False,
            session={
                "interactive": True,
                "graphical": False,
                "reason": "no-display",
                "detail": "No graphical session is available",
            },
        )
        daemon = FakeDaemon.start(lambda received: ok(received, unready))
        try:
            with pytest.raises(AxonError, match="not ready: No graphical session is available"):
                Axon.connect(transport=SocketTransport(daemon.path))
        finally:
            daemon.stop()

    def test_names_an_ungranted_permission_rather_than_leaving_it_to_a_later_refusal(self) -> None:
        warnings: list[str] = []
        daemon, _ = connect_to(
            socket_health(
                version=SCHEMA_PRODUCT_VERSION,
                permissions=[
                    {"name": "accessibility", "granted": False, "reason": "not-granted"},
                    {"name": "screenRecording", "granted": True},
                ],
            ),
            warn=warnings.append,
        )
        try:
            assert "not granted accessibility" in "\n".join(warnings)
        finally:
            daemon.stop()

    def test_explains_an_unreachable_daemon_rather_than_leaking_the_socket_error(self) -> None:
        with pytest.raises(AxonError, match="not running or could not be reached"):
            Axon.connect("/tmp/axon-py-test-absent.sock")


class TestAvailability:
    def test_admits_either_macos_facade(self) -> None:
        daemon, axon = connect_to(socket_health())
        try:
            # navigate is swift-only and click is on every facade; macOS advertises both.
            assert axon.supports("navigate")
            assert axon.supports("click")
            assert not axon.supports("capture_screen")
        finally:
            daemon.stop()

    def test_refuses_a_tool_the_platform_does_not_advertise_without_a_round_trip(self) -> None:
        daemon, axon = connect_to(socket_health())
        try:
            before = daemon.connections
            with pytest.raises(AxonError, match='"capture_screen" is not available on macos'):
                axon.raw.capture_screen()
            assert daemon.connections == before
        finally:
            daemon.stop()

    def test_assumes_support_before_a_platform_is_known(self) -> None:
        assert RawAxonClient(SocketTransport("/tmp/unused.sock")).supports("capture_screen")


class TestErrorsAndRefusals:
    def test_raises_on_a_json_rpc_error(self) -> None:
        daemon = FakeDaemon.start(
            lambda received: ok(received, socket_health())
            if received.method == "health"
            else rpc_error(received, -32602, "could not resolve target")
        )
        try:
            axon = Axon.connect(transport=SocketTransport(daemon.path), warn=lambda _: None)
            with pytest.raises(AxonRpcError) as raised:
                axon.app("Safari").click("button:Go")
            assert raised.value.code == -32602
            assert raised.value.method == "click"
            assert "could not resolve target" in str(raised.value)
        finally:
            daemon.stop()

    def test_returns_a_refusal_as_an_ordinary_result(self) -> None:
        # A refusal is the delivery ladder declining to act, not a protocol failure. Raising here
        # would hide the reason the caller needs in order to choose foregroundPermitted.
        cases: list[dict[str, Any]] = schema_fixture("delivery/results.json")["cases"]
        refused = next(case for case in cases if case["refusal"] is not None)
        daemon, axon = connect_to(socket_health(), lambda _: refused)
        try:
            result = axon.app("Safari").click("button:Go")
            assert result["dispatchSuccess"] is False
            assert result["refusal"]["reason"] == refused["refusal"]["reason"]
        finally:
            daemon.stop()


class TestSessions:
    def test_tags_every_call_with_the_session_name(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: {})
        try:
            session = axon.session("calc-demo")
            session.app("Calculator").click("button:7")
            assert daemon.last("click").params["_session"] == "calc-demo"
            # The handshake happened before the session existed and stays untagged.
            assert "_session" not in daemon.last("health").params
        finally:
            daemon.stop()

    def test_save_exports_the_session_it_was_taken_from(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: {})
        try:
            axon.session("calc-demo").save(path="/tmp/calc.axn")
            saved = daemon.last("save").params
            assert saved["sessionId"] == "calc-demo"
            assert saved["path"] == "/tmp/calc.axn"
            assert saved["_session"] == "calc-demo"
        finally:
            daemon.stop()

    def test_rejects_an_empty_session_name(self) -> None:
        daemon, axon = connect_to(socket_health())
        try:
            with pytest.raises(AxonError, match="must not be empty"):
                axon.session("")
        finally:
            daemon.stop()


class TestAppHandle:
    def test_chains_the_snapshot_id_so_a_change_check_needs_no_bookkeeping(self) -> None:
        def route(received: ReceivedRequest) -> Result:
            if "since" in received.params:
                return {
                    "changed": True,
                    "reason": "windows",
                    "snapshotId": received.params["since"],
                    "currentSnapshotId": "snap-2",
                }
            return snapshot("snap-1")

        daemon, axon = connect_to(socket_health(), route)
        try:
            app = axon.app("Safari")
            app.look()
            assert app.last_snapshot_id == "snap-1"
            first = app.changed_since()
            assert daemon.last("look").params["since"] == "snap-1"
            assert first["changed"] is True
            # The response's own current id becomes the baseline for the next check.
            assert app.last_snapshot_id == "snap-2"
            app.changed_since()
            assert daemon.last("look").params["since"] == "snap-2"
        finally:
            daemon.stop()

    def test_pins_the_process_the_first_look_observed(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: snapshot("snap-1", pid=4210))
        try:
            app = axon.app("Safari")
            assert app.app_selector == "Safari"
            app.look()
            assert app.app_selector == "4210"
            app.click("button:Go")
            assert daemon.last("click").params["target"] == {"app": "4210", "name": "button:Go"}
        finally:
            daemon.stop()

    def test_a_change_check_needs_a_snapshot_to_check_against(self) -> None:
        daemon, axon = connect_to(socket_health())
        try:
            with pytest.raises(AxonError, match="needs a snapshot id or a prior look"):
                axon.app("Safari").changed_since()
        finally:
            daemon.stop()

    def test_each_wrapper_sends_the_params_its_tool_declares(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: {})
        try:
            app = axon.app("Safari")
            target = {"app": "Safari", "name": "field:Search"}

            app.type("field:Search", "axon")
            assert daemon.last("type").params == {"target": target, "value": "axon"}

            app.invoke("field:Search", "AXPress")
            assert daemon.last("invoke").params == {"target": target, "name": "AXPress"}

            app.key("cmd+s", deliveryPolicy="foregroundPermitted")
            assert daemon.last("keyboard").params == {
                "app": "Safari",
                "key": "cmd+s",
                "deliveryPolicy": "foregroundPermitted",
            }

            app.text("hello")
            assert daemon.last("keyboard").params == {"app": "Safari", "text": "hello"}

            app.drag("row:1", "row:4")
            assert daemon.last("drag").params == {
                "from": {"app": "Safari", "name": "row:1"},
                "to": {"app": "Safari", "name": "row:4"},
            }

            app.wait_for_value("field:Search", equals="axon", timeoutMs=1000)
            assert daemon.last("wait_for_value").params == {
                "target": target,
                "equals": "axon",
                "timeoutMs": 1000,
            }

            app.wait_for_stability(condition="changed")
            assert daemon.last("wait_for_stability").params == {
                "app": "Safari",
                "condition": "changed",
            }

            app.find({"role": "AXButton"})
            assert daemon.last("find").params == {"app": "Safari", "locator": {"role": "AXButton"}}
        finally:
            daemon.stop()

    def test_scroll_names_a_target_only_when_one_is_given(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: {})
        try:
            app = axon.app("Safari")
            app.scroll(deltaY=-240)
            assert daemon.last("scroll").params == {"app": "Safari", "deltaY": -240}
            app.scroll("list:Results")
            assert daemon.last("scroll").params == {
                "app": "Safari",
                "target": {"app": "Safari", "name": "list:Results"},
            }
        finally:
            daemon.stop()

    def test_the_debug_family_reaches_the_daemons_dotted_methods(self) -> None:
        daemon, axon = connect_to(socket_health(), lambda _: {})
        try:
            axon.raw.debug("step", {"sessionId": "replay-1"})
            assert daemon.last("debug.step").params == {"sessionId": "replay-1"}
        finally:
            daemon.stop()
