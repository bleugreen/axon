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

- A **snapshot handle** identifies an element retained from a particular
  observation. It is convenient and precise within that snapshot's lifetime,
  but is not durable identity and must fail when stale.
- A **locator object** combines an application identity with semantic criteria.
  It is the durable target used for replay.
- A **point** uses screen, window, or screenshot coordinates. It is an explicit
  escape hatch with no element identity or occlusion guarantee.
- A **text location** resolves visible text from accessibility data or screenshot
  text into a pointer location. It is part of the current pointer-target contract
  even though the three fundamental target mechanisms are handle, locator, and
  point.

Tools accept only the target kinds declared by the machine-readable surface.
Semantic targets must be re-resolved and, for pointer dispatch, hit-tested
immediately before dispatch. Raw points remain explicitly unverified.

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
- Linux uses AT-SPI roles and action names.

Axon does **not** define a normalized cross-platform role or action vocabulary.
Normalization would hide distinctions exposed by each accessibility stack and
create a second, lossy semantic model. A locator is therefore portable as a data
shape, not necessarily as an artifact containing native terms.

## Resolution and honest results

Locator resolution returns exactly one status: `unique`, `ambiguous`, or
`missing`. It also returns a named confidence level: `none`, `low`, `medium`, or
`high`. Ambiguous and missing resolutions do not dispatch an action. Candidate
summaries and reasons should make the outcome diagnosable; a backend must not
silently pick the first native element returned by its API.

Candidates are ranked by semantic score before the frame tie-breaker. The frame
tie-breaker occupies only the sub-semantic part of the score and therefore cannot
overcome a one-point semantic difference. A result is `unique` only when exactly
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

The format is cross-platform; recordings are not. `.axn` files contain native
application identities, native locator vocabulary, and assumptions about a
particular interface. A recording against Finder on macOS was never expected to
replay against Explorer on Windows. Cross-platform workflows may be authored as
separate platform artifacts while still using the same parser, runner, and
result contract.

## Capability declaration and degradation

Every backend must make unavailable or restricted operations discoverable before
a client relies on them. Capability reporting distinguishes at least:

1. **Observe:** application/window enumeration, accessibility capture, retained
   handles, and change observation.
2. **Semantic actions:** invoke/action dispatch, readable and settable values,
   focus, and scrolling.
3. **Pointer and keyboard fallback:** synthetic pointer/keyboard input,
   screenshots, and hit testing.
4. **Recording:** Axon call-history serialization and, separately, global user
   input observation.

The declaration must say whether each operation is usable and explain platform,
permission, or session restrictions. Unsupported operations fail before dispatch
and identify the missing capability; they must not silently substitute a weaker
mechanism. The status vocabulary, reason codes, error shape, and discovery tool
are not defined yet. They must be added once to the canonical tool surface before
backend implementations expose them.

This allows honest degradation. For example, a Wayland backend may provide
AT-SPI capture, semantic actions, call-history serialization, and `save` while
reporting pointer synthesis, screenshots, and global user-input observation as
restricted or unavailable until the relevant portal or libei path is active.
A backend that cannot retain call history may also report `save` unavailable,
but Wayland's global-input restriction alone does not imply that limitation.

## Conformance

The shared contract will be encoded as implementation-neutral fixtures covering
tool schemas, target decoding, locator filtering/scoring outcomes, result
envelopes, `.axn` parsing and traces, capability failures, and honest action
results. Both the Swift and Rust implementations must run those fixtures in
addition to backend-specific integration tests. No implementation may treat its
own incidental native behavior as a shared guarantee without first changing
this specification.