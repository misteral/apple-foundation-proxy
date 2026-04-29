# Reliability

## Per-request `LanguageModelSession`

Every request to `/v1/chat/completions` constructs a fresh `LanguageModelSession`. This is intentional:

- The proxy is stateless by design — clients are expected to send the full conversation history each turn (matching OpenAI's contract).
- A long-lived session would accumulate state across unrelated callers (an editor and a clipboard tool, say) and silently bias outputs.
- Session construction is cheap relative to model inference.

If you ever want to reuse a session, it must be scoped per logical client (e.g., per API key once auth exists), not global. Open a design doc before changing this.

## No streaming

The endpoint returns the full response text in a single JSON response. `stream: true` is not implemented yet — it should be additive (opt-in via the request flag) when added, not a replacement for the non-streaming path. See `docs/design-docs/openai-compatible-chat.md` for the forward-looking design.

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
