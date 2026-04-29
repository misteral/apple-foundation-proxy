import Foundation
import Vapor

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - OpenAI Compatible DTOs

struct ChatCompletionRequest: Content {
    struct Message: Content {
        let role: String
        let content: String
    }
    let model: String?
    let messages: [Message]
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
/// The last `user`/`assistant` turn becomes the immediate prompt; earlier turns are prepended
/// as a labeled transcript so the model sees the history. `system`/`developer` messages are
/// handled separately via `Instructions` and are excluded here.
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
    lines.append("User: \(last.content)")
    lines.append("Assistant:")
    return lines.joined(separator: "\n")
}

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

            let instructions = systemInstructions(from: payload.messages)
            let prompt = renderPrompt(from: payload.messages)

            var generatedText = "FoundationModels framework is not available or not supported on this OS version."
            var finishReason = "stop"

            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    let session: LanguageModelSession
                    if let instructions {
                        session = LanguageModelSession(instructions: instructions)
                    } else {
                        session = LanguageModelSession()
                    }
                    let response = try await session.respond(to: prompt)
                    generatedText = response.content
                } catch {
                    app.logger.error("FoundationModels Error: \(error)")
                    generatedText = "Error during generation: \(error.localizedDescription)"
                    finishReason = "error"
                }
            }
            #else
            // Fallback mock when building on toolchains without FoundationModels.
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            generatedText = "[Mock Apple Intelligence Response] \(prompt)"
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
