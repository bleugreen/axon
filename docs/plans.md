# Automation Plans

`run_plan` is an invocation-scoped composition layer over Axon's primitive commands. The daemon accepts a submitted plan, executes it, returns trace/output data, and forgets it. There is no daemon-owned recipe registry.

YAML is the preferred source format for agent-authored plans because it is compact. JSON plan objects are also accepted over JSON-RPC.

## Invocation

CLI:

```sh
~/.swiftly/bin/swift run axon run ./docs/examples/read-and-click.yaml --dry-run --arg button=Issues
```

MCP:

```json
{
  "path": "/Users/mitch/projects/axon/docs/examples/read-and-click.yaml",
  "args": {
    "button": "Issues"
  },
  "dryRun": true
}
```

Inline source:

```json
{
  "source": "app: cairn\nsteps:\n  - read: { as: before }\n"
}
```

## Top-Level Schema

```yaml
app: cairn
result:
  outputs: compact
steps:
  - read:
      as: before
```

Fields:

- `app`: optional default app for steps
- `result.outputs`: `compact`, `full`, or `none`; default is `compact`
- `steps`: ordered list of one-operation step objects
- `dryRun`: accepted either top-level or as an invocation parameter

Invocation `args` are available as `$args.<name>`.

## Outputs and References

Most steps accept `as` to bind output for later steps:

```yaml
steps:
  - read:
      as: before
  - changed_since:
      snapshotId: $before.snapshotId
      as: changed
```

References can traverse objects and arrays:

```yaml
$before.snapshot.windows.0.handle
$args.title
```

With `result.outputs: compact`, bound snapshots return summary metadata instead of the full node tree. Use `full` while debugging and `none` when only the trace matters.

## Primitive Steps

Read current state:

```yaml
- read:
    app: cairn
    screenshot: false
    sensitive: false
    tree: false
    as: state
```

Use `sensitive: true` when the surface may contain generated keys, tokens, passwords, or other values Axon should not return verbatim:

```yaml
- read:
    app: cairn
    sensitive: true
    as: state
```

Sensitive reads redact AX values and secret-like text with short safe prefixes. They cannot include screenshots.

Capture screenshot only:

```yaml
- screenshot:
    app: cairn
    as: shot
```

Resolve locator:

```yaml
- resolve:
    locator:
      role: AXButton
      title:
        contains: Issues
      actions: [AXPress]
    as: issuesButton
```

Click locator:

```yaml
- click:
    target:
      locator:
        role: AXButton
        title:
          contains: Issues
        actions: [AXPress]
```

Scroll:

```yaml
- scroll:
    app: cairn
    deltaY: -600
```

Drag:

```yaml
- drag:
    from:
      point: { x: 320, y: 500 }
    to:
      point: { x: 320, y: 260 }
    durationMs: 300
```

Perform AX action:

```yaml
- perform_action:
    target:
      locator:
        role: AXButton
        title: Issue menu
    action: AXShowMenu
```

Set value:

```yaml
- set_value:
    target:
      locator:
        role: AXTextField
        description:
          contains: Title
    value: $args.title
```

Keyboard input:

```yaml
- type_text:
    text: $args.body
- press_key:
    key: Return
```

Change check:

```yaml
- changed_since:
    snapshotId: $before.snapshotId
    as: change
```

## Control Flow

Conditions:

```yaml
condition:
  exists:
    locator:
      role: AXButton
      title:
        contains: Backlog
```

Supported predicates:

- `exists`
- `not_exists`
- `unique`
- `changed_since`

Conditional branch:

```yaml
- if:
    condition:
      exists:
        locator:
          role: AXButton
          title:
            contains: Backlog
    then:
      - click:
          target:
            locator:
              role: AXButton
              title:
                contains: Backlog
    else:
      - read:
          as: fallbackState
```

Wait:

```yaml
- wait_until:
    timeoutMs: 5000
    intervalMs: 150
    condition:
      unique:
        locator:
          role: AXButton
          title:
            contains: Delete
```

Repeat:

```yaml
- repeat_until:
    maxIterations: 5
    condition:
      exists:
        locator:
          role: AXButton
          title:
            contains: Done
    do:
      - scroll:
          app: cairn
          deltaY: -600
```

Assert:

```yaml
- assert:
    condition:
      not_exists:
        locator:
          role: AXStaticText
          title:
            contains: Temporary smoke issue
```

## Failure Behavior

Plan failures are normal plan results, not MCP transport failures. A failed plan returns:

```json
{
  "success": false,
  "error": "Locator did not resolve uniquely: ambiguous",
  "trace": [
    {
      "op": "error",
      "success": false,
      "stepIndex": 2,
      "stepPath": "steps[2]",
      "stepOp": "click"
    }
  ]
}
```

Locator failures include target details, resolution status, candidate count, and candidate summaries. This is intentionally repair-oriented: the caller should be able to adjust the locator without doing another broad read first.

## Agent Guidelines

Use plans when multiple actions would otherwise require repeated `get_app_state` / action / `get_app_state` loops.

Prefer locator targets over handles in reusable plans.

Bind only outputs that later steps need.

Request screenshots only when visual evidence is needed.

Use `dryRun` to validate locators and control flow before dispatching mutating actions.

Add assertions around actions whose primitive result only proves dispatch, especially drag and keyboard-heavy flows.
