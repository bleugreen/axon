# What you can do with Axon

Axon gives your agent a way to understand and operate desktop apps using their accessibility information. You describe the outcome; the agent uses Axon to inspect the app, choose a meaningful target, act, and check what happened.

## Start by looking

Ask your agent to look at an app before acting:

> Look at Safari and tell me what is open.

Axon returns a compact description of windows and controls using roles, labels, values, and stable semantic names. It can include a screenshot when that helps. Passwords, credentials, and other recognized sensitive values are redacted.

## Act on meaningful targets

You can refer to controls by what they are, not by screen coordinates:

> Click the **Create issue** button in Linear.

> Fill the **Email** field with `ada@example.com`.

> Open Safari to `https://example.com`.

Axon prefers semantic actions supplied by the app, such as pressing a button or setting a field value. Coordinates are an escape hatch for surfaces that do not expose useful accessibility information.

## Keep control of your desktop

Actions run in the background when the operating system and app allow it. Axon does not silently move your pointer, steal focus, use the clipboard, or send global keyboard input.

When an action genuinely requires the app in front, your agent must opt in for that specific step. The permission does not carry into later actions.

## Expect honest results

Axon separates “the operating system accepted the input” from “the intended result happened.” If it cannot verify an outcome, it says so. If a safe delivery path does not exist, it refuses the action instead of guessing.

For tasks with a clear result, ask the agent to wait for it:

> Submit the form, then wait until the confirmation message appears.

## Save repeatable work

A useful sequence can be saved as a human-readable [`.axn` file](axn.md). You can inspect it, edit parameters, keep it in version control, and run it again.

> Save what we just did as `create-issue.axn`.

For platform-specific limits, see [Cross-platform support](cross-platform.md).

## Protocol reference

## See what an app exposes

`look()` lists regular running UI apps by default. Use `all: true` or
`format: "debug"` through MCP, or `axon look --details`, when raw running
processes, bundle identifiers, or pids are needed.

`look(app: ...)` captures an accessibility snapshot. MCP returns a compact
agent-facing observation by default; `format: "debug"` returns the raw snapshot.
The MCP observation is the `structuredContent` object itself: `app`, `snapshot`,
`tree`, `focus`, `screenshot`, `screenshotUnavailable`, `screenText`, redaction,
and warnings are top-level siblings. There is no `structuredContent.snapshot`
wrapper. Screenshot metadata stays at `structuredContent.screenshot`; its base64
bytes travel in a sibling MCP image content item.
The observation tree is a DSL string with app-scoped semantic names, normalized roles, labels,
actions, and explicit truncation markers. Full app observations include a window
screenshot by default; use `screenshot: false` or `--no-screenshot` to omit it.
`look(since:)` change checks and semantic-target child pages remain imageless by
default because they refine an observation the caller already has. Observation images are
lossless PNGs, never upscaled, with their longest edge bounded to 1280 pixels. If a
backend cannot capture the requested image, the accessibility observation still succeeds:
`screenshot` is absent and `screenshotUnavailable` reports a stable code and reason.
`screenText: true` OCRs visible text from the screenshot.
App observations also report `focus`. `available` includes the focused element's
role and label plus its semantic name when that element belongs to the captured
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
`<redacted: financial-data>`. Numeric `AXValue` strings on position controls such
as scroll bars, sliders, and value indicators are excluded from card detection;
their digits describe control state rather than financial data.
When a screenshot request is known to contain an active credential through AX or
OCR text, Axon omits the image and returns a warning instead of sending pixels.

When every child of a rendered node is filtered out of the observation, the tree says so
with a marker naming what disappeared, such as
`⟨1 unreadable node: group[AXHostingView]⟩`, instead of rendering an empty child list
against a non-zero child count. This is how a caller tells "nothing here" from "nothing
readable here" without dropping to `format: "debug"`.

`look(target: {app, name})` fetches a named node's child page. Use the `offset`
and `limit` fields from the returned continuation to page broad sibling lists.
`direct: true` returns only direct children, and `all: true` includes every
direct child. Child pages use the same DSL tree format as app observations.
`childDepth: 0` on an app observation retains top-level windows without walking
descendants so callers can page children by semantic name.

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

