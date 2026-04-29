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
| `POST` | `/v1/chat/completions` | OpenAI-shaped request/response envelope. Generates text from `messages` via `LanguageModelSession`. |

The OpenAI compatibility covers the basic text-generation request/response shape. Missing on purpose for now: streaming, `tools` / `tool_choice`, `response_format`, `n > 1`, `logprobs`, multimodal content. `usage` is returned with zero counts because `FoundationModels` does not expose token usage.

## Request pipeline for `/v1/chat/completions`

1. **`systemInstructions`** — joins all `system` and `developer` role messages into one instructions block (newline-separated). Returns nil when the request has none.
2. **`renderPrompt`** — renders the remaining `user`/`assistant` history as a labeled transcript and appends the last user message as the immediate ask. When there's only one user message it's used verbatim with no transcript framing.
3. **`LanguageModelSession`** — a fresh session is created **per request**. Constructed with `instructions:` when `systemInstructions` returned a value, otherwise with no instructions. There is no streaming, no conversation state across requests, and no tools.
4. The session's `respond(to:)` output is returned in `choices[0].message.content` as-is.

History is prompt-stuffed rather than handed to a `Transcript` API because (a) the proxy is intentionally stateless and (b) the public surface of `Transcript` for arbitrary multi-turn rehydration hasn't been validated yet — see `docs/design-docs/openai-compatible-chat.md` for the forward-looking design.

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
