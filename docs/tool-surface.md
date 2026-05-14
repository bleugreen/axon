# Tool Surface

Axon exposes one verb-shaped vocabulary through MCP, the socket router, `.axn`
files, and the CLI. There are no compatibility aliases for previous tool names.

## MCP Tools

```text
look(target?, since?, screenshot?, screenText?, tree?, sensitive?, offset?, limit?, depth?, format?, frames?)
find(app, locator)
permit()
run(actions?, path?, continueOnError?, dryRun?)
save(sessionId?, from?, to?, path?, includeReads?)

click(target)
type(target, value)
keyboard(keys, app?)
scroll(target?, app?, deltaX?, deltaY?)
drag(from, to, app?, durationMs?)
invoke(target, name)
```

## CLI Commands

```text
axon permit
axon look [target] [--since snapshot-id] [--screenshot] [--screen-text] [--sensitive] [--frames] [--json] [--no-tree] [--offset n] [--limit n] [--depth n]
axon find <app> '<locator-json>'
axon run <path.axn> [--dry-run] [--continue-on-error]
axon save [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]

axon click <handle|target-json>
axon type <handle> <value>
axon keyboard [--app app] <keys-or-text>
axon scroll [--app app] [--target target-json] [--dx n] [--dy n]
axon drag [--app app] [--duration-ms n] <from-json> <to-json>
axon invoke <handle> <action-name>
```

## Perception

`look()` lists running app names. Use `format: "debug"` through MCP or
`axon look --details` when bundle identifiers or pids are needed.

`look(target: app)` captures an accessibility snapshot. MCP returns a compact
agent-facing observation by default; `format: "debug"` returns the raw snapshot.
Screenshots are opt-in with `screenshot: true`. `screenText: true` OCRs visible
text from the screenshot. `sensitive: true` redacts values and cannot be
combined with screenshots or OCR.

`look(target: handle)` fetches a retained node's child page. Use the `offset`
and `limit` fields from the returned continuation to page broad sibling lists.

`look(since: snapshot)` recaptures the app for a retained snapshot and reports
whether the coarse app/window surface changed. It uses observer hints when
available and always compares a fresh summary.

`find(app, locator)` resolves an AX locator against a fresh app snapshot and
returns `unique`, `ambiguous`, or `missing` with candidate summaries.

## Actions

Targets may be snapshot handles or locator objects:

```yaml
target:
  app: Safari
  locator:
    role: AXButton
    title: Submit
    actions:
      - AXPress
```

`click` accepts handles, locator targets, point targets, and text locations.
`type` fills writable fields by setting `AXValue`; use it when the desired
intent is "make this field contain this value." `keyboard` posts keyboard input
for shortcuts, special keys, or raw text when keystroke behavior is the intent.
`invoke` runs a named AX action such as `AXPress` or `AXShowMenu`.

## Recordings

`run` executes `.axn` actions from a file, inline actions, or both. When both
`path` and `actions` are provided, the file is loaded first and inline actions
are appended.

```yaml
version: 1
actions:
  - tool: type
    target: s1:12
    value: Mitch
  - tool: keyboard
    app: Safari
    keys: Return
```

`save` writes recent recorded calls as an editable `.axn` file. Read calls such
as `look` and `find` are omitted unless `includeReads` is true.

`requires` and `expects` metadata can be attached to actions. Supported fact
kinds are `exists`, `focused`, `value`, `selected`, `enabled`, `window`,
`menu-selection`, and `changed`; facts resolve through the same locator model as
actions.
