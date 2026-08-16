#!/usr/bin/env python3
"""Measure whether a macOS application acts on input posted to it with `CGEventPostToPid`.

See README.md for what this measures and why it has to be measured rather than
inferred. This module is the orchestration: it launches each target, holds the
foreground in a decoy, parks the real cursor clear of everything, proves the
target owns the coordinate, posts, and reads back what the target itself says
happened.

Nothing here decides whether a result is good, and nothing here talks to the
Axon daemon. The verdict rules live in `evidence.py`, and the mechanism is
measured directly so the evidence is independent of the implementation that
will consume it.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import evidence

HERE = Path(__file__).resolve().parent
PROBE_DIR = HERE / "probe"
PROBE_BINARY = PROBE_DIR / "target" / "release" / "acceptance-probe"
RAW_DIR = HERE / "raw"

# An application that is going to act on a posted event acts on it in
# milliseconds. These bounds are for a loaded machine, not for an application
# taking its time to decide.
REACTION_TIMEOUT = 3.0
READY_TIMEOUT = 25.0
TYPED_TEXT = "axon"

# The ordered phases of one trial. Recorded with every raw record so a reviewer
# can see that the preconditions were established before the dispatch rather
# than reconstructed after it.
PHASES = (
    "identity",
    "controlBefore",
    "background",
    "ownership",
    "dispatch",
    "observe",
    "controlAfter",
    "restore",
)


# -- the reporting server ----------------------------------------------------------------------


class Reports:
    """Everything the targets say about themselves, in arrival order.

    A target reports its own state rather than the campaign inferring it: the
    campaign can see that an event was posted, and only the application can see
    that it was acted on.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: list[dict] = []

    def add(self, item: dict) -> None:
        with self._lock:
            item.setdefault("receivedAt", time.time())
            self._items.append(item)

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self._items)

    def since(self, mark: float, **match: object) -> list[dict]:
        return [
            item
            for item in self.snapshot()
            if item["receivedAt"] >= mark
            and all(item.get(key) == value for key, value in match.items())
        ]

    def mark(self) -> float:
        return time.time()

    def wait_for(self, timeout: float, **match: object) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = [
                item
                for item in self.snapshot()
                if all(item.get(key) == value for key, value in match.items())
            ]
            if found:
                return found[-1]
            time.sleep(0.02)
        return None


