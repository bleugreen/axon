# Active Credential Fragment Redaction

## Context

The active-credential redactor is intentionally HMAC-backed: Axon stores keyed
fingerprints of provider secrets and never keeps the plaintext index on disk.
That gives a strong exact-match rule at output boundaries:

> If an observed string equals an active credential value, redact it and attach
> the provider reference metadata.

The adversarial gap is that external output is not always field-aligned. AX
values, OCR lines, locator reason strings, history params, and error messages
can contain a credential as a substring inside surrounding text:

```text
Token: correct horse battery staple
Authorization: Bearer correct horse battery staple
paste correct horse battery staple
```

With the current exact-match HMAC lookup, those strings do not match the active
credential index unless a deterministic pattern rule also happens to catch the
whole string. Arbitrary provider secrets such as passphrases, recovery phrases,
or generated passwords can therefore still leak when the host app or command
surface wraps them in nearby text.

## Desired Boundary

Axon should be able to make the stronger read/write-side statement:

> If a textual output contains a known active credential value, no literal
> characters from that credential leave Axon in that output.

This is stronger than exact field matching and needs an explicit design because
the index cannot simply expose provider plaintext to every redaction path.

## Affected Boundaries

- `look` AX text and child pages.
- `look(..., screenText: true)` OCR lines.
- Text-location resolution candidates and ambiguous-target error summaries.
- `find` locator candidates and matcher reason strings.
- `run` traces and debug pause snapshots.
- `save` history records and exported `.axn` scripts.
- MCP text content and structured content derived from any of the above.

## Constraints

- Do not store active credential plaintext at rest.
- Do not expose prefixes, suffixes, or partial fingerprints as metadata.
- Keep provider references in redaction metadata where exact matches are known.
- Avoid broad false positives that make ordinary app text unusable.

## Candidate Approaches

1. **Ephemeral plaintext scanner after refresh.** Keep active secrets only in
   process memory after `refresh-secrets`, use an Aho-Corasick-style matcher at
   redaction boundaries, and discard on daemon restart. This gives strong
   substring protection while preserving the disk boundary, but requires clear
   daemon lifecycle behavior.
2. **Token candidate HMAC scanning.** Split observed strings into plausible
   token/passphrase windows, HMAC each candidate, and compare to the exact
   index. This avoids retaining plaintext but cannot reliably catch secrets with
   spaces, punctuation, or unknown boundaries.
3. **Provider-on-demand comparison.** When a boundary sees high-risk text, ask
   the provider for active concealed values and compare in memory. This is
   strongest but can trigger auth prompts and would be too expensive for hot
   paths unless carefully cached.

## Next Steps

1. Decide whether Axon is allowed to keep active credential plaintext in daemon
   memory after an explicit refresh.
2. Add a failing fixture that proves a wrapped active credential currently leaks
   through `look` and `save`.
3. Implement one shared substring-capable active redaction primitive so output
   boundaries do not each invent local matching.
4. Revisit the `ActiveCredentialFilter.mightContain` name; today it means exact
   match, which is weaker than the method name implies.
