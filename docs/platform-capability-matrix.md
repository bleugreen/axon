# Platform capability census

This is the contributor-facing census for the public v1 tool surface. [Cross-platform support](cross-platform.md) remains the shorter user-facing contract.

## Methodology

The source of truth for static advertisement is `Sources/AxonCore/ToolSurfaceSpec.swift`; `scripts/check-tool-surface --write` is the only supported way to regenerate `schema/tool-surface-v1.json`. **Implemented** means a facade has at least one real route. **Partial** means that route is advertised, while unsupported target forms, parameters, delivery rungs, permissions, or sessions refuse explicitly. **Not implemented** means the facade does not advertise the tool; a direct socket request must still return JSON-RPC `-32004` with capability-unavailable / not-implemented data rather than dispatching natively.

Static availability is not a claim that every runtime environment works. Permissions and session facts belong in `health-v1` and delivery refusals. A valid but deliberately declined delivery rung is a successful structured refusal; malformed input is `-32602`; a statically absent capability is `-32004`. This keeps schema evidence, source evidence, refusal evidence, and live session evidence distinct.

### Cell notation and evidence

- **I/A**: implemented and advertised. **P/A**: partial and advertised. **N/—**: not implemented and not advertised.
- **S** is the Swift daemon router and native executor: `Sources/AxonCore/CommandRouter.swift`, `Sources/AxonCore/AXPrimitiveActionExecutor.swift`.
- **M**, **W**, and **L** are the Rust routers/backends: `rust/axon-{mac,win,linux}/src/lib.rs` and `platform.rs`. Shared contracts live in `rust/axon-core/src/{backend,delivery,health,tool_surface}.rs`.
- For every **N/—** Rust cell, the platform router's excluded-tool test is refusal evidence: direct socket bypass returns `-32004`, reason `not-implemented`, and performs zero backend dispatch. Swift has no statically absent public tools.
- For **P/A**, router/backend tests establish explicit refusal before unsafe native dispatch. Delivery restrictions use stable delivery reasons such as `wayland-restricted`, `no-graphical-session`, or target/session-specific unavailability. The detailed live and hermetic evidence ledger is [Cross-platform internals](cross-platform-internals.md).

## Exhaustive 16 × 4 census

| tool (socket method) | Swift daemon | Rust macOS | Windows | Linux |
| --- | --- | --- | --- | --- |
| `look` (`look`) | **I/A S** AX snapshot, screenshot, OCR | **P/A M** AX capture; OCR/screen-text and some observation forms are bounded | **P/A W** UIA capture and window image; session/elevation gates | **P/A L** AT-SPI capture; screenshots are X11-only, Wayland refused; XWayland remains Wayland-governed |
| `navigate` (`navigate`) | **I/A S** browser Application Scripting | **N/— M** | **N/— W** | **N/— L** |
| `windows` (`windows`) | **I/A S** browser Application Scripting plus AX cross-check | **N/— M** | **N/— W** | **N/— L** |
| `tabs` (`tabs`) | **I/A S** browser Application Scripting | **N/— M** | **N/— W** | **N/— L** |
| `find` (`find`) | **I/A S** fresh AX locator resolution | **I/A M** shared locator over AX capture | **I/A W** shared locator over UIA capture | **I/A L** shared locator over AT-SPI capture |
| `wait_for_value` (`wait_for_value`) | **I/A S** bounded AX polling | **I/A M** bounded AX polling | **N/— W** | **N/— L** |
| `wait_for_stability` (`wait_for_stability`) | **I/A S** bounded observation polling | **I/A M** bounded AX polling | **N/— W** | **N/— L** |
| `permit` (`permit`) | **I/A S** macOS Accessibility prompt | **N/— M** status/remediation only | **N/— W** status/remediation only | **N/— L** status/remediation only |
| `run` (`run`) | **I/A S** .axn runner | **I/A M** shared .axn runner | **I/A W** shared .axn runner | **I/A L** shared .axn runner |
| `save` (`save`) | **I/A S** action-history serialization | **N/— M** | **N/— W** | **N/— L** |
| `click` (`click`) | **I/A S** semantic, point, and text-location paths | **P/A M** semantic AXPress/text path; unsupported target forms refuse | **P/A W** UIA/pixel ladder; session, elevation, and control-family limits refuse | **P/A L** semantic/pixel on measured X11 paths; Wayland and unsafe toolkit paths refuse |
| `type` (`type`) | **I/A S** AXValue | **I/A M** AXValue | **I/A W** UIA ValuePattern | **I/A L** AT-SPI EditableText |
| `keyboard` (`keyboard`) | **P/A S** Core Graphics; permission/foreground gates | **P/A M** bounded foreground Core Graphics ladder | **P/A W** bounded foreground/global-input ladder; interactive-session and target proof required | **P/A L** measured X11/toolkit ladder; Chromium and multi-window limits; all Wayland/XWayland refused |
| `scroll` (`scroll`) | **I/A S** semantic scroll and native input paths | **P/A M** AXScrollToVisible only; directional/amount forms refuse | **P/A W** UIA ScrollPattern with bounded fallback | **N/— L** AT-SPI has no portable delta-scroll operation |
| `drag` (`drag`) | **I/A S** native pointer gesture with restoration accounting | **N/— M** | **N/— W** | **N/— L** |
| `invoke` (`invoke`) | **I/A S** named AX action | **I/A M** named AX action | **P/A W** UIA InvokePattern only | **I/A L** named AT-SPI action |

