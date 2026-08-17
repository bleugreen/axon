"""Rules the fixtures have to obey, exercised without a desktop.

These tests claim nothing about macOS. They claim that a row cannot say more
than it measured: that is the property the future acceptance table depends on,
and it is the one property of this campaign that can be checked on any machine
at any time.
"""

from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import evidence  # noqa: E402


def accepted_row(**overrides) -> dict:
    row = {
        "id": "example-click-2026-08-16",
        "campaign": "bench-2026-08-16",
        "target": {
            "label": "example",
            "kind": "appkit-native",
            "identity": {
                "bundleId": "dev.axon.example",
                "bundleShortVersion": "1.0.0",
                "bundleVersion": "1",
                "versionSeries": "1.0",
                "runtimeSignature": None,
                "readableAtDispatch": True,
                "source": "NSRunningApplication then Info.plist",
                "processStartTime": "Sun Aug 16 17:00:00 2026",
            },
        },
        "action": "click",
        "mechanism": "CGEventPostToPid",
        "variant": "leftMouseDown+leftMouseUp/source=null/gapMs=0",
        "verdict": "accepted",
        "reason": "the target acted while a decoy held the foreground",
        "observations": {
            "dispatchAccepted": True,
            "targetMutated": True,
            "mutationEvidence": "the checkbox toggled",
            "eventReachedTarget": True,
            "arrivalDetail": "the application dequeued leftMouseDown",
            "frontmostUnchanged": True,
            "decoyFrontmost": True,
            "pointerUnchanged": True,
            "ownershipProved": True,
            "pointerBefore": {"x": 1.0, "y": 2.0},
            "pointerAfter": {"x": 1.0, "y": 2.0},
            "frontmostBefore": "dev.axon.acceptance.decoy",
            "frontmostAfter": "dev.axon.acceptance.decoy",
            "targetPid": 4242,
            "windowId": 7,
            "point": {"x": 10.0, "y": 20.0},
            "nonce": "abc123",
        },
        "controls": {
            "before": {"ran": True, "acted": True, "mechanism": "HID tap", "detail": "toggled"},
            "after": {"ran": True, "acted": True, "mechanism": "HID tap", "detail": "toggled"},
        },
        "freshState": {"fresh": False, "detail": "a foreground control click preceded it"},
        "rawEvidence": "raw/bench-2026-08-16.json#example-click",
        "remeasureWhen": "a macOS major release",
    }
    row.update(overrides)
    return row


def document(*rows: dict) -> dict:
    return {
        "schemaVersion": "macos-acceptance-v1",
        "generatedAt": "2026-08-16T18:00:00-04:00",
        "campaigns": [
            {
                "id": "bench-2026-08-16",
                "measuredAt": "2026-08-16T17:00:00-04:00",
                "machine": "arm64 macOS bench",
                "operatingSystem": "Version 26.4 (Build 25E246)",
                "session": "interactive desktop session with a logged-in user",
                "harness": "scripts/macos-toolkit-acceptance",
                "permissions": {
                    "accessibility": "granted",
                    "automation": None,
                    "screenRecording": "notNeeded",
                },
                "rawEvidence": "raw/bench-2026-08-16.json",
                "notes": None,
            }
        ],
        "rows": list(rows),
    }


class SchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = evidence.load_schema()

    def test_a_well_formed_document_validates(self) -> None:
        self.assertEqual(evidence.validate(document(accepted_row()), self.schema), [])

    def test_an_unknown_verdict_is_rejected(self) -> None:
        problems = evidence.validate(
            document(accepted_row(verdict="probably")), self.schema
        )
        self.assertTrue(any("probably" in problem for problem in problems), problems)

    def test_an_unexpected_field_is_rejected(self) -> None:
        row = accepted_row()
        row["confidence"] = "high"
        problems = evidence.validate(document(row), self.schema)
        self.assertTrue(any("confidence" in problem for problem in problems), problems)

    def test_a_missing_required_field_is_rejected(self) -> None:
        row = accepted_row()
        del row["remeasureWhen"]
        problems = evidence.validate(document(row), self.schema)
        self.assertTrue(any("remeasureWhen" in problem for problem in problems), problems)

    def test_a_mechanism_other_than_the_measured_one_is_rejected(self) -> None:
        problems = evidence.validate(
            document(accepted_row(mechanism="CGEventPost")), self.schema
        )
        self.assertTrue(problems)

    def test_the_validator_refuses_a_keyword_it_does_not_implement(self) -> None:
        # A validator that skipped what it did not understand would report
        # success for constraints it never checked.
        with self.assertRaises(evidence.UnsupportedSchema):
            evidence.validate({}, {"type": "object", "patternProperties": {}})

    def test_the_committed_schema_uses_only_implemented_keywords(self) -> None:
        evidence.validate(document(accepted_row()), self.schema)


class IntegrityTests(unittest.TestCase):
    def assert_rejects(self, row: dict, fragment: str) -> None:
        problems = evidence.integrity(document(row))
        self.assertTrue(
            any(fragment in problem for problem in problems),
            f"expected a problem mentioning {fragment!r}, got {problems}",
        )

    def test_a_complete_accepted_row_passes(self) -> None:
        self.assertEqual(evidence.integrity(document(accepted_row())), [])

    def test_accepted_needs_a_target_mutation(self) -> None:
        row = accepted_row()
        row["observations"]["targetMutated"] = False
        self.assert_rejects(row, "dispatch evidence only")

    def test_accepted_needs_both_controls_to_have_acted(self) -> None:
        row = accepted_row()
        row["controls"]["after"]["acted"] = False
        self.assert_rejects(row, "belongs in blocked")

    def test_accepted_needs_every_invariant(self) -> None:
        for field in ("ownershipProved", "decoyFrontmost", "frontmostUnchanged", "pointerUnchanged"):
            row = accepted_row()
            row["observations"][field] = False
            self.assert_rejects(row, "accepted without proving")

    def test_accepted_needs_a_dispatch_time_identity(self) -> None:
        row = accepted_row()
        row["target"]["identity"]["bundleId"] = None
        self.assert_rejects(row, "without a dispatch-time identity")

    def test_accepted_needs_the_exact_variant(self) -> None:
        row = accepted_row()
        row["variant"] = ""
        self.assert_rejects(row, "exact measured variant")

    def test_a_verdict_measured_without_permission_is_rejected(self) -> None:
        whole = document(accepted_row())
        whole["campaigns"][0]["permissions"]["accessibility"] = "denied"
        problems = evidence.integrity(whole)
        self.assertTrue(any("blocked, not a statement" in problem for problem in problems), problems)

    def test_a_keyboard_verdict_needs_a_fresh_target(self) -> None:
        row = accepted_row(action="keyboard", id="example-keyboard-2026-08-16")
        row["freshState"] = {"fresh": False, "detail": "it had been clicked"}
        self.assert_rejects(row, "no prior synthetic input")

    def test_a_fresh_keyboard_verdict_is_allowed(self) -> None:
        row = accepted_row(action="keyboard", id="example-keyboard-2026-08-16")
        row["freshState"] = {"fresh": True, "detail": "the keystrokes were the first input"}
        self.assertEqual(evidence.integrity(document(row)), [])

    def test_a_refusal_may_not_record_the_target_acting(self) -> None:
        row = accepted_row(verdict="refused", reason="nothing happened")
        self.assert_rejects(row, "refused while recording that the target acted")

    def test_a_refusal_needs_its_controls(self) -> None:
        row = accepted_row(verdict="refused", reason="nothing happened")
        row["observations"]["targetMutated"] = False
        row["controls"]["before"]["acted"] = False
        self.assert_rejects(row, "belongs in blocked")

    def test_a_blocked_row_may_not_record_a_mutation(self) -> None:
        row = accepted_row(verdict="blocked", reason="permission was missing")
        self.assert_rejects(row, "should carry a verdict about the target")

    def test_a_dangling_campaign_reference_is_rejected(self) -> None:
        self.assert_rejects(accepted_row(campaign="nowhere"), "not declared")

    def test_a_row_pointing_at_another_runs_raw_record_is_rejected(self) -> None:
        self.assert_rejects(
            accepted_row(rawEvidence="raw/some-other-run.jsonl#example-click"),
            "is not the raw record of campaign",
        )

    def test_duplicate_row_ids_are_rejected(self) -> None:
        problems = evidence.integrity(document(accepted_row(), accepted_row()))
        self.assertTrue(any("duplicate row id" in problem for problem in problems), problems)

    def test_an_unavailable_row_needs_no_controls(self) -> None:
        row = accepted_row(verdict="unavailable", reason="the runtime is not installed")
        row["observations"] = {"dispatchAccepted": None, "targetMutated": None}
        row["controls"] = {
            "before": {"ran": False, "acted": None},
            "after": {"ran": False, "acted": None},
        }
        self.assertEqual(evidence.integrity(document(row)), [])


