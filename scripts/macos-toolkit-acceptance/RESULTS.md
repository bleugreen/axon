# Measured macOS acceptance of PID-targeted synthetic input

Generated from `results.json` by `scripts/macos-toolkit-acceptance/check`. Do not edit by hand:
re-run the campaign, or regenerate this file.

This table records what macOS did with input posted through `CGEventPostToPid` into an
application that was not frontmost. It is evidence, not permission. A backend consuming it
decides what to authorize; a target absent from the table authorizes nothing.

## Campaigns

| campaign | measured | machine | macOS | Accessibility | raw evidence |
| --- | --- | --- | --- | --- | --- |
| `bbl-2026-08-16` | 2026-08-16T19:44:22-04:00 | arm64 macOS bench | Version 26.4 (Build 25E246) | granted | [`raw/bbl-2026-08-16.json`](raw/bbl-2026-08-16.json) |

## Rows

| row | target | identity | action | verdict | dispatch | target acted | arrival | invariants | controls |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `safari-click-2026-08-16` | safari (webkit-browser) | `com.apple.Safari` 26.4 | `click` | **refused** | accepted | no | never arrived | all held | before: acted; after: acted |
| `safari-keyboard-2026-08-16` | safari (webkit-browser) | `com.apple.Safari` 26.4 | `keyboard` | **accepted** | accepted | yes | reached | all held | before: acted; after: acted |
| `chrome-click-2026-08-16` | chrome (chromium-browser) | `com.google.Chrome` 151.0.7922.138 | `click` | **refused** | accepted | no | never arrived | all held | before: acted; after: acted |
| `chrome-keyboard-2026-08-16` | chrome (chromium-browser) | `com.google.Chrome` 151.0.7922.138 | `keyboard` | **accepted** | accepted | yes | reached | all held | before: acted; after: acted |
| `electron-click-2026-08-16` | electron (electron) | `com.github.Electron` 43.4.0 electron-framework (version not readable) | `click` | **refused** | accepted | no | never arrived | all held | before: acted; after: acted |
| `electron-keyboard-2026-08-16` | electron (electron) | `com.github.Electron` 43.4.0 electron-framework (version not readable) | `keyboard` | **accepted** | accepted | yes | reached | all held | before: acted; after: acted |
| `AxonAcceptanceTarget-click-2026-08-16` | AxonAcceptanceTarget (appkit-native) | `dev.axon.acceptance.target` 1.0.0 | `click` | **refused** | accepted | no | reached | all held | before: acted; after: acted |
| `AxonAcceptanceTarget-keyboard-2026-08-16` | AxonAcceptanceTarget (appkit-native) | `dev.axon.acceptance.target` 1.0.0 | `keyboard` | **accepted** | accepted | yes | reached | all held | before: acted; after: acted |
| `AxonAcceptanceWebView-click-2026-08-16` | AxonAcceptanceWebView (wkwebview) | `dev.axon.acceptance.webview` 1.0.0 | `click` | **refused** | accepted | no | never arrived | all held | before: acted; after: acted |
| `AxonAcceptanceWebView-keyboard-2026-08-16` | AxonAcceptanceWebView (wkwebview) | `dev.axon.acceptance.webview` 1.0.0 | `keyboard` | **accepted** | accepted | yes | reached | all held | before: acted; after: acted |

## Reading this table

**dispatch** is whether the Core Graphics post completed. `CGEventPostToPid` returns no status,
so this column is always the weakest one here: it says the events were created and handed to the
window server, and it never says the target received or acted on anything. The whole campaign
exists because that distinction is invisible from the sending side.

**target acted** is the only column that can license an `accepted` verdict. It is a change in the
target itself — a control that moved, a page that navigated, a field that echoed — observed
through the target's own reporting rather than inferred from the envelope.

**arrival** separates two outcomes a sender cannot tell apart: an event that never reached the
application, and one that reached it and was declined. It is filled in only for targets that can
report their own event stream.

