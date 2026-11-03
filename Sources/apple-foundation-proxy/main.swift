import Foundation
import Vapor

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(NaturalLanguage)
import NaturalLanguage
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
    /// OpenAI's response cap; `max_completion_tokens` is the newer name and wins if both are set.
    let max_tokens: Int?
    let max_completion_tokens: Int?
    /// Sampling controls; validated by `samplingParameters(from:)`.
    let temperature: Double?
    let top_p: Double?
    let seed: Int?
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
    struct Usage: Content, Equatable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int

        /// Reported when token counting is unavailable (macOS < 26.4) or fails.
        static let zero = Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
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
    /// Language codes the on-device model supports (e.g. `en`, `de`, `zh`).
    let supportedLanguages: [String]?
    /// Context window in tokens (prompt + response).
    let contextSize: Int?
    let capabilities: Capabilities

    struct Capabilities: Content {
        let streaming: Bool
        let toolCalls: Bool
        let structuredOutput: Bool
        /// Real `usage` counts via `SystemLanguageModel.tokenCount` (macOS 26.4+).
        let tokenCounting: Bool
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

// MARK: - OpenAI-style errors

/// A client-visible error with an OpenAI `error.code` (e.g. `context_length_exceeded`).
struct ProxyAPIError: AbortError, Equatable {
    let status: HTTPResponseStatus
    let reason: String
    let code: String?
    var headers: HTTPHeaders = [:]

    static func == (a: ProxyAPIError, b: ProxyAPIError) -> Bool {
        a.status == b.status && a.reason == b.reason && a.code == b.code
    }
}

/// OpenAI's error envelope: `{"error":{"message","type","param","code"}}`. OpenAI SDKs parse
/// this into typed exceptions; Vapor's default `{"error":true,"reason":...}` they don't.
struct OpenAIErrorBody: Content, Equatable {
    struct Detail: Content, Equatable {
        let message: String
        let type: String
        let param: String?
        let code: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(message, forKey: .message)
            try c.encode(type, forKey: .type)
            try c.encode(param, forKey: .param)
            try c.encode(code, forKey: .code)
        }
    }
    let error: Detail
}

func makeOpenAIErrorBody(status: HTTPResponseStatus, message: String, code: String?) -> OpenAIErrorBody {
    let type: String
    switch status.code {
    case 429: type = "rate_limit_error"
    case 400..<500: type = "invalid_request_error"
    default: type = "server_error"
    }
    return OpenAIErrorBody(error: .init(message: message, type: type, param: nil, code: code))
}

/// Replaces Vapor's `ErrorMiddleware` so every error (validation 400s, decoding errors, model
/// failures) leaves the server in OpenAI's error shape.
struct OpenAIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let status: HTTPResponseStatus
            let message: String
            var code: String? = nil
            var headers = HTTPHeaders()
            switch error {
            case let apiError as ProxyAPIError:
                status = apiError.status
                message = apiError.reason
                code = apiError.code
                headers = apiError.headers
            case let abort as AbortError:
                status = abort.status
                message = abort.reason
                headers = abort.headers
            default:
                status = .internalServerError
                message = "Internal server error"
            }
            if status.code >= 500 {
                request.logger.error("\(status.code): \(error)")
            } else {
                request.logger.warning("\(status.code): \(message)")
            }
            let response = Response(status: status, headers: headers)
            try response.content.encode(makeOpenAIErrorBody(status: status, message: message, code: code))
            return response
        }
    }
}

// MARK: - Language detection

/// Below this many letters, NaturalLanguage guesses are noise ("hi" → Catalan, "ok" → Polish).
let languageDetectionMinimumLetters = 20
let languageDetectionMinimumConfidence = 0.8

/// Best-effort dominant language of `text` as a BCP-47 code (`en`, `ru`, `zh-Hans`), or nil
/// when the text is too short or the guess isn't confident.
///
/// Recognition is deliberately unconstrained: restricting it to the model's supported set
/// would force e.g. Russian into some Latin language and hide exactly what we want to flag.
func detectLanguage(in text: String) -> String? {
    #if canImport(NaturalLanguage)
    guard text.filter(\.isLetter).count >= languageDetectionMinimumLetters else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
          confidence >= languageDetectionMinimumConfidence else { return nil }
    return language.rawValue
    #else
    return nil
    #endif
}

