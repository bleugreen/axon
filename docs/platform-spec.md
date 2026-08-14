# Platform-neutral Axon contract

This document defines the contract shared by every Axon implementation. It
separates that contract from the native accessibility vocabulary and mechanics
used to fulfill it. The Swift implementation remains canonical on macOS; sibling
implementations must conform to this document and the machine-readable surface.

## Sources of truth

The public tools and their parameter schemas have one machine-readable source of
truth: [`Sources/AxonCore/ToolSurfaceSpec.swift`](../Sources/AxonCore/ToolSurfaceSpec.swift).
The generated signatures in [`tool-surface.md`](tool-surface.md) are checked
against it. Implementations must expose the tools declared there: `look`, `find`,
`permit`, `run`, `save`, `click`, `type`, `keyboard`, `scroll`, `drag`, `invoke`,
`wait_for_value`, and `wait_for_stability`.

This document deliberately does not copy their signatures. A surface change
starts in `ToolSurfaceSpec.swift`, updates its generated documentation, and then
updates shared conformance fixtures. The behavioral descriptions in
[`tool-surface.md`](tool-surface.md) and the file-format definition in
[`axn.md`](axn.md) are normative alongside this document.

## Targets

An action target is polymorphic. The canonical decoding rules live in
[`Sources/AxonCore/ToolTarget.swift`](../Sources/AxonCore/ToolTarget.swift).

- An **element target** is exactly `{app, name}`. The name is derived from the
  normalized observation vocabulary and is resolved within the named application.
  Snapshot handles are private cache keys and are never accepted on the wire.
- A recording may attach locator evidence to `{app, name}` for replay. The
  evidence is subordinate to the name and is invalid as a standalone target.
- A **point** uses screen, window, or screenshot coordinates. It is an explicit
  escape hatch with no element identity or occlusion guarantee.
- A **text location** resolves visible text from accessibility data or screenshot
  text into a pointer location. It represents explicit visual intent rather than
  a competing element identity.

Tools accept only the target kinds declared by the machine-readable surface.
Semantic names must be re-resolved and, for pointer dispatch, hit-tested
immediately before dispatch. Raw points remain explicitly unverified.

Child paging uses the same `{app, name}` target as actions. Snapshot IDs remain
valid only as observation tokens for `since`; debug output may reveal internal
handles, but their appearance does not make them actionable.

## Shared locator grammar

Locator *structure* is shared across platforms:

- native `role` and, where the backend has one, native `subrole`;
- `title`, `label`, `value`, `description`, and `identifier` text matchers;
- each text matcher supports `exact` or `contains`, plus `caseSensitive`;
- a list of native `actions` or supported interaction patterns;
- first-class `window` scope;
- ordered `ancestors` constraints;
- `nearbyText`, which is a positive-only replay signal; and
- normalized `frame`, used only as a weak distance tie-breaker.

A case-insensitive matcher applies the Unicode default lowercase mapping and then
Unicode Normalization Form C (NFC) to both operands before comparison. This
mapping is locale-independent and does not remove diacritics. Implementations
must not use the process or user locale when resolving a locator.

The distinction between filtering and scoring is part of the contract. Role,
subrole, title, label, description, identifier, non-editable value, window scope,
and ancestors are hard filters. Actions, editable values, and nearby text are
replay signals: a match may improve confidence and explain a candidate, but their
absence must not eliminate an otherwise stable candidate. Nearby text is never
negative evidence. Frame proximity cannot overcome a semantic mismatch.

### Native vocabulary, shared structure

Values inside the shared grammar remain native to the target platform:

- macOS uses Accessibility names such as `AXButton` and `AXPress`;
- Windows uses UI Automation control types and pattern names;
- Linux uses AT-SPI roles and action names. AT-SPI role names are emitted as
  providers expose them (for example, `push button`), and action names are exact
  provider strings such as `click` or `activate`. Editable controls are identified
  by the AT-SPI EditableText interface, not by role inference. Linux semantic
  scrolling is unavailable when the provider cannot express the requested delta;
  it is never silently replaced with global wheel input.

