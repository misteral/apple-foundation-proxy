# Security

## Threat model

The proxy is a **local-only developer tool**. It runs on the user's Mac, calls Apple Intelligence on-device, and is intended to be reached from the same machine — typically by an editor or a clipboard tool that wants an OpenAI-compatible local endpoint.

It is **not** designed to be exposed to a network, run as a daemon for multiple users, or sit behind a reverse proxy.

## Current posture

- Binds to `127.0.0.1:8080`. Vapor's default behavior with the configured port keeps it local; do not change to `0.0.0.0` without first reading the rest of this file.
- No authentication, no API keys, no rate limiting.
- No persistent storage, no database, no logging of request bodies (Vapor's default request log line includes method/path but not the prompt text — keep it that way).
- The only outbound dependency at runtime is the `FoundationModels` framework (on-device).

## What it would take to expose this safely

Each item below is a prerequisite, not a nice-to-have. Do not skip any:

1. **Auth.** A bearer token check on `/v1/chat/completions`, with the secret read from env or Keychain — never hard-coded.
2. **Rate limiting.** `LanguageModelSession` has finite throughput and shares the user's Apple Intelligence quota; a noisy client will starve everything else on the Mac.
3. **Request size cap.** Vapor's default body limit is generous; lower it (a few KB is plenty for dictation).
4. **Logging discipline.** Decide explicitly whether prompts/responses are logged. The current default of "method/path only" is the safe baseline — opt-in to body logging only with a flag and a warning.
5. **Locale gating.** `SystemLanguageModel.default.supportsLocale(...)` should reject inputs in unsupported locales rather than silently producing low-quality output.

If you need any of the above, write a design doc in `docs/design-docs/` first.

## Secrets

There are no secrets in this repository today. Do not introduce any without putting them behind environment variables or Keychain — never `Package.resolved`, never source files, never test fixtures.

## Reporting

This is a personal/demo project; report issues to the repository owner directly.
