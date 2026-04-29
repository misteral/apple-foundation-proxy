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
| `POST` | `/v1/chat/completions` | OpenAI-shaped request/response envelope. Generates text from `messages` via `LanguageModelSession`. Supports `response_format`. |

The OpenAI compatibility covers text generation plus structured output (`response_format`). Missing on purpose for now: streaming, `tools` / `tool_choice`, `n > 1`, `logprobs`, multimodal content. `usage` is returned with zero counts because `FoundationModels` does not expose token usage.

## Request pipeline for `/v1/chat/completions`

1. **Validate `response_format.type`** (one of `text` / `json_object` / `json_schema`); reject unknown values with `400`. For `json_schema`, require a `json_schema` payload.
2. **`systemInstructions`** — joins all `system` and `developer` role messages into one instructions block (newline-separated). Returns nil when the request has none.
3. **`augmentInstructionsForJSONObject`** — when `type == "json_object"`, append a "respond with JSON only" directive to the instructions. FoundationModels has no native JSON mode, so this is best-effort.
4. **`renderPrompt`** — renders all `user`/`assistant` history as a labeled transcript and appends an empty `Assistant:` cue when the last turn is from the user. A single-user-message prompt is returned verbatim with no transcript framing.
5. **`buildGenerationSchema`** (only when `type == "json_schema"`) — translates the JSON Schema fragment into a `DynamicGenerationSchema` and wraps it in a `GenerationSchema`. Schema construction errors surface as `400` (run before opening the session so they don't get swallowed by the generic catch).
6. **`LanguageModelSession`** — a fresh session is created **per request**. Constructed with `instructions:` when those exist, otherwise with no instructions. No streaming, no conversation state across requests, no tools.
7. **Generate.** When a schema is present, call `respond(to:schema:)` and return `response.content.jsonString` as `choices[0].message.content`. Otherwise call `respond(to:)` and return the text response.

History is prompt-stuffed rather than handed to a `Transcript` API because (a) the proxy is intentionally stateless and (b) the public surface of `Transcript` for arbitrary multi-turn rehydration hasn't been validated yet — see `docs/design-docs/openai-compatible-chat.md` for the forward-looking design.

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

- Not a full OpenAI emulator. The OpenAI shape is a calling convention; advanced features (streaming, tools, structured output, vision) are not implemented.
- Not a chat assistant with memory. There is no server-side state across requests by design — clients send the full message history each turn.
- Not production-ready as a network service. Local-only; see `docs/SECURITY.md`.
