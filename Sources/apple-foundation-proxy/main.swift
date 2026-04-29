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
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
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

// MARK: - Prompt Helpers

func latestUserContent(from messages: [ChatCompletionRequest.Message]) -> String {
    messages.last(where: { $0.role == "user" })?.content ?? messages.last?.content ?? ""
}

func extractDictationText(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()
    let instructionPrefixes = [
        "исправь", "поправь", "отредактируй", "почини",
        "correct", "fix", "clean up", "rewrite"
    ]

    if instructionPrefixes.contains(where: { lowercased.hasPrefix($0) }),
       let colonIndex = trimmed.firstIndex(of: ":") {
        return String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return trimmed
}

func makeCorrectionPrompt(for text: String) -> String {
    """
    Correct the dictation text below.
    You MUST preserve the original language and meaning.
    If the text is Russian, respond in Russian.
    Do NOT translate.
    Do NOT explain.
    Do NOT add XML/Markdown/quotes.
    Return ONLY the corrected text.

    TEXT TO CORRECT:
    \(text)
    """
}

func cleanModelOutput(_ text: String) -> String {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

    for tag in ["dictation", "text", "corrected"] {
        cleaned = cleaned.replacingOccurrences(of: "<\(tag)>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "</\(tag)>", with: "")
    }

    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
        cleaned.removeFirst()
        cleaned.removeLast()
    }

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        // Change port to something distinct so it doesn't conflict easily
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
            
            // For this first version, treat the endpoint as a local dictation cleanup service.
            let rawUserText = latestUserContent(from: payload.messages)
            let dictationText = extractDictationText(from: rawUserText)
            let prompt = makeCorrectionPrompt(for: dictationText)
            
            var generatedText = "FoundationModels framework is not available or not supported on this OS version."
            
            #if canImport(FoundationModels)
            // FoundationModels is available starting macOS 26+ / iOS 26+ (Apple Intelligence).
            if #available(macOS 26.0, *) {
                do {
                    let instructions = """
                    You are a strict text correction engine.
                    ALWAYS correct dictation mistakes, typos, punctuation, and casing.
                    ALWAYS preserve the user's original language and meaning.
                    NEVER translate.
                    NEVER explain.
                    NEVER add quotes.
                    Return ONLY the corrected text.
                    """

                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt)
                    generatedText = cleanModelOutput(response.content)
                } catch {
                    app.logger.error("FoundationModels Error: \(error)")
                    generatedText = "Error during generation: \(error.localizedDescription)"
                }
            }
            #else
            // Fallback mock logic when building on older Xcode/macOS
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            generatedText = "[Mock Apple Intelligence Response] I corrected your text: \(dictationText)"
            #endif

            let choice = ChatCompletionResponse.Choice(
                index: 0,
                message: .init(role: "assistant", content: generatedText)
            )

            return ChatCompletionResponse(
                id: UUID().uuidString,
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: payload.model ?? "apple-foundation-model",
                choices: [choice]
            )
        }

        try await app.execute()
    }
}
