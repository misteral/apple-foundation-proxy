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

// MARK: - Main Application

@main
struct FoundationModelsProxy {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        
        let app = Application(env)
        defer { app.shutdown() }
        
        // Change port to something distinct so it doesn't conflict easily
        app.http.server.configuration.port = 8080
        app.logger.info("Starting Apple FoundationModels proxy on http://127.0.0.1:8080")

        app.post("v1", "chat", "completions") { req async throws -> ChatCompletionResponse in
            let payload = try req.content.decode(ChatCompletionRequest.self)
            
            // For a simple text correction proxy, we'll just extract the user's latest text
            // In a real app, you might want to combine the conversation history.
            let prompt = payload.messages.last?.content ?? ""
            
            var generatedText = "FoundationModels framework is not available or not supported on this OS version."
            
            #if canImport(FoundationModels)
            // FoundationModels is available starting macOS 15.4+ (Apple Intelligence)
            if #available(macOS 15.4, *) {
                do {
                    // Initialize the systemic on-device model
                    let model = LanguageModel()
                    
                    // NOTE: Depending on the exact Xcode/SDK version, this API syntax 
                    // might slightly differ (e.g. model.generate(text:)). 
                    // Adjust according to the latest Apple docs:
                    let response = try await model.generateText(for: prompt)
                    
                    generatedText = response.text
                } catch {
                    app.logger.error("FoundationModels Error: \(error)")
                    generatedText = "Error during generation: \(error.localizedDescription)"
                }
            }
            #else
            // Fallback mock logic when building on older Xcode/macOS
            app.logger.warning("Mocking response since FoundationModels cannot be imported.")
            generatedText = "[Mock Apple Intelligence Response] I corrected your text: \(prompt)"
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
