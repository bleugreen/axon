"""What this client raises, and the category it warns under."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

__all__ = [
    "AxonError",
    "AxonRpcError",
    "AxonTimeoutError",
    "AxonTransportError",
    "AxonWarning",
]


class AxonError(Exception):
    """Base class for every failure this client raises."""


class AxonTransportError(AxonError):
    """The daemon could not be reached, or answered something that is not a JSON-RPC response."""


class AxonTimeoutError(AxonTransportError):
    """The daemon held the connection open past the bound for this method."""


class AxonRpcError(AxonError):
    """
    A JSON-RPC ``error``: the request never reached its tool.

    A delivery refusal is not one of these. An action the daemon declined to deliver is a
    successful call whose result carries ``success: false`` and a ``refusal`` object describing
    which rung of the delivery ladder refused and why, and it is returned rather than raised.
    """

    def __init__(self, error: Mapping[str, Any], method: str) -> None:
        self.code: int = int(error.get("code", 0))
        self.message: str = str(error.get("message", ""))
        self.data: Any = error.get("data")
        self.method = method
        super().__init__(f'Axon JSON-RPC error {self.code} from "{method}": {self.message}')


class AxonWarning(UserWarning):
    """
    A daemon that will serve, but not as this client expects.

    It is its own category so that a program can silence or raise Axon's warnings alone, through
    ``warnings.simplefilter`` on this class.
    """
