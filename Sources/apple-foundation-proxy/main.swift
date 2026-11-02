import Foundation
import Vapor

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - JSON value (for arbitrary JSON Schema fragments inside `response_format`)

indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):    try container.encode(v)
        case .int(let v):     try container.encode(v)
        case .double(let v):  try container.encode(v)
        case .string(let v):  try container.encode(v)
        case .array(let v):   try container.encode(v)
        case .object(let v):  try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v } else { return nil }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v } else { return nil }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}

// MARK: - OpenAI Compatible DTOs

struct ChatCompletionRequest: Content {
    /// An OpenAI `tool_calls[]` entry. Shared by request history and response payloads.
    struct ToolCall: Content, Equatable {
        struct Function: Content, Equatable {
            let name: String
            /// JSON-encoded arguments, as a string (OpenAI wire format).
            let arguments: String
        }
        let id: String
        let type: String?
        let function: Function
    }

    struct Message: Content {
        let role: String
        /// Nil for assistant messages that only carry `tool_calls`.
        let content: String?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, tool_call_id, name
        }

        /// One element of OpenAI's array-form `content`.
        private struct ContentPart: Decodable {
            let type: String
            let text: String?
        }

        /// Accepts `content` as a string, `null`, or an array of parts. Text parts are joined
        /// with newlines. Clients such as LangChain and the Agents SDK send the array form even
        /// for plain text. Any other part type (images, audio, files) fails decoding, which
        /// Vapor reports as a 400: the on-device model is text-only.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            tool_calls = try c.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
            tool_call_id = try c.decodeIfPresent(String.self, forKey: .tool_call_id)
            name = try c.decodeIfPresent(String.self, forKey: .name)

            if (try? c.decodeNil(forKey: .content)) ?? true {
                content = nil
            } else if let text = try? c.decode(String.self, forKey: .content) {
                content = text
            } else {
                let parts = try c.decode([ContentPart].self, forKey: .content)
                content = try parts.map { part in
                    guard part.type == "text", let text = part.text else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .content,
                            in: c,
                            debugDescription: "Unsupported content part type '\(part.type)'; only 'text' parts are supported"
                        )
                    }
                    return text
                }.joined(separator: "\n")
            }
        }

        init(
            role: String,
            content: String?,
            tool_calls: [ToolCall]? = nil,
            tool_call_id: String? = nil,
            name: String? = nil
        ) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
            self.name = name
        }
    }

    struct ToolDefinition: Content {
        struct Function: Content {
            let name: String
            let description: String?
            let parameters: JSONValue?
            let strict: Bool?
        }
        let type: String
        let function: Function
    }

    struct ResponseFormat: Content {
        let type: String
        let json_schema: JSONSchemaSpec?
    }

    struct JSONSchemaSpec: Content {
        let name: String
        let description: String?
        let schema: JSONValue?
        let strict: Bool?
    }

    let model: String?
    let messages: [Message]
    let response_format: ResponseFormat?
    let tools: [ToolDefinition]?
    /// `"auto"`, `"none"`, `"required"`, or `{"type":"function","function":{"name":...}}`.
    let tool_choice: JSONValue?

    struct StreamOptions: Content {
        let include_usage: Bool?
    }
    let stream: Bool?
    let stream_options: StreamOptions?
}

struct ChatCompletionResponse: Content {
    struct Choice: Content {
        struct Message: Content {
            let role: String
            let content: String?
            let tool_calls: [ChatCompletionRequest.ToolCall]?

            init(role: String, content: String?, tool_calls: [ChatCompletionRequest.ToolCall]? = nil) {
                self.role = role
                self.content = content
                self.tool_calls = tool_calls
            }

            // OpenAI always emits `content` (as `null` on tool-call turns); some clients
            // require the key to be present, so don't let synthesized Codable drop it.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(role, forKey: .role)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(tool_calls, forKey: .tool_calls)
            }
        }
        let index: Int
        let message: Message
        let finish_reason: String
    }
    struct Usage: Content {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage
}

struct HealthResponse: Content {
    let status: String
    let foundationModelsImportable: Bool
    let runtimeSupported: Bool
    let modelAvailability: String?
    let currentLocale: String
    let currentLocaleSupported: Bool?
    let enUSSupported: Bool?
    let ruRUSupported: Bool?
    let capabilities: Capabilities

    struct Capabilities: Content {
        let streaming: Bool
        let toolCalls: Bool
        let structuredOutput: Bool
    }
}

// MARK: - Streaming DTOs (`stream: true`)

/// One `chat.completion.chunk` SSE payload.
struct ChatCompletionChunk: Content {
    struct ToolCallDelta: Content, Equatable {
        let index: Int
        let id: String
        let type: String
        let function: ChatCompletionRequest.ToolCall.Function
    }

    struct Delta: Content, Equatable {
        var role: String? = nil
        var content: String? = nil
        var tool_calls: [ToolCallDelta]? = nil
    }

    struct Choice: Content {
        let index: Int
        let delta: Delta
        let finish_reason: String?

