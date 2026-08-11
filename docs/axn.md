# The `.axn` File

`.axn` files are ordered Axon action lists. The file shape is the same shape
accepted by `run`, so a recording can be replayed from MCP or with
`axon run path.axn`.

```yaml
version: 2
args:
  - name: assignee
    type: string
    default: Mitch
  - name: assignee_email
    type: email
    default: mitch@example.com
actions:
  - tool: type
    target: {app: Example, name: form/assignee}
    value: "{{assignee}}"
  - tool: type
    target: {app: Example, name: form/assignee-email}
    value: "{{assignee_email}}"
  - tool: click
    target: {app: Example, name: form/submit}
```

`run` stops on the first failed action by default and returns a run result with a trace. `AxnRunner` and the CLI summary operate on this unwrapped shape; socket and MCP tool-call responses preserve the legacy externally visible `{"batch": ...}` envelope around it.

## Version 2 target policy

Version 2 is a deliberate breaking change. Every interactive element target is
an app-scoped semantic name, `{app, name}`. A recorded action may also carry a
`locator` beside those fields as replay evidence, but a locator without `name` is
not a target. Snapshot handles such as `s1:12` are session-local cache keys and
are never accepted from `.axn` files.

Version 1 files are rejected before the first dispatch. The error identifies the
first action whose obsolete target requires attention. Axon does not guess a
migration because a snapshot handle contains no durable identity; re-record the
workflow or edit it to version 2 with semantic names.

```json
{
  "success": true,
  "dryRun": false,
  "continueOnError": false,
  "trace": [
    { "index": 0, "tool": "type", "success": true },
    { "index": 1, "tool": "type", "success": true },
    { "index": 2, "tool": "click", "success": true }
  ]
}
```

## Locator healing

Replay reports when a recorded locator resolves uniquely but some of its saved
evidence has drifted. To review a revised workflow, pass `healedPath` to the MCP
`run` tool or `--healed-path <file>` to the CLI:

```bash
axon run ./workflow.axn --healed-path ./workflow.healed.axn
```

Axon writes a new `.axn`; it never modifies the source workflow. The revised
locator is proposed only after it resolves uniquely at no lower confidence than
the locator used during the run. Ambiguous resolutions halt healing rather than
widening a locator. Evidence that the active resolution path could not evaluate
is retained, and frame movement alone does not trigger a revision. Secret-tainted
locator values are never written. A dry run reports what it can inspect without
writing the healed file.

Treat the output as a review artifact: inspect its locator diff, keep the source
under version control, and replay the healed copy before replacing the original.

When both `path` and `actions` are supplied, Axon loads the file first and then
appends the inline actions. That supports parameterized replays without a second
plan language.

`.axn` parameters live in the top-level `args:` list. References use
`{{name}}` inside string `value`, `text`, and `key` fields, and all parameters resolve
before any action runs. Caller-provided values are passed as `argValues` over
MCP/socket calls or with repeated CLI `--arg name=value` flags. Declared
`source:` URLs such as `env://NAME` and `op://vault/item/field` bind a parameter
to a resolver; caller values cannot override sourced args.

`type: secret` is a handling rule, not a source. Secret-tainted values are sent
to the primitive action but are redacted from dry-run params, axn traces, and
history records. Prefer `source: op://...` or `source: env://...` for secrets;
literal CLI `--arg` values can still be exposed by shell history or process
inspection before Axon receives them.

## Delivery policy

Every mutating step takes the same optional `deliveryPolicy` its tool takes.
`backgroundOnly` is the default, so a step that says nothing about delivery will
not activate an application, change system focus, move the real pointer, send
global keyboard input, or touch the clipboard — it returns a structured refusal
instead.

**The policy is never inherited.** It belongs to the step that carries it. A step
that permits foreground delivery says nothing about the next step, and nothing
about later runs of the same file. Grant it once, where the run genuinely needs
it, and every other step stays in the background.

```yaml
version: 2
actions:
  # Semantic: sets AXValue and reads it back. No focus, no activation.
  - tool: type
    target: {app: Example, name: form/assignee}
    value: "{{assignee}}"

  # Still backgroundOnly, because the policy above did not carry over.
  - tool: click
    target: {app: Example, name: form/submit}

  # This one shortcut needs the app frontmost, so it opts in explicitly. Axon
  # activates the app, posts the keystroke, and restores the prior app.
  - tool: keyboard
    app: Safari
    key: cmd+shift+p
    deliveryPolicy: foregroundPermitted

  # Back to backgroundOnly.
  - tool: invoke
    target: {app: Example, name: form/submit-menu}
    name: AXPress
```

Each step's trace result carries the four delivery fields — `deliveryPolicy`,
`delivery`, `dispatchSuccess`, and `refusal` — so a replay shows which rung
carried each action. A refused step is a failed step: nothing was dispatched, so
no `expects` postcondition can promote it to success. A step that *did* dispatch
but could not prove its goal is exactly the case `expects` exists for, and a
postcondition that verifies clears the declined escalation it no longer explains.

`deliveryPolicy` needs no special version-2 syntax: `.axn` steps retain tool
parameters verbatim, and the external `{"batch": ...}` envelope is untouched.

## Metadata

Actions may carry metadata that `run` strips before dispatch:

