# axon-core fixtures

## The frozen Swift corpus

`swift-action-history-v2.yaml`, `swift-user-recording-v2.yaml`, and `swift-user-recording-v2.json`
were produced by the last Swift daemon (0.3.x), before it was deleted at 0.4.0. **They are never
regenerated.** Nothing that could regenerate them exists any more, and that is the point: they are
the `.axn` replay-compatibility guarantee for recordings people made with the Swift daemon. The
conformance tests in `tests/conformance.rs` parse and replay them, so a change that stops the Rust
daemon reading a Swift-made recording fails here.

If one of these tests fails, the fix is in the Rust codec or runner, never in the fixture.

`scripts/macos-toolkit-acceptance/live/axn125/` holds a Swift-made Calculator recording captured
from the production 0.3.6 daemon during the cutover qualification; it belongs to the same corpus.

## The Rust corpus

`rust-*` files are produced by the Rust recorder and history export and may be regenerated when
those change deliberately. `locator-cases.json` and `workflow.axn` are hand-written cases.