**controls** are what make a refusal mean something. Each trial runs a foreground control before
and after the measured dispatch, driving the real pointer or the real keyboard at the same target.
A trial whose control did not act is measuring the campaign rather than the target, and is recorded
`blocked` rather than as a refusal it never earned.

**identity** is what a backend can read about the target at dispatch time, holding only a process
identifier. It is the key any future acceptance entry would have to be written against, and a row
claims exactly as much as that key can carry and no more.

## Row detail

### `safari-click-2026-08-16`

the Core Graphics post completed and the target did nothing: dispatch was accepted by macOS and the action was not delivered

- Variant: `leftMouseDown+leftMouseUp/source=null/gapMs=0` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: not fresh — a foreground control click preceded the measured dispatch, which is what licenses the click trial; a keyboard verdict is never taken from a trial shaped this way
- Target-side observation: the page neither navigated nor reported a click
- Arrival: the page's event listeners recorded nothing
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Raw evidence: [`raw/bbl-2026-08-16.json#safari-click`](raw/bbl-2026-08-16.json)
- Re-measure when: a Safari or macOS major release

### `safari-keyboard-2026-08-16`

the target acted on input posted to its process while a decoy held the foreground and the real pointer did not move

- Variant: `keyDown+keyUp/source=null` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: fresh — the measured keystrokes were the first synthetic input this target received: its foreground control was a keystroke, not a click
- Target-side observation: the page's input read 'axon' before and 'axonaxon' after
- Arrival: the page observed keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read '' before and 'axon' after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read 'axonaxon' before and 'axonaxonaxon' after
- Raw evidence: [`raw/bbl-2026-08-16.json#safari-keyboard`](raw/bbl-2026-08-16.json)
- Re-measure when: a Safari or macOS major release

### `chrome-click-2026-08-16`

the Core Graphics post completed and the target did nothing: dispatch was accepted by macOS and the action was not delivered

- Variant: `leftMouseDown+leftMouseUp/source=null/gapMs=0` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: not fresh — a foreground control click preceded the measured dispatch, which is what licenses the click trial; a keyboard verdict is never taken from a trial shaped this way
- Target-side observation: the page neither navigated nor reported a click
- Arrival: the page's event listeners recorded nothing
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Raw evidence: [`raw/bbl-2026-08-16.json#chrome-click`](raw/bbl-2026-08-16.json)
- Re-measure when: a Chrome major release

### `chrome-keyboard-2026-08-16`

the target acted on input posted to its process while a decoy held the foreground and the real pointer did not move

- Variant: `keyDown+keyUp/source=null` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: fresh — the measured keystrokes were the first synthetic input this target received: its foreground control was a keystroke, not a click
- Target-side observation: the page's input read 'axon' before and 'axonaxon' after
- Arrival: the page observed keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read '' before and 'axon' after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read 'axonaxon' before and 'axonaxonaxon' after
- Raw evidence: [`raw/bbl-2026-08-16.json#chrome-keyboard`](raw/bbl-2026-08-16.json)
- Re-measure when: a Chrome major release

### `electron-click-2026-08-16`

the Core Graphics post completed and the target did nothing: dispatch was accepted by macOS and the action was not delivered

- Variant: `leftMouseDown+leftMouseUp/source=null/gapMs=0` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: not fresh — a foreground control click preceded the measured dispatch, which is what licenses the click trial; a keyboard verdict is never taken from a trial shaped this way
- Target-side observation: the page neither navigated nor reported a click
- Arrival: the page's event listeners recorded nothing
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Raw evidence: [`raw/bbl-2026-08-16.json#electron-click`](raw/bbl-2026-08-16.json)
- Re-measure when: an Electron or Chromium major release

### `electron-keyboard-2026-08-16`

the target acted on input posted to its process while a decoy held the foreground and the real pointer did not move

