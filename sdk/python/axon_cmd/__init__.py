"""
A dependency-free Python client for the Axon desktop automation daemon.

``axon_cmd._generated`` is written by ``sdk/generate.ts`` from ``schema/tool-surface-v1.json``, the
same artifact the TypeScript client is generated from, so the two SDKs cannot describe different
tool surfaces. Everything else in the package is hand-written.

    from axon_cmd import Axon

    axon = Axon.connect()
    calculator = axon.app("Calculator")
    calculator.look()
    calculator.click("button:7")
    print(calculator.changed_since()["changed"])
"""

from ._generated import AVAILABILITY, SCHEMA_PRODUCT_VERSION, RawClient
from .client import (
    App,
    Axon,
    DebugMethod,
    Facade,
    Health,
    HealthCapability,
    HealthPermission,
    HealthSession,
    Platform,
    RawAxonClient,
    Session,
)
from .errors import (
    AxonError,
    AxonRpcError,
    AxonTimeoutError,
    AxonTransportError,
    AxonWarning,
)
from .transport import (
    DEFAULT_TIMEOUT_S,
    LONG_RUNNING_METHODS,
    LONG_TIMEOUT_S,
    MAX_RESPONSE_BYTES,
    JsonRpcError,
    JsonRpcRequest,
    JsonRpcResponse,
    SocketTransport,
    Transport,
    default_socket_path,
)

__all__ = [
    "AVAILABILITY",
    "DEFAULT_TIMEOUT_S",
    "LONG_RUNNING_METHODS",
    "LONG_TIMEOUT_S",
    "MAX_RESPONSE_BYTES",
    "SCHEMA_PRODUCT_VERSION",
    "App",
    "Axon",
    "AxonError",
    "AxonRpcError",
    "AxonTimeoutError",
    "AxonTransportError",
    "AxonWarning",
    "DebugMethod",
    "Facade",
    "Health",
    "HealthCapability",
    "HealthPermission",
    "HealthSession",
    "JsonRpcError",
    "JsonRpcRequest",
    "JsonRpcResponse",
    "Platform",
    "RawAxonClient",
    "RawClient",
    "Session",
    "SocketTransport",
    "Transport",
    "default_socket_path",
]
