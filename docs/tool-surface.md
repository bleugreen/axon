# Tool Surface

Axon exposes one verb-shaped vocabulary through MCP, the socket router, `.axn`
files, and the CLI. There are no compatibility aliases for previous tool names.

## MCP Tools

```text
look(target?, since?, screenshot?, screenText?, tree?, offset?, limit?, direct?, childDepth?, depth?, all?, format?, frames?)
find(app, locator)
wait_for_value(target, contains?, equals?, matches?, timeoutMs?, intervalMs?)
permit()
run(actions?, path?, argValues?, continueOnError?, dryRun?)
save(sessionId?, from?, to?, path?, includeReads?)
click(target)
type(target, value)
keyboard(keys, app?)
scroll(target?, app?, deltaX?, deltaY?)
drag(from, to, app?, durationMs?, expects?)
invoke(target, name)
```

## CLI Commands

```text
axon permit
axon refresh-secrets [--json]
axon look [target] [--since snapshot-id] [--screenshot] [--screen-text] [--frames] [--json] [--details] [--debug] [--no-tree] [--offset n] [--limit n] [--depth n]
axon find <app> '<locator-json>'
axon wait_for_value '<target-json>' (--contains text | --equals text | --matches regex) [--timeout-ms n] [--interval-ms n]
axon run <path.axn> [--arg name=value] [--dry-run] [--continue-on-error]
axon save [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]

axon click <handle|target-json>
axon type <handle> <value>
axon keyboard [--app app] <keys-or-text>
axon scroll [--app app] [--target target-json] [--dx n] [--dy n]
axon drag [--app app] [--duration-ms n] <from-json> <to-json>
axon invoke <handle> <action-name>
```

## Perception

`look()` lists regular running UI apps by default. Use `all: true` or
`format: "debug"` through MCP, or `axon look --details`, when raw running
processes, bundle identifiers, or pids are needed.

`look(target: app)` captures an accessibility snapshot. MCP returns a compact
agent-facing observation by default; `format: "debug"` returns the raw snapshot.
The observation tree is a DSL string with retained handles, roles, labels,
actions, and explicit truncation markers. Screenshots are opt-in with
`screenshot: true`. `screenText: true` OCRs visible text from the screenshot.

Active credential redaction is always on when a provider-backed index has been
refreshed with `axon refresh-secrets`. Redacted active credentials appear as
`<redacted: active-credential>` with matching `op://` references in structured
redaction metadata; the secret value itself is never returned.

Deterministic rule redaction is also always on for AX and OCR text. Role rules
and curated patterns redact secure field values, secret-labeled values,
structured identifiers, Luhn-valid cards, and known token shapes as
`<redacted: auth-credential>`, `<redacted: pii-identifier>`, or
`<redacted: financial-data>`.
When a screenshot request is known to contain an active credential through AX or
OCR text, Axon omits the image and returns a warning instead of sending pixels.

`look(target: handle)` fetches a retained node's child page. Use the `offset`
and `limit` fields from the returned continuation to page broad sibling lists.
`direct: true` returns only direct children, and `all: true` includes every
direct child. Child pages use the same DSL tree format as app observations.
`childDepth: 0` on an app observation retains top-level windows without walking
descendants so callers can page children by handle.

`look(since: snapshot)` recaptures the app for a retained snapshot and reports
whether the coarse app/window surface changed. It uses observer hints when
available and always compares a fresh summary.

`find(app, locator)` resolves an AX locator against a fresh app snapshot and
returns `unique`, `ambiguous`, or `missing` with candidate summaries.
Locator fields are not all equally durable: role, subrole, title, label,
description, identifier, non-editable value, first-class window scope, and
ancestors filter candidates; actions, editable text values, and nearby text
contribute to candidate reasons and scoring when present. Frame hints are weak
normalized-distance tie-breakers, and resolution results include a named
confidence.

`wait_for_value(target, contains|equals|matches)` repeatedly resolves a locator
target and reads the unique target's readable AX state until one predicate holds
or the bounded timeout elapses. It checks readable text fields including
`AXValue`, `AXTitle`, `AXDescription`, identifier, and help, so browser controls
whose user-facing label is exposed as `AXDescription` can be waited on honestly.
Timeouts return `success: false` with elapsed milliseconds and either the last
observed readable state (`predicate_timeout`) or the last missing/ambiguous
locator resolution (`target_unresolved_timeout`). This is a settled-state wait;
`look(since:)` remains the coarse app/window change check.

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
`drag` accepts the same pointer target vocabulary for `from` and `to`. Point
coordinates may explicitly use `screen`, `window`, or `screenshot` coordinate
spaces; legacy point payloads without `coordinateSpace` remain screen points for
wire compatibility. Direct drag results separate pointer dispatch from semantic
success. A drag is semantically successful only when `run` verifies supplied
`expects` facts after dispatch, such as an AX list value exposing the new row
order.

`type` fills writable fields by setting `AXValue`; use it when the desired
intent is "make this field contain this value." `keyboard` posts keyboard input
for shortcuts, special keys, or raw text when keystroke behavior is the intent.
`invoke` runs a named AX action such as `AXPress` or `AXShowMenu`.

## Recordings

`run` executes `.axn` actions from a file, inline actions, or both. When both
`path` and `actions` are provided, the file is loaded first and inline actions
are appended. Caller-supplied `.axn` parameters are passed as `argValues`
through MCP/socket calls or as repeated CLI `--arg name=value` flags.

```yaml
version: 1
args:
  - name: user_name
    type: string
    default: Mitch
actions:
  - tool: type
    target: s1:12
    value: "{{user_name}}"
  - tool: keyboard
    app: Safari
    keys: Return
```

Parameter references are substituted inside string `value` and `keys` fields
before the first action runs. Supported v1 parameter types are `string`,
`secret`, `number`, `date`, `email`, and `path`. `env://NAME` and
`op://vault/item/field` sources can bind declared args; caller args cannot
override a declared source. Secret-tainted action values are redacted in dry-run
params, axn traces, and history. Prefer `op://` or `env://` sources for
secrets; literal CLI `--arg` values can be exposed before Axon receives them.

`save` writes recent recorded calls as an editable `.axn` file. Read calls such
as `look` and `find` are omitted unless `includeReads` is true.

`requires` and `expects` metadata can be attached to actions. Supported fact
kinds are `exists`, `focused`, `value`, `selected`, `enabled`, `window`,
`menu-selection`, and `changed`; facts resolve through the same locator model as
actions.