`wait_for_value(target, contains|equals|matches)` repeatedly resolves an app-scoped
semantic name and reads the unique target's readable state until one predicate holds
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

## Act without stealing focus

Every mutating action takes a `deliveryPolicy`, and the CLI spells
`foregroundPermitted` as `--foreground`. `backgroundOnly` is the default and
forbids application activation, system-focus changes, movement of the real
pointer, global keyboard input, and the clipboard. `foregroundPermitted` allows
the backend to escalate that one action; it is never daemon state and is never
inherited by a later action, including a later step of the same `.axn` run.

Every action result carries four stable top-level fields alongside `success`,
`strategy`, and `message`: the `deliveryPolicy` it ran under, the `delivery` rung
that carried it, whether the mechanism accepted it (`dispatchSuccess`), and a
`refusal` when Axon declined to act.

The rung names what actually happened, classified by observable side effect
rather than by the API that produced it:

| rung | meaning on macOS |
| --- | --- |
| `semantic` | `AXPress`, `AXValue`, `AXScrollToVisible` — no focus change, no activation |
| `pixel` | `CGEventPostToPid` against the target's process, with the frontmost app and the real pointer proved unchanged afterwards |
| `foreground` | Global `CGEvent` on the shared devices, allowed only by explicit opt-in |

Actions climb that ladder in order and stop at the first rung their policy and
the runtime allow. A failed semantic attempt may advance to pixel; under
`backgroundOnly` the ladder ends there. An accessibility action the app *refuses*
is a failed action, never a reason to send unrelated global input at the same
coordinates, so `invoke` has one rung only. An action reported as **unsupported**
is not a refusal: the element advertised a mechanism it does not implement, and
nothing was ever asked to decide. `scroll` therefore advances from an unsupported
action to its wheel rung, and stops where it stands on every other accessibility
error.

`foregroundPermitted` **raises the ceiling rather than choosing a rung**. An
action still takes the quietest mechanism that works, so opting in costs nothing
when the background path succeeds. A rung only advances when it can prove it did
not take: `type` reads the value back and can, while a click or keystroke cannot,
so a dispatch those accept is where they stop. Escalating past an accepted but
unverifiable dispatch would deliver the action twice.

Background delivery needs a target it can prove. A handle, locator, or text
location carries the owning process; a point carries one only when its `app` is
named. A bare screen point cannot be bound to a window without guessing, so
under `backgroundOnly` it is refused rather than delivered globally.

A refusal is an action result, not a transport error: the request was well
formed and the target resolved, and the daemon declined. It carries a stable
`reason`, the `requiredRung` it would have needed, the responsible `capability`,
a diagnostic `message`, and `alsoRefused`. A refusal is always decided before the mechanism it
names produces any native side effect, so a result whose `delivery` is null
dispatched nothing at all. A result that names a rung *and* carries a refusal ran
that rung and was only declined the escalation above it, and it keeps whatever
dispatch evidence that rung earned. Malformed requests and target-resolution
failures remain JSON-RPC errors.

| reason | meaning |
| --- | --- |
| `foregroundNotPermitted` | Only the foreground rung remained and the action did not opt in |
| `backgroundPixelUnsupported` | No target-bound mechanism could carry the action without global input |
| `targetIdentityUnavailable` | The request named coordinates with no application or window behind them |
| `clipboardForbidden` | A clipboard-backed candidate was offered; Axon never uses the pasteboard |
| `activationNotProved` | Foreground escalation could not prove the target became frontmost, so nothing was posted |
| `noDeliveryCandidate` | The action has no delivery mechanism at all on this backend |

`alsoRefused` lists every other rung the ladder walked past, in ladder order,
each with its own `rung`, `reason`, and `message`. The reported `reason` is the
most actionable one — being told to opt in beats being told about a capability
gap you cannot act on — but it is not the only useful one. A click refused as
`foregroundNotPermitted` whose `alsoRefused` names a raw screen point with no
application behind it is telling you the quiet rung would work from a handle; one
whose entry names a toolkit that does not act on background clicks is telling you
it never will for this target. The array is always present, and empty when the
ladder walked past nothing.

