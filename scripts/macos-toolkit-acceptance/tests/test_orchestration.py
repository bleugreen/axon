"""Phase ordering, verdict derivation, and cleanup, driven by fake responses.

No desktop is involved and no acceptance is claimed. What is checked is that a
trial establishes its preconditions before it dispatches, that it cannot reach a
verdict it did not earn, and that it puts the machine back on every exit path —
the three things that would silently corrupt a live campaign rather than fail
it.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import evidence  # noqa: E402
import harness  # noqa: E402


class FakeProbe:
    """Stands in for the native probe, recording what it was asked."""

    def __init__(self, **responses) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.responses = responses

    def __call__(self, command: str, **arguments) -> dict:
        self.calls.append((command, arguments))
        if command in self.responses:
            return self.responses[command]
        return {
            "frontmost": {"pid": 11, "bundleId": "dev.axon.prior", "name": "Prior"},
            "pointer": {"x": 900.0, "y": 800.0},
            "park": {"pointer": {"x": 2554.0, "y": 1434.0}},
            "activate": {"activated": True},
            "app": {"pid": 42, "bundleId": "dev.axon.fake"},
            "windows": {"windows": [{"windowId": 5, "onScreen": True, "ownerPid": 42}]},
            "owner-at": {"stack": [{"ownerPid": 42, "layer": 0, "windowId": 5}]},
            "ax-read": {"accessibilityTrusted": True, "document": None},
            "foreground-click": {"activated": True},
            "foreground-key": {"activated": True},
        }.get(command, {})

    def commands(self) -> list[str]:
        return [command for command, _ in self.calls]


class FakeTarget(harness.Target):
    label = "fake"
    kind = "appkit-native"
    remeasure_when = "never, this target is not real"

    def __init__(self, *, acts_in_background: bool, controls_act: bool = True) -> None:
        self.acts_in_background = acts_in_background
        self.controls_act = controls_act
        self.state = 0
        self.closed = False
        self.dispatched = False

    def launch(self, action: str) -> harness.Launched:
        return harness.Launched(pid=42, nonce="nonce", point={"x": 100.0, "y": 200.0})

    def identity(self, pid: int) -> dict:
        return {
            "bundleId": "dev.axon.fake",
            "bundleShortVersion": "1.0.0",
            "bundleVersion": "1",
            "versionSeries": "1.0",
            "runtimeSignature": None,
            "readableAtDispatch": True,
            "source": "fake",
            "processStartTime": None,
        }

    def snapshot(self) -> dict:
        return {"checkbox": self.state}

    def mutation(self, action: str, before: dict, after: dict) -> tuple[bool, str]:
        return (before != after, f"{before} then {after}")

    def arrival(self, mark: float) -> tuple[bool | None, str | None]:
        return (True, "the fake target saw the event")

    def close(self) -> None:
        self.closed = True


class RecordingProbe(FakeProbe):
    """A probe whose dispatch and control calls move the fake target."""

    def __init__(self, target: FakeTarget) -> None:
        super().__init__()
        self.target = target

    def __call__(self, command: str, **arguments) -> dict:
        result = super().__call__(command, **arguments)
        if command in ("foreground-click", "foreground-key") and self.target.controls_act:
            self.target.state += 1
        if command in ("post-click", "post-key"):
            if self.target.acts_in_background:
                self.target.state += 1
            return {
                "eventsCreated": True,
                "variant": "leftMouseDown+leftMouseUp/source=null/gapMs=0",
                "before": {"frontmost": {"pid": 7}, "pointer": {"x": 2554.0, "y": 1434.0}},
                "after": {"frontmost": {"pid": 7}, "pointer": {"x": 2554.0, "y": 1434.0}},
            }
        return result


class FakeDecoy:
    pid = 7

    def __init__(self) -> None:
        self.raised = 0

    def raise_to_front(self) -> dict:
        self.raised += 1
        return {"activated": True}

    def leaked(self, mark: float) -> list[dict]:
        return []


def run_trial(target: FakeTarget, action: str = "click"):
    probe = RecordingProbe(target)
    trial = harness.Trial(
        probe,
        harness.Reports(),
        target,
        action,
        FakeDecoy(),
        "fake-campaign",
        (2554.0, 1434.0),
        settle=lambda _seconds: None,
    )
    return trial, probe, trial.run("granted")


class PhaseTests(unittest.TestCase):
    def test_a_trial_runs_its_phases_in_order(self) -> None:
        trial, _probe, _raw = run_trial(FakeTarget(acts_in_background=False))
        self.assertEqual([phase["phase"] for phase in trial.phases], list(harness.PHASES))

    def test_the_preconditions_are_established_before_the_dispatch(self) -> None:
        _trial, probe, _raw = run_trial(FakeTarget(acts_in_background=False))
        commands = probe.commands()
        self.assertLess(commands.index("park"), commands.index("post-click"))
        self.assertLess(commands.index("owner-at"), commands.index("post-click"))
        self.assertLess(commands.index("foreground-click"), commands.index("post-click"))

    def test_cleanup_restores_the_machine_and_closes_the_target(self) -> None:
        target = FakeTarget(acts_in_background=False)
        _trial, probe, _raw = run_trial(target)
        self.assertTrue(target.closed)
        restoring = [
            arguments for command, arguments in probe.calls if command == "activate"
        ]
        self.assertIn({"pid": 11}, restoring)
        parking = [arguments for command, arguments in probe.calls if command == "park"]
        self.assertIn({"x": 900.0, "y": 800.0}, parking)

    def test_a_failing_trial_still_cleans_up(self) -> None:
        class Exploding(FakeTarget):
            def launch(self, action: str) -> harness.Launched:
                raise RuntimeError("the target never came up")

        target = Exploding(acts_in_background=False)
        with self.assertRaises(RuntimeError):
            run_trial(target)
        self.assertTrue(target.closed)

    def test_a_keyboard_trial_never_clicks_the_target(self) -> None:
        _trial, probe, _raw = run_trial(FakeTarget(acts_in_background=False), action="keyboard")
        self.assertNotIn("post-click", probe.commands())
        self.assertNotIn("foreground-click", probe.commands())


class VerdictTests(unittest.TestCase):
    def derive(self, **overrides) -> tuple[str, str]:
        arguments = {
            "available": True,
            "accessibility": "granted",
            "control_before": {"acted": True},
            "control_after": {"acted": True},
            "ownership_proved": True,
            "decoy_frontmost": True,
            "dispatch_accepted": True,
            "target_mutated": True,
            "frontmost_unchanged": True,
            "pointer_unchanged": True,
        }
        arguments.update(overrides)
        return harness.derive_verdict(**arguments)

    def test_everything_holding_is_accepted(self) -> None:
        self.assertEqual(self.derive()[0], "accepted")

    def test_a_silent_target_with_a_clean_post_is_refused(self) -> None:
        verdict, reason = self.derive(target_mutated=False)
        self.assertEqual(verdict, "refused")
        self.assertIn("dispatch was accepted by macOS", reason)

    def test_absent_software_is_unavailable_and_never_a_refusal(self) -> None:
        self.assertEqual(self.derive(available=False)[0], "unavailable")

    def test_missing_permission_is_blocked_and_never_a_refusal(self) -> None:
        verdict, reason = self.derive(accessibility="denied")
        self.assertEqual(verdict, "blocked")
        self.assertIn("silently", reason)

    def test_a_silent_control_invalidates_the_trial(self) -> None:
        self.assertEqual(self.derive(control_before={"acted": False})[0], "blocked")
        self.assertEqual(self.derive(control_after={"acted": False})[0], "blocked")

    def test_unproved_ownership_or_foreground_is_blocked(self) -> None:
        self.assertEqual(self.derive(ownership_proved=False)[0], "blocked")
        self.assertEqual(self.derive(decoy_frontmost=False)[0], "blocked")

    def test_acting_while_stealing_the_foreground_is_not_acceptance(self) -> None:
        verdict, reason = self.derive(frontmost_unchanged=False)
        self.assertEqual(verdict, "refused")
        self.assertIn("not background delivery", reason)

    def test_acting_while_moving_the_pointer_is_not_acceptance(self) -> None:
        verdict, reason = self.derive(pointer_unchanged=False)
        self.assertEqual(verdict, "refused")
        self.assertIn("foreground rung", reason)


class NormalizationTests(unittest.TestCase):
    def normalized(self, target: FakeTarget, action: str = "click") -> dict:
        _trial, _probe, raw = run_trial(target, action)
        return harness.normalize(raw, target, "bench", "raw/bench.json", "2026-08-16")

    def whole(self, row: dict) -> dict:
        return {
            "schemaVersion": "macos-acceptance-v1",
            "generatedAt": "2026-08-16T18:00:00-04:00",
            "campaigns": [
                {
                    "id": "bench",
                    "measuredAt": "2026-08-16T17:00:00-04:00",
                    "machine": "fake",
                    "operatingSystem": "fake",
                    "session": "fake",
                    "harness": None,
                    "permissions": {
                        "accessibility": "granted",
                        "automation": None,
                        "screenRecording": "notNeeded",
                    },
                    "rawEvidence": "raw/bench.json",
                    "notes": None,
                }
            ],
            "rows": [row],
        }

    def test_an_accepting_target_normalizes_into_a_valid_accepted_row(self) -> None:
        row = self.normalized(FakeTarget(acts_in_background=True))
        self.assertEqual(row["verdict"], "accepted")
        whole = self.whole(row)
        self.assertEqual(evidence.validate(whole, evidence.load_schema()), [])
        self.assertEqual(evidence.integrity(whole), [])

    def test_a_refusing_target_normalizes_into_a_valid_refused_row(self) -> None:
        row = self.normalized(FakeTarget(acts_in_background=False))
        self.assertEqual(row["verdict"], "refused")
        whole = self.whole(row)
        self.assertEqual(evidence.validate(whole, evidence.load_schema()), [])
        self.assertEqual(evidence.integrity(whole), [])

    def test_a_keyboard_row_is_marked_fresh_and_a_click_row_is_not(self) -> None:
        keyboard = self.normalized(FakeTarget(acts_in_background=True), "keyboard")
        click = self.normalized(FakeTarget(acts_in_background=True), "click")
        self.assertTrue(keyboard["freshState"]["fresh"])
        self.assertFalse(click["freshState"]["fresh"])

    def test_a_row_records_the_variant_the_probe_actually_posted(self) -> None:
        row = self.normalized(FakeTarget(acts_in_background=False))
        self.assertEqual(row["variant"], "leftMouseDown+leftMouseUp/source=null/gapMs=0")

    def test_an_unavailable_target_normalizes_without_claiming_anything(self) -> None:
        target = FakeTarget(acts_in_background=True)
        target.unavailable = "the runtime is not installed"
        row = self.normalized(target)
        self.assertEqual(row["verdict"], "unavailable")
        whole = self.whole(row)
        self.assertEqual(evidence.validate(whole, evidence.load_schema()), [])
        self.assertEqual(evidence.integrity(whole), [])


if __name__ == "__main__":
    unittest.main()
