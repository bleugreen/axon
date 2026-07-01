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

When both `path` and `actions` are supplied, Axon loads the file first and then
appends the inline actions. That supports parameterized replays without a second
plan language.

`.axn` parameters live in the top-level `args:` list. References use
`{{name}}` inside string `value` and `keys` fields, and all parameters resolve
before any action runs. Caller-provided values are passed as `argValues` over
MCP/socket calls or with repeated CLI `--arg name=value` flags. Declared
`source:` URLs such as `env://NAME` and `op://vault/item/field` bind a parameter
to a resolver; caller values cannot override sourced args.

`type: secret` is a handling rule, not a source. Secret-tainted values are sent
to the primitive action but are redacted from dry-run params, axn traces, and
history records. Prefer `source: op://...` or `source: env://...` for secrets;
literal CLI `--arg` values can still be exposed by shell history or process
inspection before Axon receives them.

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
    keys: Return
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
axon save --path ./workflow.axn
axon save --include-reads
```