Axon does **not** define a normalized cross-platform role or action vocabulary.
Normalization would hide distinctions exposed by each accessibility stack and
create a second, lossy semantic model. A locator is therefore portable as a data
shape, not necessarily as an artifact containing native terms.

## Resolution and honest results

Semantic-name resolution returns exactly one status: `unique`, `ambiguous`, or
`missing`. It also returns a named confidence level: `none`, `low`, `medium`, or
`high`. Ambiguous and missing resolutions do not dispatch an action. Candidate
summaries and reasons should make the outcome diagnosable; a backend must not
silently pick the first native element returned by its API. Ambiguity responses
carry the `{app, name}` query and candidate semantic names, normalized roles,
human labels, scores, reasons, and recorded locator evidence; public candidate
summaries never expose internal handles.

Candidates are ranked by semantic score before the frame tie-breaker. The frame
tie-breaker occupies only the sub-semantic part of the score and therefore cannot
overcome a one-point semantic difference. Each matched top-level field, action,
or nearby-text matcher contributes one semantic point. Window scope contributes
one point, plus one for each populated and matched window `subrole`, `identifier`,
`title`, or `label` field.
Within each ancestor constraint, every populated and matched field contributes
one point. A matching editable value contributes its field point plus two bonus
points; a mismatching editable value contributes none. A result is `unique` only when exactly
one candidate has the highest complete score, `ambiguous` when multiple
candidates share it, and `missing` when no candidate survives hard filtering.
`ambiguous` and `missing` always have `none` confidence. A unique result has
`high` confidence at four or more semantic points, `medium` at two or three,
`low` at one, and `none` at zero. Thus `unique` with `none` confidence is valid
when a sole candidate wins without any semantic criterion.

Action results distinguish **dispatch success** from **goal success**. Posting a
native action or input event proves only that dispatch occurred. `success` means
the intended semantic result was verified, either by direct readback or by an
explicit `expects` postcondition. A backend that cannot verify the effect reports
that honestly rather than promoting dispatch to success.

A rung's own conditions narrow that further and never substitute for it. The
pixel rung additionally requires that the send completed and left the foreground
and the real pointer alone; the foreground rung, that the user's session was
handed back. `success` is every applicable condition together, so an action whose
rung kept all of its own promises is still not successful while its goal is
unverified. The rule has one home across the Rust backends, `goal_success` in
`rust/axon-core/src/delivery.rs`, so no rung can hold half of it.

## Delivery contract

Axon's preference for accessibility-level actions is a caller-visible guarantee,
not an implementation detail. Every mutating action — `click`, `type`,
`keyboard`, `scroll`, `drag`, `invoke` — takes an optional `deliveryPolicy`, and
every action result reports what the daemon actually did with it.

### Policy

| policy | meaning |
| --- | --- |
| `backgroundOnly` | The default. Forbids application activation, system-focus changes, movement of the real pointer, global keyboard input, and clipboard access. |
| `foregroundPermitted` | Permits the backend to escalate **this action only**. |

The policy is per action and is never daemon state. It is decoded before the
target is resolved and before any native call, so an unrecognized value is a
JSON-RPC `invalid params` error rather than a dispatch. It is never inherited:
an `.axn` step that permits foreground delivery says nothing about the next step.

### Rungs

The reported rung is the mechanism that actually carried the action, classified
by **observable side effect** rather than by the name of the API involved:

| rung | classification rule |
| --- | --- |
| `semantic` | An AX, UIA, or AT-SPI mutation that neither focused nor activated. An action that changes system focus is foreground regardless of which API finally mutated the target. |
| `pixel` | Target-bound input derived from verified window geometry, delivered without activating the application and without moving the real pointer. |
| `foreground` | Global input devices: `CGEvent` on the HID tap, `SendInput`, `XTest`, or a virtual pointer. |

Backends enumerate an ordered ladder — semantic, then pixel, then foreground —
and dispatch at the first rung the policy and the runtime allow. A rung that
demonstrably did not take may advance; a rung that delivered must not, because a
second dispatch would repeat an action the target may already have performed.
Under `backgroundOnly` the ladder ends after pixel.