/// `zh-Hans` → `zh`, `pt-BR` → `pt`.
func baseLanguageCode(_ identifier: String) -> String? {
    Locale.Language(identifier: identifier).languageCode?.identifier
}

func isLanguageSupported(_ detected: String, supportedCodes: Set<String>) -> Bool {
    guard let code = baseLanguageCode(detected) else { return true }
    return supportedCodes.contains(code)
}

let detectedLanguageHeader = "X-AFP-Detected-Language"
let languageSupportedHeader = "X-AFP-Language-Supported"

/// The language signal is advisory: unsupported languages (e.g. Russian) still get an
/// answer, just a possibly weaker one, so the proxy reports instead of rejecting.
func languageHeaders(detected: String?, supported: Bool?) -> HTTPHeaders {
    var headers = HTTPHeaders()
    guard let detected else { return headers }
    headers.replaceOrAdd(name: detectedLanguageHeader, value: detected)
    if let supported {
        headers.replaceOrAdd(name: languageSupportedHeader, value: supported ? "true" : "false")
    }
    return headers
}

/// Re-throws any error as a `ProxyAPIError` carrying `extraHeaders`, so headers decided
/// before the failure (the language signal) also reach error responses.
func attachingHeaders(_ extraHeaders: HTTPHeaders, to error: Error) -> Error {
    guard !extraHeaders.isEmpty else { return error }
    var apiError: ProxyAPIError
    switch error {
    case let e as ProxyAPIError: apiError = e
    case let e as AbortError: apiError = ProxyAPIError(status: e.status, reason: e.reason, code: nil, headers: e.headers)
    default: return error
    }
    for (name, value) in extraHeaders {
        apiError.headers.replaceOrAdd(name: name, value: value)
    }
    return apiError
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
    /// `detectLanguage` of the latest user message; nil when unknown.
    let detectedLanguage: String?
    /// Client-requested response cap; nil when not given. See `responseTokenBudget`.
    let maxTokens: Int?
    let sampling: SamplingParameters
}

func prepareCompletion(_ payload: ChatCompletionRequest) throws -> PreparedCompletion {
    guard let lastUser = payload.messages.last(where: { $0.role == "user" }) else {
        throw Abort(.badRequest, reason: "messages must contain at least one 'user' message")
    }
    let maxTokens = payload.max_completion_tokens ?? payload.max_tokens
    if let maxTokens, maxTokens < 1 {
        throw Abort(.badRequest, reason: "max_tokens / max_completion_tokens must be at least 1")
    }
    let sampling = try samplingParameters(from: payload)

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
        // Pending results go into the prompt as text *and* are replayed through
        // `ProxyTool`. Replay alone loses them if the model answers without calling the
        // tool again; text alone loses the native tool-output framing. With both, the
        // result reaches the model either way.
        prompt = appendToolResultsToPrompt(conversation.prompt, results: conversation.pendingResults)
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
        model: payload.model ?? "apple-foundation-model",
        detectedLanguage: lastUser.content.flatMap(detectLanguage(in:)),
        maxTokens: maxTokens,
        sampling: sampling
    )
}

// MARK: - Sampling

/// OpenAI sampling controls, validated against OpenAI's ranges. FoundationModels rejects
/// some out-of-range values mid-generation (a `top_p` above 1 fails with an opaque
/// error), so they're refused up front with a clear 400.
struct SamplingParameters: Equatable {
    var temperature: Double? = nil
    /// OpenAI `top_p` → nucleus sampling (`SamplingMode.random(probabilityThreshold:)`).
    var topP: Double? = nil
    var seed: UInt64? = nil

    enum Mode: Equatable {
        case greedy
        case nucleus(threshold: Double, seed: UInt64?)
    }

    /// How tokens get picked; nil keeps the model's default sampling.
    /// `top_p: 0` means "only the top token", which is greedy. `top_p: 1` without a seed
    /// is the default. A seed needs random sampling to apply to, so a seed alone becomes
    /// nucleus sampling over the full distribution.
    var mode: Mode? {
        switch (topP, seed) {
        case (0?, _): return .greedy
        case (nil, nil), (1?, nil): return nil
        case let (topP, seed): return .nucleus(threshold: topP ?? 1, seed: seed)
        }
    }
}

