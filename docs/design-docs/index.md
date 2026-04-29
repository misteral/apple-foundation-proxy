# Design Docs

Catalogue of design decisions. Add new docs here when changing a load-bearing invariant or making a non-obvious choice.

| Doc | Summary |
|-----|---------|
| [core-beliefs.md](core-beliefs.md) | Operating principles for this project: scope, honesty about limits, dual-mode build. |
| [dictation-only-endpoint.md](dictation-only-endpoint.md) | Why the original `/v1/chat/completions` was hard-wired to dictation correction. Superseded for the general path by `openai-compatible-chat.md`; still authoritative for the dictation endpoint. |
| [openai-compatible-chat.md](openai-compatible-chat.md) | Architecture for a general OpenAI-compatible `/v1/chat/completions` supporting streaming, tool calls, and structured output. Active execution plan: `docs/exec-plans/active/openai-compatible-chat.md`. |

## When to add a design doc

- Changing any rule listed in `AGENTS.md` "Critical rules".
- Adding state across requests, streaming, auth, or new endpoints.
- Removing or relaxing a prompt-hardening step.
- Introducing a new dependency.

A design doc should state: the decision, the alternative considered, the reason for choosing this one, and the conditions under which it should be revisited.
