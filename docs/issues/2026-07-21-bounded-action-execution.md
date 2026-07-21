# Bounded action execution in the daemon

Follow-up from the visual-overlay main-queue deadlock (fixed separately: `axon serve` now runs an AppKit run loop on the main thread, and the overlay's display wait is deadline-bounded).

## What the incident exposed

The daemon has no per-request deadline. A socket worker runs a command to completion on the concurrent client queue and answers whenever it finishes; nothing bounds how long that takes. When something inside a handler blocked forever, the symptom was a client timeout with no daemon-side error, a worker thread and socket leaked per request, and no log line anywhere saying which request was stuck. Diagnosis needed `sample` on the running process.

Two unbounded calls were observed first-hand during that investigation:

- **Accessibility messaging.** `AXPrimitiveActionExecutor` calls `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, and `AXUIElementCopyAttributeValue` without ever calling `AXUIElementSetMessagingTimeout`, so every call relies on the system default (about six seconds). A target app that stops servicing its accessibility port stalls the worker for that long per call, and a snapshot makes many calls.
- **Keychain access.** `ActiveCredentialFilterLoader.loadOrEmpty()` runs on every routed command and reaches `SecItemCopyMatching`. Under an unsigned development build this blocked indefinitely inside securityd's mutex, wedging every subsequent request including `health`. The installed signed daemon has the ACL entry and returns immediately, so this is not a user-visible bug today, but it is the same unbounded shape: a per-request dependency on an external service with no deadline.

## What is worth doing

- Set an explicit accessibility messaging timeout on the elements the executor touches, so AX stalls surface as errors rather than as multi-second silence.
- Give each routed request a deadline, and answer with a JSON-RPC error naming the method and the elapsed time when it expires. A caller learning *what* timed out is worth more than the request eventually succeeding.
- Log slow requests with their method and duration, so a stuck daemon can be diagnosed from its log instead of from a process sample.

Out of scope when this was written: the deadlock that prompted it had a proven root cause and a targeted fix, and bounding execution deliberately is a larger design question about what the daemon promises its callers.
