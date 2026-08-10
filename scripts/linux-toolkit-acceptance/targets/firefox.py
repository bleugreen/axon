#!/usr/bin/env python3
"""Firefox target.

Firefox requires focus for synthetic input by explicit design (bugzilla 497839), so this target is
here to measure that decision rather than to hope it has changed. Kiosk mode is used so the content
area fills the window and the harness is aiming at the page rather than at browser chrome.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import report  # noqa: E402

PREFERENCES = """
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
"""

firefox = shutil.which("firefox")
profile = tempfile.mkdtemp(prefix="axon-harness-firefox-")
with open(os.path.join(profile, "user.js"), "w") as preferences:
    preferences.write(PREFERENCES)

process = subprocess.Popen(
    [
        firefox,
        "--no-remote",
        "--new-instance",
        "--profile",
        profile,
        "--kiosk",
        os.environ["AXON_HARNESS_PAGE"],
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)

version = subprocess.run([firefox, "--version"], capture_output=True, text=True).stdout.strip()

# The page announces itself as soon as it loads; this only says which process owns the window.
time.sleep(8)
report(
    {
        "kind": "ready",
        "pid": process.pid,
        "signature": version or "Firefox",
        "viewportOffset": [0, 0],
    }
)

try:
    process.wait()
finally:
    shutil.rmtree(profile, ignore_errors=True)
