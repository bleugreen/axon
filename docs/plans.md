# Action Batches and Scripts

Axon composition starts with the same tools agents already use. A batch is an ordered list of tool calls; each item has `tool` plus that tool's normal arguments.

## MCP: run_batch

```json
{
  "actions": [
    { "tool": "set_value", "target": "s1:12", "value": "Mitch" },
    { "tool": "set_value", "target": "s1:14", "value": "mitch@example.com" },
    { "tool": "click", "target": "s1:18" }
  ]
}
```

`run_batch` executes actions in order and returns a trace. It stops on the first failed action by default.

Options:

- `dryRun`: trace actions without dispatching them
- `continueOnError`: keep running after a failed action
- `actions`: inline action array
- `source`: YAML or JSON batch source
- `path`: local `.axn` batch file path
- `batch`: batch object

## .axn Files

`.axn` files are editable saved batches:

```yaml
version: 1
actions:
  - tool: set_value
    target:
      app: cairn
      locator:
        role: AXTextField
        label:
          contains: Title
    value: Draft issue title
  - tool: click
    target:
      app: cairn
      locator:
        role: AXButton
        label: Save
```

Run one from the CLI:

```sh
axon run ./create-issue.axn
```

The file format is intentionally the same shape as `run_batch`, so there is no separate plan language to learn.

## Tool Names

Batch actions use MCP-facing tool names:

```text
list_apps
get_app_state
get_children
get_screenshot
resolve
changed_since
click
scroll
drag
perform_action
set_value
type_text
press_key
```

For normal replayable scripts, prefer action tools such as `click`, `set_value`, `perform_action`, `scroll`, `drag`, `type_text`, and `press_key`. Read tools are useful while exploring and stay in history as context, but exported scripts omit them by default.

## Trace Shape

A successful batch returns:

```json
{
  "batch": {
    "success": true,
    "dryRun": false,
    "continueOnError": false,
    "trace": [
      { "index": 0, "tool": "set_value", "success": true },
      { "index": 1, "tool": "click", "success": true }
    ]
  }
}
```

Failures include the failed index and stop the batch unless `continueOnError` is true.

## History and Export

Axon records recent tool calls in daemon memory. History may include reads (`get_app_state`, `resolve`, `get_children`) because they explain how an agent found targets. Script export filters to replayable action calls by default and emits an `.axn` file that can be edited and rerun.

CLI:

```sh
axon export-script --path ./workflow.axn
axon export-script --include-reads
```

MCP:

```json
{
  "sessionId": "default",
  "from": "c12",
  "to": "c18",
  "path": "/Users/mitch/projects/app/workflow.axn",
  "includeReads": false
}
```

Use `includeReads: true` only when read/context calls should be replayed too.