A backend may only report `pixel` for a mechanism that is genuinely bound to a
verified target. It must carry stable app and window identity, window-relative
coordinates converted through resolved window geometry, and revalidation of a
retained element, window, or text-location resolution immediately before
dispatch. A target window may never be inferred from an unscoped screen point.
After dispatch the backend proves that the frontmost application and the real
pointer are unchanged. Relabelling a global input device as `pixel` because it
was aimed narrowly is a contract violation, not an optimization.

Dispatch at the pixel rung is evidence, not goal success: event acceptance sets
`dispatchSuccess`, while `success` still requires readback or an `expects`
postcondition.

### Result fields

Every action result carries four stable top-level fields alongside `success`,
`strategy`, and `message`:

| field | meaning |
| --- | --- |
| `deliveryPolicy` | The policy the action ran under. Always present. |
| `delivery` | The rung that carried the action, or `null` when no mechanism was reached. |
| `dispatchSuccess` | Whether the mechanism accepted the action. |
| `refusal` | Present when the backend declined a rung, otherwise `null`. |

A refusal carries a stable `reason`, the `requiredRung` it would have needed, the
responsible `capability` when one is to blame, a diagnostic `message`, and
`alsoRefused`:

| reason | meaning |
| --- | --- |
| `foregroundNotPermitted` | Only the foreground rung remained and the action did not opt in. |
| `backgroundPixelUnsupported` | No target-bound mechanism on this platform, compositor, toolkit, or window could carry the action without global input. |
| `targetIdentityUnavailable` | The request named coordinates with no application or window behind them. |
| `clipboardForbidden` | A clipboard-backed candidate was offered. Always refused. |
| `activationNotProved` | Foreground escalation could not prove the target became frontmost, so nothing was posted. |
| `noDeliveryCandidate` | This rung's mechanism does not exist on this backend. |

`alsoRefused` is every other rung the ladder walked past on the way to the one it
reports, in ladder order, each entry naming its `rung`, its own `reason`, and its
own `message`. It is always present, and empty when there was nothing else to
report, so a caller never has to tell a missing field from an empty one.

The reported `reason` is a ranking decision and the ranking stands: among rungs
that would otherwise work, the policy boundary is the most actionable thing a
caller can be told, so it outranks any capability gap below it. The obstacles
below are ranked against nothing, and they are where the platform-specific
evidence lives — the toolkit and version an AT-SPI target reports, the window
class with no probe-verified message path. Those are the sentences that answer
whether the quiet rung could ever carry this target, which is a different
question from what this caller should do next, so the winning reason keeps its
place and the rest travel beside it rather than being overwritten by it. A
selected rung reports no obstacles: a ladder that found a mechanism is describing
what happened, not why nothing could.

A refusal is always decided before the mechanism it names produces any native
side effect. A result whose `delivery` is `null` therefore dispatched nothing at
all; a result that names a rung *and* carries a refusal ran that rung and was
only declined the escalation above it, keeping whatever dispatch evidence that
rung earned. Policy and capability denials are action results, not transport
errors — malformed requests and target-resolution failures remain JSON-RPC
errors.

A refusal must never be reported as `foregroundNotPermitted` when the foreground
mechanism does not exist on that backend: telling a caller to opt in to something
that cannot happen sends them after a permission that changes nothing. Runtime
capability overlays from the health document feed the same decision that
dispatches, so a session that cannot reach global input refuses identically
whatever the policy says.

### Foreground escalation

Foreground escalation is transactional. A backend captures the prior frontmost
application, activates the target and proves it is frontmost, and dispatches exactly
one action. It restores the prior application in guaranteed cleanup whenever the
backend has a completion boundary proving that restoration cannot redirect the action;
pre-dispatch exits always restore because no input is pending.
Activation is skipped when the target already holds the foreground. If activation
cannot be proved, nothing is posted and the action refuses with
`activationNotProved`. If a dispatch moves the real pointer, the pointer is
captured and restored around it. If restoration fails after dispatch, the result
keeps its `delivery`, `dispatchSuccess`, and verification evidence and reports
the failed hand-back separately.

