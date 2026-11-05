# axn/125 bench: the Rust-main Axon.app carrying production's grants

This directory holds the evidence from `scripts/macos-cutover-qualification` on bgsrv-mac. Each
run answers one question: whether the notarized 0.4.0 `Axon.app` can carry the 0.3.6
install's Accessibility and Screen Recording grants. In 0.4.0 the main executable is the Rust
daemon, and both versions share the identity `com.bleugreen.axon` under team `JBS95V8M7P`.
The carry must happen with no prompt and no click. A Results section is added here once
the cross-platform thread has run the driver.

## Phases

| Phase | What it changes | Gates |
| --- | --- | --- |
| `carry` (Phase A) | Nothing of production's. It loads the candidate as `dev.axon.qual125.daemon` and `dev.axon.qual125.menu` on `/tmp/axon-qual125.sock`, from plists in the run directory, and ends by rehearsing Phase B's rollback. | Phase B |
| `rollback-rehearsal` | Phase A step 8 alone, bracketed by TCC dumps | nothing |
| `upgrade` (Phase B) | The real `dev.axon.daemon` registration. It installs the candidate at `~/.local/lib/axon/0.4.0/Axon.app` and runs its `daemon install`. On any failed hard gate it rolls back to 0.3.6 with no hands. | leaves the bench on 0.4.0 |

Phase B starts only when two things hold. First, `runs.jsonl` must hold a non-dry-run `carry`
at the same `--sha` with no failed verdict and a passing `5-carry`. Second, the rollback copy
verified in Phase A must still match production. It also needs either `--yes` or a typed
`upgrade` confirmation, because from step B3 until the Rust daemon is ready the thread has no
look/click bridge. On a failure, the bridge stays down until the rollback finishes. Run it only in a
window the operator approved.

## Running it

The thread stages the driver and the candidate into `/tmp` on bgsrv-mac, copies them into
`~/AxonBench/axn125` with `ditto`, and runs the driver over ssh as `dev` with a terminal for its
prompts:

```sh
cd ~/AxonBench/axn125
./macos-cutover-qualification --self-test
./macos-cutover-qualification --phase carry --candidate ./Axon.app --sha <sha> --dry-run
./macos-cutover-qualification --phase carry --candidate ./Axon.app --sha <sha>
# later, in the operator's window:
./macos-cutover-qualification --phase upgrade --candidate ./Axon.app --sha <sha>
```

`--dry-run` prints every command and socket call and runs none. It walks both of Phase B's
branches, so the rollback commands are printed beside the pass path. Its transcript is kept, but
Phase B never counts it.

To replay `rust/axon-core/fixtures/swift-user-recording-v2.yaml`, stage it beside the driver. That
fixture targets an app called `Example`, which is not on the bench, so the step is recorded as
skipped.

The driver needs only ssh and the HID hand tool (`~/AxonBench/hand`). Whenever a step needs
hands or eyes, it stops and asks. For eyes, the thread reads UserNotificationCenter and
CoreServicesUIAgent with a `look` over the production socket before and after each phase, so any
prompt that appears is attributed to a window of time. The desktop-automation bridge is no longer
installed on bgsrv-mac. The driver dismisses nothing on production's behalf. It sends
production only `health`, `look`, `invoke`, and `save`. It never sends `type`, `keyboard`, or
keyboard text, because the 0.3.6 Swift daemon crashes on keyboard text (axn/215).

Exit status: 0 when every verdict passed, 1 on any failure or abort, 3 when the only problems
are gaps (things that could not be measured, such as an unreadable system TCC database or tccd
log).

## What lands here

