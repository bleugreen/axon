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
| `look` (`look`) | **I/A S** AX snapshot, screenshot, OCR | **P/A M** AX capture; OCR/screen-text and some observation forms are bounded [P-M-LOOK] | **P/A W** UIA capture and window image; session/elevation gates [P-W-LOOK] | **P/A L** AT-SPI capture; screenshots are X11-only, Wayland refused; XWayland remains Wayland-governed [P-L-LOOK] |
| `navigate` (`navigate`) | **I/A S** browser Application Scripting | **N/— M** [N-M] | **N/— W** [N-W] | **N/— L** [N-L] |
| `windows` (`windows`) | **I/A S** browser Application Scripting plus AX cross-check | **N/— M** [N-M] | **N/— W** [N-W] | **N/— L** [N-L] |
| `tabs` (`tabs`) | **I/A S** browser Application Scripting | **N/— M** [N-M] | **N/— W** [N-W] | **N/— L** [N-L] |
| `find` (`find`) | **I/A S** fresh AX locator resolution | **I/A M** shared locator over AX capture | **I/A W** shared locator over UIA capture | **I/A L** shared locator over AT-SPI capture |
| `wait_for_value` (`wait_for_value`) | **I/A S** bounded AX polling | **I/A M** bounded AX polling | **N/— W** [N-W] | **N/— L** [N-L] |
| `wait_for_stability` (`wait_for_stability`) | **I/A S** bounded observation polling | **I/A M** bounded AX polling | **N/— W** [N-W] | **N/— L** [N-L] |
| `permit` (`permit`) | **I/A S** macOS Accessibility prompt | **N/— M** status/remediation only [N-M] | **N/— W** status/remediation only [N-W] | **N/— L** status/remediation only [N-L] |
| `run` (`run`) | **I/A S** .axn runner | **I/A M** shared .axn runner | **I/A W** shared .axn runner | **I/A L** shared .axn runner |
| `save` (`save`) | **I/A S** action-history serialization | **N/— M** [N-M] | **N/— W** [N-W] | **N/— L** [N-L] |
| `click` (`click`) | **I/A S** semantic, point, and text-location paths | **P/A M** semantic AXPress/text path; unsupported target forms refuse [P-M-CLICK] | **P/A W** UIA/pixel ladder; session, elevation, and control-family limits refuse [P-W-CLICK] | **P/A L** semantic/pixel on measured X11 paths; Wayland and unsafe toolkit paths refuse [P-L-INPUT] |
| `type` (`type`) | **I/A S** AXValue | **I/A M** AXValue | **I/A W** UIA ValuePattern | **I/A L** AT-SPI EditableText |
| `keyboard` (`keyboard`) | **P/A S** Core Graphics; permission/foreground gates [P-S-KEY] | **P/A M** bounded foreground Core Graphics ladder [P-M-KEY] | **P/A W** bounded foreground/global-input ladder; interactive-session and target proof required [P-W-KEY] | **P/A L** measured X11/toolkit ladder; Chromium and multi-window limits; all Wayland/XWayland refused [P-L-INPUT] |
| `scroll` (`scroll`) | **I/A S** semantic scroll and native input paths | **P/A M** AXScrollToVisible only; directional/amount forms refuse [P-M-SCROLL] | **P/A W** UIA ScrollPattern with bounded fallback [P-W-SCROLL] | **N/— L** AT-SPI has no portable delta-scroll operation [N-L] |
| `drag` (`drag`) | **I/A S** native pointer gesture with restoration accounting | **N/— M** [N-M] | **N/— W** [N-W] | **N/— L** [N-L] |
| `invoke` (`invoke`) | **I/A S** named AX action | **I/A M** named AX action | **P/A W** UIA InvokePattern only [P-W-INVOKE] | **I/A L** named AT-SPI action |

### Keyed refusal evidence

Locations below are stable source files rather than line numbers. A “success refusal” is JSON-RPC success whose action result has `success:false`, `strategy:"refused"`, and `dispatchSuccess:false`; it is distinct from a transport error. Runtime health may remove a delivery candidate, but never changes the static advertised tool list.

