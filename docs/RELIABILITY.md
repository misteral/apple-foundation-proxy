# Reliability

## Per-request `LanguageModelSession`

Every request to `/v1/chat/completions` constructs a fresh `LanguageModelSession`. This is intentional:

- The proxy is stateless by design — clients are expected to send the full conversation history each turn (matching OpenAI's contract).
- A long-lived session would accumulate state across unrelated callers (an editor and a clipboard tool, say) and silently bias outputs.
- Session construction is cheap relative to model inference.

If you ever want to reuse a session, it must be scoped per logical client (e.g., per API key once auth exists), not global. Open a design doc before changing this.

## Streaming is additive

Non-streaming JSON is the default; `stream: true` opts into SSE per request. Keep it that way, and don't route the non-streaming path through the stream. Once the first SSE byte is sent the status is committed as `200`, so generation errors mid-stream come back as an OpenAI error event, not an HTTP status. A prompt that can't fit is rejected by the response budget before the stream opens, so it still gets a 400. Request validation (schemas, tools, `tool_choice`) runs before the stream opens, so those failures still return `400`. Details: `docs/ARCHITECTURE.md`.

## Locale support

`SystemLanguageModel.default.supportsLocale(...)` is the source of truth. The `/health` endpoint surfaces what the host reports.

Observed today on the project owner's machine:

- `en_US` — supported.
- `ru_RU` — **unsupported** despite the proxy "working" for Russian text. Output quality is noticeably lower; treat Russian as best-effort, not a feature. Calling code that cares should consult `/health` first.

**Decision: signal, don't block.** The proxy detects the latest user message's language and reports it in `X-AFP-Detected-Language` / `X-AFP-Language-Supported` response headers, with a `notice` in the log when unsupported. It doesn't reject the request, because the owner does use Russian through the proxy and degraded output beats no output. A client that wants strictness can check the header. The only language-related error is when FoundationModels itself refuses (`unsupportedLanguageOrLocale` → `400 unsupported_language`). Mechanics: `docs/ARCHITECTURE.md`.

## Error handling

- Generation failures become real HTTP errors in OpenAI's format (`apiError(for:)`: 400 / 429 / 503 / 500 with an `error.code`). Safety blocks are the exception: `200` with `finish_reason: "content_filter"`, as OpenAI does. Inside a running stream, errors arrive as an error event. Table: `docs/ARCHITECTURE.md`.
- The mock fallback path (no `FoundationModels`) returns a clearly tagged `[Mock Apple Intelligence Response]` string so it is impossible to mistake for real output.

## Performance constraints

- `FoundationModels` runs on-device and shares a finite Apple Intelligence quota with everything else on the Mac. Treat throughput as scarce.
- Do not benchmark by hammering the endpoint in a tight loop — you will throttle Apple Intelligence system-wide and skew results. Sequential, paced requests are the realistic profile.
