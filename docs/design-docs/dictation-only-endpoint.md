# Why `/v1/chat/completions` is dictation-only

## Decision

The `/v1/chat/completions` endpoint accepts an OpenAI-shaped request, but ignores everything except the latest `user` message and treats that message as raw dictation text to correct. It does not honor `system` messages, multi-turn history, `temperature`, `tools`, or any other OpenAI parameter.

## Why not "act like a real chat endpoint"?

1. **The on-device model needs heavy steering.** `LanguageModelSession` without strong instructions tends to translate, explain, paraphrase, or wrap output in XML/quotes. A general endpoint would expose those failure modes to every caller; a fixed-task endpoint can pin them down once.
2. **Local clients want a narrow tool.** The intended callers are editor plugins / clipboard utilities that already speak OpenAI HTTP because that is the path of least integration resistance. They want "fix this text," not chat.
3. **Avoids implying capabilities that don't exist.** Honoring `system` messages would suggest the model handles arbitrary tasks well. It doesn't, on this hardware, in this framework, today.

## How the narrowness is enforced

- `latestUserContent` discards prior turns.
- `extractDictationText` strips a leading instruction prefix (English/Russian) so callers can prepend `"Correct: ..."` without that text leaking into the prompt.
- `makeCorrectionPrompt` wraps the input in a fixed correction prompt.
- `LanguageModelSession(instructions:)` repeats the same constraints — the duplication is intentional (see `core-beliefs.md` §5).
- `cleanModelOutput` strips `<dictation>` / `<text>` / `<corrected>` tags and surrounding `"` quotes that the model occasionally adds anyway.

## When to revisit

Add a sibling endpoint (e.g., `/v1/translate`, `/v1/summarize`) rather than generalizing this one. Each task that the on-device model handles well deserves its own narrow shim with its own instruction-and-output-cleanup pair. Generalizing reintroduces the drift this design avoids.
