# Tech Debt Tracker

Prioritized list of known gaps. Add an entry before introducing a workaround; remove it when the workaround is replaced with the real fix.

## Format

```markdown
### [P?] Short title
**Where:** path:line or area
**What:** the gap
**Why it matters:** consequence today
**Fix sketch:** one-paragraph plan, or link to a design doc
```

Priority: `P0` blocks correctness, `P1` blocks a real use case, `P2` is hygiene.

---

## Active items

### [P1] Unsupported-locale requests are silently degraded
**Where:** `Sources/apple-foundation-proxy/main.swift` — `/v1/chat/completions` handler
**What:** if the input is in a locale that `SystemLanguageModel.default.supportsLocale(...)` reports as unsupported (e.g., `ru_RU` on the test machine), the request is sent to the model anyway and returns lower-quality output without any signal to the caller.
**Why it matters:** clients can't tell "model corrected the text" from "model produced something plausible-looking but worse than the input."
**Fix sketch:** detect the input language (best-effort heuristic on character ranges is enough for the languages this project cares about), check `supportsLocale()`, and either return a structured error or echo the input back with a flag in the response. Decide which during the design discussion. See `docs/RELIABILITY.md` for context.

### [P2] Test target is a placeholder
**Where:** `Tests/apple-foundation-proxyTests/apple_foundation_proxyTests.swift`
**What:** the only `@Test` is a no-op. The pure helpers in `main.swift` (`extractDictationText`, `cleanModelOutput`, etc.) have no coverage.
**Why it matters:** the helpers encode load-bearing invariants (instruction-prefix stripping, output sanitization). A future agent could "simplify" them and lose the regression guard the prompt-hardening layers depend on.
**Fix sketch:** add Swift Testing cases for each pure helper. See `docs/TESTING.md` for what to cover.

---

## Resolved
_None yet._