class _Handler(BaseHTTPRequestHandler):
    reports: Reports
    page: str

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler naming
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b"{}"
        try:
            item = json.loads(body)
        except ValueError:
            item = {"kind": "malformed", "raw": body.decode(errors="replace")}
        type(self).reports.add(item)
        self._no_content()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler naming
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        nonce = (query.get("nonce") or [""])[0]
        if parsed.path in ("/page", "/navigated"):
            # The navigation endpoint is the strongest target-side evidence
            # available, because this server sees it directly rather than being
            # told about it by a page whose script an engine may have throttled.
            marker = "navigated" if parsed.path == "/navigated" else "page"
            if marker == "navigated":
                type(self).reports.add({"kind": "navigated", "nonce": nonce, "role": "server"})
            other = "/page" if marker == "navigated" else "/navigated"
            body = (
                type(self)
                .page.replace("__NONCE__", nonce)
                .replace("__MARKER__", marker)
                .replace("__HREF__", f"{other}?nonce={nonce}")
                .encode()
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._no_content()

    def _no_content(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args) -> None:
        return


# -- the probe ---------------------------------------------------------------------------------


class Probe:
    """The native half, one subprocess per observation.

    A process per call rather than a long-lived one on purpose: every command
    reads the live state of the desktop, and a cached reading is the one kind of
    evidence this campaign cannot use.
    """

    def __init__(self, binary: Path = PROBE_BINARY) -> None:
        self.binary = binary

    def __call__(self, command: str, **arguments: object) -> dict:
        argv = [str(self.binary), command]
        for key, value in arguments.items():
            flag = "--" + key.replace("_", "-")
            if value is True:
                argv.append(flag)
            elif value is not None and value is not False:
                argv.extend([flag, str(value)])
        finished = subprocess.run(argv, capture_output=True, text=True)
        try:
            return json.loads(finished.stdout or "{}")
        except ValueError:
            return {"error": f"unparseable probe output: {finished.stdout!r} {finished.stderr!r}"}


def build_probe() -> None:
    subprocess.run(
        ["cargo", "build", "--release", "--locked"],
        cwd=PROBE_DIR,
        check=True,
    )


# -- targets -----------------------------------------------------------------------------------


@dataclass
class Launched:
    """A running target: what to post at, and what to read back from."""

    pid: int
    nonce: str
    point: dict | None
    window: dict | None = None
    detail: dict = field(default_factory=dict)


class Target:
    """One application under measurement, for one action."""

    label: str = ""
    kind: str = ""
    remeasure_when: str = ""
    unavailable: str | None = None

    def launch(self, action: str) -> Launched:
        raise NotImplementedError

    def identity(self, pid: int) -> dict:
        raise NotImplementedError

    def snapshot(self) -> dict:
        raise NotImplementedError

    def mutation(self, action: str, before: dict, after: dict) -> tuple[bool, str]:
        raise NotImplementedError

    def arrival(self, mark: float) -> tuple[bool | None, str | None]:
        return (None, None)

    def close(self) -> None:
        return


def bundle_identity(probe: Probe, pid: int) -> dict:
    """What a backend holding only a process identifier can read about a target.

    Deliberately restricted to that: the campaign knows what it launched, and a
    row keyed on what the campaign knew would authorize a target no consumer
    could recognize.
    """
    reported = probe("app", pid=pid)
    path = reported.get("bundlePath")
    short = full = None
    runtime = None
    if path:
        info = Path(path) / "Contents" / "Info.plist"
        if info.exists():
            try:
                plist = plistlib.loads(info.read_bytes())
                short = plist.get("CFBundleShortVersionString")
                full = plist.get("CFBundleVersion")
            except Exception:  # noqa: BLE001 - a malformed plist is a finding, not a crash
                short = full = None
        electron = Path(path) / "Contents" / "Frameworks" / "Electron Framework.framework"
        if electron.exists():
            framework_info = electron / "Resources" / "Info.plist"
            version = None
            if framework_info.exists():
                try:
                    version = plistlib.loads(framework_info.read_bytes()).get(
                        "CFBundleShortVersionString"
                    )
                except Exception:  # noqa: BLE001
                    version = None
            runtime = {"kind": "electron-framework", "version": version}
    start = None
    try:
        start = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        start = None
    return {
        "bundleId": reported.get("bundleId"),
        "bundleShortVersion": short,
        "bundleVersion": full,
        "versionSeries": ".".join((short or "").split(".")[:2]) or None,
        "runtimeSignature": runtime,
        "readableAtDispatch": bool(reported.get("bundleId")) and short is not None,
        "source": "NSRunningApplication(processIdentifier:) then the bundle's Info.plist",
        "processStartTime": start or None,
    }


class FixtureTarget(Target):
    """The probe's own AppKit window, running from a generated application bundle.

    Bundled rather than run as a bare executable so that it has the identity a
    real application has: a bundle identifier and a version are what any future
    acceptance entry would be keyed on, and a fixture with neither could not
    stand in for one.
    """

    kind = "appkit-native"

    def __init__(
        self,
        probe: Probe,
        reports: Reports,
        bundles: Path,
        report_url: str,
        label: str = "appkit-fixture",
        webview_url: str | None = None,
        bundle_id: str = "dev.axon.acceptance.target",
    ) -> None:
        self.probe = probe
        self.reports = reports
        self.bundles = bundles
        self.report_url = report_url
        self.label = label
        self.webview_url = webview_url
        self.bundle_id = bundle_id
        self.kind = "wkwebview" if webview_url else "appkit-native"
        self.remeasure_when = "a macOS major release, which is what changes how AppKit routes a posted event"
        self.process: subprocess.Popen | None = None
        self.nonce = ""
        self.ready: dict = {}

    def launch(self, action: str) -> Launched:
        self.nonce = uuid.uuid4().hex[:12]
        bundle = make_bundle(self.bundles, self.label, self.bundle_id, PROBE_BINARY)
        argv = [
            str(bundle / "Contents" / "MacOS" / "acceptance-probe"),
            "fixture",
            "--role",
            "target",
            "--nonce",
            self.nonce,
            "--report",
            self.report_url,
            "--x",
            "120",
            "--y",
            "460",
            "--width",
            "520",
            "--height",
            "300",
            "--seconds",
            "180",
        ]
        if self.webview_url:
            argv.extend(["--webview", f"{self.webview_url}&nonce={self.nonce}"])
        self.process = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True)
        line = self.process.stdout.readline() if self.process.stdout else ""
        self.ready = json.loads(line) if line.strip().startswith("{") else {}
        if not self.ready:
            raise RuntimeError("the fixture never reported that it was ready")
        time.sleep(1.0)
        point = None
        if self.webview_url:
            geometry = self.reports.wait_for(READY_TIMEOUT, kind="geometry", nonce=self.nonce)
            if geometry:
                point = geometry["widgets"]["link"]["center"]
        elif action == "click":
            point = self.ready["checkbox"]["center"]
        return Launched(
            pid=self.ready["pid"],
            nonce=self.nonce,
            point=point,
            window=self.ready.get("window"),
            detail={"ready": self.ready},
        )

    def identity(self, pid: int) -> dict:
        return bundle_identity(self.probe, pid)

    def snapshot(self) -> dict:
        if self.webview_url:
            return web_snapshot(self.reports, self.nonce)
        states = [
            item
            for item in self.reports.snapshot()
            if item.get("kind") == "state" and item.get("nonce") == self.nonce
        ]
        latest = states[-1] if states else {}
        return {"checkbox": latest.get("checkbox"), "text": latest.get("text")}

    def mutation(self, action: str, before: dict, after: dict) -> tuple[bool, str]:
        if self.webview_url:
            return web_mutation(action, before, after)
        if action == "click":
            changed = before.get("checkbox") != after.get("checkbox")
            return (
                changed,
                f"the fixture's checkbox read {before.get('checkbox')!r} before and "
                f"{after.get('checkbox')!r} after",
            )
        changed = (after.get("text") or "") != (before.get("text") or "")
        return (
            changed,
            f"the fixture's text field read {before.get('text')!r} before and "
            f"{after.get('text')!r} after",
        )

    def arrival(self, mark: float) -> tuple[bool | None, str | None]:
        if self.webview_url:
            return web_arrival(self.reports, self.nonce, mark)
        events = self.reports.since(mark, kind="event", nonce=self.nonce)
        if not events:
            return (False, "the application's event stream recorded nothing")
        described = ", ".join(
            f"{item['eventName']} on window {item['windowNumber']}" for item in events
        )
        return (True, f"the application dequeued {described}")

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


