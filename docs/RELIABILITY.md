# Reliability

## Per-request `LanguageModelSession`

Every request to `/v1/chat/completions` constructs a fresh `LanguageModelSession`. This is intentional:

- The proxy is stateless by design — clients are expected to send the full conversation history each turn (matching OpenAI's contract).
- A long-lived session would accumulate state across unrelated callers (an editor and a clipboard tool, say) and silently bias outputs.
- Session construction is cheap relative to model inference.

If you ever want to reuse a session, it must be scoped per logical client (e.g., per API key once auth exists), not global. Open a design doc before changing this.

## Streaming is additive

Non-streaming JSON is the default; `stream: true` opts into SSE per request. Keep it that way, and don't route the non-streaming path through the stream. Once the first SSE byte is sent the status is committed as `200`, so generation errors mid-stream come back as a content chunk plus `finish_reason: "error"`, not an HTTP error. Request validation (schemas, tools, `tool_choice`) runs before the stream opens, so those failures still return `400`. Details: `docs/ARCHITECTURE.md`.

## Locale support

`SystemLanguageModel.default.supportsLocale(...)` is the source of truth. The `/health` endpoint surfaces what the host reports.

Observed today on the project owner's machine:

- `en_US` — supported.
- `ru_RU` — **unsupported** despite the proxy "working" for Russian text. Output quality is noticeably lower; treat Russian as best-effort, not a feature. Calling code that cares should consult `/health` first.

If `supportsLocale()` returns false for the input's language, the right move is to surface a structured error rather than silently producing degraded output. This is not currently implemented — it's a known gap (see `docs/exec-plans/tech-debt-tracker.md`).

## Error handling

- `try await session.respond(to:)` is wrapped in a `do/catch`. On failure the response body contains `Error during generation: <message>` and an error is logged. The HTTP status stays `200` — clients shaped for OpenAI may not check status anyway, and they will see the error in the response text. Revisit if a real client depends on status codes.
- The mock fallback path (no `FoundationModels`) returns a clearly tagged `[Mock Apple Intelligence Response]` string so it is impossible to mistake for real output.

## Performance constraints

- `FoundationModels` runs on-device and shares a finite Apple Intelligence quota with everything else on the Mac. Treat throughput as scarce.
- Do not benchmark by hammering the endpoint in a tight loop — you will throttle Apple Intelligence system-wide and skew results. Sequential, paced requests are the realistic profile.
