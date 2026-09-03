"""
Runs pyright over the package, which is where ``tests/typing_cases.py`` is checked.

CI runs pyright as its own step, so a machine without it still reports the type check rather than
silently passing on a skip.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

PACKAGE = Path(__file__).resolve().parents[1]


def test_the_package_and_its_typing_cases_type_check() -> None:
    pyright = shutil.which("pyright")
    if pyright is None:
        pytest.skip("pyright is not installed")
    completed = subprocess.run(
        [pyright, "--outputjson"], cwd=PACKAGE, capture_output=True, text=True
    )
    assert completed.returncode == 0, completed.stdout or completed.stderr
