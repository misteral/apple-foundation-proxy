# Core Beliefs

Operating principles for this project. Read before making structural changes.

## 1. Stay small

The whole server is one Swift file because that fits the problem. A multi-target package, a `Core` / `App` / `API` split, or a Vapor `routes.swift` separation would make the project look like a "real" Vapor app at the cost of being harder to read end-to-end. Resist.

If a single function grows past ~50 lines or the file passes ~500 lines, that's the signal to split — not "we should split because larger Swift projects are split."

## 2. Be honest about what works

Apple's `FoundationModels` is new, on-device, and quietly reports many locales as unsupported. The project's job is to surface those edges (via `/health`, via documentation, via clearly-tagged mock responses) rather than paper over them.

Do not silently degrade. Either produce a correct result or signal that you cannot.

## 3. Build everywhere, run where supported

The compile target is **broad** (macOS 14+, no `FoundationModels` dependency at link time). The runtime target is **narrow** (macOS 26 with Apple Intelligence). The dual-mode build (`#if canImport` + `#available`) is the price of letting CI, older Macs, and contributors without Apple Intelligence still produce a working binary.

This is a feature, not technical debt. Keep it.

## 4. The OpenAI shape is a calling convention, not a contract

Clients use OpenAI shapes because their HTTP plumbing already understands them — that is the only reason this server speaks them. Do not feel obligated to grow into a full OpenAI emulator (streaming, `usage`, function calling, vision). Add fields when a real client needs them; otherwise leave the response minimal.

## 5. Prompt-hardening lives in three layers

`instructions:`, the prompt body, and `cleanModelOutput`. They overlap on purpose. When the model misbehaves, add to `cleanModelOutput`; do not loosen the upstream layers to "let the model breathe." The model has been observed to drift in exactly the ways the current text guards against.
