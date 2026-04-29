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
    struct Message: Content {
        let role: String
        let content: String
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
}

struct ChatCompletionResponse: Content {
    struct Choice: Content {
        struct Message: Content {
            let role: String
            let content: String
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
}

// MARK: - Prompt assembly

/// Joins `system` and `developer` role messages into a single instructions block.
/// Returns nil when there are none so the caller can construct a session without instructions.
func systemInstructions(from messages: [ChatCompletionRequest.Message]) -> String? {
    let parts = messages
        .filter { $0.role == "system" || $0.role == "developer" }
        .map(\.content)
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
        return last.content
    }

    var lines: [String] = []
    for msg in history {
        let label = msg.role == "user" ? "User" : "Assistant"
        lines.append("\(label): \(msg.content)")
    }
    let lastLabel = last.role == "user" ? "User" : "Assistant"
    lines.append("\(lastLabel): \(last.content)")
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
                    ruRUSupported: model.supportsLocale(Locale(identifier: "ru_RU"))
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
                ruRUSupported: nil
            )
        }

        app.post("v1", "chat", "completions") { req async throws -> ChatCompletionResponse in
            let payload = try req.content.decode(ChatCompletionRequest.self)

            let format = payload.response_format
            let formatType = format?.type ?? "text"
            let allowedFormats = Set(["text", "json_object", "json_schema"])
            guard allowedFormats.contains(formatType) else {
                throw Abort(.badRequest, reason: "Unsupported response_format.type: '\(formatType)'")
            }
            if formatType == "json_schema", format?.json_schema == nil {
                throw Abort(.badRequest, reason: "response_format.type='json_schema' requires response_format.json_schema")
            }

            let baseInstructions = systemInstructions(from: payload.messages)
            let effectiveInstructions: String? = (formatType == "json_object")
                ? augmentInstructionsForJSONObject(baseInstructions)
                : baseInstructions
            let prompt = renderPrompt(from: payload.messages)

            var generatedText = "FoundationModels framework is not available or not supported on this OS version."
            var finishReason = "stop"

            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                // Build the schema before opening the session so input-validation errors
                // surface as 400s instead of being swallowed by the session-error catch.
                let schema: GenerationSchema?
                if formatType == "json_schema", let spec = format?.json_schema {
                    schema = try buildGenerationSchema(from: spec)
                } else {
                    schema = nil
                }

                do {
                    let session: LanguageModelSession
                    if let effectiveInstructions {
                        session = LanguageModelSession(instructions: effectiveInstructions)
                    } else {
                        session = LanguageModelSession()
                    }

                    if let schema {
                        let response = try await session.respond(to: prompt, schema: schema)
                        generatedText = response.content.jsonString
                    } else {
                        let response = try await session.respond(to: prompt)
                        generatedText = response.content
                    }
                } catch {
                    app.logger.error("FoundationModels Error: \(error)")
                    generatedText = "Error during generation: \(error.localizedDescription)"
                    finishReason = "error"
                }
            }
            #else
            // Fallback mock when building on toolchains without FoundationModels.
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            if formatType == "json_object" || formatType == "json_schema" {
                generatedText = "{\"mock\":true}"
            } else {
                generatedText = "[Mock Apple Intelligence Response] \(prompt)"
            }
            #endif

            let choice = ChatCompletionResponse.Choice(
                index: 0,
                message: .init(role: "assistant", content: generatedText),
                finish_reason: finishReason
            )

            // FoundationModels does not expose token counts; report zeros so clients that
            // require the `usage` field don't fail to decode the response.
            let usage = ChatCompletionResponse.Usage(
                prompt_tokens: 0,
                completion_tokens: 0,
                total_tokens: 0
            )

            return ChatCompletionResponse(
                id: "chatcmpl-\(UUID().uuidString)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: payload.model ?? "apple-foundation-model",
                choices: [choice],
                usage: usage
            )
        }

        try await app.execute()
    }
}
