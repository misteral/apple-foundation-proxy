# Testing

## Framework

This project uses **Swift Testing** (the new `import Testing` framework with `@Test` macros), not XCTest. Do not add `import XCTest` to test files; mixing the two is supported but unnecessary here.

## Commands

```bash
swift test                        # Full suite
swift test --filter <TestName>    # Single test by name
swift test --parallel             # Parallel execution (default in Swift Testing is concurrent already)
```

There is no separate lint step; `swift build` is the type/syntax gate.

## What to test

The pure helpers in `main.swift` are the high-leverage targets — they are deterministic and don't require `FoundationModels` at runtime:

- `systemInstructions(from:)` — joins multiple `system`/`developer` messages, returns nil when none, ignores other roles.
- `renderPrompt(from:)` — single-user-message passthrough, multi-turn transcript rendering, `Assistant:` cue only when the last turn is `user`, behavior when only `system` messages are present.
- `augmentInstructionsForJSONObject(_:)` — appends the JSON directive verbatim when no base instructions, joins with `\n\n` otherwise.
- `JSONValue` decoding — primitives, arrays, objects, round-trip through `JSONEncoder`/`JSONDecoder`, accessor helpers.
- `ChatCompletionRequest` decoding — verify `response_format` and nested `json_schema` decode from the OpenAI wire format; `tools`, `tool_choice`, `tool_calls`, `tool_call_id`, null `content`.
- Tool helpers — `parseToolChoice`, `toolChoiceDirective`, `selectTools`, `splitToolConversation`, `appendToolResultsToPrompt`, `ToolReplayCache`, `ToolInvocationRecorder`. `buildProxyTools`, `ProxyTool.call`, and `buildTranscript` are FoundationModels-gated like the schema bridge.
- `prepareCompletion` — the single place request validation lives, so this is where the `400`-vs-`200` contract is tested (formats, tool definitions, `tool_choice`, tool pipeline selection, prompt with text-fallback tool results).
- `Message` content decoding — string / `null` / missing / text-part arrays; non-text parts rejected.
- `makeCompletionResponse`, `mockCompletionOutcome`; gated: `finishReason(for:)` (`content_filter` mapping), `failureOutcome`.
- Errors — `makeOpenAIErrorBody`, `OpenAIErrorMiddleware` (driven with a throwing responder, no server), `attachingHeaders`; gated: `apiError(for:)` mapping table, `failureOutcome` contract.
- Language — `detectLanguage` (confident text vs. short / letter-poor text), base-code matching, headers. Detection tests are gated on `canImport(NaturalLanguage)`.
- Response budget — `responseTokenBudget` (clamping, no-room 400), `finishReason(completionTokens:budget:)`, `max_tokens` / `max_completion_tokens` parsing and validation.
- Streaming helpers — `streamDelta` (prefix, divergence, multi-byte), `sseEvent` framing, `ChunkFactory` chunk shapes (explicit `finish_reason: null`, omitted unset delta fields, indexed tool calls, usage trailer).

The `buildGenerationSchema(from:)` bridge requires `FoundationModels` types, so its tests are gated behind `#if canImport(FoundationModels)` and skip at runtime via `#available(macOS 26.0, *)` on older OSes. Cover both happy paths (object/array/enum/scalar) and the rejection cases (`oneOf`/`anyOf`/`allOf`/`$ref`/`pattern`/`format`/`additionalProperties`, missing `items`, unknown `type`, non-object fragment, missing `schema`).

## What not to test in unit tests

- The actual `LanguageModelSession.respond(to:)` call in the default run: it is non-deterministic and needs Apple Intelligence. That's what the opt-in integration suite is for (below).
- The `#if canImport(FoundationModels)` branches. They are compile-time switches; covering them needs two toolchains, not two test cases.

## Integration tests (opt-in, real model)

```bash
AFP_INTEGRATION=1 swift test --filter IntegrationTests
```

`Tests/apple-foundation-proxyTests/IntegrationTests.swift` runs against Apple Intelligence through the handler's own functions (`prepareCompletion` → `makeCompletionSession` → `generateCompletion`). It covers schema-conforming output (types, enum, array bounds), a tool round-trip, real `usage`, context overflow (FoundationModels' own error and the budget's up-front 400), `max_tokens` → `length`, and the runaway-reply regression (fills the window → now `length`, not an error). Assertions are structural, so they hold despite sampling. The suite is disabled without the env var, so the default `swift test` and CI never touch the model.

## Manual smoke test

```bash
swift run &  # in another terminal
curl -s http://127.0.0.1:8080/health | python3 -m json.tool
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"apple-foundation-model","messages":[{"role":"system","content":"You are concise."},{"role":"user","content":"Name three primary colors."}]}'
```

Confirm that:
- `/health` reports `runtimeSupported: true` and `modelAvailability: "available"` on an Apple Intelligence-capable Mac.
- The chat response is a sensible answer that respects the `system` message (try with and without a `system` message).
- Multi-turn requests (a `user`/`assistant`/`user` sequence) produce output that reflects the prior turns.
- A request with `tools` that needs a tool returns `finish_reason: "tool_calls"`; posting the `assistant` `tool_calls` + `tool` result back yields a final answer using the result. See the tools example in `README.md`.
- `curl -N` with `"stream": true` prints several `data:` chunks arriving over time, ending in a `finish_reason` chunk and `data: [DONE]`. Repeat with `tools` and check that the stream ends in a `tool_calls` delta.