Restoration is reported evidence, not a condition on the action's `success`.
The foreground rung promises proved activation and exactly one dispatch; action
verification still decides goal success. A session handed back immaculately says
nothing about whether the target acted on what was posted, so a foreground
dispatch of an action with no postcondition reports `dispatchSuccess: true`
alongside `success: false`.

The result reports that evidence under `foreground`: `priorApp`,
`priorAppProcessIdentifier`, `alreadyFrontmost`, `activationProved`, `restored`,
`pointerRestored` (`null` when the pointer never moved), and a `message`.

### The clipboard is not a delivery mechanism

Axon has no clipboard path. The system pasteboard is modelled as a forbidden
delivery capability so that a future fallback cannot introduce one by accident:
the planner refuses a clipboard candidate on sight, at every policy. No ladder in
any backend contains one.

### Platform support

The pixel rung is implemented where a target-bound mechanism can satisfy those
invariants, and refused honestly everywhere else. It is not universally
available, and a backend must not claim it before a live probe passes.

| platform | semantic | pixel | foreground |
| --- | --- | --- | --- |
| macOS | `AXPress`, `AXValue`, `AXScrollToVisible` | `CGEventPostToPid` against the target process, invariants proved after dispatch | Global `CGEvent`, transactional activate/dispatch/restore |
| Windows | UIA `InvokePattern`, `ValuePattern`, `ScrollItemPattern`, none of which call `SetFocus` | Client-coordinate window messages to a leaf HWND bound through UIA ancestry, for window classes a live probe has verified; every other class refuses `backgroundPixelUnsupported` by name | `SendInput` after proved activation for clicks, text, named keys, and chords; the target remains frontmost after dispatch because Windows exposes no input-consumption boundary, while pointer restoration is still attempted and reported |
| Linux | AT-SPI `Action.DoAction`, `EditableText.SetTextContents`, `Component.ScrollTo`, none of which take focus | `XSendEvent` to a window resolved from the target's own AT-SPI application, for toolkits a committed measurement recorded as acting on it: Chromium clicks, GTK 3 and Qt 6 keystrokes. Every other toolkit, and every version series nobody measured, refuses `backgroundPixelUnsupported` by name | `XTest` on an X11 session with an EWMH-capable window manager, transactional activate/dispatch/restore; withheld on every other session |

On Linux the pixel rung's availability is a fact about the target's toolkit, and
that fact is measured. `XSendEvent` against a window the backend resolved is the
only X11 mechanism with the rung's shape — XTest and virtual pointers are global
devices however narrowly aimed, and on Wayland libei has no window parameter at
all, which is why the `wayland` refusal is permanent. But every event
`XSendEvent` delivers carries `send_event`, the X server reports success as soon
as it accepts the request, and a toolkit is free to drop what arrives. Nothing on
the sending side can tell acceptance from silence, and no runtime pre-flight
exists: a probe that produces no observable effect proves nothing, and one that
produces an effect has already mutated the target.

`scripts/linux-toolkit-acceptance/` is therefore where that fact comes from. It
opens a window per toolkit, holds the focus in a decoy, parks the real pointer
clear of the target, delivers window-targeted events, and reads back whether the
target acted — with two controls, a real-pointer click and a focused keystroke,
without which a silent target cannot be told from a misaimed harness. Its first
run measured GTK 3, GTK 4, Qt 6, WebKitGTK, Electron and Firefox in a hermetic
Xvfb lane and again on a live X11 session, and the two lanes agree.

What it found is that the rung is real and narrow. Chromium acts on a background
click with the frontmost application and the real pointer provably unchanged, on
every engine generation measured. GTK 3, WebKitGTK and Qt act on background
keystrokes under the same conditions. GTK 4 receives neither. Qt also acts on a
click, but requests activation while doing so — the focus moved on the lane with
no window manager and was held only by focus-stealing prevention on the live one,
and an acceptance that survives only while a window manager declines to honour the
application is not a background delivery. Separately, a synthetic click is
honoured by GTK only while the real cursor is already inside the target window —
the reason hand experiments conclude otherwise — and arranging that is the
foreground rung by definition.

