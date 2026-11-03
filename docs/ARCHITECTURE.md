# Architecture

## Shape

Single executable Swift package, one source file:

- `Package.swift` — declares the `apple-foundation-proxy` executable target with one external dependency (Vapor 4.89+). `swift-tools-version: 5.10`. Platform floor is `macOS(.v14)` so the package resolves on older Macs; the FoundationModels code path itself requires macOS 26.
- `Sources/apple-foundation-proxy/main.swift` — DTOs, prompt helpers, route handlers, and `@main` entry point. There is no module split.
- `Tests/apple-foundation-proxyTests/apple_foundation_proxyTests.swift` — Swift Testing suites for the pure helpers and the FoundationModels bridges (see `docs/TESTING.md`).

Adding files is fine when something genuinely doesn't fit, but the design intent is "small, readable, one-process local tool." Resist module splits that exist only to mirror larger projects.

## Routes

Two endpoints, both on `127.0.0.1:8080`:

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/health` | Reports `FoundationModels` import status, runtime availability, supported languages, context size, and capabilities (including whether token counting is available). |
| `POST` | `/v1/chat/completions` | OpenAI-shaped request/response envelope. Generates text from `messages` via `LanguageModelSession`. Supports `response_format` and `tools` / `tool_choice`. |

The OpenAI compatibility covers text generation, structured output (`response_format`), and client-executed tool calls (`tools` / `tool_choice`). Streaming (`stream: true`) is supported for all of the above. Missing on purpose for now: `n > 1`, `logprobs`, non-text content parts. `usage` is counted with the model's own tokenizer on macOS 26.4+ (zeros below).

## Request pipeline for `/v1/chat/completions`

The request body limit is raised to 4 MB (`app.routes.defaultMaxBodySize`). Vapor's 16 KB default returns `413` for ordinary agent traffic with tool schemas and tool results.

The route closure is a thin shell over top-level functions:

- **`prepareCompletion(_:)`** is pure and does all request validation, so every `400` is decided there and unit-tested. It produces a `PreparedCompletion`: instructions, prompt, active tools, tool conversation, stream flags, model name.
- **`makeCompletionSession(_:)`** (gated) builds the schema, tools and transcript and opens the session. It can still `400` on an unsupported schema or malformed tool-call arguments, always before generation starts.
- **`generateCompletion`** or **`makeStreamingCompletion`** (gated) runs the model and produces a `CompletionOutcome`: content, tool calls, finish reason.
- **`makeCompletionResponse`** (pure) builds the JSON response; streaming writes the same outcome as chunks.

Message `content` may be a string, `null`, or an array of parts. Text parts are joined with `\n`; any other part type (images, audio) is a `400`.

Steps inside `prepareCompletion` and `makeCompletionSession`:

0. **Require a `user` message**; requests without one are a `400`.
1. **Validate `response_format.type`** (one of `text` / `json_object` / `json_schema`); reject unknown values with `400`. For `json_schema`, require a `json_schema` payload.
2. **`systemInstructions`** — joins all `system` and `developer` role messages into one instructions block (newline-separated). Returns nil when the request has none.
3. **`augmentInstructionsForJSONObject`** — when `type == "json_object"`, append a "respond with JSON only" directive to the instructions. FoundationModels has no native JSON mode, so this is best-effort.
4. **`renderPrompt`** — renders all `user`/`assistant` history as a labeled transcript and appends an empty `Assistant:` cue when the last turn is from the user. A single-user-message prompt is returned verbatim with no transcript framing.
5. **`buildGenerationSchema`** (only when `type == "json_schema"`) — translates the JSON Schema fragment into a `DynamicGenerationSchema` and wraps it in a `GenerationSchema`. Schema construction errors surface as `400` (run before opening the session so they don't get swallowed by the generic catch).
6. **`LanguageModelSession`** — a fresh session is created **per request**. Constructed with `instructions:` when those exist, otherwise with no instructions. No conversation state across requests.
7. **Generate.** When a schema is present, call `respond(to:schema:)` and return `response.content.jsonString` as `choices[0].message.content`. Otherwise call `respond(to:)` and return the text response.
8. **Stream** (only when `stream: true`) — instead of step 7, return an SSE response; see below.

### Errors

`OpenAIErrorMiddleware` replaces Vapor's `ErrorMiddleware` (request logging is kept), so every error leaves the server as `{"error":{"message","type","param","code"}}`. `type` comes from the status: `invalid_request_error` for 4xx, `rate_limit_error` for 429, `server_error` for 5xx. Errors that need a `code` are `ProxyAPIError`.

Generation failures go through `apiError(for:)`. The message is the error context's debug description, which is specific (token counts and limit):

| `GenerationError` | Result |
|---|---|
| `guardrailViolation`, `refusal` | Not an error: `200`, `content: null`, `finish_reason: "content_filter"` (OpenAI's behavior) |
| `exceededContextWindowSize` | 400 `context_length_exceeded` |
| `unsupportedLanguageOrLocale` | 400 `unsupported_language` |
| `unsupportedGuide` | 400 `unsupported_schema` |
| `rateLimited`, `concurrentRequests` | 429 `rate_limit_exceeded` |
| `assetsUnavailable` | 503 `model_unavailable` |
| `decodingFailure`, anything else | 500 `generation_failed` |

### Usage

`measureUsage` uses `SystemLanguageModel.tokenCount` (macOS 26.4+, ~20 ms a call):

- `prompt_tokens` is the session transcript through the latest prompt entry: instructions, tool definitions, history, prompt.
- `completion_tokens` is the generated text, or the tool-call names and arguments. `tokenCount(for: String)` adds a fixed prompt wrapper (8 tokens on 26.6), so the empty-string baseline is subtracted.
- Replayed tool round-trips after the prompt aren't counted, so tool turns report a close lower bound.
- Counting failures fall back to zeros and never fail the request. Streams count only when `include_usage` is set.

### Response token budget

`applyResponseBudget` runs for every request, streaming or not, before generation starts. It counts the transcript plus prompt and sets `GenerationOptions(maximumResponseTokens:)` to `responseTokenBudget`: the client's `max_completion_tokens ?? max_tokens`, clamped to `contextSize − prompt − responseTokenMargin`.

Why it exists: FoundationModels doesn't check the window up front. It generates until the window fills and then throws `exceededContextWindowSize`, so a runaway reply to a short prompt used to surface as "context length exceeded". With the budget, the model truncates instead.

- **Truncation is silent.** The model stops exactly at the cap, so `finish_reason: "length"` is inferred by counting the output (`finishReason(completionTokens:budget:)`, with a 1-token tolerance because re-tokenizing can land one off).
- **Margin.** `responseTokenMargin` is 128 because the real limit sits below the nominal 4096: on macOS 26.6 a 16-token margin still failed ("4091 tokens exceeds 4096"), and 128 reached the cap cleanly.
- **No room left.** A prompt that leaves no room is a `400 context_length_exceeded` before generating.
- **Below macOS 26.4** there's no tokenizer: only the client's cap is applied, and `length` can't be detected.

### Sampling

`samplingParameters(from:)` validates `temperature` (0–2) and `top_p` (0–1) against OpenAI's ranges in `prepareCompletion`, because FoundationModels fails out-of-range values mid-generation with an opaque error (`top_p: 1.5` → `com.apple.tokengeneration Code=8`). `CompletionSession.options` maps them to `GenerationOptions`: `temperature` as is, and `SamplingParameters.mode` picks the `SamplingMode`. `top_p: 0` → `.greedy`; `top_p` or `seed` → `.random(probabilityThreshold: top_p ?? 1, seed:)`; neither → the model default. A seed gives reproducible replies (checked in `IntegrationTests`).

### Language signal

`detectLanguage` (NaturalLanguage, system framework) classifies the latest `user` message and returns nil under 20 letters or below 0.8 confidence: on short text NaturalLanguage guesses `hi` → Catalan. The detected code is compared by base language (`zh-Hans` → `zh`) against `SystemLanguageModel.supportedLanguages`. The result goes into `X-AFP-Detected-Language` / `X-AFP-Language-Supported` headers, including on error responses (`attachingHeaders`), plus a `notice` log line when unsupported (not `warning`: it fires on every such request). Requests are never rejected for language; see `docs/RELIABILITY.md`.

Without `tools`, history is prompt-stuffed (step 4). With `tools`, the pipeline switches to a native `Transcript` — see below.

## Tool calls (`tools` / `tool_choice`)

OpenAI tools are executed by the **client**; FoundationModels tools are executed **in-process** by the session. The bridge is a pass-through `ProxyTool` per OpenAI definition. The tool pipeline runs when the request declares `tools` **or** its history contains tool traffic (`needsToolPipeline`). Clients often omit `tools` on the final turn, and the prompt-stuffing path would drop the `tool` results.

1. **`parseToolChoice` + `selectTools`** — validate definitions (`type: "function"`, non-empty unique names) and apply `tool_choice` (`required` with no tools is a `400`, as in OpenAI). `none` attaches no tools; a named function attaches only that tool. `required` / named function also add an instruction nudge (`toolChoiceDirective`) — FoundationModels cannot force a call.
2. **`splitToolConversation`** — the latest `user` message is the prompt; everything before it is history; `tool` results *after* it are pending results of the in-flight turn.
3. **`buildProxyTools`** — `function.parameters` goes through the same JSON Schema bridge as `response_format` (missing `parameters` = empty object). Unsupported schemas are `400`s.
4. **`buildTranscript`** — history becomes native `Transcript` entries: instructions (with tool definitions), prompts, responses, `toolCalls`, `toolOutput`. The session is `LanguageModelSession(tools:transcript:)`.
5. **Generate.** When the model calls a tool, `ProxyTool.call` either returns a pending client result from `ToolReplayCache` (replaying the round-trip), or records the call in `ToolInvocationRecorder` and throws `ProxyToolInvocation` to abort generation. Any non-empty recorder after a thrown error → response with `content: null`, `tool_calls`, `finish_reason: "tool_calls"`.

Replay matching (`ToolReplayCache`): exact `(name, arguments)` first (order-insensitive JSON compare), then the same comparison on normalized arguments (`normalizedForMatching`: strings trimmed, lowercased, whitespace collapsed; `2.0` == `2`), because regeneration may vary casing or spacing. Matches are reusable. There is no name-only fallback, because it would hand one call's result to a different call (Paris weather for London). An unmatched call goes back to the client as a new `tool_calls`. Pending results are *also* appended to the prompt as text (`appendToolResultsToPrompt`). Replay alone would lose them if the model answered without calling the tool again; with both, the result reaches the model either way. Verified on device: replay answers stay correct with the duplicated results (single and parallel calls).

Tool-call IDs are generated per response (`call_<24 hex>`); they are not stable across requests, which matches OpenAI.

## Streaming (`stream: true`)

The non-streaming path stays the default; streaming is opt-in per request. The response is `text/event-stream` built by `makeSSEResponse` on Vapor's `Response.Body(managedAsyncStream:)`:

1. A role chunk: `delta: {role: "assistant", content: ""}`.
2. Content chunks from `session.streamResponse(to:)`. FoundationModels yields **cumulative snapshots**, not deltas; `streamDelta(previous:current:)` turns them into the incremental `delta.content` OpenAI clients expect. If a snapshot ever stops extending the previous one, the text after the common prefix is sent (SSE can't take back text).
3. A finish chunk with an empty `delta` and `finish_reason` (`stop`, `tool_calls`, or `content_filter`). Non-final chunks carry `finish_reason: null` explicitly.
4. With `stream_options.include_usage: true`, a usage chunk (`choices: []`, counts as above).
5. `data: [DONE]`.

Tools: `streamResponse` invokes `Tool.call` mid-stream (verified on device), so `ProxyTool` behaves exactly as in the non-streaming path. A recorded invocation ends the stream with one `tool_calls` delta chunk (all calls, `index`ed) and `finish_reason: "tool_calls"`. Any text streamed before the call stays sent.

`json_schema` with `stream: true` is generated in full and sent as a single content chunk. Partial `GeneratedContent` snapshots re-serialize with the closing braces in different places, so they don't form a prefix-stable JSON text stream.

A failed SSE write (client disconnected) is told apart from a generation error (`StreamWriteFailed`). It ends the stream quietly, without an error chunk or error log. Before the stream opens, `applyResponseBudget` (below) rejects a prompt that can't fit with a real `400 context_length_exceeded`. After that the status is committed as `200`, so any other generation error is sent as an OpenAI error event (`data: {"error":{...}}`) followed by `[DONE]`, with no finish chunk. OpenAI SDKs raise it as an `APIError`.

## Supported JSON Schema subset (for `response_format.json_schema`)

| JSON Schema | FoundationModels mapping |
|-------------|---------------------------|
| `type: "object"` with `properties` and `required` | `DynamicGenerationSchema(name:description:properties:)`; `Property.isOptional = !required.contains(key)` |
| `type: "string"` | `DynamicGenerationSchema(type: String.self)` |
| `type: "string"` with `enum` | `DynamicGenerationSchema(name:description:anyOf:)` over the string values |
| `type: "integer"` / `"number"` / `"boolean"` | `DynamicGenerationSchema(type: Int.self / Double.self / Bool.self)` |
| `type: "array"` with `items`, optional `minItems`/`maxItems` | `DynamicGenerationSchema(arrayOf:minimumElements:maximumElements:)` |
| `additionalProperties: false` | Accepted, ignored — `DynamicGenerationSchema` already produces closed objects, so this is a no-op. Required by the OpenAI `strict: true` convention. |

Rejected with `400` (initial release): `oneOf`, `anyOf`, `allOf`, `$ref`, `pattern`, `format`, `additionalProperties: true`, and `additionalProperties` set to anything other than a boolean (e.g. a typed extension schema). Property `description` strings are forwarded into `DynamicGenerationSchema.Property.description`.

## Dual-mode build

The project must build on toolchains both with and without `FoundationModels`:

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif

// ...

#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    // real path
}
#else
// mock fallback
#endif
```

On older toolchains, `/v1/chat/completions` returns a `[Mock Apple Intelligence Response]` string. This is deliberate so the project compiles in CI and on machines without Apple Intelligence — see `docs/CODING_STANDARDS.md` for the rule.

## What this project is not

- Not a full OpenAI emulator. The OpenAI shape is a calling convention; `n > 1`, `logprobs`, and vision are not implemented.
- Not a chat assistant with memory. There is no server-side state across requests by design — clients send the full message history each turn.
- Not production-ready as a network service. Local-only; see `docs/SECURITY.md`.
