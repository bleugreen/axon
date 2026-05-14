# Recordings And Runs

`.axn` files are ordered Axon action lists. The file shape is the same shape
accepted by `run`, so a recording can be replayed from MCP or with
`axon run path.axn`.

```yaml
version: 1
actions:
  - tool: type
    target: s1:12
    value: Mitch
  - tool: type
    target: s1:14
    value: mitch@example.com
  - tool: click
    target: s1:20
```

`run` stops on the first failed action by default and returns a trace:

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
axon run ./workflow.axn --dry-run
axon save --path ./workflow.axn
axon save --include-reads
```
