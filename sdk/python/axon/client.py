"""
The hand-written layer over the generated tool surface: a connected daemon, an app-scoped handle,
and a named history session.

Every method here is exactly one socket call. Nothing polls, retries, or reshapes what the daemon
returned; waiting is the daemon's job through ``wait_for_value`` and ``wait_for_stability``.
"""

from __future__ import annotations

import warnings
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Literal, Required, TypedDict, cast

from ._generated import (
    AVAILABILITY,
    SCHEMA_PRODUCT_VERSION,
    CaptureScreenParams,
    ClickParams,
    DragParams,
    FindParams,
    InvokeParams,
    KeyboardParams,
    LookParams,
    NavigateParams,
    PermitParams,
    RawClient,
    RunParams,
    SaveParams,
    ScrollParams,
    TabsParams,
    TypeParams,
    WaitForStabilityParams,
    WaitForValueParams,
    WindowsParams,
)
from .errors import AxonError, AxonRpcError, AxonTransportError, AxonWarning
from .transport import JsonRpcRequest, SocketTransport, Transport

__all__ = [
    "App",
    "Axon",
    "DebugMethod",
    "Facade",
    "Health",
    "HealthCapability",
    "HealthPermission",
    "HealthSession",
    "RawAxonClient",
    "Session",
]

Platform = Literal["macos", "linux", "windows"]
Facade = Literal["swift", "mac", "windows", "linux"]

DebugMethod = Literal[
    "create", "start", "step", "retry", "continue", "resume", "runTo", "setBreakpoints", "stop",
]
"""The ``.axn`` replay stepping family, dispatched by the daemon's ``debug.*`` methods."""


class HealthSession(TypedDict, total=False):
    interactive: Required[bool]
    graphical: Required[bool]
    # Absent where the platform has no session-level accessibility switch, as on macOS.
    accessibilityEnabled: bool | None
    reason: str | None
    detail: str | None


class HealthPermission(TypedDict, total=False):
    name: Required[str]
    granted: Required[bool]
    reason: str | None
    detail: str | None


class HealthCapability(TypedDict, total=False):
    capability: Required[str]
    usable: Required[bool]
    reason: str | None
    restriction: str | None


class Health(TypedDict, total=False):
    """
    What the daemon answers a socket ``health`` request with: ``DaemonReport``, defined in
    ``Sources/AxonCore/HealthStatus.swift``, whose fields are flat.

    This is deliberately not the ``health-v1`` document described by
    ``schema/health-v1.schema.json``. That one nests a ``daemon`` object and adds ``schemaVersion``
    and ``registration``, and it is what the CLI's ``status --json`` synthesizes -- including for a
    daemon that never answered at all. A report read off the socket can only have come from a
    daemon that is already serving, which is why ``ready`` sits at the top level here.
    """

    version: Required[str]
    platform: Required[Platform]
    ready: Required[bool]
    processId: Required[int]
    endpoint: Required[str]
    session: Required[HealthSession]
    permissions: Required[Sequence[HealthPermission]]
    capabilities: Required[Sequence[HealthCapability]]


def _facades_for(platform: Platform | str) -> tuple[Facade, ...]:
    """
    A platform can be served by more than one daemon build, and the report names the operating
    system rather than the build. macOS therefore admits any tool either macOS facade advertises;
    the daemon stays the authority and refuses what it does not implement.
    """
    if platform == "macos":
        return ("swift", "mac")
    return ("linux",) if platform == "linux" else ("windows",)


def _ungranted(health: Health) -> list[HealthPermission]:
    return [permission for permission in health.get("permissions") or () if not permission["granted"]]


def _not_ready_detail(health: Health) -> str | None:
    """
    Why a daemon that answered nonetheless calls itself unready. The report carries no top-level
    reason, so this reads the two places one can appear: the session, then anything it was denied.
    """
    session = health.get("session") or {}
    stated = session.get("detail") or session.get("reason")
    if stated:
        return stated
    denied = _ungranted(health)
    if not denied:
        return None
    return "; ".join(
        f"{p['name']}: {p.get('detail') or p.get('reason') or 'not granted'}" for p in denied
    )


