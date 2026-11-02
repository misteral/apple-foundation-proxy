# Tech Debt Tracker

Prioritized list of known gaps. Add an entry before introducing a workaround; remove it when the workaround is replaced with the real fix.

## Format

```markdown
### [P?] Short title
**Where:** path:line or area
**What:** the gap
**Why it matters:** consequence today
**Fix sketch:** one-paragraph plan, or link to a design doc
```

Priority: `P0` blocks correctness, `P1` blocks a real use case, `P2` is hygiene.

---

## Active items

### [P1] Unsupported-locale requests are silently degraded
**Where:** `Sources/apple-foundation-proxy/main.swift` — `/v1/chat/completions` handler
**What:** if the prompt is in a locale that `SystemLanguageModel.default.supportsLocale(...)` reports as unsupported (e.g., `ru_RU` on the test machine), the request is sent to the model anyway and returns lower-quality output without any signal to the caller.
**Why it matters:** clients can't tell a real answer from "model produced something plausible-looking but worse than expected."
**Fix sketch:** detect the input language (best-effort heuristic on character ranges is enough for the languages this project cares about), check `supportsLocale()`, and either return a structured error or surface a flag in the response. Decide which during the design discussion. See `docs/RELIABILITY.md` for context.

### [P1] `usage` token counts are reported as zeros
**Where:** `Sources/apple-foundation-proxy/main.swift` — `/v1/chat/completions` handler
**What:** the `usage` object is populated with `prompt_tokens: 0`, `completion_tokens: 0`, `total_tokens: 0` because `FoundationModels` does not expose token counts.
**Why it matters:** clients that meter usage or cap requests by token budget will see zeros and either ignore the cap or refuse to bill. The field is present so decoding doesn't fail, but the values are dishonest.
**Fix sketch:** if `FoundationModels` adds a token-count surface, plumb it through. Until then, consider a best-effort character-based estimate (e.g., `len/4`) behind a documented caveat, or omit `usage` entirely if Vapor's encoder permits.

### [P2] Schema bridge tests don't exercise the model
**Where:** `Tests/apple-foundation-proxyTests/apple_foundation_proxyTests.swift` — `BuildGenerationSchemaTests`
**What:** the bridge tests verify that `buildGenerationSchema` constructs without throwing for valid input and rejects unsupported constructs, but they don't actually run a model request to confirm the produced schema yields conforming output.
**Why it matters:** a schema that builds cleanly may still produce malformed output when the model generates against it (e.g., if a property name collides with framework reserved words, or `anyOf` enum values aren't quoted as expected). Without an integration test, regressions are caught only by hand-running `curl`.
**Fix sketch:** add a separate integration target (gated, opt-in) that runs against Apple Intelligence on a developer machine and asserts the JSON output parses against a known schema. Skip in CI.

### [P2] `finish_reason: "error"` is not an OpenAI value
**Where:** `Sources/apple-foundation-proxy/main.swift` — `finishReason(for:)`, `failureOutcome`
**What:** generation failures other than safety blocks return `200` with an explanatory message and `finish_reason: "error"`. Safety blocks already map to the standard `content_filter`.
**Why it matters:** strict clients may reject the unknown value, and others treat the error text as a real answer.
**Fix sketch:** for non-streaming requests, return a real HTTP error (`500`, or `429` for `rateLimited` / `concurrentRequests`) with an OpenAI-style `error` object. Streaming can't change status after the first byte, so keep a message chunk there. This changes the client-visible contract, so it needs a decision first.

### [P2] Tool requests require a `user` message; plain requests don't
**Where:** `splitToolConversation`
**What:** with tools (or tool history), a request without any `user` message is a `400`. Without tools, the same request is accepted and the model gets an empty prompt.
**Why it matters:** an inconsistent contract, but both inputs are meaningless, so no real client is affected.
**Fix sketch:** reject a missing `user` message in `prepareCompletion` for all requests, once we're sure no client depends on the lenient path.

### [P2] Replayed tool results are lost if the model doesn't call the tool again
**Where:** `ToolReplayCache` / `ProxyTool` replay
**What:** pending tool results reach the model only when it calls the same tool again during regeneration. If it answers directly instead, the results are unused and nothing signals it.
**Why it matters:** never observed in on-device tests; the model called the tool again every time. A wrong answer would be silent, though.
**Fix sketch:** track which pending results were served. If generation finishes with some unserved, regenerate once with them appended as text (`appendToolResultsToPrompt`). Only worth doing if it's seen in practice.

---

## Resolved
_None yet._
