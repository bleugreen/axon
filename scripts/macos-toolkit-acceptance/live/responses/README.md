# Recorded Rust macOS MCP responses

These request/response pairs are the captures attached to
[axn/258](cairn://p/axn/258), captured by the cross-platform thread on
bgsrv-mac on 2026-11-04 with notarized 0.4.0 candidate commit 9ec2e946.
They are unedited apart from pretty-printing. The original capture already
replaced image data and mirrored text content with length notes. The PNG
filter checks transport metadata and nonempty data, not image decoding.

These are individual captures, not one successful transcript.
`invoke-clear-after-full.json` is the real missing-name response after a
child page (axn/257); the directly-after-full capture dispatches successfully
but has no declared postcondition (axn/228). Tests must reject the former
for dispatch and accept the latter without asserting top-level semantic success.

Run `python3 scripts/test-macos-live-filters.py` with jq installed. It imports
the same `probe.jq` used by the macOS live workflow and exercises diagnostics,
extractions, positive and negative predicates, and a mutation restoring the
old Swift tree path. Workflow simulations assemble these responses to test
request ordering and diagnostics; they do not prove desktop behavior.