| Path | What it is |
| --- | --- |
| `runs.jsonl` | One line per run: phase, sha, run directory, passed and failed verdicts, gaps, exit status. Phase B reads it. |
| `rollback-verified.json` | The rollback copy Phase A verified: path, version, designated requirement, and main-executable SHA-256 |
| `runs/<phase>-<stamp>/transcript.jsonl` | The run, one JSON object per step; verdicts read `pass`, `FAIL`, `informational`, `gap`, or `dry-run` |
| `runs/.../commands.log` | Every subprocess and socket call, with its exit or JSON-RPC error code |
| `runs/.../codesign-candidate.txt`, `codesign-production.txt` | `codesign -dvvv`, `codesign -d -r-` on the main executable, entitlements (the menu's must be empty), `spctl -a -t exec -vv`, `xcrun stapler validate` |
| `runs/.../tcc-*.tsv` | User and system `TCC.db` `access` rows, with `hex(csreq)` as the last column |
| `runs/.../tcc-*-csreq.json` | Each Axon row's code requirement, decoded with `csreq -r <blob> -t` |
| `runs/.../tcc-log-<step>.ndjson` | `log show` output for the step's window (`com.apple.TCC` and `com.apple.replayd`) |
| `runs/.../calculator-swift-0.3.6.axn` | Phase A step 1: Calculator 1 + 2 =, recorded by production's history under a private `_session` and exported with `save` |
| `runs/.../calculator-rust-recording.axn` | Phase A step 6: the candidate's own recording of the thread's hand clicks |
| `runs/.../look-calculator.png`, `look-calculator.json` | Phase A step 6: the candidate's screenshot (decoded from the response) and its look without the image |
| `runs/.../launchd/*.plist` | The exact plists the private jobs were loaded from |
| `runs/.../logs/` | The private jobs' stdout and stderr |

## How the verdicts are decided

**Carry** (`5-carry`, `B4-carry`). Health on the socket must report backend `rust-axon-mac`, the
installed main executable as `executablePath`, the same pid as `launchctl print`, version 0.4.0,
`shellContract` 1, and Accessibility and Screen Recording both granted. Every capability must be
usable except `observeChanges`, which axon-mac honestly reports as not implemented. Nothing may be
clicked between bootstrap and the verdict.

**TCC rows** (`9-tcc-carried`, `B4-tcc-carried`). Rows are compared by identity: database,
service, client, client type, and target. Rows that already existed are ignored, including
sshd-keygen-wrapper's path-keyed row, which `tccutil` cannot remove. A row is Axon's when its
client is `com.bleugreen.axon`, `com.bleugreen.axon.menu`, the editor's identifier, or a path
inside a candidate, production, or rollback bundle. An Axon row that is added or removed fails
the verdict. So does an Axon row whose `auth_value` or `csreq` changed. Rows that belong to
other apps and moved are a gap: they are reported, but they do not fail the carry.

**Prompts** (`5-zero-interaction`, `9-zero-first-grant-prompts`, `B4-zero-first-grant-prompts`).
tccd lines that share a `msgID` are joined into one request, then classified:

| Classification | Meaning | Effect |
| --- | --- | --- |
| first-grant | A prompt, or a real (non-preflight) request, for a service Axon does not already hold | FAIL |
| reauthorization-reminder | macOS 15+'s periodic "is requesting to bypass the system private window picker" reminder, or a Screen Recording prompt for an identity that already holds the grant | Informational, recorded with its timestamp |
| allowed-request, preflight | A request that cannot show a dialog | Counted |

The set of services Axon already holds comes from the TCC dump taken before the run, together
with production's health. Health matters when the system database cannot be read over ssh. If
`log show` cannot be read either, that is a gap, and the verdict then rests on the
notification windows the thread reads.

**Launcher safety.** Before the driver bootstraps anything, it checks every plist it wrote.
A plist that launches `com.bleugreen.axon`'s main executable must carry
`AXON_DAEMON_MANAGED_BY_LAUNCHD=1` or `serve`. Without either, the Rust main would run the
bundle's own `axon start`. The check treats an unreadable bundle identifier as Axon's. The menu
plist mirrors the one `daemon install` writes, with only `AXON_SOCKET_PATH` set, and the check
passes it because its executable is the nested `com.bleugreen.axon.menu`.

## Known limits

- **The unified-log scans need an administrator account.** Measured on bgsrv-mac on 2026-11-04:
  the console user `dev` is not an administrator, so every `tcc_log_scan` reports the gap
  `tcc-log-unreadable` with `log: Could not open local log store: Operation not permitted`.
  The TCC database diff is unaffected. Run the scan window's
  `log show --predicate 'subsystem == "com.apple.TCC"'` from an administrator account at the
  console, or accept the gap.

- **The rollback's last step is not rehearsed.** The rehearsal does load the 0.3.6 copy under
  the private label and verifies that its grants carry. What it does not run is the 0.3.6 CLI's
  own `daemon install`, because that command hardcodes `dev.axon.daemon` and can't run beside
  production. It is the command every 0.3.x install already ran.
- **A rollback registers production from the copy.** After a Phase B rollback, production
  runs from `~/AxonBench/axn125/rollback/Axon.app`, not from where 0.3.6 was installed before.
- **Calculator's key names are matched against a list.** The driver accepts "Add" or "+", and
  "Equals" or "=", among others. If macOS 26.6 names the keys differently, step 1 fails and
  records the names it did see.
