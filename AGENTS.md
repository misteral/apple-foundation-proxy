# AGENTS.md

Local OpenAI-compatible HTTP proxy that forwards requests to Apple's on-device `FoundationModels` framework. Single-process Swift Vapor app; the entire server lives in `Sources/apple-foundation-proxy/main.swift`. The OpenAI shape is a thin shim — the chat endpoint is hard-wired to a single task (dictation correction), not a general chat completion service.

## How to use this file

This is a map, not a manual. Detail lives in `docs/`. Read the relevant doc on demand instead of loading everything.

## docs/ index

| File | When to read |
|------|--------------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Before changing routes, prompt pipeline, or the FoundationModels gating |
| [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md) | Before editing `main.swift` — load-bearing invariants are listed here |
| [docs/TESTING.md](docs/TESTING.md) | Running tests, writing tests (Swift Testing, not XCTest) |
| [docs/SECURITY.md](docs/SECURITY.md) | Before exposing the server beyond `127.0.0.1` or adding auth |
| [docs/RELIABILITY.md](docs/RELIABILITY.md) | Before adding state across requests, streaming, or new locales |
| [docs/design-docs/index.md](docs/design-docs/index.md) | Catalogue of design decisions, including why the endpoint is dictation-only |
| [docs/exec-plans/active/](docs/exec-plans/active/) | In-progress execution plans — read before starting work that overlaps |
| [docs/exec-plans/tech-debt-tracker.md](docs/exec-plans/tech-debt-tracker.md) | Known debt before starting non-trivial work |

### Active execution plans

- [openai-compatible-chat.md](docs/exec-plans/active/openai-compatible-chat.md) — adding a general OpenAI-compatible chat endpoint (streaming, tool calls, structured output) alongside the dictation endpoint. Contains four spike tasks that must resolve before implementation begins.

## Critical rules (do not violate without explicit user approval)

1. **Do not unconditionally `import FoundationModels`.** The import must stay behind `#if canImport(FoundationModels)` and the call site behind `#available(macOS 26.0, *)`. The project must continue to build on older toolchains. See `docs/CODING_STANDARDS.md`.
2. **Do not loosen the model instructions/prompt.** The "no translation / no explanation / no quotes / no XML" lines compensate for observed model drift. Tighten via `cleanModelOutput`, not by relaxing the prompt. See `docs/design-docs/dictation-only-endpoint.md`.
3. **Do not introduce per-request state or session reuse without a design doc.** A fresh `LanguageModelSession` per request is intentional. See `docs/RELIABILITY.md`.
4. **Do not bind the server to anything other than `127.0.0.1`** without first reading `docs/SECURITY.md` — there is no auth, no rate limiting, and the model runs on the user's hardware.
5. **Do not add dependencies** beyond Vapor without a note in `docs/exec-plans/tech-debt-tracker.md` and user approval. The dependency surface is intentionally tiny.

## Build / run / test

```bash
swift build                       # Compile
swift run                         # Start server on http://127.0.0.1:8080
swift test                        # Full test suite (Swift Testing)
swift test --filter <TestName>    # Single test
```

Health: `curl http://127.0.0.1:8080/health`.
Smoke test: see the `curl` example in `README.md`.

## Omitted from the standard harness-engineering layout

The pattern's full `docs/` tree assumes a multi-package project with a release pipeline and active execution plans. This repo is a single-file demo, so the following are intentionally absent — add them when the situation justifies real content:

- `docs/CONTRIBUTING.md` — no team workflow yet.
- `docs/RELEASING.md` — no release pipeline; `swift run` from `main` is the deploy.
- `docs/QUALITY_SCORE.md` — overkill for one source file.
- `docs/product-specs/` — no specs to catalogue yet.
- `docs/exec-plans/completed/` — no completed plans yet; create the directory when archiving a finished plan.

## CLAUDE.md

`CLAUDE.md` is a pointer to this file. Edit `AGENTS.md` and `docs/`; do not duplicate content there.
