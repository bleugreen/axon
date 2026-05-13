# Packaging and Installability

## Context

Axon is usable from source, but the product path should be a real Mac install, not remembered Swiftly commands. The target install shape is:

```sh
brew install --cask bleugreen/tap/axon
axon
```

`Axon.app` should own the running socket service and macOS trust identity. The bundled `axon` CLI should be the control plane and MCP entrypoint.

The LaunchAgent installer remains useful for daemon experiments, but it is no longer the product center.

## Desired Direction

- Build `Axon.app` as a signed, notarizable menu bar service.
- Bundle `axon` inside the app and let the Homebrew cask link it onto `PATH`.
- Use `com.bleugreen.axon` as the stable Accessibility trust identity.
- Make no-arg `axon` launch the app, check socket health, request Accessibility, and print MCP config.
- Publish a release zip that the cask can install directly.
- Add a smoke command that verifies app health, Accessibility trust, MCP facade startup, and screenshot capture separately.

## Non-Goals

- Do not hide macOS permission failures behind retries. Permission state should be reported directly.
- Do not create a second daemon or runner layer for packaging convenience.
- Do not make Homebrew compile Swift from source for normal installs. Releases should be prebuilt app zips.

## Next Steps

- Add release automation around `scripts/package-app`.
- Publish `Axon-<version>.zip` on GitHub releases.
- Create `bleugreen/homebrew-tap` with the generated `axon` cask.
- Add `axon check-local` for app, MCP facade, and screenshot smoke checks.
- Decide whether Codex config mutation should be a helper command or just precise documentation.