def web_snapshot(reports: Reports, nonce: str) -> dict:
    items = [item for item in reports.snapshot() if item.get("nonce") == nonce]
    clicks = [item for item in items if item.get("kind") == "click"]
    texts = [item for item in items if item.get("kind") == "text"]
    navigations = [item for item in items if item.get("kind") == "navigated"]
    return {
        "clicks": clicks[-1]["count"] if clicks else 0,
        "text": texts[-1]["value"] if texts else "",
        "navigations": len(navigations),
    }


def web_mutation(action: str, before: dict, after: dict) -> tuple[bool, str]:
    if action == "click":
        navigated = after.get("navigations", 0) > before.get("navigations", 0)
        clicked = after.get("clicks", 0) > before.get("clicks", 0)
        return (
            navigated or clicked,
            "the page navigated to the local endpoint"
            if navigated
            else (
                "the page reported a click without navigating"
                if clicked
                else "the page neither navigated nor reported a click"
            ),
        )
    changed = (after.get("text") or "") != (before.get("text") or "")
    return (
        changed,
        f"the page's input read {before.get('text')!r} before and {after.get('text')!r} after",
    )


def web_arrival(reports: Reports, nonce: str, mark: float) -> tuple[bool | None, str | None]:
    raw = reports.since(mark, kind="raw", nonce=nonce)
    if not raw:
        return (False, "the page's event listeners recorded nothing")
    described = ", ".join(f"{item['event']} isTrusted={item['isTrusted']}" for item in raw)
    return (True, f"the page observed {described}")


class BrowserTarget(Target):
    """An installed browser, opened on the measurement page."""

    def __init__(
        self,
        probe: Probe,
        reports: Reports,
        label: str,
        kind: str,
        application: str,
        bundle_id: str,
        page_url: str,
        remeasure_when: str,
        extra_args: list[str] | None = None,
    ) -> None:
        self.probe = probe
        self.reports = reports
        self.label = label
        self.kind = kind
        self.application = application
        self.bundle_id = bundle_id
        self.page_url = page_url
        self.remeasure_when = remeasure_when
        self.extra_args = extra_args or []
        self.nonce = ""
        self.unavailable = None if Path(application).exists() else f"{application} is not installed"

    def launch(self, action: str) -> Launched:
        self.nonce = uuid.uuid4().hex[:12]
        url = f"{self.page_url}?nonce={self.nonce}"
        argv = ["open", "-n", "-a", self.application]
        if self.extra_args:
            argv.extend(["--args", *self.extra_args, url])
        else:
            argv.append(url)
        subprocess.run(argv, check=True, capture_output=True)
        geometry = self.reports.wait_for(READY_TIMEOUT, kind="geometry", nonce=self.nonce)
        if geometry is None:
            raise RuntimeError(f"{self.label} never loaded the measurement page")
        found = self.probe("find-app", bundle_id=self.bundle_id)
        applications = found.get("applications") or []
        if not applications:
            raise RuntimeError(f"{self.label} is not running after being opened")
        pid = applications[0]["pid"]
        time.sleep(1.0)
        return Launched(
            pid=pid,
            nonce=self.nonce,
            point=geometry["widgets"]["link"]["center"],
            detail={"geometry": geometry},
        )

    def identity(self, pid: int) -> dict:
        return bundle_identity(self.probe, pid)

    def snapshot(self) -> dict:
        return web_snapshot(self.reports, self.nonce)

    def mutation(self, action: str, before: dict, after: dict) -> tuple[bool, str]:
        return web_mutation(action, before, after)

    def arrival(self, mark: float) -> tuple[bool | None, str | None]:
        return web_arrival(self.reports, self.nonce, mark)


