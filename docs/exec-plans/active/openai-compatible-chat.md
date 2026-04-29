# OpenAI-compatible chat completions — Execution Plan

**Status:** active
**Owner:** repo owner
**Design doc:** [docs/design-docs/openai-compatible-chat.md](../../design-docs/openai-compatible-chat.md)

## Goal

Ship a general OpenAI-compatible `POST /v1/chat/completions` endpoint that supports:

1. **Streaming** (`stream: true` → SSE)
2. **Tool calls** (`tools`, `tool_choice`, `tool_calls` round-trip)
3. **Structured output** (`response_format: json_schema` with arbitrary JSON Schema)

Move existing dictation behavior to `POST /v1/dictation/correct` so the general endpoint is unburdened by special-cases.

## Sub-tasks

Each task is sized to be independently mergeable. Validation criteria are mechanical (build, test, or `curl` smoke).

### Phase 0 — Spikes (resolve unknowns before building)

- [ ] **S1: GenerationSchema runtime construction.** Read `FoundationModels.GenerationSchema` public surface in Xcode. Determine: can `GenerationSchema` be built from a dynamic dictionary, or only via the `@Generable` macro? Document findings inline in the design doc under "JSON Schema ↔ GenerationSchema bridge."
  - **Validation:** a 20-line throwaway `swift run` snippet that builds a `GenerationSchema` for `{type:"object", properties:{name:{type:"string"}}}` and uses it with `respond(to:schema:...)`. Either it works (proceed) or we have a written reason it can't (degrade scope).

- [ ] **S2: Transcript public surface.** Determine what `Transcript` accepts and whether it can model OpenAI's full message list (assistant tool calls, tool results, multiple system messages).
  - **Validation:** a snippet that constructs a 3-turn `Transcript` (system, user, assistant) and instantiates `LanguageModelSession(model:tools:transcript:)` successfully. Document the entry types in the design doc.

- [ ] **S3: `streamResponse` + `Tool.call` interaction.** Determine whether `Tool.call` is invoked during `streamResponse` (vs the framework deferring tools to non-streaming paths). Build a stream with one tool registered, prompt that should invoke it, observe.
  - **Validation:** stdout log showing whether `Tool.call` ran during a streaming response. If it does not run mid-stream, the design doc's "Streaming variant" branch updates to "tools force non-streaming" and we document that limitation.

- [ ] **S4: GenerationOptions surface.** Enumerate fields on `GenerationOptions` and map them to OpenAI's `temperature`, `top_p`, `max_tokens`, `presence_penalty`, etc. Anything without a mapping gets a debug log when supplied.
  - **Validation:** a table in the design doc with two columns (OpenAI field, FoundationModels equivalent or "ignored").

Spikes write their findings back into `docs/design-docs/openai-compatible-chat.md` "Decisions Log" — they are not throwaway investigation.

### Phase 1 — File/module restructure

- [ ] **R1: Split `main.swift` into route modules.** Move dictation route to `Sources/apple-foundation-proxy/Routes/DictationRoute.swift`, health to `Routes/HealthRoute.swift`. `main.swift` becomes the entry point + route registration only. No behavior change.
  - **Validation:** `swift build` passes; `curl /health` and the existing dictation `curl` example both produce identical output to before.

- [ ] **R2: Repath dictation.** Register dictation handler at `POST /v1/dictation/correct`. Remove it from `POST /v1/chat/completions`. Update `README.md` example.
  - **Validation:** `curl /v1/dictation/correct` works; `curl /v1/chat/completions` returns 404 (until R3 lands).

### Phase 2 — General chat endpoint, text-only

Build the new endpoint without tools or structured output first. This validates the message → Prompt/Instructions/Transcript pipeline in isolation.

- [ ] **C1: OpenAI DTOs.** Define `Codable` types for the full chat completions request/response surface in `Sources/apple-foundation-proxy/OpenAI/DTOs.swift`. Cover: messages with all roles (`system`/`developer`/`user`/`assistant`/`tool`), `tool_calls` on assistant messages, `tool_call_id` on tool messages, `tools`, `tool_choice`, `response_format`, `stream`.
  - **Validation:** unit tests round-tripping fixtures lifted verbatim from OpenAI's API examples (one per role, one with `tool_calls`, one with `response_format: json_schema`).

- [ ] **C2: TranscriptBuilder.** `Sources/apple-foundation-proxy/FoundationModelsBridge/TranscriptBuilder.swift` — pure function `build(messages:) -> (Instructions, Prompt, Transcript)`. Concatenate `system`/`developer` into `Instructions`; treat the last `user` message as the `Prompt`; build `Transcript` from earlier turns.
  - **Validation:** unit tests for: (a) single user message, (b) system + user, (c) multi-turn user/assistant alternation, (d) message with tool result.

