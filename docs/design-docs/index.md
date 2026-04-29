# Design Docs

Catalogue of design decisions. Add new docs here when changing a load-bearing invariant or making a non-obvious choice.

| Doc | Summary |
|-----|---------|
| [core-beliefs.md](core-beliefs.md) | Operating principles for this project: scope, honesty about limits, dual-mode build. |
| [openai-compatible-chat.md](openai-compatible-chat.md) | Forward-looking architecture for `/v1/chat/completions` covering streaming, tool calls, and structured output. The basic text-generation shape is already implemented in `main.swift`; this doc covers what's still missing. |

## When to add a design doc

- Changing any rule listed in `AGENTS.md` "Critical rules".
- Adding state across requests, streaming, auth, or new endpoints.
- Removing or relaxing a prompt-hardening step.
- Introducing a new dependency.

A design doc should state: the decision, the alternative considered, the reason for choosing this one, and the conditions under which it should be revisited.
