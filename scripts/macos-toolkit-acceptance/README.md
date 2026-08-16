# macOS PID-targeted input acceptance campaign

Measures, per application, whether input posted to it with `CGEventPostToPid` while it is **not**
frontmost is acted on — and separates that from whether the post itself succeeded.

That separation is the whole point. `CGEventPostToPid` returns `void`. It reports nothing, ever, and
an application that examined the event and did nothing is indistinguishable from one that acted on
it, which is indistinguishable from one that never received it. Nothing on the sending side can tell
the three apart. Only the target's own behaviour can.

This campaign is evidence, not product code. It changes nothing in `Sources/` and nothing in the
Swift daemon's delivery ladder, and it does not invoke the daemon at all: it measures the operating
system mechanism directly, so the evidence is independent of the implementation that will consume
it. What consumes it is recorded below under [the AXN-125 consumer contract](#the-axn-125-consumer-contract).

## Why this has to be measured

`docs/platform-spec.md` only permits a backend to classify a mechanism as `pixel` when it is bound to
a verified target, derives its coordinates from resolved geometry, and leaves the frontmost
application and the real pointer unchanged. On macOS exactly one mechanism has that shape — a Core
Graphics event posted to a process rather than to the HID tap — and macOS accepts that post from any
Accessibility-trusted process without ever saying what became of it.

There is no honest runtime alternative. A pre-flight probe that produces no observable effect proves
nothing, and one that produces an effect has already mutated the user's window. Inferring acceptance
from a bundle identifier or from linked frameworks is a guess wearing a probe's clothes. So the fact
is measured once, here, and committed.

This is the macOS counterpart of `scripts/linux-toolkit-acceptance/`, which answered the same
question for `XSendEvent`, and of the window-class allowlist that `axon-win probe pixel-click`
earned on Windows.

## Running it

```sh
scripts/macos-toolkit-acceptance/run                    # the whole matrix
scripts/macos-toolkit-acceptance/run --only safari
scripts/macos-toolkit-acceptance/run --skip-build       # reuse the built probe
scripts/macos-toolkit-acceptance/check                  # validate fixtures, verify RESULTS.md
scripts/macos-toolkit-acceptance/check --write          # regenerate RESULTS.md
cd scripts/macos-toolkit-acceptance && python3 -m unittest discover -s tests
```

### There is no hermetic lane, and there cannot be one

The Linux harness brings up its own Xvfb so that a run means the same thing on a developer's machine
and in CI. macOS has no equivalent. PID-targeted delivery is a property of a real window server with
a logged-in user in front of it, and the permission that gates it is granted to a process by a person
in System Settings. A headless macOS lane would measure a machine on which the answer is trivially
"nothing is delivered", which is not the question.

So this runs on an **interactive bench, serialized**, and while it runs it takes over the pointer and
the foreground. Nobody should be typing on the machine: a stray keystroke lands in whichever fixture
holds the focus and contaminates the trial it lands in. The campaign restores the prior frontmost
application and the prior pointer position on every exit path, including a failed trial.

### Permissions

| permission | needed for | when it is missing |
| --- | --- | --- |
| Accessibility | posting any event at all, and the `AXDocument` readback | every row is `blocked` |
| Automation | not used | — |
| Screen Recording | not used | — |

Accessibility is granted to the *process* that posts, which in practice is the terminal or agent
running the campaign. Without it macOS drops every posted event in silence — which from the sending
side looks exactly like a target declining them, and would otherwise produce a full table of
refusals the campaign never earned. `derive_verdict` checks the permission before anything else and
records `blocked`, and `evidence.py` refuses to let an `accepted` or `refused` row exist in a
campaign that ran without it.

## What is in here

| file | what it is |
| --- | --- |
| `run` | entry point; refuses to run off macOS and warns about missing permission |
| `harness.py` | the coordinator: targets, phases, invariants, cleanup, normalization |
| `evidence.py` | schema validation, integrity rules, and the `RESULTS.md` renderer |
| `check` | validates the committed fixtures and verifies `RESULTS.md` has not drifted |
| `schema.json` | the versioned `macos-acceptance-v1` contract the fixtures are written against |
| `page.html` | the measurement page every web-engine target loads |
| `probe/` | the native macOS probe, a standalone Rust crate |
| `targets/electron/` | the pinned Electron runtime's main script (the runtime is gitignored) |
| `tests/` | hermetic tests: phase order, verdicts, integrity, rendering |
| `results.json` | the normalized fixtures, consumed by the future Rust table |
| `RESULTS.md` | generated from `results.json`; never edited by hand |
| `raw/` | machine and date stamped raw records, kept for diagnosis |

### The probe is standalone on purpose

`probe/` is a Rust crate with an empty `[workspace]` table, which makes it its own workspace root and
keeps it out of `rust/Cargo.toml`. Its bindings are macOS-only — Core Graphics, HIServices, the
Objective-C runtime, AppKit, WebKit — and the product workspace's lockfile is resolved with
`--locked` by lanes that build on Linux and Windows. A macOS-only crate landing in that lockfile
would make those lanes carry a resolution they can never build. It has no dependencies at all, so
re-running the campaign on a fresh bench needs no registry access.

On any platform other than macOS the binary refuses with a sentence before a single binding is
reached, and the bindings themselves are behind `#[cfg(target_os = "macos")]`, so a Linux
`cargo check` of the crate never sees a Core Graphics symbol.

## How a target is measured

Each target and action is one trial, run as ordered phases. The order is the argument: everything
that could invalidate the trial is established *before* the dispatch, so a reviewer does not have to
take the campaign's word that the preconditions held.

| phase | what it does | what it protects |
| --- | --- | --- |
| `identity` | reads the target's pid, bundle identifier, versions, process start time, and window list | that the row names something a backend could recognize at dispatch time |
| `controlBefore` | drives the real pointer or the real keyboard at the same target | that the target and the coordinate are live. A silent control invalidates the trial |
| `background` | raises the decoy application and parks the real cursor clear of everything | that the target is genuinely in the background |
| `ownership` | reads the window stack at the dispatch coordinate | that the target, and not the decoy or anything else, owns that point |
| `dispatch` | posts through `CGEventPostToPid`, recording frontmost and pointer either side | the measurement itself |
| `observe` | reads back what the target says happened, and what the decoy received | target-side mutation, and leakage into the wrong application |
| `controlAfter` | drives the real pointer or keyboard again | that the target was still live and still aimed at |
| `restore` | puts the prior frontmost application and the prior pointer back | the machine the campaign borrowed |

The decoy is an AppKit window of the campaign's own, in its own application bundle, that reports
every event it is handed. It holds the foreground so the target is measurably not frontmost, and it
catches delivery that went somewhere the caller did not ask for — a keystroke that lands in the decoy
is worse than one that lands nowhere, and would be invisible if the decoy were a passive window.

### The controls are what make a refusal mean something

Without them, a silent target is ambiguous between "macOS did not deliver this" and "the campaign
aimed at nothing". This is not hypothetical: the first version of the native fixture reported that
even a real, human-speed pointer click failed to move its checkbox. The cause was that an
`NSButton` switch hit-tests what it draws — the box and its label — and not the rest of its frame,
so a click at the centre of the control's frame landed in empty space beside the label. Every
verdict in that run would have been a statement about the fixture. The control caught it, which is
precisely what a control is for.

### Three outcomes, not two

Where a target can report its own event stream — the AppKit fixture, and any page through its
`isTrusted` listeners — the campaign records **arrival** separately from **action**. That separates
an event that never reached the application from one that reached it and was declined, which the
sending side cannot tell apart and which mean very different things for a future implementation.

### Freshness, and why keyboard is measured on its own

The Linux campaign found that Chromium routes background key events to a window only once a
background click has landed in it: a window that has not been clicked drops every delivered key
event in silence. A keyboard row measured after a click row on the same window records the
post-click state and reads as an acceptance it did not earn.

So a keyboard trial here launches its own target and its foreground control is a *keystroke*, not a
click: the measured keystrokes are the first synthetic input that target ever receives. Click trials
are not fresh by construction — their control clicks the target first, which is what licenses them —
and every row says which it is. `evidence.py` refuses a keyboard `accepted` or `refused` row that
does not come from a fresh trial.

### Verdicts

| verdict | what it means |
| --- | --- |
| `accepted` | the target acted, while a decoy held the foreground and the real pointer did not move |
| `refused` | the post completed and the target did nothing |
| `blocked` | the trial could not establish its own preconditions, so it says nothing about the target |
| `unavailable` | the target software was not present on the bench |

A clean Core Graphics post is only `dispatchAccepted`. It is never `accepted`. Missing permission and
absent software are `blocked` and `unavailable`; neither is ever recorded as a refusal, because
neither is the target's answer.

## Rerun policy

Application and macOS releases invalidate these rows. Commits to this repository do not. Each row
carries its own `remeasureWhen`, and the campaign is re-run and re-dated when one of those happens —
not wired into the pull-request gate, which has no interactive desktop, no granted Accessibility
permission, and no reason to re-answer a question whose answer changes on Apple's schedule rather
than on ours.

The hermetic tests under `tests/` *are* suitable for the gate. They claim nothing about macOS. They
claim that a row cannot say more than it measured, which is the property the future acceptance table
depends on.

## The AXN-125 consumer contract

This section is the handoff. Nothing in this directory implements a delivery decision, and no
dormant table or parser is added here: a table with no caller cannot be reviewed against a caller,
and would rot before it was used.

**Destination.** AXN-125 adds the acceptance table to `rust/axon-mac`, at pixel-candidate planning,
*before* `dispatch_pixel_click`. Today that path is `BackgroundPixelPointer::plan_pixel_click`,
`PixelPlan`, and `Router::pointer_ladder` in `rust/axon-mac/src/lib.rs`; when the implementation
lands it should extract `rust/axon-mac/src/pixel.rs`, matching the shape
`rust/axon-linux/src/pixel.rs` already has.

**Shape.** Follow `rust/axon-linux/src/pixel.rs`. Each entry — accepted or refused — cites the stable
row identifiers from `scripts/macos-toolkit-acceptance/results.json` in its `evidence` field, so the
measurement behind a permission is one hop from the permission. A target with no matching entry
refuses `backgroundPixelUnsupported`, and so does a target whose entry says refused; the difference
is that a refused entry can say *why*, and an absent one can only say that nobody measured it.

**The key is what a backend can read at dispatch time.** Holding a process identifier, `axon-mac`
can read a bundle identifier and the bundle's own version through `NSRunningApplication`. That is
what an entry may be keyed on. It may not be keyed on anything the campaign happened to know because
it launched the target itself. Where macOS publishes no stable generic toolkit signature — and it
publishes none: there is no macOS equivalent of the AT-SPI toolkit name Linux keys on — rows stay
application-specific, and an unknown bundle identifier fails closed.

**Dispatch is not delivery.** A completed `CGEventPostToPid` remains dispatch evidence only. It never
authorizes candidate availability and never authorizes goal success. `success` still requires
readback or a declared `expects` postcondition, exactly as it does on the other two platforms.

**Ladder behaviour.** Under `foregroundPermitted`, the router walks past a refused pixel candidate
and preserves that obstacle through `alsoRefused`, which is the AXN-101 contract and the reason the
field scenario reaches the foreground transaction that axn/195 repaired. Under `backgroundOnly`, the
measured refusal is what the caller gets, named rather than generic.

**One action, one row.** Click evidence authorizes clicks. It does not authorize keyboard, drag,
scroll, or a different delivery variant — including a different event source or a different down/up
construction, which is why every row records the exact variant it measured. A variant nobody
measured is a variant nobody measured.
