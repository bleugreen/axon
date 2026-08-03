# Windows UI Automation spike findings

Tested on `bglab-win` on 2026-08-02. The Rust workspace location is the recommended monorepo shape from AXN-25, but it is not yet settled.

## Interactive desktop access

SSH ran as `bglab-win\mitch` in Windows session 0. `WTSGetActiveConsoleSessionId()` returned 1, and `qwinsta` reported session 1 as the active console session for the same user. Explorer and Edge processes ran in session 1.

UI Automation initialized in session 0, but the desktop root had exactly zero children. The same binary, launched by the user from PowerShell in session 1, enumerated 11 top-level elements. The Windows Axon daemon must therefore start in the logged-in user's session, with remote agents connecting over a named pipe. A service-session workaround is neither needed nor appropriate.

## Crate assessment

The spike uses `uiautomation` 0.25.0. It made enumeration, property access, control-view walking, and typed `InvokePattern` dispatch concise enough to validate the core loop quickly.

Feature selection exposed rough edges. Building with only `pattern` failed because core imports the feature-gated input module. Adding `input` alone then failed because a transitive Windows API feature was not enabled. The supported default feature set compiled, but pulls in more than this spike needs.

For the real daemon, provisionally prefer evaluating direct `windows` crate COM
bindings for Axon's narrow UI Automation surface. They are more verbose, but
would make COM initialization, cache requests, HRESULT handling, timeouts, and
Windows features explicit. This spike did not implement that alternative, so a
direct-binding prototype covering cache requests and timeout behavior is still
needed before making the architectural choice. The wrapper remains useful as
executable reference material.

## Notepad capture

The session-1 run captured 46 nodes from modern Notepad at depth 6, with control type, name, AutomationId, and bounding rectangle. The semantic tree included:

- `Document` / `Text editor`
- tabs with `Tabs`, `TabListView`, `CloseButton`, and `AddButton`
- File, Edit, and View `MenuItem` controls with matching AutomationIds
- named formatting and settings buttons
- cursor position, character count, line-ending, and encoding status text
- title-bar Minimize, Maximize, and Close buttons

First-substring window matching initially selected a terminal title containing “cairn” before the exact app title. The spike now ranks an exact case-insensitive title above a contains match. The real locator scorer must similarly rank exact evidence above partial evidence.

## Invoke dispatch and verification

The locator `control type = MenuItem` plus `name contains = File` resolved the Notepad File menu item. `InvokePattern::Invoke` reported:

    dispatch_success=true

After 500 ms, an independent recapture observed the tree grow from 61 to 91
nodes, evidence consistent with the menu opening:

    verified_outcome=true
    verification=bounded_tree_changed before_nodes=61 after_nodes=91

This proves dispatch and a coarse independent change signal can be represented
separately. Whole-tree inequality does not prove action-specific goal success:
an unrelated UI mutation could satisfy it. Real actions need action-specific
predicates and bounded waits rather than a fixed sleep.

## WebView2 observation

Cairn's exact `cairn` window was reachable, but its WebView2 subtree was poor. At depth 8 the capture contained only 20 nodes. Beneath the native window it exposed `cairn - Web content` followed almost entirely by anonymous nested `Pane` elements, with no page controls, page text, or AutomationIds.

This is insufficient for Axon's semantic locator model. Before relying on UI Automation for Cairn, investigate WebView2 accessibility configuration and the rendered app's accessibility markup. Edge itself was visible as a top-level window, but Cairn was the motivating and more relevant target.

## Conclusion

The core Windows loop is viable in Rust when it runs in the interactive user
session. UI Automation gives a strong native Notepad tree, locator resolution
is straightforward, and Invoke dispatch can be measured separately from a
post-dispatch state signal. The implementation-shaping risks are now concrete:
daemon placement must be per-user-session, and WebView2 cannot be assumed to
expose a useful tree without additional work.
