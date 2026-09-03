# Recorded socket responses

What a live Axon daemon actually answered over its JSON-RPC socket, kept here rather than inside
one SDK's tests because every SDK's fake daemon replays them. A recording only one language holds
is a recording the other can drift away from without anything noticing.

## The rule these exist to enforce

**A fake daemon replays recordings of the socket, never a fixture from `schema/fixtures/`** unless
that fixture is known to describe the socket rather than a facade. `schema/fixtures/` documents the
contracts the CLI and MCP surfaces present; several of them are shaped by the facade that
synthesizes them, not by the daemon:

- `health` over the socket returns the flat `DaemonReport` from `Sources/AxonCore/HealthStatus.swift`.
  The nested `health-v1` document is what `axon status --json` synthesizes, including for a daemon
  that never answered at all.
- `look(since:)` returns `{changed, reason, snapshotId, currentSnapshotId, previous, current}`, not
  the `{unchanged}` / `{diff}` shape under `schema/fixtures/`.
- An action result nests the delivery contract's fields under `action`, rather than carrying
  `delivery`, `dispatchSuccess`, and `refusal` at the top level as `schema/fixtures/delivery/`
  states them.

A fake that replays a facade document agrees with a wrong client instead of failing it. The
TypeScript SDK passed twenty-nine green tests that way while unable to connect to a real daemon.

## What is here

All recorded from a macOS 0.3.6 daemon against Calculator, under the default `backgroundOnly`
delivery policy.

| File | Call |
| --- | --- |
| `socket-health-macos.json` | `health` on a daemon with both permissions granted |
| `socket-look-calculator-macos.json` | `look` with `childDepth: 0`, so windows without their subtrees |
| `socket-look-since-calculator-macos.json` | `look(since:)` after two keypresses — `changed: false`, because the check reads window signatures rather than values |
| `socket-click-calculator-macos.json` | a semantic `click` the accessibility layer verified |
| `socket-click-unverified-macos.json` | a screen-point `click` delivered as background pixel input: `success: false` with no refusal |
| `socket-save-calculator-macos.json` | `save` exporting a history session as a version-2 `.axn` |

## Adding one

Record it from a running daemon and commit the result object verbatim — the JSON-RPC `result`, not
the envelope around it. Do not hand-edit a recording into the shape a test wants; a test that needs
a shape no daemon produces is a test asserting the wrong thing.