- [ ] **C3: ChatCompletionsRoute (non-streaming, text only).** New handler at `POST /v1/chat/completions`. Decode request, build session via `TranscriptBuilder`, call `respond(to:options:)`, return `CreateChatCompletionResponse` with `finish_reason: "stop"`.
  - **Validation:** `curl` smoke with multi-turn history; response matches OpenAI envelope (id, object: "chat.completion", created, choices, model). Field order and presence checked against an OpenAI-compatible client (e.g. `openai` Python SDK pointed at `http://127.0.0.1:8080/v1`).

- [ ] **C4: GenerationOptions mapping.** Wire `temperature`, `max_tokens`, `top_p` through `GenerationOptions` per the S4 spike findings. Reject `n > 1` with HTTP 400.
  - **Validation:** request with `temperature: 0.0` produces deterministic output across two runs; request with `n: 2` returns 400 with a structured error.

### Phase 3 — Streaming

- [ ] **ST1: SSEWriter.** `Sources/apple-foundation-proxy/OpenAI/SSEWriter.swift` — wraps Vapor's `Response.body = .init(stream: ...)` and writes `data: <json>\n\n` lines, ending with `data: [DONE]\n\n`. No business logic — just framing.
  - **Validation:** unit test that exercises `SSEWriter` against an in-memory writer and asserts framing exactly matches OpenAI's spec (including the `[DONE]` sentinel).

- [ ] **ST2: StreamAdapter.** `Sources/apple-foundation-proxy/FoundationModelsBridge/StreamAdapter.swift` — consumes `LanguageModelSession.ResponseStream<String>` and emits `CreateChatCompletionStreamResponse` chunks. First chunk carries `delta.role: "assistant"`; subsequent chunks carry `delta.content` deltas (token-level if FM provides; otherwise text-diff between successive partials); final chunk carries `finish_reason: "stop"` and empty delta.
  - **Validation:** smoke test with `openai` Python SDK in streaming mode; reassembled output matches the non-streaming response for the same prompt within deterministic settings.

- [ ] **ST3: Wire streaming into ChatCompletionsRoute.** Branch on `stream: true`: use `SSEWriter` + `StreamAdapter` instead of returning a single body.
  - **Validation:** `curl -N` shows incremental output; `[DONE]` sentinel arrives.

### Phase 4 — Structured output

- [ ] **SO1: JSONSchemaBridge.** `Sources/apple-foundation-proxy/OpenAI/JSONSchemaBridge.swift` — translates the supported JSON Schema subset (per design doc) into `GenerationSchema`. Reject unsupported constructs with a typed error that the route maps to HTTP 400.
  - **Validation:** unit tests for each supported construct (object, primitives, array, nested, enum) plus rejection tests for `oneOf`, `$ref`, `pattern`.

- [ ] **SO2: response_format wiring.** When `response_format.type == "json_schema"`, route to `respond(to:schema:...)` and serialize the resulting `GeneratedContent` to JSON for `choices[0].message.content`. When `response_format.type == "json_object"`, fall back to text mode with strong instructions and a post-validation pass; on parse failure return the raw text plus a debug log.
  - **Validation:** request with a small object schema (name + age) returns valid JSON parseable against the original schema; request with `oneOf` returns 400.

- [ ] **SO3: Streaming structured output (best-effort).** Use `streamResponse(to:schema:...)`; serialize partial `GeneratedContent` per chunk. Document in the design doc that mid-stream chunks may not be standalone-parseable — clients should accumulate.
  - **Validation:** streamed output reassembles into the same JSON as the non-streaming path. Parsing each individual chunk as JSON is *not* asserted.

### Phase 5 — Tool calls

- [ ] **TC1: ProxyTool.** `Sources/apple-foundation-proxy/FoundationModelsBridge/ProxyTool.swift` — implements `Tool` with `Arguments = GeneratedContent`, parameters built from the OpenAI JSON Schema via `JSONSchemaBridge`, and `call(arguments:)` that throws `ProxyToolInvocation(id:, name:, arguments:)`. The error carries the captured args as a JSON string ready for the OpenAI response.
  - **Validation:** unit test that constructs a `ProxyTool`, calls `call(arguments:)` directly, asserts the error type and payload.

- [ ] **TC2: Outbound tool_calls translation (non-streaming).** In the route, when `respond` throws `ProxyToolInvocation`, build an OpenAI response with `choices[0].message.tool_calls` populated and `finish_reason: "tool_calls"`. Generate stable `tool_call_id`s (UUID).
  - **Validation:** smoke with a request carrying one tool definition and a prompt that should invoke it; response matches OpenAI's tool-call envelope; `tool_call_id` is unique per invocation.

