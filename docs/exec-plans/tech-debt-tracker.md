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

_None._

---

## Resolved

- **[P1] Unsupported-locale requests are silently degraded.** Resolved as a signal, not a gate: `X-AFP-Detected-Language` / `X-AFP-Language-Supported` headers plus a warning log (NaturalLanguage detection, ≥ 20 letters, ≥ 0.8 confidence). FoundationModels' own `unsupportedLanguageOrLocale` → `400 unsupported_language`. Rationale in `docs/RELIABILITY.md`.
- **[P1] `usage` token counts are reported as zeros.** Real counts via `SystemLanguageModel.tokenCount` on macOS 26.4+, zeros below. The same tokenizer sizes the response budget (see below).
- **[P2] Schema bridge tests don't exercise the model.** Opt-in `IntegrationTests` suite (`AFP_INTEGRATION=1`) checks schema-conforming output, a tool round-trip, usage, and context overflow on the real model.
- **[P2] `finish_reason: "error"` is not an OpenAI value.** Removed. Generation failures are HTTP errors in OpenAI's format (400 / 429 / 503 / 500 with `error.code`), and mid-stream failures are OpenAI error events. Safety blocks remain `200` + `content_filter`.
- **[P2] Tool requests require a `user` message; plain requests don't.** `prepareCompletion` now requires a `user` message for every request.
- **[P2] Replayed tool results are lost if the model doesn't call the tool again.** Pending results are now appended to the prompt as text in addition to `ProxyTool` replay, so they reach the model either way (verified on device, single and parallel calls).
- **[P2] No `max_tokens` → runaway generations surface as a misleading 400.** `max_completion_tokens` / `max_tokens` map to `GenerationOptions(maximumResponseTokens:)`, clamped to the context left after the prompt; that clamp is the default cap when the client sends none. Runaway replies now end as `finish_reason: "length"` (regression test in `IntegrationTests`).
- **[P3] `temperature` / `top_p` silently ignored.** Mapped to `GenerationOptions` (`temperature`, nucleus / greedy `SamplingMode`), plus `seed` for reproducible replies; out-of-range values are a 400.