Foreground escalation is transactional. Axon captures the prior frontmost
application, activates the target and proves it is frontmost, dispatches exactly
one action, and hands the session back — on success, on validation failure, and
on a thrown error alike. The result reports that evidence under `foreground`:
prior app identity, whether the target was already frontmost, whether activation
was proved, whether the prior app was restored, and whether the real pointer was
put back. If activation cannot be proved, nothing is posted and the action
refuses. If restoration fails after dispatch, the dispatch evidence is kept and
the overall result is a failure.

Axon has no clipboard path and will not grow one by accident: the pasteboard is
modelled as a forbidden delivery capability that the planner refuses on sight.

## Interact with a target

Interactive element targets are app-scoped semantic names:

```yaml
target:
  app: Safari
  name: checkout/submit
```

`click` accepts semantic-name targets, point targets, and text locations.
`drag` accepts the same pointer target vocabulary for `from` and `to`. Point
coordinates may explicitly use `screen`, `window`, or `screenshot` coordinate
spaces; legacy point payloads without `coordinateSpace` remain screen points for
wire compatibility. Semantic-name-derived pointer events are hit-tested
again immediately before dispatch and fail closed if the intended element moved,
is occluded, or cannot be resolved. Explicit point targets carry no intended
element identity, so they dispatch as unverified coordinates; use an app-scoped
semantic name when fail-closed target validation is required. Raw snapshot handles
and standalone locator objects are invalid public targets, including handles shown
by `look(format: "debug")`.

Pointer results separate dispatch from semantic success. A click on an element
that advertises `AXPress` is a semantic action and proves its own outcome, but a
click or drag that has to travel as pointer input cannot read back what it
achieved: it reports `dispatchSuccess` with `semanticStatus: "unverified"` and
leaves `success` false. Such an action is semantically successful only when
`run` verifies supplied `expects` facts after dispatch, such as an AX list value
exposing the new row order.

`scroll` chooses between two strategies by the kind of target it was given. A point
target posts `CGEventScroll` wheel events at that point and never consults the
accessibility tree, which is what makes surfaces that render their own contents —
iPhone Mirroring, remote desktops, games, canvas views — scrollable at all. A semantic
name or bare app resolves an offscreen descendant *that advertises*
`AXScrollToVisible` and presses it. Advertising the action is part of being a candidate
rather than something checked afterwards: most AppKit list rows expose no scrolling
action at all, and choosing one on placement alone would commit the scroll to a
mechanism that does not exist. Only a proved absence disqualifies a descendant: one whose
action list could not be read at all is still attempted, because silence from the tree is
not evidence that the element cannot scroll. When no descendant can carry the action — or
when one is attempted and reports it unsupported — the scroll falls back to a wheel burst
aimed at the center of the element or window the caller named, never at the ranked
descendant.
The reported `strategy` always names which one ran. `deltaX`/`deltaY` are pixels and negative `deltaY` scrolls down; only the wheel
path honors the distance, because `AXScrollToVisible` lets the app decide how far to
move. Both strategies report `dispatchSuccess` separately from `semanticSuccess` and
leave `semanticStatus` unverified: a dispatched wheel, or an app acknowledging the
accessibility action, is not proof that the viewport moved, so `success` stays false
until a `run` postcondition proves the viewport moved.

A wheel burst is global input whatever it is aimed at, so it rides the delivery ladder:
it reaches a verified process in the background when the target carries one, and the
shared devices only under `foregroundPermitted`. `scroll` never activates the app it was
given, at either rung: a posted wheel is routed by the event's location to the window
under that point whatever is frontmost, so raising the app would only take the user's
focus. A point covered by another window therefore scrolls whatever is on top of it. A
delta too small to round to a whole pixel of wheel movement is reported as a failure
rather than as an empty dispatch, and a zero delta is a no-op carrying
`semanticStatus: "noop"` that claims no dispatch and names no rung.

