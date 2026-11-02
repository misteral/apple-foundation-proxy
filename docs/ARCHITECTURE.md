# Architecture

## Shape

Single executable Swift package, one source file:

- `Package.swift` — declares the `apple-foundation-proxy` executable target with one external dependency (Vapor 4.89+). `swift-tools-version: 5.10`. Platform floor is `macOS(.v14)` so the package resolves on older Macs; the FoundationModels code path itself requires macOS 26.
- `Sources/apple-foundation-proxy/main.swift` — DTOs, prompt helpers, route handlers, and `@main` entry point. There is no module split.
- `Tests/apple-foundation-proxyTests/apple_foundation_proxyTests.swift` — Swift Testing scaffolding (currently a single placeholder `@Test`).

Adding files is fine when something genuinely doesn't fit, but the design intent is "small, readable, one-process local tool." Resist module splits that exist only to mirror larger projects.

## Routes

Two endpoints, both on `127.0.0.1:8080`:

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/health` | Reports `FoundationModels` import status, runtime availability, and which locales `SystemLanguageModel.default` supports on the host. |
| `POST` | `/v1/chat/completions` | OpenAI-shaped request/response envelope. Generates text from `messages` via `LanguageModelSession`. Supports `response_format` and `tools` / `tool_choice`. |

The OpenAI compatibility covers text generation, structured output (`response_format`), and client-executed tool calls (`tools` / `tool_choice`). Streaming (`stream: true`) is supported for all of the above. Missing on purpose for now: `n > 1`, `logprobs`, multimodal content. `usage` is returned with zero counts because `FoundationModels` does not expose token usage.

## Request pipeline for `/v1/chat/completions`

1. **Validate `response_format.type`** (one of `text` / `json_object` / `json_schema`); reject unknown values with `400`. For `json_schema`, require a `json_schema` payload.
2. **`systemInstructions`** — joins all `system` and `developer` role messages into one instructions block (newline-separated). Returns nil when the request has none.
3. **`augmentInstructionsForJSONObject`** — when `type == "json_object"`, append a "respond with JSON only" directive to the instructions. FoundationModels has no native JSON mode, so this is best-effort.
4. **`renderPrompt`** — renders all `user`/`assistant` history as a labeled transcript and appends an empty `Assistant:` cue when the last turn is from the user. A single-user-message prompt is returned verbatim with no transcript framing.
5. **`buildGenerationSchema`** (only when `type == "json_schema"`) — translates the JSON Schema fragment into a `DynamicGenerationSchema` and wraps it in a `GenerationSchema`. Schema construction errors surface as `400` (run before opening the session so they don't get swallowed by the generic catch).
6. **`LanguageModelSession`** — a fresh session is created **per request**. Constructed with `instructions:` when those exist, otherwise with no instructions. No conversation state across requests.
7. **Generate.** When a schema is present, call `respond(to:schema:)` and return `response.content.jsonString` as `choices[0].message.content`. Otherwise call `respond(to:)` and return the text response.

8. **Stream** (only when `stream: true`) — instead of step 7, return an SSE response; see below.

Without `tools`, history is prompt-stuffed (step 4). With `tools`, the pipeline switches to a native `Transcript` — see below.

## Tool calls (`tools` / `tool_choice`)

OpenAI tools are executed by the **client**; FoundationModels tools are executed **in-process** by the session. The bridge is a pass-through `ProxyTool` per OpenAI definition:

1. **`parseToolChoice` + `selectTools`** — validate definitions (`type: "function"`, non-empty unique names) and apply `tool_choice`. `none` attaches no tools; a named function attaches only that tool. `required` / named function also add an instruction nudge (`toolChoiceDirective`) — FoundationModels cannot force a call.
2. **`splitToolConversation`** — the latest `user` message is the prompt; everything before it is history; `tool` results *after* it are pending results of the in-flight turn.
3. **`buildProxyTools`** — `function.parameters` goes through the same JSON Schema bridge as `response_format` (missing `parameters` = empty object). Unsupported schemas are `400`s.
4. **`buildTranscript`** — history becomes native `Transcript` entries: instructions (with tool definitions), prompts, responses, `toolCalls`, `toolOutput`. The session is `LanguageModelSession(tools:transcript:)`.
5. **Generate.** When the model calls a tool, `ProxyTool.call` either returns a pending client result from `ToolReplayCache` (replaying the round-trip), or records the call in `ToolInvocationRecorder` and throws `ProxyToolInvocation` to abort generation. Any non-empty recorder after a thrown error → response with `content: null`, `tool_calls`, `finish_reason: "tool_calls"`.

Replay matching: exact `(name, arguments)` first (order-insensitive JSON compare, reusable), then the first unconsumed result with the same tool name. The fallback exists because regeneration may phrase arguments slightly differently. Pending results for tools not attached this turn (e.g. `tool_choice: "none"`) are appended to the prompt as text.

Tool-call IDs are generated per response (`call_<24 hex>`); they are not stable across requests, which matches OpenAI.

## Streaming (`stream: true`)

The non-streaming path stays the default; streaming is opt-in per request. The response is `text/event-stream` built by `makeSSEResponse` on Vapor's `Response.Body(managedAsyncStream:)`:

1. A role chunk: `delta: {role: "assistant", content: ""}`.
2. Content chunks from `session.streamResponse(to:)`. FoundationModels yields **cumulative snapshots**, not deltas; `streamDelta(previous:current:)` turns them into the incremental `delta.content` OpenAI clients expect. If a snapshot ever stops extending the previous one, the text after the common prefix is sent (SSE can't take back text).
3. A finish chunk with an empty `delta` and `finish_reason` (`stop`, `tool_calls`, or `error`). Non-final chunks carry `finish_reason: null` explicitly.
4. With `stream_options.include_usage: true`, a usage chunk (`choices: []`, zeros).
5. `data: [DONE]`.

Tools: `streamResponse` invokes `Tool.call` mid-stream (verified on device), so `ProxyTool` behaves exactly as in the non-streaming path. A recorded invocation ends the stream with one `tool_calls` delta chunk (all calls, `index`ed) and `finish_reason: "tool_calls"`. Any text streamed before the call stays sent.

`json_schema` with `stream: true` is generated in full and sent as a single content chunk. Partial `GeneratedContent` snapshots re-serialize with the closing braces in different places, so they don't form a prefix-stable JSON text stream.

Errors mid-stream mirror the non-streaming path: an `Error during generation: ...` content chunk plus `finish_reason: "error"`. HTTP status is already `200` by then.

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