func samplingParameters(from payload: ChatCompletionRequest) throws -> SamplingParameters {
    if let t = payload.temperature, !(0...2).contains(t) {
        throw Abort(.badRequest, reason: "temperature must be between 0 and 2")
    }
    if let p = payload.top_p, !(0...1).contains(p) {
        throw Abort(.badRequest, reason: "top_p must be between 0 and 1")
    }
    // OpenAI seeds are signed 64-bit; keep every value distinct.
    let seed = payload.seed.map { UInt64(bitPattern: Int64($0)) }
    return SamplingParameters(temperature: payload.temperature, topP: payload.top_p, seed: seed)
}

// MARK: - Response token budget

/// Headroom kept free in the context window. FoundationModels' real limit sits below the
/// nominal `contextSize`. Measured on macOS 26.6 with a 2960-token prompt: a cap leaving 16
/// tokens free still failed ("4091 tokens exceeds 4096"), while 128 free reached the cap
/// cleanly (transcript total 3969).
let responseTokenMargin = 128

/// The response cap for one request: the client's `max_tokens`, clamped to what's left of the
/// context window after the prompt. Without a cap, FoundationModels generates until the window
/// fills and only then throws `exceededContextWindowSize`, so a runaway reply to a short prompt
/// would surface as a misleading "context length exceeded". With the cap it ends as
/// `finish_reason: "length"`. A prompt that leaves no room at all is a 400 up front.
func responseTokenBudget(requested: Int?, promptTokens: Int, contextSize: Int) throws -> Int {
    let remaining = contextSize - promptTokens - responseTokenMargin
    guard remaining > 0 else {
        throw ProxyAPIError(
            status: .badRequest,
            reason: "Content contains \(promptTokens) tokens, which leaves no room for a response within the maximum context size of \(contextSize).",
            code: "context_length_exceeded"
        )
    }
    return min(requested ?? remaining, remaining)
}

/// `length` when generation used the whole budget. FoundationModels truncates silently at
/// `maximumResponseTokens`, so the token count is the only signal. Re-tokenizing the output
/// can land one token off the generated count at the boundary (cap 1008 → counted 1007),
/// hence the 1-token tolerance.
func finishReason(completionTokens: Int, budget: Int?) -> String {
    if let budget, completionTokens + 1 >= budget {
        return "length"
    }
    return "stop"
}

/// Result of one generation, independent of how it's delivered (JSON or SSE).
struct CompletionOutcome: Equatable {
    let content: String?
    let toolCalls: [ToolInvocationRecorder.Invocation]
    var finishReason: String
    var usage: ChatCompletionResponse.Usage = .zero

    static func text(_ content: String, finishReason: String = "stop") -> CompletionOutcome {
        .init(content: content, toolCalls: [], finishReason: finishReason)
    }

    /// The model-generated part, for counting completion tokens.
    var completionText: String {
        content ?? toolCalls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "\n")
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
        usage: outcome.usage
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

    /// `stream_options.include_usage` trailer: empty `choices`, then usage.
    func usage(_ usage: ChatCompletionResponse.Usage) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: model,
            choices: [],
            usage: usage
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