`type` fills writable fields by setting `AXValue`; use it when the desired
intent is "make this field contain this value." Its exact AXValue readback is a
verified success. If it must fall back to click-and-keyboard events, dispatch is
reported separately and success remains false unless a `run` postcondition
proves a causal transition. For a type fallback, that requires an explicit
`changed` expectation because the before-state cannot be reconstructed after
dispatch. A keystroke fallback that does land the value is still proved by
readback, so it reports a verified success at whichever rung carried it.

`keyboard` requires exactly one explicit intent: `text` accepts arbitrary text,
while `key` accepts only recognized keys and keystrokes such as `End`, `Return`,
or `cmd+shift+p`. Keyboard event dispatch alone is likewise unverified and does
not set `success` to true. `keyboard` has no semantic rung — there is no element
to mutate, only input to deliver — so background delivery needs `app` to name the
receiving application. Without it the only rung left is foreground, and
`backgroundOnly` refuses.

`invoke` runs a named AX action such as `AXPress` or `AXShowMenu`. It is always
semantic and never escalates.

## Save and replay useful work

`run` executes `.axn` actions from a file, inline actions, or both. When both
`path` and `actions` are provided, the file is loaded first and inline actions
are appended. Caller-supplied `.axn` parameters are passed as `argValues`
through MCP/socket calls or as repeated CLI `--arg name=value` flags.

```yaml
version: 2
args:
  - name: user_name
    type: string
    default: Mitch
actions:
  - tool: type
    target:
      app: Safari
      name: account/user-name
    value: "{{user_name}}"
  - tool: keyboard
    app: Safari
    key: Return
```

Parameter references are substituted inside string `value`, `text`, and `key` fields
before the first action runs. Supported v2 parameter types are `string`,
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

## Protocol signatures

### MCP

```text
look(app?, target?, since?, screenshot?, screenText?, tree?, offset?, limit?, direct?, childDepth?, depth?, all?, format?, frames?)
navigate(app, url)
windows(app)
tabs(app, window?)
find(app, locator)
wait_for_value(target, contains?, equals?, matches?, timeoutMs?, intervalMs?)
wait_for_stability(app, condition?, stableMs?, timeoutMs?, intervalMs?)
permit()
run(actions?, path?, argValues?, continueOnError?, dryRun?, healedPath?)
save(sessionId?, from?, to?, path?, includeReads?)
click(target, deliveryPolicy?)
type(target, value, deliveryPolicy?)
keyboard(text?, key?, app?, deliveryPolicy?)
scroll(target?, app?, deltaX?, deltaY?, deliveryPolicy?)
drag(from, to, app?, durationMs?, expects?, deliveryPolicy?)
invoke(target, name, deliveryPolicy?)
```

### CLI

```text
axon permit
axon refresh-secrets [--json]
axon look [app | target-json] [--since snapshot-id] [--no-screenshot] [--screen-text] [--frames] [--json] [--details] [--debug] [--no-tree] [--offset n] [--limit n] [--depth n]
axon find <app> '<locator-json>'
axon wait_for_value '<target-json>' (--contains text | --equals text | --matches regex) [--timeout-ms n] [--interval-ms n]
axon wait_for_stability <app> [--condition stable|changed] [--stable-ms n] [--timeout-ms n] [--interval-ms n]
axon run <path.axn> [--arg name=value] [--dry-run] [--healed-path file] [--continue-on-error]
axon save [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]

axon click [--foreground] <target-json>
axon type [--foreground] <target-json> <value>
axon keyboard [--app app] [--foreground] (--text text | --key keystroke)
axon scroll [--app app] [--target target-json] [--dx n] [--dy n]
axon drag [--app app] [--duration-ms n] [--foreground] <from-json> <to-json>
axon invoke [--foreground] <target-json> <action-name>
```

The command line has one positional slot where `look` has two parameters, so the
shape of the argument selects between them: a bare word is an `app` to observe,
and a JSON object is a `target` whose children are paged. Every other command
that takes a target takes it as JSON, because an element target is the
`{app, name}` object `look` returned and never a bare string.