- Variant: `keyDown+keyUp/source=null` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: fresh — the measured keystrokes were the first synthetic input this target received: its foreground control was a keystroke, not a click
- Target-side observation: the page's input read 'axon' before and 'axonaxon' after
- Arrival: the page observed keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read '' before and 'axon' after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read 'axonaxon' before and 'axonaxonaxon' after
- Raw evidence: [`raw/bbl-2026-08-16.json#electron-keyboard`](raw/bbl-2026-08-16.json)
- Re-measure when: an Electron or Chromium major release

### `AxonAcceptanceTarget-click-2026-08-16`

the Core Graphics post completed and the target did nothing: dispatch was accepted by macOS and the action was not delivered

- Variant: `leftMouseDown+leftMouseUp/source=null/gapMs=0` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: not fresh — a foreground control click preceded the measured dispatch, which is what licenses the click trial; a keyboard verdict is never taken from a trial shaped this way
- Target-side observation: the fixture's checkbox read 1 before and 1 after
- Arrival: the application dequeued leftMouseDown on window 0, leftMouseUp on window 0
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the fixture's checkbox read 0 before and 1 after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the fixture's checkbox read 1 before and 0 after
- Raw evidence: [`raw/bbl-2026-08-16.json#AxonAcceptanceTarget-click`](raw/bbl-2026-08-16.json)
- Re-measure when: a macOS major release, which is what changes how AppKit routes a posted event

### `AxonAcceptanceTarget-keyboard-2026-08-16`

the target acted on input posted to its process while a decoy held the foreground and the real pointer did not move

- Variant: `keyDown+keyUp/source=null` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: fresh — the measured keystrokes were the first synthetic input this target received: its foreground control was a keystroke, not a click
- Target-side observation: the fixture's text field read 'axon' before and 'axonaxon' after
- Arrival: the application dequeued keyDown on window 3441, keyUp on window 3441, keyDown on window 3441, keyUp on window 3441, keyDown on window 3441, keyUp on window 3441, keyDown on window 3441, keyUp on window 3441
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the fixture's text field read '' before and 'axon' after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the fixture's text field read 'axonaxon' before and 'axonaxonaxon' after
- Raw evidence: [`raw/bbl-2026-08-16.json#AxonAcceptanceTarget-keyboard`](raw/bbl-2026-08-16.json)
- Re-measure when: a macOS major release, which is what changes how AppKit routes a posted event

### `AxonAcceptanceWebView-click-2026-08-16`

the Core Graphics post completed and the target did nothing: dispatch was accepted by macOS and the action was not delivered

- Variant: `leftMouseDown+leftMouseUp/source=null/gapMs=0` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: not fresh — a foreground control click preceded the measured dispatch, which is what licenses the click trial; a keyboard verdict is never taken from a trial shaped this way
- Target-side observation: the page neither navigated nor reported a click
- Arrival: the page's event listeners recorded nothing
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the real pointer over the coordinate` — the page followed its link and the server served the next document
- Raw evidence: [`raw/bbl-2026-08-16.json#AxonAcceptanceWebView-click`](raw/bbl-2026-08-16.json)
- Re-measure when: a macOS major release, which is what changes how AppKit routes a posted event

### `AxonAcceptanceWebView-keyboard-2026-08-16`

the target acted on input posted to its process while a decoy held the foreground and the real pointer did not move

- Variant: `keyDown+keyUp/source=null` through `CGEventPostToPid`
- Campaign: `bbl-2026-08-16`
- Fresh state: fresh — the measured keystrokes were the first synthetic input this target received: its foreground control was a keystroke, not a click
- Target-side observation: the page's input read 'Axon' before and 'Axonaxon' after
- Arrival: the page observed keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True, keydown isTrusted=True, keyup isTrusted=True
- Control before: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read '' before and 'axon' after
- Control after: acted via `CGEventPost(kCGHIDEventTap) with the target activated` — the page's input read 'Axonaxon' before and 'Axonaxonaxon' after
- Raw evidence: [`raw/bbl-2026-08-16.json#AxonAcceptanceWebView-keyboard`](raw/bbl-2026-08-16.json)
- Re-measure when: a macOS major release, which is what changes how AppKit routes a posted event
