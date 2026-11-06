# Context window

What the on-device model's context window is, whether it can be raised, and what that means for clients such as pi. Researched 2026-11-06 on macOS 26.6.2 (M4 Pro, 24 GB). The OS 27 numbers are third-party measurements, so re-check them on real hardware before relying on them.

## Current limit (macOS 26.x)

- **4096 tokens per `LanguageModelSession`.** The budget covers instructions, tool schemas, `Generable` schemas, the whole transcript and the response. TN3193 says the size is "determined by model architecture and hardware limits".
- **It can't be changed.** No setting, entitlement or private API is known to raise it. An Apple engineer's accepted forum answer says: "This is always the fixed token limit, there's no possibility of it changing" ([forum 806542](https://developer.apple.com/forums/thread/806542)). In June 2026 a developer asked why the window wasn't larger. Apple gave its usual "can't comment on future plans" answer ([forum 831208](https://developer.apple.com/forums/thread/831208)).
- **Error numbers are misleading.** Figures like 4090 or 4100 in `exceededContextWindowSize` messages only show where the error tripped. The limit is still 4096, and the usable limit sits a little lower (see `responseTokenMargin` in [ARCHITECTURE.md](ARCHITECTURE.md)).
- **Adapters don't help.** Nothing shows a custom LoRA adapter enlarging the window. In one report an adapter session filled about 90% of the window after one prompt ([forum 806779](https://developer.apple.com/forums/thread/806779)).
- **There is an API for the size.** macOS 26.4 added `SystemLanguageModel.contextSize` and `tokenCount(for:)`, both back-deployed. The proxy reads the size from `contextSize` instead of hardcoding it, and `/health` reports it, so a larger window is picked up without code changes.

## OS 27 (WWDC26)

- **New on-device model.** In WWDC26 session 241's code sample, `SystemLanguageModel().contextSize` prints `// 8192`. Apple advises adapting to "the hardware it's running on" ([session 241](https://developer.apple.com/videos/play/wwdc2026/241)).
- **The size appears to depend on hardware.** This is unconfirmed by Apple. apfel measured 4096 on an M2 Air (27.0.1) and 8192 on an M3 Pro. It attributes the difference to "AFM 3 Core Advanced", which it says needs M3 or later and at least 12 GB of RAM. 8 GB devices fall back to the Core model ([apfel notes](https://raw.githubusercontent.com/Arthur-Ficial/apfel/master/docs/coreai-impact.md)).
- **`PrivateCloudComputeLanguageModel`** is Apple's server model.
  - It has a 32,000-token window and the same `LanguageModel` protocol, so it plugs into `LanguageModelSession`.
  - It needs an entitlement and the network, and has per-user daily quotas, which are higher for iCloud+ users.
  - Using it would end "fully on-device", so it needs a design doc before the proxy adopts it (see `AGENTS.md` critical rules).
- macOS 27 also ships an `fm` CLI for both models.

## Working within the limit

Apple's guidance (TN3193) and what the community does:

- Keep instructions short and offer at most 3–5 tools. Tool schemas count against the budget.
- Ask for short outputs, and treat `maximumResponseTokens` only as a safety net.
- Split work across sessions. When the window fills, start a new session from a summarized or trimmed transcript.
- Fetch only relevant snippets (RAG) instead of pasting whole files.

The proxy creates a fresh session per request and has no server-side memory (see [RELIABILITY.md](RELIABILITY.md)). Trimming the transcript is therefore the client's job.

## Client: pi

pi talks to the proxy through its `openai-completions` API. Provider entry in `~/.pi/agent/models.json`:

```json
"apple": {
  "baseUrl": "http://127.0.0.1:18080/v1",
  "api": "openai-completions",
  "apiKey": "local",
  "models": [{
    "id": "apple-foundation-model",
    "reasoning": false,
    "input": ["text"],
    "contextWindow": 8192,
    "maxTokens": 1024,
    "compat": { "supportsReasoningEffort": false }
  }]
}
```

Gotchas found while wiring it up:

- **`contextWindow` must overstate the real window.** pi reserves 4096 "safety" tokens: `CONTEXT_SAFETY_TOKENS` in `pi-mono/packages/ai/src/api/simple-options.ts` caps the response at `contextWindow − estimate − 4096`. Declaring the real 4096 makes every request go out with `max_completion_tokens: 1`, and every reply ends as `length` ("Response was truncated"). Declare the real window + 4096. The proxy still clamps the reply to what really fits. The side effect is that pi's usage indicator shows a share of 8.2k. Once the model reports 8192 (OS 27), raise this to about 12288.
- **pi's full system prompt doesn't fit.** With AGENTS.md, skills, extensions and all tools it is about 6900 tokens, which comes back as `400 context_length_exceeded`. Run pi stripped down:

  ```bash
  pi --model apple/apple-foundation-model -nc -ns -ne -np --no-mcp --no-session --tools read,bash
  ```

  That leaves about 900 prompt tokens, and a short `read`/`bash` tool round-trip works. Even so, 2–3 tool results fill a large part of the window.
- **Port.** The proxy hardcodes 8080. Vapor's `serve --port` overrides it without code changes, which helps when 8080 is taken (here it was taken by an ssh tunnel): `swift run apple-foundation-proxy serve --port 18080`.
- **Language.** Russian is not a supported language (`ruRUSupported: false` in `/health`), so Russian prompts get `400 unsupported_language`.
- **Unresolved: one streaming request hung.** A streaming tool request from pi once got no response for about 4 minutes. The proxy stayed responsive to other requests, and the identical request succeeded on retry. The cause is not known. If it happens again, capture the request body and check whether the FoundationModels stream stalls.
