# Screenshot Pixel Secret Redaction

## Context

The active-secret HMAC index in [Active-Secret Redaction And Late-Bound Credentials](2026-05-13-late-bound-values-and-credentials.md) protects textual AX-derived output. It does not by itself protect pixels.

The tool-surface consolidation makes this simpler than it would have been before: screenshots now flow through `look(..., screenshot: true)` instead of a separate screenshot tool. That gives Axon one perception boundary where text redaction, OCR redaction, and screenshot policy can be coordinated.

The remaining leak path is visual: a password, recovery code, API key, or OTP seed may be visible in a screenshot even when the AX tree output is redacted. If that screenshot is returned through MCP or CLI output, the raw secret can still leave Axon as pixels.

## Desired Boundary

Eventually, Axon should be able to say:

> Active credentials cannot leave Axon output as text or pixels when provider-backed active-secret protection is enabled.

That requires a visual redaction layer inside `look` before screenshot-bearing responses are returned.

## Affected Outputs

- `look(target, screenshot: true)`
- `look(target, screenshot: true, tree: false)`
- `look(target, screenText: true)`
- Any future `look` modality that embeds an image, a cropped region, OCR text, or video frame

## First Guard

Before full spatial masking exists, `look` should still avoid obvious unsafe image returns:

1. Capture AX tree and/or OCR text.
2. Run text through the active-secret redactor.
3. If the text path redacts an active credential and `screenshot: true` was requested, do not return the unmasked screenshot.
4. Return the redacted textual observation plus metadata explaining that the screenshot modality was refused or omitted because active credentials were detected.

This does not prove pixels are safe when text redaction finds nothing. It only prevents returning a screenshot that Axon already has strong evidence contains a secret.

Status: implemented for AX text, returned `screenText`, and screenshot-only requests that can be OCR-checked internally. The image is omitted with a warning rather than masked.

## Full Spatial Redaction

The full version needs region masking:

1. Capture screenshot.
2. Run OCR and/or AX text geometry to locate visible strings.
3. Pass OCR text through the same active-secret redactor.
4. Mask the image regions corresponding to redacted text before returning pixels.
5. Return redaction metadata that reports masked regions and reasons without revealing the value.

## Hard Parts

- OCR may miss or misread secrets, especially in small text, custom fonts, or masked/unmasked password fields.
- AX text geometry is app-dependent and not always available.
- A visible secret may be split across multiple text runs or partially obscured.
- Cropped screenshots and future video/frame outputs need the same policy, not a special-case path.
- False positives in image masking are acceptable; false negatives are the security risk.

## Non-Goals

- No claim that screenshot modality is active-secret safe before spatial masking exists.
- No attempt to infer secrets from visual patterns alone in the first pass.
- No model-provider upload of unmasked screenshots as part of redaction.

## Next Steps

1. Done: Add the first guard in `look`: omit/refuse screenshot output when text redaction detects an active credential in the same response.
2. Decide whether image-returning `look` calls should also be warning-gated whenever active-secret protection is configured, even if the text path finds no active credential.
3. Prototype OCR-based masking for text regions that exactly match active-secret index hits.
4. Add tests with synthetic screenshots containing known secret fixtures.
5. Wire redaction metadata into screenshot responses.
