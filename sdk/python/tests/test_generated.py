"""The generated client against the artifact it is generated from."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import pytest

from axon_cmd._generated import AVAILABILITY, SCHEMA_PRODUCT_VERSION, RawClient
from axon_cmd.client import RawAxonClient

ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = ROOT / "schema" / "tool-surface-v1.json"
GENERATED_PATH = ROOT / "sdk" / "python" / "axon_cmd" / "_generated.py"

SURFACE: dict[str, Any] = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
TOOLS: list[dict[str, Any]] = SURFACE["tools"]


def regenerate() -> str:
    if shutil.which("bun") is None:
        pytest.skip("bun is needed to regenerate the client")
    with tempfile.TemporaryDirectory() as directory:
        destination = Path(directory) / "_generated.py"
        subprocess.run(
            ["bun", "sdk/generate.ts", "--lang", "python", str(destination)],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        return destination.read_text(encoding="utf-8")


def test_matches_what_the_committed_tool_surface_implies() -> None:
    assert regenerate() == GENERATED_PATH.read_text(encoding="utf-8")


def test_resolves_every_schema_construct_to_a_real_type() -> None:
    # A branch that only states `required` refines the object around it. Rendering such a branch as
    # a standalone type produced `Any`, silently erasing a tool's whole parameter shape. `Any` as a
    # mapping's value type is legitimate; `Any` as a field's own type is this failure.
    assert "[Any]" not in regenerate()


def test_carries_every_tools_availability_keyed_by_socket_method() -> None:
    assert list(AVAILABILITY) == [tool["socketMethod"] for tool in TOOLS]
    for tool in TOOLS:
        assert AVAILABILITY[tool["socketMethod"]] == tool["availability"]


def test_states_the_product_version_the_surface_was_exported_at() -> None:
    assert SCHEMA_PRODUCT_VERSION == SURFACE["productVersion"]


def test_declares_one_method_per_tool_and_the_client_implements_each() -> None:
    declared = {
        name for name, member in vars(RawClient).items()
        if callable(member) and not name.startswith("_")
    }
    assert declared == {tool["socketMethod"] for tool in TOOLS}
    for tool in TOOLS:
        assert callable(getattr(RawAxonClient, tool["socketMethod"]))
