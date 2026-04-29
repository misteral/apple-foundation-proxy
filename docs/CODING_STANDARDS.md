# Coding Standards

Beyond standard Swift style, this project has a small number of **load-bearing invariants**. They look like normal lines of code but encode design decisions; removing them silently regresses the project.

## Load-bearing invariants

### 1. `FoundationModels` import must remain guarded

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif
```

And every call site must be inside both:

```swift
#if canImport(FoundationModels)
if #available(macOS 26.0, *) { ... }
#endif
```

**Why:** the package floor is `macOS 14`, but `FoundationModels` requires macOS 26. Removing either guard breaks the build on older toolchains and CI.

### 2. The model prompt and `instructions:` block are intentionally repetitive

`makeCorrectionPrompt` and the `LanguageModelSession(instructions:)` block both forbid translation, explanation, quotes, and XML. This is **not** redundancy to clean up. The on-device model occasionally honors one and not the other; the duplication is a regression guard.

If the model still drifts, fix it in `cleanModelOutput` (post-processing), not by relaxing the prompt.

### 3. `LanguageModelSession` is created per request

There is no shared `LanguageModelSession`, no session pool, and no conversation state. Adding any of these is a design change — see `docs/RELIABILITY.md` and open a design doc in `docs/design-docs/` first.

### 4. Server binds to `127.0.0.1`

The port is `8080` and the bind is local-only. The proxy has no auth, no rate limiting, and runs on-device against the user's Apple Intelligence quota. See `docs/SECURITY.md`.

### 5. Dependency surface

The only external dependency is Vapor. `Package.resolved` is committed. Adding a dependency requires a note in `docs/exec-plans/tech-debt-tracker.md` and a reason — most utility code is small enough to inline.

## Style

- Standard Swift formatting; no formatter is configured. Match the surrounding code.
- Prefer `// MARK: -` section banners as in `main.swift` when growing the file.
- Functions in `main.swift` are top-level and pure where possible (`latestUserContent`, `extractDictationText`, `makeCorrectionPrompt`, `cleanModelOutput`). Keep new helpers in the same shape — they are unit-testable without booting Vapor.

## Comments

Comments in `main.swift` exist where the *why* is non-obvious — the macOS 26 gating, the mock fallback, the "treat the endpoint as a local dictation cleanup service" line. Don't add comments that restate code; do add comments when you encode an invariant a future agent might "clean up."
