# axn/249 bench: the Rust daemon and the menu shell as two launchd jobs

bgsrv-mac, macOS 26.6, 2026-11-01 22:17 to 22:31 PST. The bundle was built from branch commit
`6e33079`. Every later commit on the branch touches only the bench scripts, docs, or this directory,
so the binaries measured are the ones in the PR.

The bundle was staged by `scripts/stage-macos-shell-bench --stage-only` from a build placement. The
daemon is the signed main executable of `AxonMacDev.app` (`dev.axon.mac-bench`, Developer ID team
`JBS95V8M7P`, hardened runtime, Apple Events entitlement). The shell is
`Contents/Library/Applications/Axon Menu.app` (`dev.axon.mac-bench.menu`, same team, no
entitlements). See `codesign.txt`.

The cross-platform thread ran `scripts/macos-shell-bench-protocol` over ssh as `dev`. That driver
called `--bootstrap-only` to load `dev.axon.bench249.daemon` (`KeepAlive` true) and
`dev.axon.bench249.menu` (`KeepAlive {SuccessfulExit: false}`) on `/tmp/axon-bench249.sock`.

## Files

| File | What it is |
| --- | --- |
| `transcript.jsonl` | The complete run (attempt 2), one JSON object per step |
| `transcript.attempt1-aborted-4b.jsonl` | Attempt 1. It passed 3 and 4a, then aborted at 4b on a driver bug: an empty reply from a daemon shutting down was not read as a transport failure. Fixed in the driver before attempt 2. |
| `tcc-before.tsv`, `tcc-after.tsv` | User and system `TCC.db` `access` rows. Both dumps read the system database directly (`systemRoute: direct`, through the ssh session's Full Disk Access). |
| `codesign.txt` | `codesign -dvvv` and entitlements for both bundles |
| `daemon.err.log` | The daemon's stderr: one line per Automation determination, naming its leg |
| `recordings/` | The `.axn` files the shell wrote to `~/Library/Application Support/Axon/Recordings` |

## Results

| Step | Verdict | What was measured |
| --- | --- | --- |
| 3 ownership | pass | Health from the Rust daemon: `backend rust-axon-mac`, executable inside the staged bundle, `shellContract: 1`, both permissions granted. The socket lock is held by the daemon's pid alone, and the shell has no Unix-socket listener. |
| 4a status line | pass | The menu read "Daemon 0.3.6: ready" with no ungranted line |
| 4b daemon gone | pass | After `launchctl bootout` of the daemon, the menu read "Axon daemon not running (/tmp/axon-bench249.sock)" with Record disabled |
| 4c recovers | pass | After bootstrapping again, the menu returned to ready. The shell's pid was unchanged. |
| 4d crash | pass | After `kill -9` of the daemon, launchd relaunched it and the menu recovered |
| 5a menu recording | pass | Record... chose Calculator. `recording.status` showed the session, and the stop wrote `recordings/2026-11-01-222355-Calculator.axn`, a v2 document naming Calculator. |
| 5b restored from daemon state | pass | A `recording.start` sent over the socket appeared in the shell (Stop Recording... offered), and stopping from the menu ended it |
| 6a status agrees with menu | pass | `automation.status` need `request`, and the menu showed Browser Automation... |
| 6b consent minted for the daemon | pass | The dialog named "AxonMacDev" (the daemon bundle's name) with the daemon's usage string, presented by UserNotificationCenter. After Allow, the row was `kTCCServiceAppleEvents dev.axon.mac-bench -> com.apple.Safari` auth 2, need was `none`, and the item was gone. |
| 6c denial explained | pass | After `tccutil reset` and a daemon restart, Don't Allow gave auth 0 and need `explain`. The alert named System Settings > Privacy & Security > Automation, and the item stayed. |
| 7 permit | pass | `accessibility: trusted` on the granted bench |
| 8 quit stays quit | pass | Quit Axon Menu: the job was not running with last exit code 0, and still not running 60 s later. Health still answered. |
| 9 crash relaunches | pass | After `kill -9` of the shell, a new pid appeared. The daemon's pid was unchanged. |
| 10 TCC | pass | Exactly one row added: `user kTCCServiceAppleEvents dev.axon.mac-bench 0 com.apple.Safari auth=0`, the final Don't Allow. None were removed or changed, and no row names `dev.axon.mac-bench.menu` or `Axon Menu.app` in either database. |
| production untouched | FAIL, operator-induced | See below |

## How these were measured, exactly

**Operator answers were given through accessibility, not eyes.** The thread used bgsrv-mac's
desktop-automation bridge (the production Axon daemon) as hands and eyes. Every "the menu reads"
answer is the shell's menu as its accessibility tree reported it.

**The recording icon's colour was inferred, not observed.** No process the operator held could
capture the status item. In 5a and 5b the evidence was the status item's accessibility name
becoming "Axon Recording", which is set on the same code path as the red image (`updateStatusImage`
in `Sources/AxonMenuApp/MenuShell.swift`), and the menu listing "Recording Calculator" and "Stop
Recording...".

**The Browser Automation item reflects the last real open.** `automation.status` is fetched in
`menuWillOpen` by design, so reading the menu's accessibility tree without opening it shows the
previous item set. The operator opened the menu with a real click before every consent answer.

**5a was redone before the driver moved on**, which is legitimate because the driver reads the
newest file. The first menu recording (`2026-11-01-222213-Calculator.axn`) had only typed
`12+3=` and came back as `actions: []`, although Calculator showed 15. The second
(`2026-11-01-222355-Calculator.axn`) used six keypad clicks, recorded as point fallbacks, and then
`+4=`, recorded as a keyboard fallback. Losing keyboard-only input is a recorder defect independent
of this change, filed as axn/251. `2026-11-01-222451-Calculator.axn` is 5b's recording, which had
no input between start and stop.

**production untouched failed because of the operator's tooling.** During step 5 the operator
delivered `keyboard` text to Calculator through the desktop-automation bridge, which is served by
the production Swift 0.3.6 daemon (`dev.axon.daemon`). That tripped the known Swift keyboard-layout
crash (axn/215), and launchd relaunched the production daemon (pid 71224 to 42722, runs 1 to 2,
near 22:21). The bench itself never touched `dev.axon.daemon` or `/tmp/axon.sock`.

**Pre-existing prompts on the desktop.** Three stale system prompts were on screen throughout and
are not evidence of anything here: a Screen Recording private-window-picker prompt for AxonMacDev,
a local-network prompt for `cairn-exec`, and "Messages quit unexpectedly". The operator raised the
Safari dialog above them before answering it.

## What this did not measure

- `permit`'s prompt path, which needs an ungranted identity.
- Opening the editor from a stopped recording, which `AppBundle.pairedEditorURL` deliberately
  refuses for a non-release identity. The written file is the evidence.
- The in-app update from the shell, which needs a Developer-ID release that contains the shell.

All three belong to the signed qualification of the packaged split.
