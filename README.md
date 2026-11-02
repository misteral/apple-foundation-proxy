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
  "ruRUSupported": false
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

Tool `parameters` use the same JSON Schema subset as `response_format.json_schema`. `tool_choice` accepts `auto` (default), `none`, `required`, and `{"type":"function","function":{"name":"..."}}`. FoundationModels cannot force a call, so `required` and a named function are instruction-level nudges. `parallel_tool_calls` is ignored. If the model calls several tools at once, all of them are reported. Tool calls aren't available with streaming yet.

Not implemented yet: streaming (`stream: true`), `n > 1`, `logprobs`, multimodal content. `usage` token counts are reported as zeros because `FoundationModels` does not surface them.

Note: Apple Foundation Models currently reports `ru_RU` as unsupported on the tested machine, so Russian output may be unreliable even though the endpoint works.