Chromium's keystrokes are the one row the harness records as accepted that is not
offered. Chromium routes background key events to a window only after a background
click has landed in it, and the harness measures its keyboard phase after its
click phase on the same window, so the row records that state rather than an
independent acceptance. Delivered to a window that has not been clicked, every key
event is dropped in silence — which from the sending side is indistinguishable
from delivery, and is exactly the shape of failure this whole apparatus exists to
refuse. The entry is withheld until the phases are measured independently.

A backend may therefore offer the pixel candidate only for a toolkit the harness
measured as accepting, keyed on the AT-SPI toolkit name and version the
application declares about itself. Inferring acceptance from `WM_CLASS` or from
loaded libraries is a guess wearing a probe's clothes. Everything else refuses
`backgroundPixelUnsupported` naming the toolkit that refused, including a version
series nobody measured.

The delivery variant is measured per toolkit and is not a detail. An event sent
with the mask matching it reaches whichever clients selected that event on the
destination window; an event sent with an empty mask reaches the client that
created the window whatever it selected. GTK 3 acts only on the second, Chromium
and Qt only on the first, and sending a toolkit the other one arrives as silence.

Binding a target is the other half. The pointer path resolves the window by
descending from the root to the window that owns the resolved element's point and
requiring it to be one of the target process's own managed top-level windows,
which settles ownership and occlusion in one question — that descent is the only
hit test this backend has, since AT-SPI offers no portable point-to-element
lookup. The keyboard path has no point to descend from, so it binds only while the
application has exactly one managed top-level window and refuses the ambiguity
otherwise. Both revalidate immediately before dispatch: the application still runs
as the process the plan bound, the window is still the one that owns the point,
its origin and size are unchanged, and the element still reports extents covering
the point. Afterwards the frontmost window, the X input focus and the real pointer
are all read back — the input focus separately from the frontmost window, because
they are different facts and Qt's click moved one of them while the other stood
still.

That key is only as precise as the toolkit chooses to be, and one entry is
coarser than the rest. Chromium reports itself as toolkit `Chromium` version
`1.0` — a constant carrying neither the engine version nor the application — so
an entry keyed on it authorizes the whole family and no narrower key exists to
move to. It is therefore held to a higher evidentiary bar: measured across three
engine generations rather than one, with the obligation to re-measure when the
family releases, because a Chromium that began filtering these events would be
undetectable by signature.

The same run also settles the rung's coordinate source. Each target reports its
own widget rectangles from inside the toolkit, and all four components are
compared against what AT-SPI publishes: GTK 3, Qt, WebKitGTK and Chromium agree,
exactly in every case but one, which sits four pixels out in x on both lanes.
GTK 4 reports the correct sizes at `(0, 0)` origins, so a GTK 4 target has no
usable coordinate source whatever the delivery mechanism does.

The foreground rung is not merely "global input". It is global input whose
backend can capture the foreground, activate the named target, and prove that
activation before dispatch. A backend that cannot provide those facts must not
offer the rung. Such a backend reports `noDeliveryCandidate` naming the missing
transaction, at either policy, because opting in cannot supply a faculty the
backend lacks.

Whether a backend can activate and prove the target is a fact about the running
session as much as about the build. The Linux backend offers the rung on an X11 session
with an EWMH-capable window manager and withholds it on a Wayland session, where
the compositor refuses synthetic input and the foreground cannot be read or set
even with XWayland running alongside. A mechanism that dispatches while its proof
quietly does not is the trap this contract exists to close, so the capability is
reported per session and the same answer decides both the health document and the
dispatch. Windows offers the rung because it can activate and prove the target. A live
Notepad control showed immediate hand-back redirecting a suffix of a successfully
inserted `SendInput` stream, while the identical already-frontmost dispatch landed
completely. Windows therefore withholds post-dispatch foreground restoration and
reports that fact rather than sacrificing delivery the caller explicitly permitted.

