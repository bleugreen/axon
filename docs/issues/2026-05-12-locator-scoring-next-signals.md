# Locator Scoring: Nearby Text And Geometry

Phase 3 implements the first honest locator subset: role, subrole, title, value, description, identifier, actions, and ordered ancestry. It also returns `unique`, `ambiguous`, or `missing` with candidate reasons and refuses to act on ambiguous locators.

The next locator signals should be added deliberately instead of folded into fuzzy matching:

- Nearby text: derive stable context from sibling/ancestor text nodes and section-like containers, then explain which nearby strings contributed to a match.
- Geometry hints: use normalized frame distance only as a weak tie-breaker after semantic signals, never as a silent replacement for them.
- Window scope: expose a first-class window matcher above generic ancestry so callers do not need to know the exact intermediate AX tree shape.
- Confidence: return a named confidence or numeric score once multiple weighted signals exist. The current score is only the count of matched reasons.

These should get tests against synthetic trees before being used by live AX actions.
