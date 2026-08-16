#!/usr/bin/env python3
"""Schema validation, integrity checks, and rendering for the acceptance fixtures.

This module never touches a desktop. It is the part of the campaign that can be
run and tested anywhere, and it is deliberately the part that decides whether a
row is allowed to say what it says: `harness.py` records what happened, and
nothing it records becomes an `accepted` row unless the rules below let it.

`RESULTS.md` is generated from the same document the rules run against, so the
prose a reader sees and the machine evidence a backend consumes cannot drift
apart.
"""

from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA_PATH = HERE / "schema.json"
RESULTS_PATH = HERE / "results.json"
RENDERED_PATH = HERE / "RESULTS.md"


class UnsupportedSchema(Exception):
    """A schema keyword this validator does not implement.

    Raised rather than ignored. A validator that silently skips what it does not
    understand reports success for documents it never checked, which is the
    exact failure mode these fixtures exist to avoid.
    """


_KEYWORDS = {
    "$schema",
    "$id",
    "$ref",
    "$defs",
    "title",
    "description",
    "type",
    "const",
    "enum",
    "required",
    "properties",
    "additionalProperties",
    "items",
    "minLength",
    "minimum",
}

_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
    "integer": int,
    "null": type(None),
}


def load_schema(path: Path = SCHEMA_PATH) -> dict:
    return json.loads(path.read_text())


def validate(document: object, schema: dict) -> list[str]:
    """Structural validation against the committed schema.

    A deliberately small subset of JSON Schema, strict about its own limits: an
    unrecognized keyword raises instead of passing, so the schema cannot grow a
    constraint this never checks.
    """
    problems: list[str] = []
    _check(document, schema, schema, "$", problems)
    return problems


def _resolve(reference: str, root: dict) -> dict:
    if not reference.startswith("#/"):
        raise UnsupportedSchema(f"only local references are supported, got {reference}")
    node: object = root
    for step in reference[2:].split("/"):
        node = node[step]  # type: ignore[index]
    return node  # type: ignore[return-value]