        // OpenAI emits `"finish_reason": null` on every non-final chunk; keep the key.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(delta, forKey: .delta)
            try c.encode(finish_reason, forKey: .finish_reason)
        }
    }

    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: ChatCompletionResponse.Usage?
}

// MARK: - Prompt assembly

/// Joins `system` and `developer` role messages into a single instructions block.
/// Returns nil when there are none so the caller can construct a session without instructions.
func systemInstructions(from messages: [ChatCompletionRequest.Message]) -> String? {
    let parts = messages
        .filter { $0.role == "system" || $0.role == "developer" }
        .compactMap(\.content)
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
}

/// Renders the conversation as a single prompt string.
///
/// All `user`/`assistant` turns are joined into a labeled transcript. When the last turn is
/// from the user, an empty `Assistant:` line is appended to cue the model to continue.
/// `system`/`developer` messages are excluded here — they are routed through `Instructions`.
///
/// Prompt-stuffing the history is intentional: it keeps the proxy stateless across requests
/// (no `LanguageModelSession` reuse) at the cost of growing prompts on long conversations.
func renderPrompt(from messages: [ChatCompletionRequest.Message]) -> String {
    let convo = messages.filter { $0.role == "user" || $0.role == "assistant" }
    guard let last = convo.last else { return "" }
    let history = convo.dropLast()

    if history.isEmpty {
        return last.content ?? ""
    }

    var lines: [String] = []
    for msg in history {
        let label = msg.role == "user" ? "User" : "Assistant"
        lines.append("\(label): \(msg.content ?? "")")
    }
    let lastLabel = last.role == "user" ? "User" : "Assistant"
    lines.append("\(lastLabel): \(last.content ?? "")")
    if last.role == "user" {
        lines.append("Assistant:")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Structured output

/// Appended to `instructions` when the caller asks for `response_format.type == "json_object"`.
/// FoundationModels has no native "JSON mode"; instruction-level guidance is the best we can do
/// without a schema.
let jsonObjectDirective = """
You MUST respond with a single valid JSON value and nothing else. \
Do not include code fences, markdown, prose, or commentary.
"""

func augmentInstructionsForJSONObject(_ base: String?) -> String {
    if let base, !base.isEmpty {
        return base + "\n\n" + jsonObjectDirective
    }
    return jsonObjectDirective
}

// MARK: - Tool calls (pure helpers)

/// Parsed OpenAI `tool_choice`.
enum ToolChoice: Equatable {
    case auto
    case none
    case required
    case function(String)
}

func parseToolChoice(_ value: JSONValue?) throws -> ToolChoice {
    switch value {
    case nil, .null:
        return .auto
    case .string("auto"):
        return .auto
    case .string("none"):
        return .none
    case .string("required"):
        return .required
    case .object(let dict):
        if dict["type"]?.stringValue == "function",
           let name = dict["function"]?.objectValue?["name"]?.stringValue {
            return .function(name)
        }
        throw Abort(.badRequest, reason: "tool_choice object must be {\"type\":\"function\",\"function\":{\"name\":...}}")
    default:
        throw Abort(.badRequest, reason: "Unsupported tool_choice value")
    }
}

/// FoundationModels has no way to force a tool call, so `required` / named-function
/// choices degrade to an instruction-level nudge.
func toolChoiceDirective(_ choice: ToolChoice) -> String? {
    switch choice {
    case .auto, .none:
        return nil
    case .required:
        return "You MUST call one of the available tools before answering."
    case .function(let name):
        return "You MUST call the tool '\(name)' before answering."
    }
}

/// Validates `tools` and applies `tool_choice`, returning the definitions that should be
/// attached to the session (empty for `tool_choice: "none"`).
func selectTools(
    _ tools: [ChatCompletionRequest.ToolDefinition],
    choice: ToolChoice
) throws -> [ChatCompletionRequest.ToolDefinition] {
    var seen = Set<String>()
    for tool in tools {
        guard tool.type == "function" else {
            throw Abort(.badRequest, reason: "Unsupported tool type '\(tool.type)'; only 'function' is supported")
        }
        guard !tool.function.name.isEmpty else {
            throw Abort(.badRequest, reason: "tools[].function.name must not be empty")
        }
        guard seen.insert(tool.function.name).inserted else {
            throw Abort(.badRequest, reason: "Duplicate tool name '\(tool.function.name)'")
        }
    }
    switch choice {
    case .required where tools.isEmpty:
        throw Abort(.badRequest, reason: "tool_choice 'required' needs at least one entry in tools")
    case .auto, .required:
        return tools
    case .none:
        return []
    case .function(let name):
        let matching = tools.filter { $0.function.name == name }
        guard !matching.isEmpty else {
            throw Abort(.badRequest, reason: "tool_choice references unknown tool '\(name)'")
        }
        return matching
    }
}

/// Whether a request needs the tool-aware pipeline (native transcript + replay). True when
/// tools are declared, and also when only the *history* has tool traffic: clients often omit
/// `tools` on the final turn, and the prompt-stuffing path would silently drop `tool`
/// results, so the model would make up an answer.
func needsToolPipeline(
    tools: [ChatCompletionRequest.ToolDefinition],
    messages: [ChatCompletionRequest.Message]
) -> Bool {
    !tools.isEmpty || messages.contains { $0.role == "tool" || !($0.tool_calls ?? []).isEmpty }
}

/// A tool result the client already supplied for a call made after the latest user turn.
struct ReplayedToolResult: Equatable {
    let id: String
    let name: String
    let arguments: String
    let output: String
}

/// A request's messages split for the tool-call round-trip.
///
/// FoundationModels can only *continue* a session by responding to a new prompt, so the
/// latest `user` message is always the prompt. Everything before it becomes transcript
/// history. Tool calls/results *after* it belong to the in-flight turn: they are replayed by
/// re-running generation and having `ProxyTool` hand back the client's results instead of
/// surfacing the call again.
struct ToolConversation {
    let history: [ChatCompletionRequest.Message]
    let prompt: String
    let pendingResults: [ReplayedToolResult]
}

func splitToolConversation(_ messages: [ChatCompletionRequest.Message]) throws -> ToolConversation {
    guard let lastUser = messages.lastIndex(where: { $0.role == "user" }) else {
        throw Abort(.badRequest, reason: "messages must contain at least one 'user' message")
    }
    let trailing = messages[(lastUser + 1)...]

    var callsByID: [String: ChatCompletionRequest.ToolCall] = [:]
    var results: [ReplayedToolResult] = []
    for msg in trailing {
        switch msg.role {
        case "assistant":
            for call in msg.tool_calls ?? [] {
                callsByID[call.id] = call
            }
        case "tool":
            guard let id = msg.tool_call_id else {
                throw Abort(.badRequest, reason: "'tool' messages require tool_call_id")
            }
            guard let call = callsByID[id] else {
                throw Abort(.badRequest, reason: "tool message references unknown tool_call_id '\(id)'")
            }
            results.append(.init(
                id: id,
                name: call.function.name,
                arguments: call.function.arguments,
                output: msg.content ?? ""
            ))
        default:
            // Trailing assistant prose or system messages can't be placed after the prompt
            // in a transcript; they're dropped. Real clients don't send these.
            continue
        }
    }

    return ToolConversation(
        history: Array(messages[..<lastUser]),
        prompt: messages[lastUser].content ?? "",
        pendingResults: results
    )
}

/// Renders pending tool results as text, for when they can't be replayed through tools
/// (e.g. `tool_choice: "none"`).
func appendToolResultsToPrompt(_ prompt: String, results: [ReplayedToolResult]) -> String {
    guard !results.isEmpty else { return prompt }
    var lines = [prompt, "", "Tool results:"]
    for r in results {
        lines.append("- \(r.name)(\(r.arguments)): \(r.output)")
    }
    return lines.joined(separator: "\n")
}

/// Parses a JSON string into a `JSONValue` for order-insensitive argument comparison.
func parseJSONValue(_ json: String) -> JSONValue? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// Canonical form of tool arguments for replay matching: strings are trimmed, lowercased,
/// and have inner whitespace collapsed, so `"Paris"` and `" paris "` match but `"London"`
/// does not.
func normalizedForMatching(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let s):
        let words = s.lowercased().split(whereSeparator: { $0.isWhitespace })
        return .string(words.joined(separator: " "))
    case .double(let d):
        if let i = Int(exactly: d) { return .int(i) }
        return value
    case .array(let items):
        return .array(items.map(normalizedForMatching))
    case .object(let dict):
        return .object(dict.mapValues(normalizedForMatching))
    case .null, .bool, .int:
        return value
    }
}