## Linux session distinctions

X11 is eligible for the measured XTest pixel and keyboard ladders only when an interactive graphical session, EWMH window identity, toolkit behavior, and target proof all agree. GNOME/Mutter Wayland supports semantic AT-SPI access, but global input and screenshots are refused; portal presence is not proof of unattended authorization. KWin and wlroots remain experimental because there is no live evidence. XWayland applications remain subject to the enclosing Wayland session's safety rules: semantic AT-SPI access may work, but Axon does not use XTest because it cannot prove or restore focus across native Wayland windows. A session with accessibility disabled can hide Chromium-family applications entirely; that is a runtime health fact, not a static tool-list change.

## Evidence maintenance

A cell is promoted by a named live lane or dated probe, never by API availability alone. The macOS, Windows, and Linux live loops and hermetic tests are catalogued in [Cross-platform internals](cross-platform-internals.md). Changes to a platform router or backend must reconcile five views: this census, the Swift specification, the generated schema, router refusal tests, and live evidence. If any disagree, the advertised claim is wrong.

## Roadmap

### Priority 0: shared AXN-125 convergence

1. Port observation/change tracking and waits into Rust shared core, then enable Windows/Linux waits only after their event or polling adapters meet that contract.
2. Port action history, serialization, recording, and global-input observation into shared core so `save` is not implemented three times.
3. Centralize strict canonical parameter/target decoding and result/refusal envelopes.

The macOS cutover retains Swift-only browser scripting, permission prompting, and debug-session orchestration unless a separate product decision moves them.

### Priority 1: high-value native fills

1. Add Linux Wayland screenshots through the desktop portal with explicit authorization lifecycle and `portal-authorization-required` health/refusal evidence.
2. Add cross-platform `look(screenText:true)` OCR with one response shape.
3. Implement measured Linux semantic or compositor-safe scrolling; only then restore its availability flag.
4. Design drag as its own capability with interruption, restoration, and postcondition semantics.

### Priority 2: bounded parity

1. Complete transactional foreground delivery where activation, proof, dispatch, and restoration can all be demonstrated.
2. Expand target-bound pointer/keyboard acceptance only from live toolkit/control evidence.
3. Fill Rust macOS point-target and wheel-scroll forms only after native delivery is proven.

### Intentionally platform-absent

Swift browser `navigate`/`windows`/`tabs` remain macOS Application Scripting features. `permit` remains a macOS interactive prompt; other platforms use health and installation remediation. Swift debug-session methods remain app/editor orchestration rather than public cross-platform tools. Unsafe Wayland global input remains absent unless a compositor-authorized protocol can prove target identity and restoration.
