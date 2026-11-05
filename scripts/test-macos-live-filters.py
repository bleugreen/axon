#!/usr/bin/env python3
"""Exercise the live lane's actual jq module on unedited Rust MCP captures.

No daemon, application, or launchd command is invoked. Run with Python 3 and jq.
An optional module directory allows testing proposed filter mutations.
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
LIVE = REPO / "scripts/macos-toolkit-acceptance/live"
MODULE = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else LIVE
FIXTURES = {p.stem: json.loads(p.read_text()) for p in (LIVE / "responses").glob("*.json")}


def response(name):
    return copy.deepcopy(FIXTURES[name]["response"])


def query(expression, value, module=MODULE):
    return subprocess.run(["jq", "-e", "-c", "-L", str(module),
                           'include "probe"; ' + expression],
                          input=json.dumps(value), text=True, capture_output=True, timeout=10)


class Filters(unittest.TestCase):
    def check_value(self, expression, name, expected):
        answer = query(expression, response(name))
        self.assertEqual(answer.returncode, 0 if expected is not False else 1, answer.stderr)
        self.assertEqual(json.loads(answer.stdout), expected)

    def test_recorded_shapes(self):
        for expression, name in [
            ("full", "look-full"), ("shallow", "look-shallow"),
            ("child_page", "child-page-after-full"),
            ("invoked", "invoke-clear-directly-after-full"),
            ("display_one", "look-after-one"), ("unchanged", "since-settle-0"),
            ("changed", "since-changed-0"), ("ocr", "look-screentext"),
            ("retention_missing", "invoke-clear-after-full"),
        ]:
            with self.subTest(expression=expression):
                self.check_value(expression, name, True)
        self.check_value("invoked", "invoke-clear-after-full", False)
        self.check_value("display_one", "look-full", False)
        self.check_value("changed", "since-settle-0", False)
        self.check_value("unchanged", "since-changed-0", False)

    def test_extractions(self):
        self.check_value("app_name", "look-full", "Calculator")
        for label, name, fixture in [
            ("All Clear", "all-clear", "look-full"), ("1", "1", "look-full"),
            ("Clear", "clear", "look-after-one"),
        ]:
            self.check_value(f"button_name({json.dumps(label)})", fixture,
                             "main-sidebarnavigationsplitview/calculatorkeypadview/" + name)
        for name in ("look-full", "look-after-one", "since-settle-0", "since-changed-0"):
            self.check_value("since_token", name,
                             response(name)["result"]["structuredContent"]["since"])
        self.check_value("screen_text", "look-screentext",
                         [x["text"] for x in response("look-screentext")["result"]
                          ["structuredContent"]["screenText"]][:12])

    def test_diagnostics_accept_every_capture_including_errors_and_string_apps(self):
        for name in FIXTURES:
            with self.subTest(name=name):
                answer = query("diagnostic", response(name))
                self.assertEqual(answer.returncode, 0, answer.stderr)
                document = json.loads(answer.stdout)
                self.assertEqual(document["isError"], response(name)["result"]["isError"])
        diagnostic = json.loads(query("diagnostic", response("look-full")).stdout)
        self.assertTrue(any(x["label"] == "All Clear" for x in diagnostic["targets"]))
        diagnostic = json.loads(query("diagnostic", response("invoke-clear-after-full")).stdout)
        self.assertEqual(diagnostic["observation"]["data"]["status"], "missing")

    def test_controls_are_not_vacuous(self):
        cases = [
            ("full", "look-full", ["result", "content"], []),
            ("full", "look-full", ["result", "structuredContent", "app", "name"], ""),
            ("shallow", "look-shallow",
             ["result", "structuredContent", "app", "windows", 0, "root", "children"], [{}]),
            ("shallow", "look-shallow",
             ["result", "structuredContent", "app", "windows", 0, "root", "frame"], {}),
            ("child_page", "child-page-after-full",
             ["result", "structuredContent", "children", "limit"], 1),
            ("child_page", "child-page-after-full",
             ["result", "structuredContent", "children", "nextOffset"], 1),
            ("invoked", "invoke-clear-directly-after-full",
             ["result", "structuredContent", "dispatch", "success"], False),
            ("invoked", "invoke-clear-directly-after-full",
             ["result", "structuredContent", "resolution", "status"], "ambiguous"),
            ("ocr", "look-screentext", ["result", "structuredContent", "screenText"], []),
        ]
        for expression, name, path, replacement in cases:
            value = response(name)
            parent = value
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = replacement
            with self.subTest(expression=expression, path=path):
                answer = query(expression, value)
                self.assertEqual(answer.returncode, 1, answer.stderr)
                self.assertEqual(json.loads(answer.stdout), False)
        # The display must be the value 1, not a keypad label or a substring of 11.
        value = response("look-after-one")
        def replace_display(node):
            if isinstance(node, dict):
                if node.get("role") == "AXStaticText":
                    node["value"] = "\u200e11"
                for child in node.values():
                    replace_display(child)
            elif isinstance(node, list):
                for child in node:
                    replace_display(child)
        replace_display(value)
        self.assertEqual(query("display_one", value).returncode, 1)

    def test_old_swift_tree_path_mutation_is_rejected(self):
        source = (MODULE / "probe.jq").read_text()
        anchor = 'def nodes: observation.app | objects | .windows[]?.root | .. | objects;'
        self.assertEqual(source.count(anchor), 1)
        mutated = source.replace(anchor,
            'def nodes: .result.structuredContent.tree | split("\\n")[];')
        self.assertNotEqual(source, mutated)
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "probe.jq").write_text(mutated)
            answer = query("full", response("look-full"), Path(directory))
            self.assertNotEqual(answer.returncode, 0, answer.stdout)


class Workflow(unittest.TestCase):
    def run_probe(self, captures):
        # Extract the workflow rather than keeping a second copy of its shell logic.
        helper = runpy.run_path(str(REPO / "scripts/test-macos-live-recovery"))
        body = helper["run_block"](helper["job_lines"](
            (REPO / ".github/workflows/live.yml").read_text(), "macos"),
            "Capture, resolve, act, and verify")
        start = body.index("probe() {")
        end = body.index("# A recording the production Swift daemon made", start)
        body = body[start:end]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "axon"
            # Each scenario assembles individual captures, not a real successful session.
            cli.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
request = json.load(sys.stdin)
log = pathlib.Path(os.environ["REQUESTS"])
index = len(log.read_text().splitlines()) if log.exists() else 0
with log.open("a") as stream:
    stream.write(json.dumps(request) + "\\n")
name = json.loads(os.environ["CAPTURES"])[index]
print(json.dumps(json.loads((pathlib.Path(os.environ["FIXTURES"]) / (name + ".json")).read_text())["response"]))
""")
            cli.chmod(0o755)
            log = root / "requests"
            script = 'set -euo pipefail\nopen() { :; }\nsleep() { :; }\n' + body
            result = subprocess.run(["bash", "-c", script], cwd=REPO, text=True,
                capture_output=True, timeout=30,
                env={**os.environ, "cli": str(cli), "REQUESTS": str(log),
                     "FIXTURES": str(LIVE / "responses"), "CAPTURES": json.dumps(captures)})
            requests = [json.loads(line) for line in log.read_text().splitlines()]
            return result, requests

    def test_recorded_retention_failure_reaches_precise_diagnostic(self):
        for captures in [
            ["look-full", "look-shallow", "child-page-after-full", "invoke-clear-after-full"],
            ["look-full", "look-shallow", "invoke-clear-after-full"],
        ]:
            with self.subTest(captures=captures):
                result, requests = self.run_probe(captures)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("a name issued by the earlier full look no longer resolves after a narrower look",
                              result.stdout)
                self.assertNotIn("jq: error", result.stderr)
                self.assertEqual(len(requests), len(captures))
                args = [r["params"]["arguments"] for r in requests]
                self.assertEqual(args[1]["childDepth"], 0)
                self.assertTrue(args[2]["direct"])
                self.assertEqual(args[-1]["target"],
                    FIXTURES["invoke-clear-after-full"]["request"]["params"]["arguments"]["target"])

    def test_successful_responses_preserve_retention_and_change_check_order(self):
        result, requests = self.run_probe([
            "look-full", "look-shallow", "child-page-after-full",
            "invoke-clear-directly-after-full", "invoke-clear-directly-after-full",
            "look-after-one", "look-after-one", "since-settle-0",
            "invoke-clear-directly-after-full", "since-changed-0", "look-screentext",
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Calculator display verified", result.stdout)
        self.assertIn("screenText recognized", result.stdout)
        self.assertEqual([r["params"]["name"] for r in requests],
            ["look", "look", "look", "invoke", "invoke", "look", "look", "look",
             "invoke", "look", "look"])
        args = [r["params"]["arguments"] for r in requests]
        self.assertEqual(args[1], FIXTURES["look-shallow"]["request"]["params"]["arguments"])
        self.assertEqual(args[2], FIXTURES["child-page-after-full"]["request"]["params"]["arguments"])
        prefix = "main-sidebarnavigationsplitview/calculatorkeypadview/"
        self.assertEqual(args[3]["target"], {"app": "Calculator", "name": prefix + "all-clear"})
        self.assertEqual(args[4]["target"], {"app": "Calculator", "name": prefix + "1"})
        self.assertEqual(args[8]["target"], {"app": "Calculator", "name": prefix + "clear"})
        self.assertEqual(args[7]["since"],
                         response("look-after-one")["result"]["structuredContent"]["since"])
        self.assertEqual(args[9]["since"],
                         response("since-settle-0")["result"]["structuredContent"]["since"])
        self.assertEqual(args[10], FIXTURES["look-screentext"]["request"]["params"]["arguments"])


if __name__ == "__main__":
    unittest.main()
