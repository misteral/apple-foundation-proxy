# apple-foundation-proxy

Local OpenAI-compatible HTTP proxy for Apple's on-device `FoundationModels` framework.

## Requirements

- macOS 26+ SDK / Xcode with `FoundationModels`
- Apple Intelligence-capable Mac
- Apple Intelligence enabled

The service can still build on older SDKs because the `FoundationModels` import is guarded, but real generation requires the framework at runtime.

## Run

```bash
swift run
```

The server listens on:

```text
http://127.0.0.1:8080
```

## Health check

```bash
curl http://127.0.0.1:8080/health | python3 -m json.tool
```

Example:

```json
{
  "status": "ok",
  "foundationModelsImportable": true,
  "runtimeSupported": true,
  "modelAvailability": "available",
  "currentLocale": "en_GE",
  "currentLocaleSupported": true,
  "enUSSupported": true,
  "ruRUSupported": false,
  "supportedLanguages": ["da", "de", "en", "es", "fr", "it", "ja", "ko", "nb", "nl", "pt", "sv", "tr", "vi", "zh"],
  "contextSize": 4096,
  "capabilities": {"streaming": true, "toolCalls": true, "structuredOutput": true, "tokenCounting": true}
}
```

## OpenAI-compatible endpoint

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple-foundation-model",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user", "content": "Give me three names for a black cat."}
    ]
  }'
```

## Current behavior

`POST /v1/chat/completions` accepts a standard OpenAI request and returns a `chat.completion` response. `system`/`developer` messages are joined into `LanguageModelSession` instructions; the remaining conversation is rendered into a single prompt with the last `user` message as the immediate ask. A fresh session is created per request — there is no server-side conversation memory.

`response_format` is supported:

- `{"type":"text"}` — default text generation.
- `{"type":"json_object"}` — instruction-level "respond with JSON only" augmentation. FoundationModels has no native JSON mode, so the result is best-effort JSON.
- `{"type":"json_schema","json_schema":{"name":"...","schema":{...}}}` — schema-enforced output via `LanguageModelSession.respond(to:schema:)`. The supported JSON Schema subset is `object` (with `properties`/`required`), `string` (with optional `enum`), `integer`, `number`, `boolean`, and `array` (with `items`/`minItems`/`maxItems`). `additionalProperties: false` (the OpenAI `strict: true` convention) is accepted as a no-op. Rejected with `400`: `oneOf`/`anyOf`/`allOf`/`$ref`/`pattern`/`format` and `additionalProperties: true` (or any non-boolean value).

Example structured-output request:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"apple-foundation-model",
    "messages":[{"role":"user","content":"Suggest one name for a black cat."}],
    "response_format":{
      "type":"json_schema",
      "json_schema":{
        "name":"CatName",
        "schema":{
          "type":"object",
          "properties":{
            "name":{"type":"string","description":"the suggested name"},
            "confidence":{"type":"number"}
          },
          "required":["name"]
        }
      }
    }
  }'
```

### Tools

`tools` / `tool_choice` follow the OpenAI round-trip: the proxy never executes tools itself. When the model wants a tool, the response has `finish_reason: "tool_calls"`, `content: null`, and `tool_calls`. Execute the tool on your side, then resend the conversation with the `assistant` message (with its `tool_calls`) and a `role: "tool"` message per result (`tool_call_id` + `content`).

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":"What is the weather in Paris?"}],
    "tools":[{"type":"function","function":{
      "name":"get_weather",
      "description":"Get the current weather for a city",
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
    }}]
  }'
```

Tool `parameters` use the same JSON Schema subset as `response_format.json_schema`. `tool_choice` accepts `auto` (default), `none`, `required`, and `{"type":"function","function":{"name":"..."}}`. FoundationModels cannot force a call, so `required` and a named function are instruction-level nudges. `parallel_tool_calls` is ignored. If the model calls several tools at once, all of them are reported.

### Streaming

`"stream": true` returns OpenAI-style server-sent events (`chat.completion.chunk` deltas, then `data: [DONE]`). `stream_options.include_usage` adds a final usage chunk. Tools work in streaming mode too: a tool call ends the stream with a `tool_calls` delta and `finish_reason: "tool_calls"`. With `json_schema`, the JSON arrives in one chunk. Chunks are as coarse as FoundationModels' snapshots, usually a few words each.

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"stream":true,"messages":[{"role":"user","content":"Count from 1 to 10 in words."}]}'
```

Message `content` can be a string or an array of `{"type":"text"}` parts, which are joined with newlines. Images and other non-text parts are rejected with `400`.

### Usage

`usage` holds real token counts from the model's own tokenizer (`SystemLanguageModel.tokenCount`, macOS 26.4+): `prompt_tokens` covers instructions, tool definitions, history and prompt, and `completion_tokens` covers the generated text or tool calls. On older macOS the counts are zeros. The context window is 4096 tokens for prompt and response combined (see `contextSize` in `/health`).

### Response length (`max_tokens`)

`max_completion_tokens` (or the older `max_tokens`; the newer name wins) caps the reply. When the cap is hit, the reply is truncated and `finish_reason` is `"length"`. Without a cap, the reply is limited to what's left of the context window after the prompt, so a runaway reply also ends as `"length"` instead of failing. A prompt that leaves no room for a reply is a `400 context_length_exceeded` before anything is generated. Detecting `"length"` needs the tokenizer (macOS 26.4+); on older macOS the cap still applies, but `finish_reason` stays `"stop"`.

### Sampling (`temperature`, `top_p`, `seed`)

- `temperature` (0–2) is passed to the model as is.
- `top_p` (0–1) becomes nucleus sampling; `top_p: 0` is greedy decoding (same reply every time).
- `seed` makes sampling reproducible: the same request with the same seed gives the same reply.

Out-of-range values are a `400`. The on-device model is fairly deterministic even at default settings, so short answers often don't change much with `temperature`.

### Errors

Errors use OpenAI's format, `{"error":{"message","type","param","code"}}`, so OpenAI SDKs raise typed exceptions:

| Situation | Status | `code` |
|---|---|---|
| Invalid request (format, schema, tools, no `user` message) | 400 | `null` |
| Prompt doesn't fit the context window | 400 | `context_length_exceeded` |
| Language the model rejects outright | 400 | `unsupported_language` |
| Schema construct the model can't follow | 400 | `unsupported_schema` |
| Model busy / rate-limited | 429 | `rate_limit_exceeded` |
| Model assets not available | 503 | `model_unavailable` |
| Other generation failure | 500 | `generation_failed` |

Safety blocks are not errors: like OpenAI, the reply is `200` with `content: null` and `finish_reason: "content_filter"`. Once a stream has started, errors arrive as a `data: {"error":{...}}` event (the status is already `200`); a prompt that doesn't fit is rejected before a stream opens, so it's still a 400.

### Language

The proxy detects the language of the latest user message and reports it in response headers:

```
X-AFP-Detected-Language: ru
X-AFP-Language-Supported: false
```

Unsupported languages aren't rejected. Russian, for example, gets answers, just noticeably weaker ones, so this is a signal, not a gate. Short messages (under ~20 letters) aren't classified because detection on them is noise; no headers are sent then.

Not implemented yet: `n > 1`, `logprobs`, non-text content parts.

Note: Apple Foundation Models doesn't support Russian (it's not in `supportedLanguages`). Russian requests still get answers, but they can be unreliable; watch the `X-AFP-Language-Supported` header.