def _check(value: object, schema: dict, root: dict, path: str, problems: list[str]) -> None:
    unknown = set(schema) - _KEYWORDS
    if unknown:
        raise UnsupportedSchema(f"{path}: unsupported schema keywords {sorted(unknown)}")

    if "$ref" in schema:
        _check(value, _resolve(schema["$ref"], root), root, path, problems)
        return

    if "const" in schema and value != schema["const"]:
        problems.append(f"{path}: expected {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} is not one of {schema['enum']}")

    if "type" in schema:
        wanted = schema["type"]
        names = wanted if isinstance(wanted, list) else [wanted]
        # bool is a subclass of int in Python, and a schema that asks for an
        # integer does not mean to accept True.
        matched = any(
            isinstance(value, _TYPES[name])
            and not (name in ("integer", "number") and isinstance(value, bool))
            for name in names
        )
        if not matched:
            problems.append(f"{path}: expected type {wanted}, got {type(value).__name__}")
            return

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            problems.append(f"{path}: shorter than {schema['minLength']} characters")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.append(f"{path}: below minimum {schema['minimum']}")

    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                problems.append(f"{path}: missing required field {name!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for name in value:
                if name not in properties:
                    problems.append(f"{path}: unexpected field {name!r}")
        for name, child in value.items():
            if name in properties:
                _check(child, properties[name], root, f"{path}.{name}", problems)

    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            _check(item, schema["items"], root, f"{path}[{index}]", problems)


# -- integrity ---------------------------------------------------------------------------------

# What an accepted row has to be able to show. Each of these is a way a row
# could otherwise claim delivery it did not measure, and each names the specific
# claim it is defending.
_ACCEPTED_INVARIANTS = [
    ("ownershipProved", "the target owned the coordinate at dispatch time"),
    ("decoyFrontmost", "a decoy application held the foreground across the dispatch"),
    ("frontmostUnchanged", "the foreground application did not change"),
    ("pointerUnchanged", "the real pointer did not move"),
]


def integrity(document: dict) -> list[str]:
    """The rules that decide whether a row may say what it says.

    These are separate from the schema because they are not about shape. A row
    that is structurally perfect and claims acceptance without a control that
    acted is exactly the kind of evidence a delivery table must never be built
    on, and it is rejected here by name.
    """
    problems: list[str] = []
    campaigns = {campaign["id"]: campaign for campaign in document.get("campaigns", [])}
    seen: set[str] = set()

    for row in document.get("rows", []):
        identifier = row.get("id", "<unidentified>")
        where = f"row {identifier}"
        if identifier in seen:
            problems.append(f"{where}: duplicate row id")
        seen.add(identifier)

        campaign = campaigns.get(row.get("campaign", ""))
        if campaign is None:
            problems.append(f"{where}: cites campaign {row.get('campaign')!r}, which is not declared")

        verdict = row.get("verdict")
        observations = row.get("observations", {})
        controls = row.get("controls", {})
        identity = row.get("target", {}).get("identity", {})

        if verdict in ("accepted", "refused"):
            if observations.get("dispatchAccepted") is None:
                problems.append(
                    f"{where}: a {verdict} verdict needs a recorded dispatch outcome, because "
                    "the verdict is a statement about what the target did with a post that happened"
                )
            if not row.get("rawEvidence"):
                problems.append(f"{where}: a {verdict} verdict must link to its raw observations")
            for phase in ("before", "after"):
                if controls.get(phase, {}).get("acted") is not True:
                    problems.append(
                        f"{where}: the {phase} control did not act, so this trial says nothing "
                        "about the target and belongs in blocked rather than in "
                        f"{verdict}"
                    )
            if campaign and campaign.get("permissions", {}).get("accessibility") != "granted":
                problems.append(
                    f"{where}: measured without Accessibility permission, where macOS drops "
                    "posted events silently; that is blocked, not a statement about the target"
                )

        if verdict == "accepted":
            if observations.get("targetMutated") is not True:
                problems.append(
                    f"{where}: accepted without an observed target-side mutation; a completed "
                    "Core Graphics post is dispatch evidence only"
                )
            for field, claim in _ACCEPTED_INVARIANTS:
                if observations.get(field) is not True:
                    problems.append(f"{where}: accepted without proving that {claim}")
            if not identity.get("bundleId") or identity.get("readableAtDispatch") is not True:
                problems.append(
                    f"{where}: accepted without a dispatch-time identity, so no consumer could "
                    "recognize the target this row speaks for"
                )
            if row.get("mechanism") != "CGEventPostToPid" or not row.get("variant"):
                problems.append(f"{where}: accepted without recording the exact measured variant")

        if verdict == "refused" and observations.get("targetMutated") is True:
            problems.append(f"{where}: refused while recording that the target acted")

        if verdict in ("blocked", "unavailable") and observations.get("targetMutated") is True:
            problems.append(
                f"{where}: a {verdict} row records a target mutation, which means the trial "
                "ran after all and should carry a verdict about the target"
            )

        if row.get("action") == "keyboard" and verdict in ("accepted", "refused"):
            if row.get("freshState", {}).get("fresh") is not True:
                problems.append(
                    f"{where}: a keyboard verdict may only come from a target that had received "
                    "no prior synthetic input; post-click keyboard behaviour is diagnostic only"
                )

        if not row.get("reason"):
            problems.append(f"{where}: every verdict carries its reason")

    return problems


# -- rendering ---------------------------------------------------------------------------------

_VERDICT_WORDS = {
    "accepted": "accepted",
    "refused": "refused",
    "blocked": "blocked",
    "unavailable": "unavailable",
}

_PREAMBLE = """\
# Measured macOS acceptance of PID-targeted synthetic input

Generated from `results.json` by `scripts/macos-toolkit-acceptance/check`. Do not edit by hand:
re-run the campaign, or regenerate this file.

This table records what macOS did with input posted through `CGEventPostToPid` into an
application that was not frontmost. It is evidence, not permission. A backend consuming it
decides what to authorize; a target absent from the table authorizes nothing.
"""

_READING = """\
## Reading this table

**dispatch** is whether the Core Graphics post completed. `CGEventPostToPid` returns no status,
so this column is always the weakest one here: it says the events were created and handed to the
window server, and it never says the target received or acted on anything. The whole campaign
exists because that distinction is invisible from the sending side.

**target acted** is the only column that can license an `accepted` verdict. It is a change in the
target itself — a control that moved, a page that navigated, a field that echoed — observed
through the target's own reporting rather than inferred from the envelope.

**arrival** separates two outcomes a sender cannot tell apart: an event that never reached the
application, and one that reached it and was declined. It is filled in only for targets that can
report their own event stream.

**controls** are what make a refusal mean something. Each trial runs a foreground control before
and after the measured dispatch, driving the real pointer or the real keyboard at the same target.
A trial whose control did not act is measuring the campaign rather than the target, and is recorded
`blocked` rather than as a refusal it never earned.

**identity** is what a backend can read about the target at dispatch time, holding only a process
identifier. It is the key any future acceptance entry would have to be written against, and a row
claims exactly as much as that key can carry and no more.
"""


def render(document: dict) -> str:
    lines: list[str] = [_PREAMBLE]

    lines.append("## Campaigns\n")
    lines.append("| campaign | measured | machine | macOS | Accessibility | raw evidence |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for campaign in document.get("campaigns", []):
        lines.append(
            "| `{id}` | {measuredAt} | {machine} | {operatingSystem} | {access} | [`{raw}`]({raw}) |".format(
                id=campaign["id"],
                measuredAt=campaign["measuredAt"],
                machine=campaign["machine"],
                operatingSystem=campaign["operatingSystem"],
                access=campaign["permissions"]["accessibility"],
                raw=campaign["rawEvidence"],
            )
        )
    lines.append("")

    lines.append("## Rows\n")
    lines.append(
        "| row | target | identity | action | verdict | dispatch | target acted | arrival | "
        "invariants | controls |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for row in document.get("rows", []):
        observations = row["observations"]
        controls = row["controls"]
        lines.append(
            "| `{id}` | {label} ({kind}) | {identity} | `{action}` | **{verdict}** | {dispatch} | "
            "{mutated} | {arrival} | {invariants} | {controls} |".format(
                id=row["id"],
                label=row["target"]["label"],
                kind=row["target"]["kind"],
                identity=_identity_cell(row["target"]["identity"]),
                action=row["action"],
                verdict=_VERDICT_WORDS[row["verdict"]],
                dispatch=_tri(observations.get("dispatchAccepted"), "accepted", "failed"),
                mutated=_tri(observations.get("targetMutated"), "yes", "no"),
                arrival=_tri(observations.get("eventReachedTarget"), "reached", "never arrived"),
                invariants=_invariants_cell(observations),
                controls=_controls_cell(controls),
            )
        )
    lines.append("")

    lines.append(_READING)

    lines.append("## Row detail\n")
    for row in document.get("rows", []):
        lines.append(f"### `{row['id']}`\n")
        lines.append(f"{row['reason']}\n")
        lines.append(f"- Variant: `{row['variant']}` through `{row['mechanism']}`")
        lines.append(f"- Campaign: `{row['campaign']}`")
        lines.append(f"- Fresh state: {_fresh(row['freshState'])}")
        mutation = row["observations"].get("mutationEvidence")
        if mutation:
            lines.append(f"- Target-side observation: {mutation}")
        arrival = row["observations"].get("arrivalDetail")
        if arrival:
            lines.append(f"- Arrival: {arrival}")
        for phase in ("before", "after"):
            control = row["controls"][phase]
            lines.append(f"- Control {phase}: {_control(control)}")
        lines.append(f"- Raw evidence: [`{row['rawEvidence']}`]({row['rawEvidence'].split('#')[0]})")
        lines.append(f"- Re-measure when: {row['remeasureWhen']}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def _identity_cell(identity: dict) -> str:
    bundle = identity.get("bundleId") or "no bundle identifier"
    version = identity.get("bundleShortVersion")
    runtime = identity.get("runtimeSignature")
    parts = [f"`{bundle}`"]
    if version:
        parts.append(version)
    if runtime:
        parts.append("{kind} {version}".format(**runtime))
    if identity.get("readableAtDispatch") is not True:
        parts.append("(not readable at dispatch)")
    return " ".join(parts)


def _tri(value: object, yes: str, no: str) -> str:
    if value is True:
        return yes
    if value is False:
        return no
    return "not observed"


def _invariants_cell(observations: dict) -> str:
    held = [name for name, _ in _ACCEPTED_INVARIANTS if observations.get(name) is True]
    broken = [name for name, _ in _ACCEPTED_INVARIANTS if observations.get(name) is False]
    if broken:
        return "broke " + ", ".join(broken)
    if len(held) == len(_ACCEPTED_INVARIANTS):
        return "all held"
    if not held:
        return "not established"
    return f"{len(held)} of {len(_ACCEPTED_INVARIANTS)} held"


def _controls_cell(controls: dict) -> str:
    words = []
    for phase in ("before", "after"):
        control = controls.get(phase, {})
        if not control.get("ran"):
            words.append(f"{phase}: not run")
        else:
            words.append(f"{phase}: " + _tri(control.get("acted"), "acted", "silent"))
    return "; ".join(words)


def _control(control: dict) -> str:
    if not control.get("ran"):
        return "not run" + (f" — {control['detail']}" if control.get("detail") else "")
    state = _tri(control.get("acted"), "acted", "stayed silent")
    mechanism = control.get("mechanism")
    detail = control.get("detail")
    text = state
    if mechanism:
        text += f" via `{mechanism}`"
    if detail:
        text += f" — {detail}"
    return text


def _fresh(fresh: dict) -> str:
    word = "fresh" if fresh.get("fresh") else "not fresh"
    return f"{word} — {fresh.get('detail')}"
