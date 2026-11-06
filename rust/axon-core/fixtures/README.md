# axon-core fixtures

## The frozen Swift corpus

`swift-action-history-v2.yaml`, `swift-user-recording-v2.yaml`, and `swift-user-recording-v2.json`
were produced by the last Swift daemon (0.3.x), before it was deleted at 0.4.0. **They are never
regenerated.** Nothing that could regenerate them exists any more, and that is the point: they are
the `.axn` replay-compatibility guarantee for recordings people made with the Swift daemon. The
conformance tests in `tests/conformance.rs` parse and replay them, so a change that stops the Rust
daemon reading a Swift-made recording fails here.

If one of these tests fails, the fix is in the Rust codec or runner, never in the fixture.

`swift-calculator-recording-0.3.6.axn` belongs to the same corpus but has a different origin: the
others were written from the Swift schema, while this one is a real recording, four `invoke` steps
on Calculator saved by the production 0.3.6 daemon during the cutover qualification (run
`carry-20261104-162953`). Its conformance test resolves it against an axon-mac capture of the same
window, `scripts/macos-toolkit-acceptance/live/responses/look-full.json`, so it pins what the
field-by-field correspondence between a Swift locator and an axon-mac node has to keep true (see
"Reading `description`" in `docs/axn.md`).

## The Rust corpus

`rust-*` files are produced by the Rust recorder and history export and may be regenerated when
those change deliberately. `locator-cases.json` and `workflow.axn` are hand-written cases.
