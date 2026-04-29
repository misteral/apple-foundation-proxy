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
      {
        "role": "user",
        "content": "Correct this dictated text: i went too the store and buyed milk yesterday"
      }
    ]
  }'
```

## Current behavior

This first version is intentionally narrow: it treats the latest user message as dictation text to clean up, sends it to `LanguageModelSession`, and returns a minimal OpenAI-style `chat.completion` response.

Note: Apple Foundation Models currently reports `ru_RU` as unsupported on the tested machine, so Russian correction may be unreliable even though the endpoint works.
