# axn/250 bench: the Rust daemon's browser verbs, from consent gesture to verb

bgsrv-mac, macOS 26.6, 2026-11-02 PST. Safari 26.6 and Google Chrome 156.0.8078.80 (in
`~/Applications`, launched by bundle id with `--no-first-run --no-default-browser-check`). The
bundle was built and signed from branch commit `2bdcbbbc` (`built-from.txt`). The only later commits
change a Python SDK test's example, the docs, and this directory, so the binary measured here is the
one in the PR.

`scripts/stage-macos-shell-bench --stage-only` staged the bundle from a build placement into
`/tmp/AxonBench-axn250`, with `AXON_BENCH_SOCKET` and `AXON_BENCH_LABEL_PREFIX` set for this bench.
The build placement's sandbox cannot write `~/AxonBench`. The bundle's identity is
`dev.axon.mac-bench`, signed with Developer ID team `JBS95V8M7P`, with the hardened runtime and the
Apple Events entitlement (see `codesign.txt`). The cross-platform thread copied the bundle to
`~/AxonBench/axn250` with `ditto` and ran `scripts/macos-browser-bench-protocol` over ssh as `dev`.
The driver loaded `dev.axon.bench250.{daemon,menu}` on `/tmp/axon-bench250.sock`. The driver sends
no Apple events itself, so every Automation row in `tcc-after.tsv` belongs to the daemon.

The run exited 0. Every verdict passed. Two steps are informational, both explained below.

## Files

| File | What it is |
| --- | --- |
| `transcript.jsonl` | The complete run, one JSON object per step |
| `tcc-before.tsv`, `tcc-after.tsv` | User and system `TCC.db` `access` rows |
| `daemon.err.log` | The daemon's stderr: one line per Automation decision naming its leg, and one line per Apple event with its status and latency |
| `daemon.err.excerpt.log` | The driver's excerpt of the same log, written at step 10 |
| `codesign.txt` | `codesign -dvvv` and entitlements for both bundles |
| `built-from.txt` | The commit the bundle was built from |

## Results