class RawAxonClient(RawClient):
    """One typed method per tool over one transport. Results stay loose; the daemon owns them."""

    def __init__(
        self,
        transport: Transport,
        platform: Platform | None = None,
        session_id: str | None = None,
    ) -> None:
        self.transport = transport
        self.platform = platform
        self.session_id = session_id
        self._next_id = 1

    def with_session(self, session_id: str) -> RawAxonClient:
        return RawAxonClient(self.transport, self.platform, session_id)

    def supports(self, method: str) -> bool:
        """Whether the connected platform advertises this socket method at all."""
        support = AVAILABILITY.get(method)
        if support is None or self.platform is None:
            return True
        return any(support.get(facade, False) for facade in _facades_for(self.platform))

    def request(self, method: str, params: Mapping[str, Any] | None = None) -> dict[str, Any]:
        if not self.supports(method):
            raise AxonError(f'Axon tool "{method}" is not available on {self.platform}')
        sent: dict[str, Any] = dict(params or {})
        if self.session_id is not None:
            sent["_session"] = self.session_id
        request: JsonRpcRequest = {
            "jsonrpc": "2.0",
            "id": self._next_id,
            "method": method,
            "params": sent,
        }
        self._next_id += 1
        response = self.transport.send(request)
        error = response.get("error")
        if error is not None:
            raise AxonRpcError(error, method)
        result = response.get("result")
        if result is None:
            raise AxonTransportError(f'Axon response to "{method}" had neither result nor error')
        return result

    def health(self) -> dict[str, Any]:
        return self.request("health")

    def shutdown(self, params: Mapping[str, Any] | None = None) -> dict[str, Any]:
        return self.request("shutdown", params)

    def debug(self, method: DebugMethod, params: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """
        The stepping-debugger family for ``.axn`` replay. It is not part of the generated tool
        surface, so its parameters and results stay loose; only the method names are enumerated.
        """
        return self.request(f"debug.{method}", params)

    def capture_screen(self, params: CaptureScreenParams | None = None) -> dict[str, Any]:
        return self.request("capture_screen", params)

    def look(self, params: LookParams | None = None) -> dict[str, Any]:
        return self.request("look", params)

    def navigate(self, params: NavigateParams) -> dict[str, Any]:
        return self.request("navigate", params)

    def windows(self, params: WindowsParams) -> dict[str, Any]:
        return self.request("windows", params)

    def tabs(self, params: TabsParams) -> dict[str, Any]:
        return self.request("tabs", params)

    def find(self, params: FindParams) -> dict[str, Any]:
        return self.request("find", params)

    def wait_for_value(self, params: WaitForValueParams) -> dict[str, Any]:
        return self.request("wait_for_value", params)

    def wait_for_stability(self, params: WaitForStabilityParams) -> dict[str, Any]:
        return self.request("wait_for_stability", params)

    def permit(self, params: PermitParams | None = None) -> dict[str, Any]:
        return self.request("permit", params)

    def run(self, params: RunParams | None = None) -> dict[str, Any]:
        return self.request("run", params)

    def save(self, params: SaveParams | None = None) -> dict[str, Any]:
        return self.request("save", params)

    def click(self, params: ClickParams) -> dict[str, Any]:
        return self.request("click", params)

    def type(self, params: TypeParams) -> dict[str, Any]:
        return self.request("type", params)

    def keyboard(self, params: KeyboardParams) -> dict[str, Any]:
        return self.request("keyboard", params)

    def scroll(self, params: ScrollParams | None = None) -> dict[str, Any]:
        return self.request("scroll", params)

    def drag(self, params: DragParams) -> dict[str, Any]:
        return self.request("drag", params)

    def invoke(self, params: InvokeParams) -> dict[str, Any]:
        return self.request("invoke", params)


def _warn_through(warn: Callable[[str], None] | None) -> Callable[[str], None]:
    if warn is not None:
        return warn
    return lambda message: warnings.warn(message, AxonWarning, stacklevel=3)


class Axon:
    """A connected daemon. :meth:`connect` proves it is reachable and ready before returning."""

    def __init__(self, raw: RawAxonClient, health: Health) -> None:
        self.raw = raw
        self.health = health
        self.version: str = health["version"]

    @classmethod
    def connect(
        cls,
        socket_path: str | None = None,
        *,
        transport: Transport | None = None,
        warn: Callable[[str], None] | None = None,
    ) -> Axon:
        """
        Handshakes with the daemon over ``health`` and hands back a client, or explains why not.

        Warnings go through :class:`~axon.errors.AxonWarning` unless ``warn`` is given a callable
        to receive them instead.
        """
        channel = transport if transport is not None else SocketTransport(socket_path)
        try:
            report = cast(Health, RawAxonClient(channel).health())
        except Exception as error:
            raise AxonError("Axon daemon is not running or could not be reached") from error
        if not report.get("ready"):
            detail = _not_ready_detail(report)
            raise AxonError(f"Axon daemon is not ready{f': {detail}' if detail else ''}")
        emit = _warn_through(warn)
        if report["version"] != SCHEMA_PRODUCT_VERSION:
            emit(
                f"Axon SDK was generated for {SCHEMA_PRODUCT_VERSION}, "
                f"but the daemon reports {report['version']}"
            )
        # A daemon that is serving still refuses every action it lacks the grant for, and that
        # failure reads as an unexplained refusal several calls later unless it is named here.
        denied = _ungranted(report)
        if denied:
            emit(
                "Axon daemon is ready but was not granted "
                f"{', '.join(p['name'] for p in denied)}; actions that need it will be refused"
            )
        return cls(RawAxonClient(channel, report["platform"]), report)

    def supports(self, tool: str) -> bool:
        """Whether the connected platform advertises a tool, answered without calling the daemon."""
        return self.raw.supports(tool)

    def app(self, selector: str) -> App:
        """A handle that remembers the app it looked at, so later calls need no repeated selector."""
        return App(self.raw, selector)

    def session(self, name: str) -> Session:
        """A client whose every call is recorded under a named history session, exported by save."""
        if not name:
            raise AxonError("Axon session name must not be empty")
        return Session(self.raw.with_session(name), name, self.health)


class App:
    """
    An app-scoped handle. It holds exactly two pieces of state -- the newest snapshot id this app
    produced and the process id that snapshot named -- so a script reads as a sequence of actions
    on one running app. Every method is one socket call; nothing here polls or retries.

    Keyword arguments are passed to the tool unchanged, so they use the schema's own names
    (``deliveryPolicy``, ``timeoutMs``). ``axon.raw`` is the fully typed way to call the same
    tools; this layer trades that typing for brevity at the call site.
    """

    def __init__(self, raw: RawAxonClient, selector: str) -> None:
        self.raw = raw
        self.selector = selector
        self._snapshot_id: str | None = None
        self._pinned: str | None = None

    @property
    def last_snapshot_id(self) -> str | None:
        """The most recent snapshot id observed through this handle, if any."""
        return self._snapshot_id

    @property
    def app_selector(self) -> str:
        """
        The selector later calls use: the pid from the last look once one is known, which keeps a
        script bound to the process it observed rather than re-resolving a name that may now match
        a different instance.
        """
        return self._pinned or self.selector

    def _target(self, name: str) -> dict[str, str]:
        return {"app": self.app_selector, "name": name}

    def look(self, **options: Any) -> dict[str, Any]:
        return self._remember(
            self.raw.look(cast(LookParams, {**options, "app": self.app_selector}))
        )

    def changed_since(self, snapshot_id: str | None = None) -> dict[str, Any]:
        """
        The daemon's change check against a prior snapshot, defaulting to this handle's own.

        The verdict is returned unaltered, and the daemon reaches it by comparing app identity and
        top-level window signatures only, so a change confined to an element's value reports
        ``changed: false``. Wait on a specific value with :meth:`wait_for_value`, or on any
        observable change with ``wait_for_stability(condition="changed")``, rather than this.
        """
        since = snapshot_id or self._snapshot_id
        if not since:
            raise AxonError("changed_since needs a snapshot id or a prior look()")
        return self._remember(
            self.raw.look(cast(LookParams, {"app": self.app_selector, "since": since}))
        )

    def click(self, name: str, **options: Any) -> dict[str, Any]:
        return self.raw.click(cast(ClickParams, {**options, "target": self._target(name)}))

    def type(self, name: str, value: str, **options: Any) -> dict[str, Any]:
        return self.raw.type(
            cast(TypeParams, {**options, "target": self._target(name), "value": value})
        )

    def invoke(self, name: str, action: str, **options: Any) -> dict[str, Any]:
        return self.raw.invoke(
            cast(InvokeParams, {**options, "target": self._target(name), "name": action})
        )

    def drag(self, from_name: str, to_name: str, **options: Any) -> dict[str, Any]:
        return self.raw.drag(cast(DragParams, {
            **options, "from": self._target(from_name), "to": self._target(to_name),
        }))

    def scroll(self, name: str | None = None, **options: Any) -> dict[str, Any]:
        params: dict[str, Any] = {**options, "app": self.app_selector}
        if name is not None:
            params["target"] = self._target(name)
        return self.raw.scroll(cast(ScrollParams, params))

    def key(self, key: str, **options: Any) -> dict[str, Any]:
        return self.raw.keyboard(
            cast(KeyboardParams, {**options, "app": self.app_selector, "key": key})
        )

    def text(self, text: str, **options: Any) -> dict[str, Any]:
        return self.raw.keyboard(
            cast(KeyboardParams, {**options, "app": self.app_selector, "text": text})
        )

    def wait_for_value(self, name: str, **options: Any) -> dict[str, Any]:
        """The daemon polls; this waits on one call."""
        return self.raw.wait_for_value(
            cast(WaitForValueParams, {**options, "target": self._target(name)})
        )

    def wait_for_stability(self, **options: Any) -> dict[str, Any]:
        return self.raw.wait_for_stability(
            cast(WaitForStabilityParams, {**options, "app": self.app_selector})
        )

    def find(self, locator: Mapping[str, Any], **options: Any) -> dict[str, Any]:
        return self.raw.find(
            cast(FindParams, {**options, "app": self.app_selector, "locator": locator})
        )

    def _remember(self, result: dict[str, Any]) -> dict[str, Any]:
        """
        A full look nests its snapshot; a ``since`` check names the fresh snapshot at the top
        level. Both advance the handle so a script can keep asking what changed without tracking
        ids of its own.
        """
        snapshot = result.get("snapshot")
        if isinstance(snapshot, dict):
            identifier = snapshot.get("id")
            if isinstance(identifier, str):
                self._snapshot_id = identifier
            app = snapshot.get("app")
            if isinstance(app, dict):
                pid = app.get("processIdentifier")
                if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
                    self._pinned = str(pid)
        current = result.get("currentSnapshotId")
        if isinstance(current, str):
            self._snapshot_id = current
        return result


class Session(Axon):
    """Every call this client makes is recorded under ``name``; save exports it as a .axn file."""

    def __init__(self, raw: RawAxonClient, name: str, health: Health) -> None:
        super().__init__(raw, health)
        self.name = name

    def save(self, **params: Any) -> dict[str, Any]:
        return self.raw.save(cast(SaveParams, {**params, "sessionId": self.name}))