class RenderingTests(unittest.TestCase):
    def test_the_rendered_table_carries_the_row_and_its_verdict(self) -> None:
        rendered = evidence.render(document(accepted_row()))
        self.assertIn("example-click-2026-08-16", rendered)
        self.assertIn("**accepted**", rendered)
        self.assertIn("dev.axon.example", rendered)

    def test_rendering_is_deterministic(self) -> None:
        whole = document(accepted_row())
        self.assertEqual(evidence.render(whole), evidence.render(copy.deepcopy(whole)))

    def test_a_refusal_renders_its_reason(self) -> None:
        row = accepted_row(
            verdict="refused",
            reason="the post completed and the target did nothing",
        )
        row["observations"]["targetMutated"] = False
        rendered = evidence.render(document(row))
        self.assertIn("the post completed and the target did nothing", rendered)
        self.assertIn("**refused**", rendered)

    def test_an_unobserved_column_is_not_rendered_as_a_negative(self) -> None:
        row = accepted_row(verdict="unavailable", reason="not installed")
        row["observations"] = {"dispatchAccepted": None, "targetMutated": None}
        rendered = evidence.render(document(row))
        self.assertIn("not observed", rendered)


class CommittedFixtureTests(unittest.TestCase):
    """The committed evidence is held to the same rules as any fixture."""

    def setUp(self) -> None:
        if not evidence.RESULTS_PATH.exists():
            self.skipTest("no campaign has been committed yet")
        self.document = json.loads(evidence.RESULTS_PATH.read_text())

    def test_it_validates(self) -> None:
        self.assertEqual(evidence.validate(self.document, evidence.load_schema()), [])

    def test_it_satisfies_the_integrity_rules(self) -> None:
        self.assertEqual(evidence.integrity(self.document), [])

    def test_the_rendered_table_matches(self) -> None:
        self.assertEqual(
            evidence.RENDERED_PATH.read_text(),
            evidence.render(self.document),
            "RESULTS.md is not what results.json renders to; run check --write",
        )

    def test_every_rows_bench_reference_is_well_formed_and_names_its_own_campaign(self) -> None:
        # The record itself is not committed — it stays on the bench that
        # produced it — so this cannot and does not resolve the reference. What
        # it checks is that the reference is well formed and names the record of
        # the campaign that measured this row, which is the part that goes wrong
        # silently when a rerun rewrites provenance.
        campaigns = {item["id"]: item for item in self.document["campaigns"]}
        for row in self.document["rows"]:
            path, _, fragment = row["rawEvidence"].partition("#")
            self.assertEqual(path, campaigns[row["campaign"]]["rawEvidence"])
            self.assertEqual(
                fragment,
                f"{row['target']['label']}-{row['action']}",
                f"{row['id']} names a trial its own target and action do not",
            )


if __name__ == "__main__":
    unittest.main()
