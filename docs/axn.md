# The `.axn` File

`.axn` files are ordered Axon action lists. The file shape is the same shape
accepted by `run`, so a recording can be replayed from MCP or with
`axon run path.axn`.

```yaml
version: 1
args:
  - name: assignee
    type: string
    default: Mitch
  - name: assignee_email
    type: email
    default: mitch@example.com
actions:
  - tool: type
    target: s1:12
    value: "{{assignee}}"
  - tool: type
    target: s1:14
    value: "{{assignee_email}}"
  - tool: click
    target: s1:20
```

`run` stops on the first failed action by default and returns a run result with a trace. `AxnRunner` and the CLI summary operate on this unwrapped shape; socket and MCP tool-call responses preserve the legacy externally visible `{"batch": ...}` envelope around it.

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
version: 1
actions:
  # Semantic: sets AXValue and reads it back. No focus, no activation.
  - tool: type
    target: s1:12
    value: "{{assignee}}"

  # Still backgroundOnly, because the policy above did not carry over.
  - tool: click
    target: s1:20

  # This one shortcut needs the app frontmost, so it opts in explicitly. Axon
  # activates the app, posts the keystroke, and restores the prior app.
  - tool: keyboard
    app: Safari
    key: cmd+shift+p
    deliveryPolicy: foregroundPermitted

  # Back to backgroundOnly.
  - tool: invoke
    target: s1:24
    name: AXPress
```

Each step's trace result carries the four delivery fields — `deliveryPolicy`,
`delivery`, `dispatchSuccess`, and `refusal` — so a replay shows which rung
carried each action. A refused step is a failed step: nothing was dispatched, so
no `expects` postcondition can promote it to success. A step that *did* dispatch
but could not prove its goal is exactly the case `expects` exists for, and a
postcondition that verifies clears the declined escalation it no longer explains.

The format version is unchanged. `.axn` steps already retain tool parameters
verbatim, so `deliveryPolicy` needs no new syntax and the external `{"batch": ...}`
envelope is untouched.

## Metadata

Actions may carry metadata that `run` strips before dispatch:

```yaml
version: 1
actions:
  - id: title
    tool: type
    target: s1:12
    value: Draft issue title
    expects:
      - id: title.value
        kind: value
        target: s1:12
        equals: Draft issue title
  - tool: keyboard
    app: Safari
    key: Return
    requires:
      - title.value
```

Supported replay tools are `click`, `type`, `keyboard`, `scroll`, `drag`, and
`invoke`. Read tools such as `look` and `find` may be kept in history as context
and can be included by `save(..., includeReads: true)`, but normal saved
workflows omit them.

## CLI

```bash
axon run ./workflow.axn
axon run ./workflow.axn --arg assignee=Ada
axon run ./workflow.axn --dry-run
axon run ./workflow.axn --healed-path ./workflow.healed.axn
axon save --path ./workflow.axn
axon save --include-reads
```