/// Serves client-supplied tool results during replay.
///
/// Lookup order: exact `(name, arguments)` match (order-insensitive JSON), then a match on
/// normalized arguments (`normalizedForMatching`), because the model may vary casing or
/// spacing when it regenerates. Matches are reusable: asking the same question again gets
/// the same answer instead of going back to the client. Anything else is a new call and
/// goes to the client. There is deliberately no "any result for this tool name" fallback:
/// it would hand one call's result to a different call (Paris weather for London).
struct ToolReplayCache: Sendable {
    private let results: [ReplayedToolResult]

    init(_ results: [ReplayedToolResult]) {
        self.results = results
    }

    func result(name: String, arguments: String) -> String? {
        let candidates = results.filter { $0.name == name }
        guard !candidates.isEmpty else { return nil }

        guard let parsed = parseJSONValue(arguments) else {
            return candidates.first { $0.arguments == arguments }?.output
        }
        if let exact = candidates.first(where: { parseJSONValue($0.arguments) == parsed }) {
            return exact.output
        }
        let normalized = normalizedForMatching(parsed)
        return candidates.first(where: {
            parseJSONValue($0.arguments).map(normalizedForMatching) == normalized
        })?.output
    }
}

/// Collects tool invocations that must be surfaced to the client. Shared by all
/// `ProxyTool`s of one request so parallel calls are all reported, not just the first.
final class ToolInvocationRecorder: @unchecked Sendable {
    struct Invocation: Equatable {
        let name: String
        let arguments: String
    }

