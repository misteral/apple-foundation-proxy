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
| `POST` | `/v1/chat/completions` | OpenAI-shaped request/response envelope wrapping a single fixed task: dictation correction. |

The OpenAI compatibility is **shape only**. Missing on purpose: `usage`, `finish_reason`, streaming, multi-turn history, tool calls, function calling, system messages.

## Request pipeline for `/v1/chat/completions`

1. **`latestUserContent`** — picks the most recent `user` message; falls back to the last message of any role. Earlier turns are ignored.
2. **`extractDictationText`** — if the message starts with an instruction prefix (`"Исправь:"`, `"Correct:"`, `"Fix:"`, `"Clean up:"`, `"Rewrite:"`, etc.) followed by `:`, strips the prefix so a caller can prepend an instruction without it leaking into the model input.
3. **`makeCorrectionPrompt`** — wraps the text in a fixed correction prompt that forbids translation/explanation/quotes/XML.
4. **`LanguageModelSession(instructions:)`** — a fresh session is created **per request**. There is no streaming, no conversation state, and no tools. System-style guidance is passed via `instructions:` in addition to being repeated in the prompt body (belt-and-braces against drift).
5. **`cleanModelOutput`** — strips the `<dictation>` / `<text>` / `<corrected>` tags and surrounding `"` quotes that the model occasionally emits despite instructions.

The redundant instruction layering and the output-stripping step are not stylistic — see `docs/design-docs/dictation-only-endpoint.md` for the rationale.

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

- Not a general-purpose OpenAI proxy. The OpenAI shape is a convenience for clients that already speak it.
- Not a chat assistant. There is no memory across requests by design.
- Not a translation service. The prompt explicitly forbids language changes; Russian and English (and other locales reported as supported by `SystemLanguageModel`) stay in their original language.
- Not production-ready as a network service. Local-only; see `docs/SECURITY.md`.
