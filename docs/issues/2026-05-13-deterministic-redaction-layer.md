# Deterministic Redaction Layer

## Context

The [sensitivity classifier](2026-05-13-policy-driven-sensitivity-classifier.md) reframe promoted what was previously a "heuristic floor" into the primary defense for snapshot redaction. Most sensitive content in AX snapshots — credentials, structured PII, financial fields — has a shape, a role, or a known value, and is best handled by cheap exact rules rather than by a model. The classifier exists on top of this layer for what regex structurally can't reach: textural categories, contextual sensitivity, and user-custom policies.

This issue is that primary layer, scoped as its own deliverable. It ships independently of and before the encoder backbone, the head training pipeline, or any model dependency. It is the cheapest thing we can do that produces the biggest immediate read-side security improvement.

## Desired Shape

A pipeline stage that runs synchronously on every element of every snapshot and either clears the element or returns a redaction verdict with a rule tag and rule identifier. Three categories of rule:

1. **Role-based** — AX role and label-substring checks.
2. **Pattern-based** — regex matchers for structured PII, token shapes, and currency-context.
3. **Set-based** — hash-set membership checks (the op-backed bloom filter).

Verdicts are additive: an element can match multiple rules, all matches surface in trace metadata, and the strongest tag wins for the displayed `<redacted: ...>` label. The classifier layer (when active) only sees elements the deterministic layer cleared; nothing above can subtract a deterministic redaction.

## Rule Categories

### Role-based

- `AXSecureTextField` values → `auth-credential`. The platform already declares "this is secret"; we just honor it.
- Element labels containing `password`, `secret`, `token`, `private key`, `recovery code`, `api key`, `seed phrase`, etc. → `auth-credential` (on the labeled value).

### Pattern-based

- SSN (`\d{3}-\d{2}-\d{4}`) → `pii-identifier`.
- Luhn-valid 13–19 digit sequences → `financial-data`.
- Phone numbers (E.164 plus common US formats) → `pii-identifier`.
- Email addresses (simplified RFC) → `pii-identifier`.
- Passport / driver-license number formats (where the shape is unambiguous) → `pii-identifier`.
- Token shapes: `sk-...`, `sk_live_...`, `ghp_...`, `gho_...`, `xoxb-...`, `xoxp-...`, `AKIA...`, JWT (three base64 segments dot-joined), PEM-armored keys (`-----BEGIN ... PRIVATE KEY-----`) → `auth-credential`.
- Currency-context: an ISO currency literal (`$N.NN`, `£N.NN`, etc.) adjacent to a "balance" / "total" / "amount" / "due" / "owed" label → `financial-data`.

### Set-based

- **Op-backed bloom filter** — verbatim sha256 match against the user's currently-active op secrets → `auth-credential`. The design and operational details live in [Late-Bound Values And Credentials](2026-05-13-late-bound-values-and-credentials.md#active-secret-bloom-filter-read-side-protection); this layer is where the rule executes. This is the load-bearing rule of the whole deterministic layer — it's the one that delivers the "active credentials cannot appear in `get_app_state`" guarantee.

## Rule Library Maintenance

The pattern set grows as new token formats appear in the wild. This is ongoing maintenance, not a one-time decision. Structure:

- Each rule is `(name, matcher, tag, version)`.
- The active rule library is a versioned bundle shipped with the app.
- New rules ship via app update; the rule library version surfaces in trace metadata so audit can prove which rule set produced any historical verdict.
- Rules can be marked deprecated (retained for re-classification of old snapshots) without continuing to fire on new ones.

This is also where the [bloom filter as labeling oracle](2026-05-13-policy-driven-sensitivity-classifier.md#deterministic-layer-primary-defense) pays off: anything the deterministic layer flags becomes a high-confidence positive label when classifier heads are trained later. The same library doing redaction at runtime doubles as the label source at train time.

## Pipeline Integration

Per-element output schema:

```json
{
  "matched": [
    {"rule": "luhn-credit-card", "version": 3, "tag": "financial-data"},
    {"rule": "currency-near-balance-label", "version": 1, "tag": "financial-data"}
  ],
  "verdict": "redact",
  "display_tag": "financial-data"
}
```

All matches stay in `matched` for trace inspection; `display_tag` picks the strongest. The element's `value` is replaced with `<redacted: financial-data>` at the snapshot-rendering boundary; raw values stay in the history store so policy changes can retroactively re-render.

## Performance

This layer must be cheap enough to run unconditionally on every snapshot without a cache. Single-pass per element, no allocation in the hot path:

- Bloom filter lookup: one sha256 per element-value, one bit-array probe. Microseconds.
- Pattern set: compile-once, run-once-per-element. Modern regex engines handle small fixed pattern sets at memory-bandwidth speed.
- Role rules: hash-map lookup.

Target: single-digit milliseconds for 200-element snapshots regardless of hardware. The deterministic layer should never be the bottleneck.

## Open Questions

- **Email contextuality.** Some user policies want all emails redacted; others want only "non-self" emails redacted. Lean: detect all emails deterministically, defer the "which to actually redact" decision to a render-time policy filter. Avoids putting policy interpretation in the matcher.
- **Currency-context tightness.** `$3` without a "balance" label is ambiguous (money? "$3 of 12 items"?). How tight does the label-adjacency window need to be?
- **Masked-account false positives.** `•••• 4421` looks Luhn-related but isn't a real card. Needs an explicit "obviously-masked" exemption rule, or a length floor on Luhn matches.
- **Rule library distribution.** Bundle with the app, or ship as a separately-updatable signed resource (like ad-block lists)? Faster cadence is nice; signing and integrity matter more.
- **Trace verbosity default.** Always show `matched` array, or only on opt-in for audit? Tiny per-snapshot overhead, but it's noise in normal output.

## Non-Goals

- **No model inference.** This layer is pure rules. The point of the deterministic-first reframe is that this layer stands on its own without any classifier dependency.
- **No user-authored rules.** Custom rules belong in the [custom-head workflow](2026-05-13-policy-driven-sensitivity-classifier.md#custom-heads-power-user-workflow). The deterministic layer ships axon-curated rules only — keeping it a small reviewed surface.
- **No contextual judgments.** "This name is sensitive because of nearby content" is not a deterministic rule; it's a classifier case. Drawing the line here keeps the layer fast and explainable.
- **No semantic interpretation.** "Does this number look like money?" requires context. "Does this match `\d{3}-\d{2}-\d{4}`?" doesn't. Only the second kind lives here.

## Next Steps

- Define the rule schema (`name`, `matcher`, `tag`, `version`, `enabled`) and the pipeline integration surface.
- Implement the role-based rules first — `AXSecureTextField` plus label-substring matchers. Smallest deliverable that meaningfully reduces leak surface.
- Implement the structured-PII regex set (SSN, phone, email, passport).
- Implement the token-shape regex set with an explicit list of known issuer prefixes.
- Implement the currency-context heuristic with label-adjacency.
- Wire the op-backed bloom filter as the set-based rule once op integration phase 1 lands. This is the highest-impact rule in the layer and the one that delivers the headline read-side guarantee.
- Define the trace metadata schema and add an `axon redaction-trace <snapshot-id>` CLI for auditing which rules fired against which elements in a given snapshot.
- Coordinate with the [classifier](2026-05-13-policy-driven-sensitivity-classifier.md) work so the deterministic layer's output is shaped to feed both runtime rendering and head training.
