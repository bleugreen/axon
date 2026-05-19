# Update Check Reads A Stale Source And Can't Retry

Status: Design. Filed 2026-05-18.

## Context

After 0.1.5 shipped (GitHub release created, tap cask published, both
verified correct), the running 0.1.4 app's menubar "Check for Updates..."
reported "Up to Date (0.1.4)" and offered no way to re-check. This is two
compounding defects in the in-app updater, not a release-pipeline failure.

## What's Broken (evidence)

**1. The checker reads the slowest, most-cached source.**
`ReleaseUpdateChecker` (`Sources/AxonCore/ReleaseUpdateChecker.swift:31`)
fetches `https://raw.githubusercontent.com/bleugreen/homebrew-tap/main/Casks/axon.rb`
via `URLSession.shared` using the default `.useProtocolCachePolicy`
(`defaultFetch`, line 73-83) with no cache-busting. That endpoint returns
`cache-control: max-age=300` (Fastly, ~5-minute edge cache; observed
`expires` ≈ 5 min out, `etag` present). The tap cask is also the *last*
artifact `release.yml` publishes — the GitHub release is created first
(step "Publish GitHub release"), the tap commit happens after (step
"Publish Homebrew cask"). So the update path reads the artifact that is
both updated last and cached hardest. A check inside the post-release
window reads the previous version and concludes "up to date."

The strongly-consistent source is unused: `GET /repos/bleugreen/axon/releases/latest`
reflected `v0.1.5` immediately (verified at release time), with no CDN
body cache in the way.

**2. `.upToDate` is a terminal menu state with no retry.**
`addUpdateItem` (`Sources/AxonApp/AppDelegate.swift:122-138`) gives
`.failed` a "Check Again" action item but `.upToDate` only a disabled
label. `updateMenuState` starts `.idle` and is only ever moved by the
user-initiated `checkForUpdates()` (`AppDelegate.swift:151`); there is no
periodic or background re-check (the 2s `refreshTimer` only refreshes
status appearance, not updates). Once a session lands on
`.upToDate(0.1.4)`, the only recovery is relaunching the app to reset to
`.idle`.

Either defect alone yields the reported symptom. Together they make a
single stale read sticky and unrecoverable for the rest of the app
session — which is what the user hit.

## Why It Matters

The updater is the one mechanism that carries existing installs forward.
A version check that reports "up to date" immediately after a release —
and then refuses to be asked again — trains the user to distrust it and
fall back to `brew upgrade` by hand, which defeats the point of shipping
an in-app updater at all.

## Desired Shape

**Check the authoritative source, not the tap mirror.** Resolve "latest"
from `GET /repos/bleugreen/axon/releases/latest` (or the releases list),
which is the first thing CI publishes and is strongly consistent. The tap
cask can remain the *install* mechanism for `performAvailableUpdate`'s
`brew` path; it should not be the *detection* source.

**Defeat the response cache on an explicit check.** A user clicking
"Check for Updates..." is asking for a fresh answer. The request should
use `.reloadIgnoringLocalAndRemoteCacheData` (and/or a cache-busting
query) so a manual check never returns a CDN- or `URLCache`-stale body,
regardless of which endpoint is used.

**`.upToDate` must offer a re-check.** Give `.upToDate` the same "Check
Again" affordance `.failed` already has, so a stale or mistimed check is
recoverable without relaunching. Showing the last-checked version is
fine; making it a dead end is not.

## Non-Goals

- Not a release-pipeline change. 0.1.5's release, notarized asset, and
  tap cask were all published correctly; `release.yml` is not at fault.
- No background/auto-update polling in this issue. The fix is to make the
  *explicit* check correct and retryable; a periodic check is a separate
  question.
- No change to the `brew`-based install path in `performAvailableUpdate`.

## Next Steps

- Switch `ReleaseUpdateChecker` detection to the GitHub releases API;
  keep version-compare logic (`isVersion(_:newerThan:)`) as-is.
- Set a no-cache policy on the explicit-check request path.
- Add a "Check Again" item to the `.upToDate` case in `addUpdateItem`.
- Decide separately whether a periodic check is warranted.
