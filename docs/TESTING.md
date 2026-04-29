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
- `ChatCompletionRequest` decoding — verify `response_format` and nested `json_schema` decode from the OpenAI wire format.

The `buildGenerationSchema(from:)` bridge requires `FoundationModels` types, so its tests are gated behind `#if canImport(FoundationModels)` and skip at runtime via `#available(macOS 26.0, *)` on older OSes. Cover both happy paths (object/array/enum/scalar) and the rejection cases (`oneOf`/`anyOf`/`allOf`/`$ref`/`pattern`/`format`/`additionalProperties`, missing `items`, unknown `type`, non-object fragment, missing `schema`).

## What not to test in unit tests

- The actual `LanguageModelSession.respond(to:)` call. It is non-deterministic, requires Apple Intelligence, and is an integration concern — exercise it manually via `curl` or a smoke script, not via CI.
- The `#if canImport(FoundationModels)` branches. They are compile-time switches; covering them needs two toolchains, not two test cases.

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