| key | named evidence and wire result | router/backend location and dispatch boundary | runtime health/session distinction |
| --- | --- | --- | --- |
| P-S-KEY | `DeliveryRoutingTests` and `DeliveryContractTests` cover policy refusal; success refusal reasons are delivery-policy/capability reasons, while malformed input is `-32602`. | `Sources/AxonCore/CommandRouter.swift` → `AXPrimitiveActionExecutor.swift`; refusal is selected before Core Graphics dispatch. | Accessibility trust and a provable foreground application are runtime gates, reported through `health-v1`, not static absence. |
| P-M-LOOK | `screen_text_and_unsupported_click_forms_refuse_before_dispatch`: `look(screenText:true)` is `-32004`, capability `screenText`; reason is `not-implemented`. | `rust/axon-mac/src/lib.rs` (`Router::look`); `rust/axon-mac/src/platform.rs` (`MacBackend`). The enumeration backend proves the refusal needs no native capture. | Screen Recording and Accessibility are separate health facts; `screenshot_capability_requires_both_native_permissions` proves screenshot availability is permission-dependent. |
| P-M-CLICK | `screen_text_and_unsupported_click_forms_refuse_before_dispatch`: point/coordinate targets are `-32004`, capability `point-target`, reason `not-implemented`. | `rust/axon-mac/src/lib.rs` (`select_and_deliver_click`); the enumeration backend records no point dispatch. | Foreground proof and Accessibility trust govern delivery, not advertisement. |
| P-M-KEY | Router delivery-ladder tests use success refusals with `dispatchSuccess:false`; missing foreground/global-input capability produces `noDeliveryCandidate`. | `rust/axon-mac/src/lib.rs` (`keyboard_ladder`, `keyboard_intent`); `rust/axon-mac/src/platform.rs` owns Core Graphics dispatch. | Accessibility and foreground/restoration proof are runtime delivery facts. |
| P-M-SCROLL | `canonical_scroll_defaults_and_unsupported_forms_refuse_before_dispatch`: directional, amount, point, and text-location forms return `-32004`, capability `directional-scroll`/target capability, reason `not-implemented`. | `rust/axon-mac/src/lib.rs` (`Router::request` scroll route); the enumeration backend proves zero scroll dispatch. | AX availability is runtime health; it does not make directional scrolling statically present. |
| P-W-LOOK | `look_defaults_to_screenshot_and_explicit_false_opts_out` and `look_screenshot_and_text_share_one_capture_and_use_canonical_keys` prove bounded capture behavior. Unsupported capture is `-32004`/`not-implemented`; unavailable desktop capture is reported as runtime unavailability. | `rust/axon-win/src/lib.rs` (`Router::look`); `rust/axon-win/src/platform.rs` and `capture.rs`. The tests assert one capture, preventing fallback dispatch. | Interactive graphical session, elevation parity, and desktop visibility are `health-v1` facts. |
| P-W-CLICK | `click_rejects_mismatched_immediate_hit_before_send_input` and `ocr_click_refuses_dispatch_when_fresh_hit_test_fails`: success refusal with target-verification reason and no `SendInput`. | `rust/axon-win/src/lib.rs` (`select_and_deliver_click`); `rust/axon-win/src/platform.rs`/`pixel.rs`. | Session 0, non-graphical sessions, elevation mismatch, and restoration failure remove delivery rungs. |
| P-W-KEY | `keyboard_aimed_at_an_application_that_is_not_running_refuses_rather_than_typing_elsewhere`: success refusal, `dispatchSuccess:false`; malformed keyboard input is `-32602`. | `rust/axon-win/src/lib.rs` (`keyboard_ladder`, `keyboard_intent`); `platform.rs` owns native input. | `not-interactive-session` and `no-graphical-session` are runtime health reasons; target and foreground proof remain required. |
| P-W-SCROLL | `delta_scroll_reports_position_verification_and_goal_success` proves the bounded ScrollPattern route; unsupported targets/capabilities are `-32004`/`not-implemented` before native fallback. | `rust/axon-win/src/lib.rs` (`scroll_windows`); `rust/axon-win/src/platform.rs` backend scroll. | UIA pattern availability and session/elevation reachability are runtime facts. |
| P-W-INVOKE | `unsupported_invoke_names_refuse_before_native_dispatch`: `-32004`, capability `named-action`, reason `not-implemented`; capture list remains empty. | `rust/axon-win/src/lib.rs` invoke route; `rust/axon-win/src/platform.rs` InvokePattern backend. | A supported name can still fail runtime target/session health without changing advertisement. |
| P-L-LOOK | `look_refuses_all_process_listing_instead_of_ignoring_it` and `look_defaults_to_honest_screenshot_absence_and_opt_out_omits_the_claim` prove explicit bounded results. Unsupported listing is `-32004`/`not-implemented`; screenshot absence is a named runtime result. | `rust/axon-linux/src/lib.rs` (`Router::look`); `rust/axon-linux/src/platform.rs`/`x11.rs`. | X11 screenshot eligibility differs from Wayland/XWayland; `wayland-restricted`, `no-graphical-session`, and `accessibility-disabled` are health/session reasons. |
| P-L-INPUT | `click_refuses_without_a_backend_call_and_names_the_missing_mechanism` and `keyboard_refuses_without_a_backend_call`: success refusal, reason `noDeliveryCandidate`, capability `globalInput`, `dispatchSuccess:false`; click counter remains zero. `wayland_withholds_global_input_however_complete_the_x11_session_looks` proves XWayland does not bypass the gate. | `rust/axon-linux/src/lib.rs` delivery selection; `rust/axon-linux/src/platform.rs`, `pixel.rs`, and `x11.rs` own native dispatch. | `reports_wayland_restrictions_explicitly` names `wayland-restricted`; no graphical session, no window manager, no XTEST, toolkit acceptance, target binding, and restoration are separate runtime facts. |
| N-M | `excluded_tools_are_capability_errors_before_dispatch` covers `navigate`, `windows`, `tabs`, `permit`, `save`, and `drag`: `-32004`, capability-specific data, reason `not-implemented`. | `rust/axon-mac/src/lib.rs` `EXCLUDED` guard runs before the method match; no backend route exists. Backend stubs in `platform.rs` also return capability errors rather than native dispatch. | Runtime health is irrelevant: these tools are statically absent even in a healthy session. |
| N-W | `excluded_tools_have_structured_errors_before_backend_dispatch` covers `navigate`, `windows`, `tabs`, `wait_for_value`, `wait_for_stability`, `permit`, `save`, and `drag`: `-32004`, capability-specific data, reason `not-implemented`; `capture_queries` remains empty. | `rust/axon-win/src/lib.rs` `EXCLUDED` guard precedes validation, capture, and backend routing. | Runtime health is irrelevant: these tools are statically absent. |
| N-L | `unimplemented_tools_have_structured_errors_before_backend_dispatch` covers `navigate`, `windows`, `tabs`, `wait_for_value`, `wait_for_stability`, `permit`, `save`, `drag`, and `scroll`: `-32004`, capability-specific data, reason `not-implemented`; scroll dispatch count remains zero. | `rust/axon-linux/src/lib.rs` `EXCLUDED` guard precedes validation and backend routing. | Runtime health is irrelevant: these tools are statically absent. |

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

1. Complete foreground delivery per the AXN-165 contract: prove activation, dispatch once, and report `session.restored` honestly as a best-effort fact rather than a success gate.
2. Expand target-bound pointer/keyboard acceptance only from live toolkit/control evidence.
3. Fill Rust macOS point-target and wheel-scroll forms only after native delivery is proven.

### Intentionally platform-absent

Swift browser `navigate`/`windows`/`tabs` remain macOS Application Scripting features. `permit` remains a macOS interactive prompt; other platforms use health and installation remediation. Swift debug-session methods remain app/editor orchestration rather than public cross-platform tools. Unsafe Wayland global input remains absent unless a compositor-authorized protocol can prove target identity and restoration.