    private let lock = NSLock()
    private var storage: [Invocation] = []

    func record(name: String, arguments: String) {
        lock.lock()
        storage.append(.init(name: name, arguments: arguments))
        lock.unlock()
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

func makeToolCallID() -> String {
    "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
}

// MARK: - Request preparation

/// Everything the chat handler derives from a request before touching FoundationModels.
/// `prepareCompletion` does all request validation, so every 400 is decided here and can be
/// unit-tested without booting Vapor or the model.
struct PreparedCompletion {
    let formatType: String
    let schemaSpec: ChatCompletionRequest.JSONSchemaSpec?
    let instructions: String?
    let prompt: String
    /// Tools to attach to the session (after `tool_choice`).
    let activeTools: [ChatCompletionRequest.ToolDefinition]
    /// Non-nil → tool pipeline (native transcript + replay); nil → prompt stuffing.
    let conversation: ToolConversation?
    let stream: Bool
    let includeUsage: Bool
    let model: String
}

func prepareCompletion(_ payload: ChatCompletionRequest) throws -> PreparedCompletion {
    let format = payload.response_format
    let formatType = format?.type ?? "text"
    guard ["text", "json_object", "json_schema"].contains(formatType) else {
        throw Abort(.badRequest, reason: "Unsupported response_format.type: '\(formatType)'")
    }
    if formatType == "json_schema", format?.json_schema == nil {
        throw Abort(.badRequest, reason: "response_format.type='json_schema' requires response_format.json_schema")
    }

    let baseInstructions = systemInstructions(from: payload.messages)
    var instructions: String? = (formatType == "json_object")
        ? augmentInstructionsForJSONObject(baseInstructions)
        : baseInstructions

    let requestedTools = payload.tools ?? []
    let toolChoice = try parseToolChoice(payload.tool_choice)
    let activeTools = try selectTools(requestedTools, choice: toolChoice)
    let conversation: ToolConversation? = needsToolPipeline(tools: requestedTools, messages: payload.messages)
        ? try splitToolConversation(payload.messages)
        : nil

    if !activeTools.isEmpty, let directive = toolChoiceDirective(toolChoice) {
        instructions = [instructions, directive].compactMap { $0 }.joined(separator: "\n\n")
    }

    let prompt: String
    if let conversation {
        // Results for tools that aren't attached this turn can't be replayed via
        // `ProxyTool`; hand them to the model as text instead.
        let activeNames = Set(activeTools.map(\.function.name))
        let unreplayable = conversation.pendingResults.filter { !activeNames.contains($0.name) }
        prompt = appendToolResultsToPrompt(conversation.prompt, results: unreplayable)
    } else {
        prompt = renderPrompt(from: payload.messages)
    }

    return PreparedCompletion(
        formatType: formatType,
        schemaSpec: formatType == "json_schema" ? format?.json_schema : nil,
        instructions: instructions,
        prompt: prompt,
        activeTools: activeTools,
        conversation: conversation,
        stream: payload.stream == true,
        includeUsage: payload.stream_options?.include_usage == true,
        model: payload.model ?? "apple-foundation-model"
    )
}

/// Result of one generation, independent of how it's delivered (JSON or SSE).
struct CompletionOutcome: Equatable {
    let content: String?
    let toolCalls: [ToolInvocationRecorder.Invocation]
    let finishReason: String

    static func text(_ content: String, finishReason: String = "stop") -> CompletionOutcome {
        .init(content: content, toolCalls: [], finishReason: finishReason)
    }
}

/// Mock reply for toolchains without FoundationModels, so the project builds and answers in
/// CI and on machines without Apple Intelligence.
func mockCompletionOutcome(_ prepared: PreparedCompletion) -> CompletionOutcome {
    if prepared.formatType == "json_object" || prepared.formatType == "json_schema" {
        return .text("{\"mock\":true}")
    }
    return .text("[Mock Apple Intelligence Response] \(prepared.prompt)")
}

let unavailableCompletionOutcome = CompletionOutcome.text(
    "FoundationModels framework is not available or not supported on this OS version."
)

func makeCompletionResponse(
    _ outcome: CompletionOutcome,
    id: String,
    created: Int,
    model: String
) -> ChatCompletionResponse {
    let toolCalls: [ChatCompletionRequest.ToolCall]? = outcome.toolCalls.isEmpty ? nil : outcome.toolCalls.map {
        .init(id: makeToolCallID(), type: "function", function: .init(name: $0.name, arguments: $0.arguments))
    }
    return ChatCompletionResponse(
        id: id,
        object: "chat.completion",
        created: created,
        model: model,
        choices: [.init(
            index: 0,
            message: .init(role: "assistant", content: outcome.content, tool_calls: toolCalls),
            finish_reason: outcome.finishReason
        )],
        // FoundationModels does not expose token counts; report zeros so clients that
        // require the `usage` field don't fail to decode the response.
        usage: .init(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
    )
}

// MARK: - Streaming (pure helpers)

/// Turns FoundationModels' cumulative snapshots into OpenAI-style incremental deltas.
///
/// `streamResponse` yields the *whole* text generated so far on every element, not the new
/// piece. Normally each snapshot extends the previous one; if it ever doesn't, SSE has no way
/// to retract already-sent text, so we emit what follows the common prefix and accept the
/// divergence rather than duplicating output.
///
/// Compares Unicode scalars, not `Character`s: a snapshot can end mid-grapheme (`e` before
/// a combining accent, half of a flag or ZWJ emoji). Character comparison would then see no
/// common prefix for that grapheme and re-send it. The client concatenates the scalars back
/// into the right character.
func streamDelta(previous: String, current: String) -> String {
    let prev = previous.unicodeScalars
    let cur = current.unicodeScalars
    if cur.starts(with: prev) {
        return String(String.UnicodeScalarView(cur.dropFirst(prev.count)))
    }
    let common = zip(prev, cur).prefix(while: { $0 == $1 }).count
    return String(String.UnicodeScalarView(cur.dropFirst(common)))
}

let sseDone = "data: [DONE]\n\n"

func sseEvent<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
}

/// Builds the chunk sequence of one streamed completion. All chunks share `id`/`created`/
/// `model`, as OpenAI clients expect.
struct ChunkFactory {
    let id: String
    let created: Int
    let model: String

    private func chunk(_ delta: ChatCompletionChunk.Delta, finish: String? = nil) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: model,
            choices: [.init(index: 0, delta: delta, finish_reason: finish)],
            usage: nil
        )
    }

