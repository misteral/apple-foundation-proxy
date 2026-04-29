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

Not implemented yet: streaming (`stream: true`), `tools` / `tool_choice`, `n > 1`, `logprobs`, multimodal content. `usage` token counts are reported as zeros because `FoundationModels` does not surface them.

Note: Apple Foundation Models currently reports `ru_RU` as unsupported on the tested machine, so Russian output may be unreliable even though the endpoint works.