- [ ] **TC3: Inbound tool_results round-trip.** When the request's message list ends with one or more `role: tool` results: build a `ProxyTool` whose `call(arguments:)` returns the supplied result for that `tool_call_id` (matched against the prior assistant message's `tool_calls`); replay the request via `LanguageModelSession(transcript:)`; produce the next assistant turn.
  - **Validation:** two-turn smoke (request → tool_call → request with tool result → final assistant message). Final message references the tool's output content.

- [ ] **TC4: tool_choice.** Honor `tool_choice: "none"` (do not register tools), `"auto"` (default), `"required"` (register tools and instruct the model that it must call one — there's no FM-native enforcement, so this is best-effort with a strong instruction), and `{type:"function", function:{name}}` (register only the named tool).
  - **Validation:** test each branch with a probe prompt; document any cases where the framework refuses to call a tool despite `required`.

- [ ] **TC5: Streaming tool_calls.** Per S3 outcome: either emit `tool_calls` chunks with index-based deltas (per OpenAI spec), or fall back to non-streaming when tools are present and document the limitation.
  - **Validation:** if streaming supported, `openai` SDK's streaming tool-call path reassembles arguments correctly. If not, requests with both `stream: true` and non-empty `tools` return 400 with a clear message.

### Phase 6 — Polish

- [ ] **P1: Health capabilities.** Extend `/health` per design doc with a `capabilities` block reflecting the actual feature flags on the running host (e.g., streaming-with-tools may be false depending on S3).
  - **Validation:** `/health` JSON includes `capabilities` block with all four keys.

- [ ] **P2: Error surface.** Map FoundationModels errors and bridge errors to OpenAI-shaped error responses (`{error: {message, type, code}}`) instead of the current `200` + error-string-in-content. Status codes: 400 for client errors (unsupported schema, n>1, multimodal content), 500 for model errors, 503 when `SystemLanguageModel.default.availability` is not `.available`.
  - **Validation:** each error path reproduces with a known-bad request and returns the correct status + body shape.

- [ ] **P3: Documentation.** Update `README.md` with general endpoint examples (multi-turn, tools, streaming, json_schema). Update `docs/ARCHITECTURE.md` with the new file layout and request flow. Move this plan to `docs/exec-plans/completed/` with a brief outcome note.
  - **Validation:** `README.md` examples produce expected output when copy-pasted.

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-29 | Pass-through `ProxyTool` with sentinel exception over server-side execution | OpenAI tools are client-executed by contract; FoundationModels tools are in-process. The sentinel approach preserves OpenAI semantics without requiring the proxy to host arbitrary code. |
| 2026-04-29 | New endpoint at `/v1/chat/completions`; dictation moves to `/v1/dictation/correct` | Per `dictation-only-endpoint.md` "When to revisit" — siblings preferred over generalization, but the generic chat path is the one OpenAI clients expect. |
| 2026-04-29 | Reject `n > 1`, multimodal content, `oneOf`/`$ref` JSON Schema with HTTP 400 | Better to fail loudly than degrade silently; FoundationModels has no equivalent. |
| 2026-04-29 | `Arguments = GeneratedContent` on `ProxyTool` | Cannot synthesize Swift types at runtime; `GeneratedContent` is the type-erased generable representation FoundationModels exposes. |

## Known Risks

- **R1 — `GenerationSchema` may not support runtime construction.** Mitigation: spike S1 first; if it doesn't, structured output degrades to prompt-instructed JSON and the design doc updates accordingly. Do not start Phase 4 work until S1 resolves.
- **R2 — `Tool.call` may not be invoked mid-stream.** Mitigation: spike S3; fall back to forcing non-streaming for any request with tools, documented in `/health` capabilities.
- **R3 — `Transcript` may not model assistant tool calls.** Mitigation: prompt-stuff prior turns as a rendered textual transcript. Uglier but always works.
- **R4 — Sentinel-via-exception is a stretch of `Tool`'s contract.** A future FoundationModels SDK may invalidate this pattern (e.g., by retrying tools that throw, or by silencing exceptions). Mitigation: pin to specific SDK behavior in tests; revisit when the SDK changes.
- **R5 — Apple Intelligence quota throttling under load.** Already a constraint for the dictation endpoint; surface area grows with this work. Mitigation: document in `RELIABILITY.md`; do not benchmark in tight loops.

## Out of scope

The following are explicitly **not** in this plan:

- Authentication / API keys
- Rate limiting
- Vision / audio / multimodal inputs
- `n > 1` parallel sampling
- `logprobs`
- Vector embeddings (`POST /v1/embeddings`)
- Persisting conversations server-side (the proxy stays stateless)

Each is a separate plan if and when it's needed.