| Step | Verdict | What was measured |
| --- | --- | --- |
| 2 healthy | pass | `tccutil reset AppleEvents dev.axon.mac-bench`, then a restart of the daemon. Health reported `backend rust-axon-mac` from the staged bundle. |
| 3 windows | pass | Safari and Chrome, both launched by this run, each showed a window to Accessibility (checked with the daemon's `look`, so no Apple event was sent) |
| 4 tools listed | pass | The staged binary's `mcp` `tools/list` includes `navigate`, `windows`, `tabs` |
| 5 undetermined refusal | pass | All three verbs against both browsers returned `-32603` with `automation-not-granted`, `notDetermined`, leg `checked`, `nativeStatus -1744`. No consent dialog appeared, and `automation.status` reported need `request`. |
| 6 gesture | pass | The menu's Browser Automation... raised one dialog per browser, each naming AxonMacDev. After Allow, `automation.status` reported both browsers `granted`, leg `prompted`, need `none`. |
| 7 Safari navigate | pass | `/page`: success, `dictionary_readback`, `stable_readback`, title carries the nonce, 542 ms. The root with no slash read back with a slash (success, 502 ms). `/redirect` read back `/navigated` as a settled `dictionary_mismatch`. |
| 7 Safari windows, tabs | pass | `windows`: one window, `window:1` active, cross-check `matched`. `tabs`: the active tab's URL is the redirect destination; the other tab reads `favorites://`. `window` 0 and 99 are each `-32602`. |
| 7-8 Chrome navigate | pass | `/page` and the root settled on `loading_flag` in about 65 ms. `/slow` (body delayed 1500 ms) waited for the flag, 1598 ms. The redirect is a settled mismatch. |
| 7 Chrome windows, tabs | pass | `window:1` active. The cross-check is `partial` (informational, below). `tabs` read the redirect destination as active. `window` 0 and 99 are each `-32602`. |
| 9 inputs | pass | A `file:` URL and `app: Firefox` are each `-32602` |
| 10 executed leg | informational | See below |
| 11 not running | pass | After the run quit Chrome, `navigate` returned `-32603` "Browser is not running: Google Chrome" |
| 12 TCC | pass | The daemon's Automation targets are exactly Safari and Chrome. Nothing is recorded for the shell, and nothing foreign was added. |
| production untouched | pass | `dev.axon.daemon` kept pid 39271 and ran once throughout |

All 149 Apple events the daemon sent answered with status 0: 64 to Safari and 85 to Chrome. Each
event was `core/cnte`, `core/getd`, or `core/setd`, as the hermetic encoding test pins. Median
latency was 7 ms for Safari and 13 ms for Chrome; the maximum was 92 ms.

## How these were measured, exactly

**Step 10 was not an untick.** The thread's hand click on the Safari toggle beneath AxonMacDev in
System Settings registered. System Settings answered with an administrator authentication sheet
("Privacy & Security is trying to modify your system settings"). `dev` is not an administrator on
bgsrv-mac, so nothing the thread holds can untick a grant, and the thread does not type credentials.
The thread closed System Settings, which cancels the sheet, and reached the same TCC end state
without administrator rights:

1. `tccutil reset AppleEvents dev.axon.mac-bench`.
2. `launchctl kickstart -k gui/501/dev.axon.bench250.daemon`, the driver's own step-2 mechanic, to
   clear the in-process ledger. The bench daemon therefore ran three times in this run; its final pid
   was 38284.
3. The menu gesture again, answering Don't Allow on the Safari dialog and Allow on the Chrome
   dialog.

The resulting user `TCC.db` rows are `dev.axon.mac-bench -> com.apple.Safari` with `auth_value` 0
and `-> com.google.Chrome` with `auth_value` 2. The navigate that followed was refused `denied` at
leg `checked`, `nativeStatus -1743`: macOS answered the silent check, so no event was sent, and the
driver took the informational branch. The message carried the "earlier in this session" sentence.
That sentence is correct: the restarted daemon's own gesture had just recorded the denial it was
reporting.

Because the daemon was restarted, its ledger at step 10 was fresh rather than holding a grant TCC no
longer had. The variant this step was written for, where the process-held answer says granted while
TCC says denied, was **not** measured, so a refused event (`-1743` at the send) was never produced
live. The executed leg, its sticky ledger rule, the gesture's short-circuit, and the refusal's wire
shape stand on the hermetic tests. Those are `a_refused_event_records_the_executed_leg_and_stays_refused`
and `a_passing_check_does_not_retire_an_executed_denial` in `rust/axon-mac`, plus
`error-denied-executed.json`, which Swift generates and the Rust router reproduces. The
`answeredEarlierInThisProcess=true` checked-leg lines with status 0 in the driver's `10-daemon-log`
entry predate the restart. `daemon.err.log` shows the restarted process's sequence: the prompted
answers (Safari `-1743`, Chrome `0`), then the refusing check (Safari `-1743`).

**`tcc-before.tsv` was taken before the step-2 reset.** It still holds the axn/249 Safari denied
row. That is why step 12 lists only the Chrome row as added, while Safari reads unchanged (0 to 0)
after being reset, allowed, and denied again during the run.

**Operator answers were given through accessibility, not eyes.** The thread used bgsrv-mac's
desktop-automation bridge (the production Axon daemon).

- Step 5's "no dialog" is UserNotificationCenter and CoreServicesUIAgent reporting no windows.
- Both step-6 dialogs read "“AxonMacDev” wants access to control “Safari”…" (and likewise for
  Chrome), with the usage string "Axon uses browser automation to navigate and enumerate browser
  windows and tabs."
- Hand (HID) clicks pressed the status item, the menu item, every consent-dialog button, and the
  Safari toggle.
- An Accessibility press was used twice. Once to expand the AxonMacDev row in System Settings: three
  HID clicks on the disclosure triangle's reported frame never expanded it. Once to dismiss the menu
  shell's own results alert ("Safari: allowed / Google Chrome: allowed"). That alert is not a
  system dialog, and left standing after step 6 it swallowed the next status-item click.
- No keyboard text was sent through the bridge.
- The production daemon's stale Screen Recording private-window-picker prompt was on screen during
  step 10. Each consent dialog was raised clear of it before its buttons were clicked.

**Chrome's window cross-check is partial, and Swift's would be too.** Chrome's scripted window name
was "Navigated 0007179", and Accessibility reported one window whose title matched none of the
scripted names (`axWindowCount` 1, `matchingTitles` 0). The transcript does not record the AX title
itself. The comparison is the same one Swift's router makes (each AX title consumed once, as
`windows-partial.json` pins), so Swift would answer `partial` against the same window. Safari's
titles matched.

**`tabs` with `window: 99` says "must be greater than zero".** That is Swift's wording too: Swift
raises `invalidWindow` for a window above the count, and that error has one message for both cases.
The Rust message matches it on purpose, and `error-invalid-window.json` pins the shared text.

**Teardown.** The run quit Safari and Chrome, which it had launched, and booted out both bench
labels. System Settings was closed.

## What this did not measure

- A refused event at the executed leg, which needs an administrator to untick a grant behind a
  running daemon (step 10 above).
- Safari non-browser windows, such as Settings, in `windows`/`tabs`.
- An event timeout against a hung browser. The 15-second per-event limit and the shared per-call
  budget are pinned by `navigate_is_bounded_in_wall_clock_time_however_slowly_the_browser_answers`.