    func role() -> ChatCompletionChunk { chunk(.init(role: "assistant", content: "")) }

    func content(_ text: String) -> ChatCompletionChunk { chunk(.init(content: text)) }

    func toolCalls(_ invocations: [ToolInvocationRecorder.Invocation]) -> ChatCompletionChunk {
        chunk(.init(tool_calls: invocations.enumerated().map { i, inv in
            .init(index: i, id: makeToolCallID(), type: "function", function: .init(name: inv.name, arguments: inv.arguments))
        }))
    }

    func finish(_ reason: String) -> ChatCompletionChunk { chunk(.init(), finish: reason) }

    /// `stream_options.include_usage` trailer: empty `choices`, zeroed usage (see `Usage`).
    func usage() -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: model,
            choices: [],
            usage: .init(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}

extension AsyncBodyStreamWriter {
    func writeSSE(_ chunk: ChatCompletionChunk) async throws {
        try await writeBuffer(ByteBuffer(string: try sseEvent(chunk)))
    }

    func writeSSEDone() async throws {
        try await writeBuffer(ByteBuffer(string: sseDone))
    }

    /// Writes an outcome's content and tool calls as chunks (not the finish chunk).
    func writeOutcomeTail(_ outcome: CompletionOutcome, chunks: ChunkFactory) async throws {
        if let content = outcome.content, !content.isEmpty {
            try await writeSSE(chunks.content(content))
        }
        if !outcome.toolCalls.isEmpty {
            try await writeSSE(chunks.toolCalls(outcome.toolCalls))
        }
    }
}

/// Wraps a generator in an OpenAI-shaped SSE response: role chunk, whatever `generate`
/// writes, a finish chunk with the reason it returns, an optional usage trailer, `[DONE]`.
func makeSSEResponse(
    chunks: ChunkFactory,
    includeUsage: Bool,
    generate: @escaping @Sendable (AsyncBodyStreamWriter) async throws -> String
) -> Response {
    let body = Response.Body(managedAsyncStream: { writer in
        try await writer.writeSSE(chunks.role())
        let finishReason = try await generate(writer)
        try await writer.writeSSE(chunks.finish(finishReason))
        if includeUsage {
            try await writer.writeSSE(chunks.usage())
        }
        try await writer.writeSSEDone()
    })
    var headers = HTTPHeaders()
    headers.contentType = HTTPMediaType(type: "text", subType: "event-stream")
    headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    return Response(status: .ok, headers: headers, body: body)
}

#if canImport(FoundationModels)

/// Translates a (subset of) JSON Schema into a `GenerationSchema` consumable by
/// `LanguageModelSession.respond(to:schema:)`.
///
/// Supported: `object` (with `properties`/`required`), `string` (with optional `enum`),
/// `integer`, `number`, `boolean`, `array` (with `items`/`minItems`/`maxItems`).
/// Unsupported and rejected with a 400: `oneOf`/`anyOf`/`allOf`/`$ref`/`pattern`/`format`/
/// `additionalProperties`.
@available(macOS 26.0, *)
func buildGenerationSchema(from spec: ChatCompletionRequest.JSONSchemaSpec) throws -> GenerationSchema {
    guard let schema = spec.schema else {
        throw Abort(.badRequest, reason: "response_format.json_schema.schema is required")
    }
    let root = try buildDynamicSchema(name: spec.name, description: spec.description, schema: schema)
    do {
        return try GenerationSchema(root: root, dependencies: [])
    } catch {
        throw Abort(.badRequest, reason: "Failed to build GenerationSchema: \(error.localizedDescription)")
    }
}

@available(macOS 26.0, *)
func buildDynamicSchema(name: String, description: String?, schema: JSONValue) throws -> DynamicGenerationSchema {
    guard case .object(let dict) = schema else {
        throw Abort(.badRequest, reason: "Schema fragment '\(name)' must be a JSON object")
    }

    // `additionalProperties: false` is the canonical OpenAI strict-mode pattern and is a
    // no-op for us — DynamicGenerationSchema already produces closed objects. `true` (or
    // any non-bool, e.g. a typed extension schema) we cannot model.
    if let additional = dict["additionalProperties"] {
        switch additional {
        case .bool(false):
            break
        case .bool(true):
            throw Abort(
                .badRequest,
                reason: "JSON Schema 'additionalProperties: true' is not supported (at '\(name)')"
            )
        default:
            throw Abort(
                .badRequest,
                reason: "JSON Schema 'additionalProperties' must be a boolean (at '\(name)')"
            )
        }
    }

    for unsupported in ["oneOf", "anyOf", "allOf", "$ref", "pattern", "format"] {
        if dict[unsupported] != nil {
            throw Abort(
                .badRequest,
                reason: "JSON Schema construct '\(unsupported)' is not supported (at '\(name)')"
            )
        }
    }

    let inferredType: String = {
        if let explicit = dict["type"]?.stringValue { return explicit }
        if dict["properties"] != nil { return "object" }
        if dict["enum"] != nil { return "string" }
        return "object"
    }()

    let resolvedDescription = description ?? dict["description"]?.stringValue

    switch inferredType {
    case "object":
        let propDict = dict["properties"]?.objectValue ?? [:]
        let required = Set(dict["required"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
        var properties: [DynamicGenerationSchema.Property] = []
        for (key, sub) in propDict {
            let subSchema = try buildDynamicSchema(
                name: "\(name).\(key)",
                description: nil,
                schema: sub
            )
            let propDescription = sub.objectValue?["description"]?.stringValue
            properties.append(.init(
                name: key,
                description: propDescription,
                schema: subSchema,
                isOptional: !required.contains(key)
            ))
        }
        return DynamicGenerationSchema(
            name: name,
            description: resolvedDescription,
            properties: properties
        )

    case "string":
        if let enums = dict["enum"]?.arrayValue?.compactMap({ $0.stringValue }), !enums.isEmpty {
            return DynamicGenerationSchema(name: name, description: resolvedDescription, anyOf: enums)
        }
        return DynamicGenerationSchema(type: String.self)

    case "integer":
        return DynamicGenerationSchema(type: Int.self)

    case "number":
        return DynamicGenerationSchema(type: Double.self)

    case "boolean":
        return DynamicGenerationSchema(type: Bool.self)

    case "array":
        guard let items = dict["items"] else {
            throw Abort(.badRequest, reason: "Array schema at '\(name)' requires 'items'")
        }
        let itemSchema = try buildDynamicSchema(
            name: "\(name).item",
            description: nil,
            schema: items
        )
        return DynamicGenerationSchema(
            arrayOf: itemSchema,
            minimumElements: dict["minItems"]?.intValue,
            maximumElements: dict["maxItems"]?.intValue
        )

    default:
        throw Abort(.badRequest, reason: "Unsupported schema type '\(inferredType)' at '\(name)'")
    }
}

// MARK: - Tool calls (FoundationModels bridge)

/// Thrown by `ProxyTool.call` to abort generation when the model wants a tool the client
/// must execute. FoundationModels wraps it in `LanguageModelSession.ToolCallError`.
struct ProxyToolInvocation: Error {
    let name: String
    let arguments: String
}

/// Pass-through tool synthesized from an OpenAI tool definition.
///
/// FoundationModels executes tools in-process, but OpenAI tools are executed by the client.
/// So `call` never does real work: it returns a client-supplied result when replaying a
/// round-trip, and otherwise records the invocation and throws to stop generation.
@available(macOS 26.0, *)
struct ProxyTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let replay: ToolReplayCache
    let recorder: ToolInvocationRecorder

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        if let cached = replay.result(name: name, arguments: json) {
            return cached
        }
        recorder.record(name: name, arguments: json)
        throw ProxyToolInvocation(name: name, arguments: json)
    }
}

@available(macOS 26.0, *)
func buildToolParametersSchema(_ tool: ChatCompletionRequest.ToolDefinition) throws -> GenerationSchema {
    let schema = tool.function.parameters ?? .object(["type": .string("object"), "properties": .object([:])])
    let root = try buildDynamicSchema(name: tool.function.name, description: nil, schema: schema)
    do {
        return try GenerationSchema(root: root, dependencies: [])
    } catch {
        throw Abort(
            .badRequest,
            reason: "Failed to build parameters schema for tool '\(tool.function.name)': \(error.localizedDescription)"
        )
    }
}

@available(macOS 26.0, *)
func buildProxyTools(
    _ tools: [ChatCompletionRequest.ToolDefinition],
    replay: ToolReplayCache,
    recorder: ToolInvocationRecorder
) throws -> [ProxyTool] {
    try tools.map { tool in
        ProxyTool(
            name: tool.function.name,
            description: tool.function.description ?? "",
            parameters: try buildToolParametersSchema(tool),
            replay: replay,
            recorder: recorder
        )
    }
}

/// Rebuilds prior turns (including completed tool round-trips) as a native `Transcript`,
/// so the model sees real tool-call/tool-output entries rather than prose.
@available(macOS 26.0, *)
func buildTranscript(
    instructions: String?,
    tools: [ProxyTool],
    history: [ChatCompletionRequest.Message]
) throws -> Transcript {
    func text(_ s: String) -> [Transcript.Segment] {
        [.text(.init(content: s))]
    }

    var entries: [Transcript.Entry] = []
    if instructions != nil || !tools.isEmpty {
        entries.append(.instructions(.init(
            segments: instructions.map(text) ?? [],
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
        )))
    }

    var toolNamesByCallID: [String: String] = [:]
    for msg in history {
        switch msg.role {
        case "user":
            entries.append(.prompt(.init(segments: text(msg.content ?? ""))))
        case "assistant":
            if let content = msg.content, !content.isEmpty {
                entries.append(.response(.init(assetIDs: [], segments: text(content))))
            }
            if let calls = msg.tool_calls, !calls.isEmpty {
                let converted = try calls.map { call -> Transcript.ToolCall in
                    toolNamesByCallID[call.id] = call.function.name
                    let args: GeneratedContent
                    do {
                        args = try GeneratedContent(json: call.function.arguments.isEmpty ? "{}" : call.function.arguments)
                    } catch {
                        throw Abort(.badRequest, reason: "tool_calls[].function.arguments for '\(call.id)' is not valid JSON")
                    }
                    return .init(id: call.id, toolName: call.function.name, arguments: args)
                }
                entries.append(.toolCalls(.init(converted)))
            }
        case "tool":
            let id = msg.tool_call_id ?? UUID().uuidString
            let name = toolNamesByCallID[id] ?? msg.name ?? "unknown"
            entries.append(.toolOutput(.init(id: id, toolName: name, segments: text(msg.content ?? ""))))
        default:
            // system/developer are already folded into `instructions`.
            continue
        }
    }
    return Transcript(entries: entries)
}

// MARK: - Streaming (FoundationModels bridge)

// MARK: - Generation (FoundationModels bridge)

/// A ready-to-run session for one request, plus what's needed to interpret its result.
@available(macOS 26.0, *)
struct CompletionSession {
    let session: LanguageModelSession
    let schema: GenerationSchema?
    let recorder: ToolInvocationRecorder
}

/// Builds the schema, tools and transcript, then opens the session. Throws `Abort(400)` on
/// unsupported schemas or malformed tool-call arguments. It runs before any generation, so
/// those failures never get mistaken for model errors.
@available(macOS 26.0, *)
func makeCompletionSession(_ prepared: PreparedCompletion) throws -> CompletionSession {
    let schema = try prepared.schemaSpec.map(buildGenerationSchema(from:))
    let recorder = ToolInvocationRecorder()
    let session: LanguageModelSession
    if let conversation = prepared.conversation {
        let replay = ToolReplayCache(conversation.pendingResults)
        let tools = try buildProxyTools(prepared.activeTools, replay: replay, recorder: recorder)
        let transcript = try buildTranscript(
            instructions: prepared.instructions,
            tools: tools,
            history: conversation.history
        )
        session = LanguageModelSession(tools: tools, transcript: transcript)
    } else if let instructions = prepared.instructions {
        session = LanguageModelSession(instructions: instructions)
    } else {
        session = LanguageModelSession()
    }
    return CompletionSession(session: session, schema: schema, recorder: recorder)
}

/// Maps a generation error to an OpenAI `finish_reason`. Safety blocks become the standard
/// `content_filter`. Everything else stays `error`, which is non-standard but keeps the
/// existing 200-with-explanation contract; see `docs/ARCHITECTURE.md`.
@available(macOS 26.0, *)
func finishReason(for error: Error) -> String {
    if let generationError = error as? LanguageModelSession.GenerationError {
        switch generationError {
        case .guardrailViolation, .refusal:
            return "content_filter"
        default:
            return "error"
        }
    }
    return "error"
}

/// Turns a failed generation into an outcome. A recorded invocation means `ProxyTool`
/// aborted generation on purpose; the error arrives wrapped in `ToolCallError`, but the
/// recorder is the source of truth for what was asked.
@available(macOS 26.0, *)
func failureOutcome(_ error: Error, recorder: ToolInvocationRecorder, logger: Logger) -> CompletionOutcome {
    let invocations = recorder.invocations
    if !invocations.isEmpty {
        return .init(content: nil, toolCalls: invocations, finishReason: "tool_calls")
    }
    logger.error("FoundationModels Error: \(error)")
    return .text("Error during generation: \(error.localizedDescription)", finishReason: finishReason(for: error))
}

@available(macOS 26.0, *)
func generateCompletion(_ cs: CompletionSession, prompt: String, logger: Logger) async -> CompletionOutcome {
    do {
        if let schema = cs.schema {
            return .text(try await cs.session.respond(to: prompt, schema: schema).content.jsonString)
        }
        return .text(try await cs.session.respond(to: prompt).content)
    } catch {
        return failureOutcome(error, recorder: cs.recorder, logger: logger)
    }
}

/// Wraps a failed SSE write (client went away) so the streaming `catch` doesn't mistake it
/// for a generation error and try to write an error chunk to a dead connection.
struct StreamWriteFailed: Error {
    let underlying: Error
}

@available(macOS 26.0, *)
func makeStreamingCompletion(
    _ cs: CompletionSession,
    prompt: String,
    chunks: ChunkFactory,
    includeUsage: Bool,
    logger: Logger
) -> Response {
    makeSSEResponse(chunks: chunks, includeUsage: includeUsage) { writer in
        func send(_ chunk: ChatCompletionChunk) async throws {
            do {
                try await writer.writeSSE(chunk)
            } catch {
                throw StreamWriteFailed(underlying: error)
            }
        }

        do {
            if let schema = cs.schema {
                // Partial `GeneratedContent` snapshots re-serialize with closing braces in
                // different places, so they aren't prefix-stable JSON. Structured output is
                // generated in full and sent as a single content chunk.
                let response = try await cs.session.respond(to: prompt, schema: schema)
                try await send(chunks.content(response.content.jsonString))
            } else {
                var previous = ""
                for try await snapshot in cs.session.streamResponse(to: prompt) {
                    let delta = streamDelta(previous: previous, current: snapshot.content)
                    previous = snapshot.content
                    if !delta.isEmpty {
                        try await send(chunks.content(delta))
                    }
                }
            }
            return "stop"
        } catch let failure as StreamWriteFailed {
            // Rethrowing ends the managed stream; leaving the `for await` loop drops the
            // response stream.
            logger.debug("Streaming client disconnected: \(failure.underlying)")
            throw failure.underlying
        } catch {
            // Text streamed before a tool call or failure stays sent.
            let outcome = failureOutcome(error, recorder: cs.recorder, logger: logger)
            try await writer.writeOutcomeTail(outcome, chunks: chunks)
            return outcome.finishReason
        }
    }
}

#endif

// MARK: - Main Application

@main
struct FoundationModelsProxy {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        app.http.server.configuration.port = 8080
        // Vapor's 16 KB default rejects (413) ordinary agent traffic: tool schemas plus a
        // few tool results in the history go past it quickly.
        app.routes.defaultMaxBodySize = "4mb"
        app.logger.info("Starting Apple FoundationModels proxy on http://127.0.0.1:8080")