class ElectronTarget(Target):
    """A pinned Electron runtime loading the measurement page.

    Electron is not something a Mac has by default, and it is what stands in for
    a packaged Chromium application rather than a browser. A bench without one
    records `unavailable`, which is a statement about the bench; it is never
    read as a statement about Electron.
    """

    kind = "electron"
    label = "electron"

    def __init__(self, probe: Probe, reports: Reports, page_url: str) -> None:
        self.probe = probe
        self.reports = reports
        self.page_url = page_url
        self.remeasure_when = "an Electron or Chromium major release"
        self.runtime = HERE / "targets" / "electron"
        self.nonce = ""
        self.process: subprocess.Popen | None = None
        binary = self.runtime / "node_modules" / "electron" / "dist" / "Electron.app"
        self.unavailable = (
            None
            if binary.exists()
            else "no pinned Electron runtime is installed; run scripts/macos-toolkit-acceptance/install-electron"
        )
        self.binary = binary

    def launch(self, action: str) -> Launched:
        self.nonce = uuid.uuid4().hex[:12]
        url = f"{self.page_url}?nonce={self.nonce}"
        self.process = subprocess.Popen(
            [
                str(self.binary / "Contents" / "MacOS" / "Electron"),
                str(self.runtime / "main.js"),
                url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        geometry = self.reports.wait_for(READY_TIMEOUT, kind="geometry", nonce=self.nonce)
        if geometry is None:
            raise RuntimeError("the Electron runtime never loaded the measurement page")
        time.sleep(1.0)
        return Launched(
            pid=self.process.pid,
            nonce=self.nonce,
            point=geometry["widgets"]["link"]["center"],
            detail={"geometry": geometry},
        )

    def identity(self, pid: int) -> dict:
        return bundle_identity(self.probe, pid)

    def snapshot(self) -> dict:
        return web_snapshot(self.reports, self.nonce)

    def mutation(self, action: str, before: dict, after: dict) -> tuple[bool, str]:
        return web_mutation(action, before, after)

    def arrival(self, mark: float) -> tuple[bool | None, str | None]:
        return web_arrival(self.reports, self.nonce, mark)

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
        self.process = None


def make_bundle(root: Path, name: str, bundle_id: str, binary: Path) -> Path:
    """Wraps the probe in an application bundle so it has a real identity."""
    bundle = root / f"{name}.app"
    macos = bundle / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, macos / "acceptance-probe")
    (bundle / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "acceptance-probe",
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
                "NSHighResolutionCapable": True,
            }
        )
    )
    return bundle


# -- the decoy ---------------------------------------------------------------------------------


