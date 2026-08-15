#!/usr/bin/env python3
"""Samples one systemd unit's memory every 100 ms, starting before its process exists.

Two details make this different from watching a process with `top`, and both come from what was
observed on 2026-08-15: an Axon daemon reached its 1 GiB cap 9.967 seconds after launch, having
served at most one request.

A process that dies in ten seconds is invisible at one-second resolution, so the interval is
100 ms and every row is flushed as it is written -- the record has to survive an OOM kill, which
arrives without warning and takes any buffered output with it.

And the growth may be startup-side, which is the region most tooling misses: a sampler that waits
for a pid has already missed the part of the curve that matters. This samples the unit's cgroup,
which systemd creates before it forks anything, and picks up the per-process detail as soon as
there is a process to read it from.
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

CGROUP_ROOT = Path("/sys/fs/cgroup")


def unit_property(unit: str, name: str) -> str:
    """One systemd property, or the empty string while the unit has not published it yet."""
    result = subprocess.run(
        ["systemctl", "--user", "show", unit, "-p", name, "--value"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def read_int(path: Path) -> int | None:
    try:
        return int(path.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def read_keyed(path: Path, keys: dict[str, str]) -> dict[str, int | None]:
    """Pulls `Key: value` lines out of a /proc file in one read."""
    found: dict[str, int | None] = {alias: None for alias in keys.values()}
    try:
        text = path.read_text()
    except OSError:
        return found
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        alias = keys.get(key)
        if alias is not None:
            try:
                found[alias] = int(rest.split()[0])
            except (ValueError, IndexError):
                pass
    return found


def descriptor_count(pid: int) -> int | None:
    try:
        return len(list((Path("/proc") / str(pid) / "fd").iterdir()))
    except OSError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unit", required=True, help="transient user unit to watch")
    parser.add_argument("--out", required=True, help="CSV path")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--interval", type=float, default=0.1)
    arguments = parser.parse_args()

    columns = [
        "elapsed_ms",
        "cgroup_bytes",
        "cgroup_peak_bytes",
        "cgroup_swap_bytes",
        "rss_kb",
        "anon_kb",
        "threads",
        "fds",
        "pid",
    ]

    cgroup: Path | None = None
    pid: int | None = None
    started = time.monotonic()
    deadline = started + arguments.seconds

    with open(arguments.out, "w", buffering=1) as csv:
        csv.write(",".join(columns) + "\n")
        while time.monotonic() < deadline:
            tick = time.monotonic()

            if cgroup is None:
                published = unit_property(arguments.unit, "ControlGroup")
                if published:
                    cgroup = CGROUP_ROOT / published.lstrip("/")
            if pid is None:
                published = unit_property(arguments.unit, "MainPID")
                if published and published != "0":
                    pid = int(published)

            row: dict[str, int | None] = dict.fromkeys(columns)
            row["elapsed_ms"] = int((tick - started) * 1000)
            if cgroup is not None:
                row["cgroup_bytes"] = read_int(cgroup / "memory.current")
                row["cgroup_peak_bytes"] = read_int(cgroup / "memory.peak")
                row["cgroup_swap_bytes"] = read_int(cgroup / "memory.swap.current")
            if pid is not None:
                process = Path("/proc") / str(pid)
                status = read_keyed(
                    process / "status", {"VmRSS": "rss_kb", "Threads": "threads"}
                )
                row["rss_kb"] = status["rss_kb"]
                row["threads"] = status["threads"]
                rollup = read_keyed(process / "smaps_rollup", {"Anonymous": "anon_kb"})
                row["anon_kb"] = rollup["anon_kb"]
                row["fds"] = descriptor_count(pid)
                row["pid"] = pid

            csv.write(",".join("" if row[c] is None else str(row[c]) for c in columns) + "\n")

            slept = arguments.interval - (time.monotonic() - tick)
            if slept > 0:
                time.sleep(slept)
    return 0


if __name__ == "__main__":
    sys.exit(main())
