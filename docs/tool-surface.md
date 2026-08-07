# Tool Surface

Axon exposes one verb-shaped vocabulary through MCP, the socket router, `.axn`
files, and the CLI. There are no compatibility aliases for previous tool names.

## MCP Tools

```text
look(target?, since?, screenshot?, screenText?, tree?, offset?, limit?, direct?, childDepth?, depth?, all?, format?, frames?)
navigate(app, url)
windows(app)
tabs(app, window?)
find(app, locator)
wait_for_value(target, contains?, equals?, matches?, timeoutMs?, intervalMs?)
wait_for_stability(app, condition?, stableMs?, timeoutMs?, intervalMs?)
permit()
run(actions?, path?, argValues?, continueOnError?, dryRun?)
save(sessionId?, from?, to?, path?, includeReads?)
click(target)
type(target, value)
keyboard(text?, key?, app?)
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
axon wait_for_stability <app> [--condition stable|changed] [--stable-ms n] [--timeout-ms n] [--interval-ms n]
axon run <path.axn> [--arg name=value] [--dry-run] [--continue-on-error]
axon save [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]

axon click <handle|target-json>
axon type <handle> <value>
axon keyboard [--app app] (--text text | --key keystroke)
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
App observations also report `focus`. `available` includes the focused element's
role and label plus a retained handle when that element belongs to the captured
tree. `none` means the app reported no focused UI element. `inaccessible` means
the `AXFocusedUIElement` query itself failed and includes the Accessibility error;
it is never collapsed into `none`.

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

When every child of a rendered node is filtered out of the observation, the tree says so
with a marker naming what disappeared, such as
`⟨1 unreadable node: group[AXHostingView]⟩`, instead of rendering an empty child list
against a non-zero child count. This is how a caller tells "nothing here" from "nothing
readable here" without dropping to `format: "debug"`.

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

`navigate`, `windows`, and `tabs` are the narrow semantic browser layer for
Safari and Google Chrome. They use each application's scripting dictionary when
AX does not model navigation or tabs. Navigation accepts only absolute `http`
and `https` URLs and succeeds only when the browser dictionary reads the
requested URL back from the active tab. Window and tab IDs are one-call,
index-based references and must be refreshed by enumerating again. Browser
enumeration is authoritative from application scripting; `windows` also reports
an AX title/count cross-check when Accessibility access is available, while
`tabs` explicitly reports that a portable AX tab cross-check is unavailable.
Automation consent is separate from Accessibility consent and permission errors
direct callers to System Settings. Apple Events are bounded by a 15-second
timeout. These operations never accept script source.

`wait_for_value(target, contains|equals|matches)` repeatedly resolves a locator
target and reads the unique target's readable AX state until one predicate holds
or the bounded timeout elapses. It checks readable text fields including
`AXValue`, `AXTitle`, `AXDescription`, identifier, and help, so browser controls
whose user-facing label is exposed as `AXDescription` can be waited on honestly.
Timeouts return `success: false` with elapsed milliseconds and either the last
observed readable state (`predicate_timeout`) or the last missing/ambiguous
locator resolution (`target_unresolved_timeout`). This is a settled-state wait;
`look(since:)` remains the coarse app/window change check.

`wait_for_stability(app, condition)` polls full app observations rather than a
single element value. The default `stable` condition succeeds after the tree and
focused element remain unchanged for `stableMs` (300 ms by default). `changed`
succeeds when those observable fields differ from the initial observation. Both
conditions use a bounded interval of at least 10 ms, cap the timeout at 60 seconds,
and return `finalObservation` on success or timeout. This is the post-navigation
settle primitive; use `wait_for_value` when readiness has a specific semantic
field predicate instead.

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
wire compatibility. Handle- and locator-derived pointer events are hit-tested
again immediately before dispatch and fail closed if the intended element moved,
is occluded, or cannot be resolved. Explicit point targets carry no intended
element identity, so they dispatch as unverified coordinates; use a handle or
locator when fail-closed target validation is required. Direct drag results separate pointer dispatch from semantic
success. A drag is semantically successful only when `run` verifies supplied
`expects` facts after dispatch, such as an AX list value exposing the new row
order.

`scroll` chooses between two strategies by the kind of target it was given. A point
target posts `CGEventScroll` wheel events at that point and never consults the
accessibility tree, which is what makes surfaces that render their own contents —
iPhone Mirroring, remote desktops, games, canvas views — scrollable at all. A handle,
locator, or bare app resolves an offscreen descendant and presses `AXScrollToVisible`
as before, and falls back to a wheel burst at the element's or window's center when the
tree exposes no scrollable descendant. The reported `strategy` always names which one
ran. `deltaX`/`deltaY` are pixels and negative `deltaY` scrolls down; only the wheel
path honors the distance, because `AXScrollToVisible` lets the app decide how far to
move. Both strategies report `dispatchSuccess` separately from `semanticSuccess` and
leave `semanticStatus` unverified: a dispatched wheel, or an app acknowledging the
accessibility action, is not proof that the viewport moved. `success` reflects dispatch
rather than semantics here, unlike `drag`, because a scroll moves a viewport instead of
mutating state. Unlike `drag`, `scroll` never activates the app it was given: a posted
wheel is routed by the event's location to the window under that point whatever is
frontmost, so raising the app would only take the user's focus. A point covered by
another window therefore scrolls whatever is on top of it. A delta too small to round to
a whole pixel of wheel movement is reported as a failure rather than as an empty
dispatch, and a zero delta is a no-op carrying `semanticStatus: "noop"`.

`type` fills writable fields by setting `AXValue`; use it when the desired
intent is "make this field contain this value." Its exact AXValue readback is a
verified success. If it must fall back to click-and-keyboard events, dispatch is
reported separately and success remains false unless a `run` postcondition
proves a causal transition. For a type fallback, that requires an explicit
`changed` expectation because the before-state cannot be reconstructed after
dispatch. `keyboard` requires exactly one explicit
intent: `text` accepts arbitrary text, while `key` accepts only recognized keys
and keystrokes such as `End`, `Return`, or `cmd+shift+p`. Keyboard event dispatch
alone is likewise unverified and does not set `success` to true.
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
    key: Return
```

Parameter references are substituted inside string `value`, `text`, and `key` fields
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