class Decoy:
    """The application that holds the foreground while a target is measured.

    Focus is what makes the measurement mean anything. A target that happened to
    be frontmost would be receiving ordinary input through the paths a
    background rung is forbidden to rely on.
    """

    def __init__(self, probe: Probe, reports: Reports, bundles: Path, report_url: str) -> None:
        self.probe = probe
        self.reports = reports
        self.bundles = bundles
        self.report_url = report_url
        self.process: subprocess.Popen | None = None
        self.pid = 0
        self.nonce = ""
        self.ready: dict = {}

    def start(self, position: tuple[float, float]) -> None:
        self.nonce = uuid.uuid4().hex[:12]
        bundle = make_bundle(self.bundles, "AxonAcceptanceDecoy", "dev.axon.acceptance.decoy", PROBE_BINARY)
        self.process = subprocess.Popen(
            [
                str(bundle / "Contents" / "MacOS" / "acceptance-probe"),
                "fixture",
                "--role",
                "decoy",
                "--title",
                "axon-acceptance-decoy",
                "--nonce",
                self.nonce,
                "--report",
                self.report_url,
                "--x",
                str(position[0]),
                "--y",
                str(position[1]),
                "--width",
                "360",
                "--height",
                "180",
                "--seconds",
                "3600",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        line = self.process.stdout.readline() if self.process.stdout else ""
        self.ready = json.loads(line) if line.strip().startswith("{") else {}
        self.pid = self.ready.get("pid", 0)

    def raise_to_front(self) -> dict:
        return self.probe("activate", pid=self.pid)

    def leaked(self, mark: float) -> list[dict]:
        """Anything the decoy received. A keystroke that landed here instead of
        in the target is a delivery that went somewhere the caller did not ask
        for, which is worse than one that went nowhere."""
        return self.reports.since(mark, nonce=self.nonce)

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
        self.process = None


# -- verdicts ----------------------------------------------------------------------------------


def derive_verdict(
    *,
    available: bool,
    accessibility: str,
    control_before: dict,
    control_after: dict,
    ownership_proved: bool | None,
    decoy_frontmost: bool | None,
    dispatch_accepted: bool | None,
    target_mutated: bool | None,
    frontmost_unchanged: bool | None,
    pointer_unchanged: bool | None,
    unavailable_reason: str | None = None,
) -> tuple[str, str]:
    """The rule that turns observations into one of four words.

    Written as a pure function so it can be exercised without a desktop, and so
    the order of its tests is readable: everything that would make a trial say
    nothing is checked before anything that would make it say something.
    """
    if not available:
        return ("unavailable", unavailable_reason or "the target software was not present")
    if accessibility != "granted":
        return (
            "blocked",
            "the posting process did not hold Accessibility permission, and macOS drops posted "
            "events from an untrusted process silently, so a silent target would prove nothing",
        )
    if control_before.get("acted") is not True:
        return (
            "blocked",
            "the foreground control before the dispatch did not act, so this trial is measuring "
            "the campaign rather than the target",
        )
    if ownership_proved is not True:
        return (
            "blocked",
            "the target did not own the topmost ordinary window at the dispatch coordinate, so "
            "the trial would have been aimed at something else",
        )
    if decoy_frontmost is not True:
        return (
            "blocked",
            "a decoy application did not hold the foreground across the dispatch, so the target "
            "may simply have been receiving ordinary input",
        )
    if dispatch_accepted is not True:
        return ("blocked", "the Core Graphics post itself did not complete")
    if control_after.get("acted") is not True:
        return (
            "blocked",
            "the foreground control after the dispatch did not act, so the target cannot be shown "
            "to have been live and aimed at throughout",
        )
    if target_mutated is True:
        if frontmost_unchanged is not True:
            return (
                "refused",
                "the target acted, but the foreground changed across the dispatch, which is not "
                "background delivery whatever it managed to deliver",
            )
        if pointer_unchanged is not True:
            return (
                "refused",
                "the target acted, but the real pointer moved across the dispatch, which is the "
                "foreground rung by definition",
            )
        return (
            "accepted",
            "the target acted on input posted to its process while a decoy held the foreground "
            "and the real pointer did not move",
        )
    return (
        "refused",
        "the Core Graphics post completed and the target did nothing: dispatch was accepted by "
        "macOS and the action was not delivered",
    )


# -- one trial ---------------------------------------------------------------------------------


class Trial:
    """One target, one action, measured in ordered phases.

    Every phase records what it saw before the next one runs, so a reviewer can
    see that the preconditions were established before the dispatch rather than
    reconstructed after it. Cleanup runs on every exit path.
    """

    def __init__(
        self,
        probe: Probe,
        reports: Reports,
        target: Target,
        action: str,
        decoy: Decoy,
        campaign: str,
        park_at: tuple[float, float],
    ) -> None:
        self.probe = probe
        self.reports = reports
        self.target = target
        self.action = action
        self.decoy = decoy
        self.campaign = campaign
        self.park_at = park_at
        self.phases: list[dict] = []

    def _phase(self, name: str, data: object) -> None:
        self.phases.append({"phase": name, "at": time.time(), "data": data})

    def run(self, accessibility: str) -> dict:
        raw: dict = {
            "target": self.target.label,
            "action": self.action,
            "campaign": self.campaign,
            "phases": self.phases,
        }
        if self.target.unavailable:
            self._phase("identity", {"unavailable": self.target.unavailable})
            raw["verdict"] = derive_verdict(
                available=False,
                accessibility=accessibility,
                control_before={},
                control_after={},
                ownership_proved=None,
                decoy_frontmost=None,
                dispatch_accepted=None,
                target_mutated=None,
                frontmost_unchanged=None,
                pointer_unchanged=None,
                unavailable_reason=self.target.unavailable,
            )
            return raw

        prior_frontmost = self.probe("frontmost")
        prior_pointer = self.probe("pointer")
        try:
            launched = self.target.launch(self.action)
            identity = self.target.identity(launched.pid)
            self._phase(
                "identity",
                {
                    "pid": launched.pid,
                    "identity": identity,
                    "nonce": launched.nonce,
                    "point": launched.point,
                    "windows": self.probe("windows", pid=launched.pid),
                    "detail": launched.detail,
                },
            )

            control_before = self._control(launched)
            self._phase("controlBefore", control_before)

            self.decoy.raise_to_front()
            parked = self.probe("park", x=self.park_at[0], y=self.park_at[1])
            background = {
                "decoy": self.probe("app", pid=self.decoy.pid),
                "frontmost": self.probe("frontmost"),
                "parked": parked,
            }
            self._phase("background", background)

            ownership = None
            ownership_proved = None
            if launched.point:
                ownership = self.probe("owner-at", x=launched.point["x"], y=launched.point["y"])
                ordinary = [
                    window for window in ownership.get("stack", []) if window.get("layer") == 0
                ]
                ownership_proved = bool(ordinary) and ordinary[0]["ownerPid"] == launched.pid
            else:
                # A keyboard trial has no coordinate to own. What stands in for
                # it is that the target still has an on-screen window of its own.
                windows = self.probe("windows", pid=launched.pid).get("windows", [])
                ownership = {"windows": windows}
                ownership_proved = any(window.get("onScreen") for window in windows)
            self._phase("ownership", {"proved": ownership_proved, "observed": ownership})

            before = self.target.snapshot()
            mark = self.reports.mark()
            if self.action == "click":
                dispatch = self.probe(
                    "post-click", pid=launched.pid, x=launched.point["x"], y=launched.point["y"]
                )
            else:
                dispatch = self.probe("post-key", pid=launched.pid, text=TYPED_TEXT)
            self._phase("dispatch", dispatch)

            time.sleep(REACTION_TIMEOUT)
            after = self.target.snapshot()
            mutated, mutation_detail = self.target.mutation(self.action, before, after)
            reached, arrival_detail = self.target.arrival(mark)
            observe = {
                "before": before,
                "after": after,
                "mutated": mutated,
                "mutationEvidence": mutation_detail,
                "eventReachedTarget": reached,
                "arrivalDetail": arrival_detail,
                "decoyReceived": self.decoy.leaked(mark),
                "accessibility": self.probe("ax-read", pid=launched.pid),
            }
            self._phase("observe", observe)

            control_after = self._control(launched)
            self._phase("controlAfter", control_after)

            frontmost_before = (dispatch.get("before", {}).get("frontmost") or {}).get("pid")
            frontmost_after = (dispatch.get("after", {}).get("frontmost") or {}).get("pid")
            pointer_before = dispatch.get("before", {}).get("pointer")
            pointer_after = dispatch.get("after", {}).get("pointer")
            raw["observations"] = {
                "dispatchAccepted": bool(dispatch.get("eventsCreated")),
                "variant": dispatch.get("variant"),
                "targetMutated": mutated,
                "mutationEvidence": mutation_detail,
                "eventReachedTarget": reached,
                "arrivalDetail": arrival_detail,
                "frontmostUnchanged": frontmost_before == frontmost_after,
                "decoyFrontmost": frontmost_before == self.decoy.pid
                and frontmost_after == self.decoy.pid,
                "pointerUnchanged": same_point(pointer_before, pointer_after),
                "ownershipProved": ownership_proved,
                "pointerBefore": pointer_before,
                "pointerAfter": pointer_after,
                "frontmostBefore": describe_app(dispatch.get("before", {}).get("frontmost")),
                "frontmostAfter": describe_app(dispatch.get("after", {}).get("frontmost")),
                "targetPid": launched.pid,
                "windowId": (launched.window or {}).get("windowId"),
                "point": launched.point,
                "nonce": launched.nonce,
            }
            raw["identity"] = identity
            raw["controls"] = {"before": control_before, "after": control_after}
            raw["verdict"] = derive_verdict(
                available=True,
                accessibility=accessibility,
                control_before=control_before,
                control_after=control_after,
                ownership_proved=ownership_proved,
                decoy_frontmost=raw["observations"]["decoyFrontmost"],
                dispatch_accepted=raw["observations"]["dispatchAccepted"],
                target_mutated=mutated,
                frontmost_unchanged=raw["observations"]["frontmostUnchanged"],
                pointer_unchanged=raw["observations"]["pointerUnchanged"],
            )
            return raw
        finally:
            self.target.close()
            if prior_frontmost and prior_frontmost.get("pid"):
                self.probe("activate", pid=prior_frontmost["pid"])
            if prior_pointer and "x" in prior_pointer:
                self.probe("park", x=prior_pointer["x"], y=prior_pointer["y"])
            self._phase("restore", {"frontmost": prior_frontmost, "pointer": prior_pointer})

    def _control(self, launched: Launched) -> dict:
        """A foreground control at the same target: real pointer, or real keys."""
        before = self.target.snapshot()
        if self.action == "click":
            observed = self.probe(
                "foreground-click",
                pid=launched.pid,
                x=launched.point["x"],
                y=launched.point["y"],
            )
            mechanism = "CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate"
        else:
            observed = self.probe("foreground-key", pid=launched.pid, text=TYPED_TEXT)
            mechanism = "CGEventPost(kCGHIDEventTap) with the target activated"
        time.sleep(REACTION_TIMEOUT)
        after = self.target.snapshot()
        acted, detail = self.target.mutation(self.action, before, after)
        return {"ran": True, "acted": acted, "mechanism": mechanism, "detail": detail, "observed": observed}


def same_point(before: object, after: object) -> bool | None:
    if not isinstance(before, dict) or not isinstance(after, dict):
        return None
    return abs(before.get("x", 0) - after.get("x", 0)) < 0.5 and (
        abs(before.get("y", 0) - after.get("y", 0)) < 0.5
    )


def describe_app(application: object) -> str | None:
    if not isinstance(application, dict):
        return None
    return application.get("bundleId") or application.get("name") or f"pid:{application.get('pid')}"


# -- normalization -----------------------------------------------------------------------------


def normalize(raw: dict, target: Target, campaign_id: str, raw_path: str, date: str) -> dict:
    """One raw trial record as one schema row.

    The row keeps only what a consumer can act on and what a reviewer needs to
    check it, and points at the raw record for everything else.
    """
    verdict, reason = raw["verdict"]
    action = raw["action"]
    observations = raw.get("observations", {})
    identity = raw.get(
        "identity",
        {
            "bundleId": None,
            "bundleShortVersion": None,
            "bundleVersion": None,
            "versionSeries": None,
            "runtimeSignature": None,
            "readableAtDispatch": False,
            "source": "not read: the trial did not reach a running target",
            "processStartTime": None,
        },
    )
    controls = raw.get(
        "controls",
        {
            "before": {"ran": False, "acted": None, "mechanism": None, "detail": None},
            "after": {"ran": False, "acted": None, "mechanism": None, "detail": None},
        },
    )
    fresh = action == "keyboard"
    return {
        "id": f"{target.label}-{action}-{date}",
        "campaign": campaign_id,
        "target": {"label": target.label, "kind": target.kind, "identity": identity},
        "action": action,
        "mechanism": "CGEventPostToPid",
        "variant": observations.get("variant")
        or (
            "leftMouseDown+leftMouseUp/source=null/gapMs=0"
            if action == "click"
            else "keyDown+keyUp/source=null"
        ),
        "verdict": verdict,
        "reason": reason,
        "observations": {
            key: observations.get(key)
            for key in (
                "dispatchAccepted",
                "targetMutated",
                "mutationEvidence",
                "eventReachedTarget",
                "arrivalDetail",
                "frontmostUnchanged",
                "decoyFrontmost",
                "pointerUnchanged",
                "ownershipProved",
                "pointerBefore",
                "pointerAfter",
                "frontmostBefore",
                "frontmostAfter",
                "targetPid",
                "windowId",
                "point",
                "nonce",
            )
        },
        "controls": {
            phase: {
                "ran": controls[phase].get("ran", False),
                "acted": controls[phase].get("acted"),
                "mechanism": controls[phase].get("mechanism"),
                "detail": controls[phase].get("detail"),
            }
            for phase in ("before", "after")
        },
        "freshState": {
            "fresh": fresh,
            "detail": (
                "the measured keystrokes were the first synthetic input this target received: "
                "its foreground control was a keystroke, not a click"
                if fresh
                else "a foreground control click preceded the measured dispatch, which is what "
                "licenses the click trial; a keyboard verdict is never taken from a trial "
                "shaped this way"
            ),
        },
        "rawEvidence": f"{raw_path}#{target.label}-{action}",
        "remeasureWhen": target.remeasure_when,
    }


# -- the campaign ------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated target labels")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument(
        "--merge",
        default=str(HERE / "results.json"),
        help="an existing fixture file whose campaigns and rows are preserved",
    )
    arguments = parser.parse_args(argv)

    if platform.system() != "Darwin":
        print("this campaign measures macOS and runs on macOS only", file=sys.stderr)
        return 64
    if not arguments.skip_build:
        build_probe()

    probe = Probe()
    machine_facts = probe("env")
    accessibility = "granted" if machine_facts.get("accessibilityTrusted") else "denied"

    reports = Reports()
    _Handler.reports = reports
    _Handler.page = (HERE / "page.html").read_text()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{port}"
    page_url = f"{origin}/page"
    report_url = f"{origin}/report"

    bundles = Path(os.environ.get("TMPDIR", "/tmp")) / "axon-acceptance-bundles"
    bundles.mkdir(parents=True, exist_ok=True)

    display = machine_facts.get("mainDisplay", {"width": 1440, "height": 900})
    # The decoy sits top right and the cursor parks bottom right, both clear of
    # where every target is placed or opens.
    decoy = Decoy(probe, reports, bundles, report_url)
    decoy.start((display["width"] - 400, display["height"] - 220))
    park_at = (display["width"] - 6, display["height"] - 6)

    targets: list[Target] = [
        BrowserTarget(
            probe,
            reports,
            label="safari",
            kind="webkit-browser",
            application="/Applications/Safari.app",
            bundle_id="com.apple.Safari",
            page_url=page_url,
            remeasure_when="a Safari or macOS major release",
        ),
        BrowserTarget(
            probe,
            reports,
            label="chrome",
            kind="chromium-browser",
            application="/Applications/Google Chrome.app",
            bundle_id="com.google.Chrome",
            page_url=page_url,
            remeasure_when="a Chrome major release",
            extra_args=["--new-window"],
        ),
        ElectronTarget(probe, reports, page_url),
        FixtureTarget(probe, reports, bundles, report_url, label="AxonAcceptanceTarget"),
        FixtureTarget(
            probe,
            reports,
            bundles,
            report_url,
            label="AxonAcceptanceWebView",
            webview_url=f"{page_url}?webview=1",
            bundle_id="dev.axon.acceptance.webview",
        ),
    ]
    wanted = set(arguments.only.split(",")) if arguments.only else None

    date = datetime.now().strftime("%Y-%m-%d")
    campaign_id = f"{platform.node().split('.')[0]}-{date}"
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    raw_path = f"raw/{campaign_id}.json"

    trials: list[dict] = []
    rows: list[dict] = []
    try:
        for target in targets:
            if wanted and target.label not in wanted:
                continue
            for action in ("click", "keyboard"):
                print(f"measuring {target.label} {action}", file=sys.stderr)
                trial = Trial(probe, reports, target, action, decoy, campaign_id, park_at)
                try:
                    raw = trial.run(accessibility)
                except Exception as problem:  # noqa: BLE001 - a failed trial is data
                    raw = {
                        "target": target.label,
                        "action": action,
                        "campaign": campaign_id,
                        "phases": trial.phases,
                        "verdict": (
                            "blocked",
                            f"the trial could not be established: {problem}",
                        ),
                    }
                trials.append(raw)
                rows.append(normalize(raw, target, campaign_id, raw_path, date))
    finally:
        decoy.close()
        server.shutdown()

    campaign = {
        "id": campaign_id,
        "measuredAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "machine": f"{platform.machine()} macOS bench",
        "operatingSystem": machine_facts.get("operatingSystem") or "unknown",
        "session": "interactive desktop session with a logged-in user",
        "harness": "scripts/macos-toolkit-acceptance",
        "permissions": {
            "accessibility": accessibility,
            "automation": None,
            "screenRecording": "notNeeded",
        },
        "rawEvidence": raw_path,
        "notes": None,
    }
    (HERE / raw_path).write_text(
        json.dumps({"campaign": campaign, "machineFacts": machine_facts, "trials": trials}, indent=2)
        + "\n"
    )

    document = {
        "schemaVersion": "macos-acceptance-v1",
        "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "campaigns": [],
        "rows": [],
    }
    existing = Path(arguments.merge)
    if existing.exists():
        previous = json.loads(existing.read_text())
        document["campaigns"] = [
            item for item in previous.get("campaigns", []) if item["id"] != campaign_id
        ]
        document["rows"] = [
            item for item in previous.get("rows", []) if item["campaign"] != campaign_id
        ]
    document["campaigns"].append(campaign)
    document["rows"].extend(rows)

    (HERE / "results.json").write_text(json.dumps(document, indent=2) + "\n")
    evidence.RENDERED_PATH.write_text(evidence.render(document))
    problems = evidence.validate(document, evidence.load_schema()) + evidence.integrity(document)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
