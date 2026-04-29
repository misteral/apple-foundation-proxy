# OpenAI-compatible chat completions over FoundationModels

## Decision

Add a **general** OpenAI-compatible chat completions endpoint that supports streaming, tool calls, and structured output, alongside the existing dictation-only endpoint. The new endpoint is the canonical `POST /v1/chat/completions`; the dictation behavior moves to its own sibling path.

This supersedes the "OpenAI shape is just a calling convention" framing in `dictation-only-endpoint.md` for the general endpoint only — the dictation endpoint's narrowness still stands and stays at `POST /v1/dictation/correct`.

## Endpoints after this work

| Path | Purpose | Behavior |
|------|---------|----------|
| `POST /v1/chat/completions` | General OpenAI-compatible chat | Honors `messages` history, `tools`, `tool_choice`, `response_format`, `stream`, basic options |
| `POST /v1/dictation/correct` | Existing dictation correction | Unchanged from today's `/v1/chat/completions` (latest user message → fixed correction prompt → cleaned output) |
| `GET /health` | Capability probe | Existing |

The dictation logic moves to its own path so the general endpoint isn't burdened with detection heuristics. Clients pinned to the old behavior need a one-line URL update; that breakage is acceptable for a single-author project at this stage.

## Capability matrix

| OpenAI feature | Status | FoundationModels mechanism |
|----------------|--------|----------------------------|
| `messages` (multi-turn) | Supported | `LanguageModelSession(transcript:)` rehydrated from prior turns; latest user message becomes the `Prompt` |
| `system` / `developer` role | Supported | Concatenated into `Instructions` |
| `stream: true` | Supported | `streamResponse(to:options:)` → SSE chunks |
| `tools` + `tool_choice` | Supported via pass-through | Synthesized `ProxyTool` per OpenAI tool def; sentinel-throws on invocation, proxy translates to OpenAI `tool_calls` response |
| `response_format: text` | Supported | Default `respond(to:options:)` → `Response<String>` |
| `response_format: json_object` | Supported (best-effort) | Strong instructions only — FM has no native "json mode"; surface a warning if the model returns non-JSON |
| `response_format: json_schema` | Supported | Translate JSON Schema → `GenerationSchema` at runtime, use `respond(to:schema:...)` → `GeneratedContent` → JSON |
| `n > 1` | **Not supported** | FM has no batch sampling; reject with 400 |
| `logprobs` | **Not supported** | FM does not expose token probabilities; field omitted in response |
| `temperature`, `top_p`, `max_tokens` | Best-effort | Map to `GenerationOptions` where corresponding fields exist; ignore otherwise (with debug log) |
| Vision / audio / multimodal | **Not supported** | Reject with 400 if non-text content parts present |
| `parallel_tool_calls: false` | Supported (default behavior) | `LanguageModelSession` tools are invoked sequentially |
| `parallel_tool_calls: true` | Best-effort | Allow framework's natural behavior; document non-determinism |

## The tool-call round-trip — the load-bearing decision

**Mismatch:** OpenAI tools are *declared by the client*; the model emits `tool_calls`; the client executes; the client sends results back as `role: tool` messages. FoundationModels tools are *implemented in-process*; `LanguageModelSession` invokes `Tool.call(arguments:)` directly during generation and feeds the result back without surfacing the call to the proxy's caller.

**Solution: pass-through tool with sentinel exception.**

For every entry in `request.tools`, the proxy synthesizes a `ProxyTool` whose:

- `name`, `description` mirror the OpenAI definition.
- `parameters: GenerationSchema` is built by translating the OpenAI JSON Schema (see `JSONSchemaBridge`).
- `Arguments` is `GeneratedContent` (the type-erased Generable representation), not a custom Swift type — we cannot generate Swift types at runtime.
- `call(arguments:)` immediately throws `ProxyToolInvocation(name:, arguments:)`. The proxy's request handler catches this, ends the response, and returns an OpenAI `tool_calls` payload with `finish_reason: "tool_calls"`.

**Round-trip on the next request:** when the client posts a follow-up message list ending in one or more `role: tool` results, the proxy:

1. Parses the prior `assistant` message's `tool_calls` and the corresponding `tool` results from the message history.
2. Builds a `Transcript` (or equivalent prior-context construct) representing those turns.
3. Constructs a `ProxyTool` whose `call(arguments:)` returns the **client-supplied result** (matched by `tool_call_id`) for that one invocation, and otherwise sentinel-throws as before.
4. Calls `respond(to:options:)` again; the framework sees the tool result already in context and produces the next assistant turn.

This keeps the proxy stateless across requests — the entire round-trip is encoded in the messages the client sends, exactly like real OpenAI.

**Streaming variant:** during `streamResponse`, when `ProxyTool.call` is invoked the stream is terminated; whatever text was streamed becomes the assistant's `content`, and a final synthetic chunk emits the `tool_calls` deltas (one chunk per call) plus `finish_reason: "tool_calls"` on the last chunk. **Spike required:** verify that `streamResponse` does invoke `Tool.call` mid-stream (vs deferring to a non-streaming path internally). If it doesn't, fall back to non-streaming for any request that supplies `tools`.

## JSON Schema ↔ GenerationSchema bridge

OpenAI sends JSON Schema as an arbitrary dictionary. `GenerationSchema` is a Swift struct in FoundationModels. The bridge is required for both `tools[].function.parameters` and `response_format.json_schema.schema`.

**Spike required** (see plan): determine `GenerationSchema`'s public init surface. Likely candidates per the docs (verify before relying):

- A programmatic builder taking name, description, and a list of property descriptors with types and optional `GenerationGuide`s. If present, the bridge enumerates the JSON Schema and constructs the corresponding `GenerationSchema` recursively.
- A description-string-only init that just feeds the JSON Schema to the model as text. If that's all that exists, support degrades to "schema in prompt" rather than "structured generation," and we document that limitation.

**Supported JSON Schema subset** (initial):

- `type: "object"` with named `properties` and `required`
- `type: "string"`, `"number"`, `"integer"`, `"boolean"`
- `type: "array"` with `items` and optional `maxItems`/`minItems` (mapped to `GenerationGuide.maximumCount` where available)
- `enum` on string fields
- Nested objects (recursive)
- `description` strings preserved as `@Guide`-equivalent metadata

**Unsupported initially** — reject with 400 and a clear message:

- `oneOf` / `anyOf` / `allOf`
- `$ref` (resolve before sending or reject)
- `pattern` / `format` (no FM equivalent)
- `additionalProperties: true` with no fixed shape

OpenAI's `strict: true` flag is taken as a hint that we should reject rather than relax when something is unsupported.

## Message → Prompt / Instructions / Transcript translation

| OpenAI role | Becomes |
|-------------|---------|
| `system`, `developer` | Concatenated into `Instructions` (newline-joined, in order). If multiple are present, all are honored. |
| `user` (final message) | The `Prompt` for this request. |
| `user` (earlier message) | Prior turn in `Transcript`. |
| `assistant` (earlier message) | Prior turn in `Transcript`, including any `tool_calls`. |
| `tool` (earlier message) | Tool result in `Transcript`, paired by `tool_call_id` with its assistant `tool_call`. |

**Spike required:** the public surface of `Transcript` (entry types, init signature). If `Transcript` is too restrictive to model arbitrary prior turns, fall back to **prompt stuffing**: render prior turns as a textual transcript inside the prompt body. This is uglier but always works and matches what most local OpenAI proxies do.

## Health endpoint changes

`/health` gains a `capabilities` block reporting which features are usable on the current host:

```json
{
  "status": "ok",
  "...": "...existing fields...",
  "capabilities": {
    "streaming": true,
    "toolCalls": true,
    "structuredOutput": true,
    "supportedLocalesForTools": ["en_US"]
  }
}
```

Clients can probe before sending advanced requests.

## When to revisit

- If FoundationModels exposes a public "tool calls without auto-invocation" mode in a future SDK, the sentinel-throwing `ProxyTool` becomes obsolete — replace with the native API.
- If the JSON Schema → `GenerationSchema` spike reveals that runtime schema construction isn't supported, structured output degrades to prompt-instructed JSON only, and this doc must be updated to reflect that.
- If a real client needs `n > 1` or `logprobs`, those move from "not supported" to "not yet" and need their own design.