    /// Mid-stream failure: HTTP status is already 200, so the error travels as an OpenAI
    /// error event, which OpenAI SDKs raise as an `APIError`.
    func writeSSEError(_ error: ProxyAPIError) async throws {
        let body = makeOpenAIErrorBody(status: error.status, message: error.reason, code: error.code)
        try await writeBuffer(ByteBuffer(string: try sseEvent(body)))
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

/// How a streamed generation ended. `nil` from a generator means it already wrote an error
/// event, so there's no finish chunk or usage.
struct StreamEnd {
    let finishReason: String
    let usage: ChatCompletionResponse.Usage
}

/// Wraps a generator in an OpenAI-shaped SSE response: role chunk, whatever `generate`
/// writes, a finish chunk, an optional usage trailer, `[DONE]`.
func makeSSEResponse(
    chunks: ChunkFactory,
    includeUsage: Bool,
    generate: @escaping @Sendable (AsyncBodyStreamWriter) async throws -> StreamEnd?
) -> Response {
    let body = Response.Body(managedAsyncStream: { writer in
        try await writer.writeSSE(chunks.role())
        if let end = try await generate(writer) {
            try await writer.writeSSE(chunks.finish(end.finishReason))
            if includeUsage {
                try await writer.writeSSE(chunks.usage(end.usage))
            }
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
    let sampling: SamplingParameters
    /// Response cap passed to the model; set by `applyResponseBudget`.
    var responseBudget: Int? = nil

    var options: GenerationOptions {
        let mode: GenerationOptions.SamplingMode? = switch sampling.mode {
        case nil: nil
        case .greedy: .greedy
        case let .nucleus(threshold, seed): .random(probabilityThreshold: threshold, seed: seed)
        }
        return GenerationOptions(sampling: mode, temperature: sampling.temperature, maximumResponseTokens: responseBudget)
    }
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
    return CompletionSession(session: session, schema: schema, recorder: recorder, sampling: prepared.sampling)
}

/// Maps a FoundationModels failure to a client-visible HTTP error, or `nil` for safety
/// blocks, which OpenAI reports as a normal reply with `finish_reason: "content_filter"`.
@available(macOS 26.0, *)
func apiError(for error: Error) -> ProxyAPIError? {
    guard let generationError = error as? LanguageModelSession.GenerationError else {
        return ProxyAPIError(status: .internalServerError, reason: error.localizedDescription, code: "generation_failed")
    }
    // The context's debug description is the specific one ("Content contains 5907 tokens,
    // which exceeds ... 4096."); `localizedDescription` is a generic sentence.
    let message = generationErrorContext(generationError)?.debugDescription ?? error.localizedDescription
    switch generationError {
    case .guardrailViolation, .refusal:
        return nil
    case .exceededContextWindowSize:
        return ProxyAPIError(status: .badRequest, reason: message, code: "context_length_exceeded")
    case .unsupportedLanguageOrLocale:
        return ProxyAPIError(status: .badRequest, reason: message, code: "unsupported_language")
    case .unsupportedGuide:
        return ProxyAPIError(status: .badRequest, reason: message, code: "unsupported_schema")
    case .rateLimited, .concurrentRequests:
        return ProxyAPIError(status: .tooManyRequests, reason: message, code: "rate_limit_exceeded")
    case .assetsUnavailable:
        return ProxyAPIError(status: .serviceUnavailable, reason: message, code: "model_unavailable")
    case .decodingFailure:
        return ProxyAPIError(status: .internalServerError, reason: message, code: "generation_failed")
    @unknown default:
        return ProxyAPIError(status: .internalServerError, reason: message, code: "generation_failed")
    }
}

@available(macOS 26.0, *)
func generationErrorContext(_ error: LanguageModelSession.GenerationError) -> LanguageModelSession.GenerationError.Context? {
    switch error {
    case .exceededContextWindowSize(let c), .assetsUnavailable(let c), .guardrailViolation(let c),
         .unsupportedGuide(let c), .unsupportedLanguageOrLocale(let c), .decodingFailure(let c),
         .rateLimited(let c), .concurrentRequests(let c), .refusal(_, let c):
        return c
    @unknown default:
        return nil
    }
}

/// Turns a failed generation into an outcome, or throws the client-visible error.
/// A recorded invocation means `ProxyTool` aborted generation on purpose. The error arrives
/// wrapped in `ToolCallError`, but the recorder is the source of truth for what was asked.
@available(macOS 26.0, *)
func failureOutcome(_ error: Error, recorder: ToolInvocationRecorder, logger: Logger) throws -> CompletionOutcome {
    let invocations = recorder.invocations
    if !invocations.isEmpty {
        return .init(content: nil, toolCalls: invocations, finishReason: "tool_calls")
    }
    guard let apiError = apiError(for: error) else {
        logger.warning("Generation blocked by safety guardrails: \(error)")
        return .init(content: nil, toolCalls: [], finishReason: "content_filter")
    }
    throw apiError
}

/// Real token usage from the model's own tokenizer (macOS 26.4+; zeros below or on failure).
///
/// `prompt_tokens` counts the session transcript through the latest prompt entry: the
/// instructions, tool definitions, history and prompt. `completion_tokens` counts what the
/// model produced this turn (text, or tool-call names and arguments). Entries replayed after
/// the prompt aren't counted, so on tool round-trips the numbers are a close lower bound.
@available(macOS 26.0, *)
func measureUsage(_ cs: CompletionSession, outcome: CompletionOutcome) async -> ChatCompletionResponse.Usage {
    guard #available(macOS 26.4, *) else { return .zero }
    let model = SystemLanguageModel.default
    let entries = Array(cs.session.transcript)
    let lastPrompt = entries.lastIndex { entry in
        if case .prompt = entry { return true }
        return false
    }
    let promptEntries = lastPrompt.map { Array(entries[...$0]) } ?? entries
    guard let promptTokens = try? await model.tokenCount(for: promptEntries) else { return .zero }
    let text = outcome.completionText
    var completionTokens = 0
    if !text.isEmpty {
        // `tokenCount(for: String)` wraps the text as a prompt, which adds a fixed framing
        // overhead (8 tokens on macOS 26.6). Subtract the empty-string baseline so
        // `completion_tokens` counts only the generated content.
        async let raw = try? model.tokenCount(for: text)
        async let baseline = try? model.tokenCount(for: "")
        if let raw = await raw, let baseline = await baseline {
            completionTokens = max(raw - baseline, 0)
        }
    }
    return .init(
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: promptTokens + completionTokens
    )
}

/// Sets the session's response cap (`responseTokenBudget`). On macOS 26.4+ it counts the
/// prompt with the model's tokenizer, which also rejects prompts that can't fit before any
/// generation or stream starts. Below 26.4 there's no tokenizer, so only the client's
/// `max_tokens` is applied.
@available(macOS 26.0, *)
func applyResponseBudget(_ cs: CompletionSession, prompt: String, requested: Int?) async throws -> CompletionSession {
    var budgeted = cs
    guard #available(macOS 26.4, *) else {
        budgeted.responseBudget = requested
        return budgeted
    }
    let model = SystemLanguageModel.default
    guard let historyTokens = try? await model.tokenCount(for: cs.session.transcript),
          let promptTokens = try? await model.tokenCount(for: prompt) else {
        budgeted.responseBudget = requested
        return budgeted
    }
    budgeted.responseBudget = try responseTokenBudget(
        requested: requested,
        promptTokens: historyTokens + promptTokens,
        contextSize: model.contextSize
    )
    return budgeted
}

/// Fills in usage and, for a normal stop, whether the budget cut the reply short.
@available(macOS 26.0, *)
func finalize(_ outcome: CompletionOutcome, _ cs: CompletionSession) async -> CompletionOutcome {
    var final = outcome
    final.usage = await measureUsage(cs, outcome: outcome)
    if final.finishReason == "stop", final.usage != .zero {
        final.finishReason = finishReason(completionTokens: final.usage.completion_tokens, budget: cs.responseBudget)
    }
    return final
}

@available(macOS 26.0, *)
func generateCompletion(_ cs: CompletionSession, prompt: String, logger: Logger) async throws -> CompletionOutcome {
    var outcome: CompletionOutcome
    do {
        if let schema = cs.schema {
            outcome = .text(try await cs.session.respond(to: prompt, schema: schema, options: cs.options).content.jsonString)
        } else {
            outcome = .text(try await cs.session.respond(to: prompt, options: cs.options).content)
        }
    } catch {
        outcome = try failureOutcome(error, recorder: cs.recorder, logger: logger)
    }
    return await finalize(outcome, cs)
}

@available(macOS 26.0, *)
func supportedLanguageCodes() -> Set<String> {
    Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
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
        func end(_ outcome: CompletionOutcome) async -> StreamEnd {
            // Counting (~20 ms a call) is needed for usage and to tell `length` from `stop`.
            guard includeUsage || cs.responseBudget != nil else {
                return StreamEnd(finishReason: outcome.finishReason, usage: .zero)
            }
            let final = await finalize(outcome, cs)
            return StreamEnd(finishReason: final.finishReason, usage: final.usage)
        }

        do {
            if let schema = cs.schema {
                // Partial `GeneratedContent` snapshots re-serialize with closing braces in
                // different places, so they aren't prefix-stable JSON. Structured output is
                // generated in full and sent as a single content chunk.
                let json = try await cs.session.respond(to: prompt, schema: schema, options: cs.options).content.jsonString
                try await send(chunks.content(json))
                return await end(.text(json))
            }
            var previous = ""
            for try await snapshot in cs.session.streamResponse(to: prompt, options: cs.options) {
                let delta = streamDelta(previous: previous, current: snapshot.content)
                previous = snapshot.content
                if !delta.isEmpty {
                    try await send(chunks.content(delta))
                }
            }
            return await end(.text(previous))
        } catch let failure as StreamWriteFailed {
            // Rethrowing ends the managed stream; leaving the `for await` loop drops the
            // response stream.
            logger.debug("Streaming client disconnected: \(failure.underlying)")
            throw failure.underlying
        } catch {
            // Text streamed before a tool call or failure stays sent.
            do {
                let outcome = try failureOutcome(error, recorder: cs.recorder, logger: logger)
                try await writer.writeOutcomeTail(outcome, chunks: chunks)
                return await end(outcome)
            } catch let apiError as ProxyAPIError {
                logger.error("FoundationModels error mid-stream: \(error)")
                try await writer.writeSSEError(apiError)
                return nil
            }
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
        // Same stack as Vapor's default, with the error middleware swapped for one that
        // speaks OpenAI's error format.
        app.middleware = Middlewares()
        app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
        app.middleware.use(OpenAIErrorMiddleware())
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
                    supportedLanguages: supportedLanguageCodes().sorted(),
                    contextSize: model.contextSize,
                    capabilities: .init(
                        streaming: true,
                        toolCalls: true,
                        structuredOutput: true,
                        tokenCounting: { if #available(macOS 26.4, *) { return true } else { return false } }()
                    )
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
                supportedLanguages: nil,
                contextSize: nil,
                capabilities: .init(streaming: false, toolCalls: false, structuredOutput: false, tokenCounting: false)
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
                let languageSupported = prepared.detectedLanguage.map {
                    isLanguageSupported($0, supportedCodes: supportedLanguageCodes())
                }
                if let detected = prepared.detectedLanguage, languageSupported == false {
                    // `notice`, not `warning`: it fires on every request in that language.
                    app.logger.notice("Prompt language '\(detected)' is not supported by the on-device model; output quality may be degraded.")
                }

                let extraHeaders = languageHeaders(detected: prepared.detectedLanguage, supported: languageSupported)
                do {
                    let cs = try await applyResponseBudget(
                        try makeCompletionSession(prepared),
                        prompt: prepared.prompt,
                        requested: prepared.maxTokens
                    )
                    let response: Response
                    if prepared.stream {
                        response = makeStreamingCompletion(
                            cs,
                            prompt: prepared.prompt,
                            chunks: chunks,
                            includeUsage: prepared.includeUsage,
                            logger: app.logger
                        )
                    } else {
                        let generated = try await generateCompletion(cs, prompt: prepared.prompt, logger: app.logger)
                        response = try await makeCompletionResponse(
                            generated,
                            id: completionID,
                            created: created,
                            model: prepared.model
                        ).encodeResponse(for: req)
                    }
                    for (name, value) in extraHeaders {
                        response.headers.replaceOrAdd(name: name, value: value)
                    }
                    return response
                } catch {
                    throw attachingHeaders(extraHeaders, to: error)
                }
            } else {
                outcome = unavailableCompletionOutcome
            }
            #else
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            outcome = mockCompletionOutcome(prepared)
            #endif

            // Reached on the mock build and on pre-macOS-26 runtimes.
            if prepared.stream {
                return makeSSEResponse(chunks: chunks, includeUsage: prepared.includeUsage) { writer in
                    try await writer.writeOutcomeTail(outcome, chunks: chunks)
                    return StreamEnd(finishReason: outcome.finishReason, usage: outcome.usage)
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
