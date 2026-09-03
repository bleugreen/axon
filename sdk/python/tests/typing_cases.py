"""
Calls the generated types must accept, and calls they must reject.

pytest does not run this file; pyright does, and that is the point. ``reportUnnecessaryTypeIgnoreComment``
is an error in ``pyrightconfig.json``, so a ``# type: ignore`` here fails the type check unless the
line under it really is a type error. Each ignore below is therefore an assertion that the schema's
requirement survived into Python, not a suppression of one.
"""

from __future__ import annotations

from axon._generated import ClickParams, KeyboardParams, NavigateParams, SaveParams

# keyboard is one object whose oneOf demands either text or key.
text: KeyboardParams = {"text": "hello"}
key: KeyboardParams = {"key": "cmd+s", "app": "Safari"}
neither: KeyboardParams = {"app": "Safari"}  # type: ignore

# navigate requires both app and url.
navigate: NavigateParams = {"app": "Safari", "url": "https://example.com"}
no_url: NavigateParams = {"app": "Safari"}  # type: ignore

# A target is an object, and a semantic one names both the app and the element.
semantic: ClickParams = {"target": {"app": "Calculator", "name": "button:7"}}
point: ClickParams = {"target": {"x": 12.0, "y": 40.0, "coordinateSpace": "screen"}}
nameless: ClickParams = {"target": {"app": "Calculator"}}  # type: ignore
unknown_space: ClickParams = {"target": {"x": 1.0, "y": 2.0, "coordinateSpace": "desk"}}  # type: ignore

# A reserved word survives as a key because save is declared through TypedDict's functional form.
save: SaveParams = {"from": "call-1", "to": "call-9", "sessionId": "checkout"}
mistyped_save: SaveParams = {"includeReads": "yes"}  # type: ignore