        app.get("health") { _ -> HealthResponse in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let model = SystemLanguageModel.default
                return HealthResponse(
                    status: "ok",
                    foundationModelsImportable: true,
                    runtimeSupported: true,
                    modelAvailability: String(describing: model.availability),
                    currentLocale: Locale.current.identifier,
                    currentLocaleSupported: model.supportsLocale(),
                    enUSSupported: model.supportsLocale(Locale(identifier: "en_US")),
                    ruRUSupported: model.supportsLocale(Locale(identifier: "ru_RU")),
                    capabilities: .init(streaming: true, toolCalls: true, structuredOutput: true)
                )
            }
            #endif

            return HealthResponse(
                status: "ok",
                foundationModelsImportable: false,
                runtimeSupported: false,
                modelAvailability: nil,
                currentLocale: Locale.current.identifier,
                currentLocaleSupported: nil,
                enUSSupported: nil,
                ruRUSupported: nil,
                capabilities: .init(streaming: false, toolCalls: false, structuredOutput: false)
            )
        }

        app.post("v1", "chat", "completions") { req async throws -> Response in
            let payload = try req.content.decode(ChatCompletionRequest.self)
            let prepared = try prepareCompletion(payload)

            let completionID = "chatcmpl-\(UUID().uuidString)"
            let created = Int(Date().timeIntervalSince1970)
            let chunks = ChunkFactory(id: completionID, created: created, model: prepared.model)

            let outcome: CompletionOutcome
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let cs = try makeCompletionSession(prepared)
                if prepared.stream {
                    return makeStreamingCompletion(
                        cs,
                        prompt: prepared.prompt,
                        chunks: chunks,
                        includeUsage: prepared.includeUsage,
                        logger: app.logger
                    )
                }
                outcome = await generateCompletion(cs, prompt: prepared.prompt, logger: app.logger)
            } else {
                outcome = unavailableCompletionOutcome
            }
            #else
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            outcome = mockCompletionOutcome(prepared)
            #endif

            if prepared.stream {
                // Reached on the mock build and on pre-macOS-26 runtimes: stream the fixed
                // outcome so streaming clients still get a well-formed reply.
                return makeSSEResponse(chunks: chunks, includeUsage: prepared.includeUsage) { writer in
                    try await writer.writeOutcomeTail(outcome, chunks: chunks)
                    return outcome.finishReason
                }
            }
            return try await makeCompletionResponse(
                outcome,
                id: completionID,
                created: created,
                model: prepared.model
            ).encodeResponse(for: req)
        }

        try await app.execute()
    }
}