Restoration covers the pointer as well as the foreground. A mechanism that moves
the real cursor puts it back before the prior application returns, and reports
`pointerRestored`: `true` when it was put back, `false` when it could not be, and
null when the dispatch never moved it. An action that leaves either the window or
the cursor where it put them reports that fact and its reason while keeping both
its dispatch evidence and the success earned by verification.

## Transport and result envelopes

The daemon speaks JSON-RPC 2.0 over a local socket. Success responses use
`{"jsonrpc":"2.0","id":...,"result":{...}}`; failures use the JSON-RPC
`error` member. The MCP facade forwards the socket result object as MCP
`structuredContent`, accompanied by normalized text content and `isError`.

The `run` method has one intentionally named public wrapper: its socket result is
`{"batch": <run-result>}`. The MCP facade must therefore expose that same
`batch` key inside `structuredContent`. The unwrapped run result contains the
batch `success`, execution flags, and per-action `trace` described in
[`axn.md`](axn.md). Renaming or flattening `batch` is a breaking wire change.

## `.axn` files

All implementations read and write the versioned, human-editable format defined
in [`axn.md`](axn.md): arguments, ordered primitive actions, late-bound values,
`requires`, `expects`, execution flags, and trace semantics are shared.

The format is cross-platform; recordings are not. Version 2 `.axn` files address
elements by `{app, name}` and may retain native locator evidence for replay.
They contain native application identities, native locator vocabulary, and assumptions about a
particular interface. A recording against Finder on macOS was never expected to
replay against Explorer on Windows. Cross-platform workflows may be authored as
separate platform artifacts while still using the same parser, runner, and
result contract.

## Capability declaration and degradation

Every backend must make unavailable or restricted operations discoverable before
a client relies on them. Capability reporting distinguishes at least:

1. **Observe:** application/window enumeration, accessibility capture, internal
   retained-element caches, semantic naming, and change observation.
2. **Semantic actions:** invoke/action dispatch, readable and settable values,
   focus, and scrolling.
3. **Pointer and keyboard fallback:** synthetic pointer/keyboard input,
   screenshots, and hit testing.
4. **Recording:** Axon call-history serialization and, separately, global user
   input observation.

The declaration must say whether each operation is usable and explain platform,
permission, or session restrictions. Unsupported operations fail before dispatch
and identify the missing capability; they must not silently substitute a weaker
mechanism.

The status vocabulary is now defined once, as the `health-v1` document described
by `schema/health-v1.schema.json` and modelled in both implementations
(`AxonCore`'s `HealthStatus` and `axon-core::health`). It carries the complete
capability vocabulary — one entry per known capability, so "unusable here" stays
distinguishable from "older than your vocabulary" — alongside daemon, session,
and permission state, each degraded entry naming a stable kebab-case reason code
from the registry in `docs/embedding.md`. The document is what `status --json`
emits on every platform. Backends report capabilities through the same structure
rather than defining their own.

This allows honest degradation. For example, a Wayland backend may provide
AT-SPI capture, semantic actions, call-history serialization, and `save` while
reporting pointer synthesis, screenshots, and global user-input observation as
restricted or unavailable until the relevant portal or libei path is active.
A backend that cannot retain call history may also report `save` unavailable,
but Wayland's global-input restriction alone does not imply that limitation.

## Conformance

The shared contract will be encoded as implementation-neutral fixtures covering
tool schemas, strict `{app, name}` target decoding, locator filtering/scoring outcomes, result
envelopes, `.axn` parsing and traces, capability failures, and honest action
results. Both the Swift and Rust implementations must run those fixtures in
addition to backend-specific integration tests.

The status contract already works this way: `schema/fixtures/health/` holds the
healthy and degraded examples, and both implementations are tested against those
same files — round-tripping each one exactly, so a field either implementation
silently dropped is a test failure rather than a document a consumer never meant
to publish. No implementation may treat its
own incidental native behavior as a shared guarantee without first changing
this specification.