```yaml
version: 2
actions:
  - id: a001
    tool: type
    target:
      app: Safari
      name: form/issue-title
      locator:
        role: AXTextField
        identifier: issue-title
    value: Draft issue title
    expects:
      - id: a001.value.0
        kind: value
        target:
          app: Safari
          name: form/issue-title
          locator:
            role: AXTextField
            identifier: issue-title
        state:
          value:
            equals: Draft issue title
  - id: a002
    tool: keyboard
    app: Safari
    key: Return
    requires:
      - a001.value.0
```

A fact's matchers live under `state`, keyed by what the fact is about: `value`,
`selected`, `focused`, `enabled`. A fact's `target` must include `{app, name}`.
It may attach `locator` evidence, but is never a snapshot handle or standalone
locator.

The pair above is the one case where a workflow asserts its own input back at
itself, and it is a *dependency guard* rather than a postcondition: the `requires`
on the following step is what makes it worth writing. Do not press Return unless
the field still holds what was typed.

Supported replay tools are `click`, `type`, `keyboard`, `scroll`, `drag`, and
`invoke`. Read tools such as `look` and `find` may be kept in history as context
and can be included by `save(..., includeReads: true)`, but normal saved
workflows omit them.

## Derived postconditions

Both workflow producers — `save` from an agent session and a live user
recording — compile `expects` from a bounded before/after read taken around
each action, through the same shared rule set. The reads are targeted — the
acted-on element, the app's focused element, the app's window titles — never
a full tree capture. Settling has one answer in both paths: two agreeing
reads, up to a 150ms budget, before the after-read counts. The agent path
pays that wait only for actions likely to cause a transition (`click`,
`invoke`, `keyboard`, `drag`); a live recording pays it on every event,
because the wait runs when the user has already moved on, and a passive
event tap has no other way to let an effect land.

A recording's before-read is the best a passive tap can do. Clicks and drags
read at mouseDown, before the press is delivered to the app; a text burst
reads at its first keyDown; a special key reads before the pending text
flush, so the flush's own settle wait cannot contaminate the read with the
key's effect. Alongside the shared compiler the recorder keeps two producers
of its own, both rooted in evidence the compiler cannot see: the `changed`
fact, derived from AX notification evidence rather than a state comparison,
and the typed-value dependency guard described above.

A post-action read that never settled derives nothing at all. A button that
disables during submission and re-enables after the budget would otherwise be
saved as permanently disabled, and a boolean read mid-transition is no more
trustworthy than a string one.

The derivation set is deliberately small. Each entry is a direct comparison
between the before and after read of one element that has a durable locator, and
every comparison needs both sides. An attribute the pre-action read could not
reach comes back the same way an attribute that does not exist does, so a missing
before side is never read as "it changed" — that would assert state the action may
have had nothing to do with. The same applies to the window list: a list that
could not be read is not an app with no windows.

| Transition | Emitted fact |
| --- | --- |
| The target gained focus | `focused`, `state: {focused: true}` |
| Focus landed on a different element | `focused` on that element |
| The target's enabled state flipped | `enabled`, `state: {enabled: <after>}` |
| The target's value changed | `value`, `state: {value: {equals: <after>}}` |
| A selection control's value changed | `selected`, `state: {selected: {equals: <after>}}` |
| A window title appeared that was not there before | `window` on `{role: AXWindow, title: <new>}` |

The fact's target locator comes from the **post-action** read while the action's
own target comes from the **pre-action** read. This matters for any action whose
purpose is to mutate its target: Firefox's URL bar exposes an `AXDescription`
only while it is empty, so a fact carrying the pre-action locator would resolve
`missing` and never evaluate its predicate.

Three exclusions apply to every candidate. A candidate that trips one is dropped
silently — an action with nothing safe to say is saved with no `expects` and
stays a valid, unverified step.

**Never assert a parameterized value or a downstream echo of one.** A candidate
is dropped when its string equals, contains, or is contained by any input string
(`value`, `text`, `key`) the saved workflow carries — not only the step's own,
because an echo often surfaces a step or two later, as when a click opens a
window titled after text typed earlier. This covers both the direct case — a
`type` asserting back exactly what it typed, which the user is expected to
replace with `{{a_parameter}}` — and the downstream case, where a preview label
or window title elsewhere quotes the typed text. Parameter references are
only substituted in `value`, `text`, and `key`; `expects` is not a substitutable
field, and `run` rejects a file that puts a reference there. So an assertion
built from an input is either a literal that goes stale the first time the
parameter changes, or a hard rejection of the whole workflow.

**Never assert a clicked target's own label.** A candidate is dropped when its
string already appears as the `title`, `value`, `description`, or `identifier`
of the fact target's own locator. Clicking a button labelled `Submit` and then
asserting the button still reads `Submit` verifies nothing: the locator
resolving at all already proved it.

**Never assert a secret.** A candidate is dropped when it is redacted or when the
deterministic redaction rules recognise it.

Beyond those, a candidate is also dropped when the element has no durable
locator and when the assertion is empty.

Steps whose target cannot be given a semantic name are not emitted as replayable
version-2 actions. The recorder reports a warning instead of preserving an
unusable snapshot handle.

## CLI

```bash
axon run ./workflow.axn
axon run ./workflow.axn --arg assignee=Ada
axon run ./workflow.axn --dry-run
axon run ./workflow.axn --healed-path ./workflow.healed.axn
axon save --path ./workflow.axn
axon save --include-reads
```
