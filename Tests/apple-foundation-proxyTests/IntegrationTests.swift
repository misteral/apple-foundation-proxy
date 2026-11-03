import Foundation
import Testing
import Vapor
@testable import apple_foundation_proxy

#if canImport(FoundationModels)
import FoundationModels

/// Opt-in tests against the real on-device model: `AFP_INTEGRATION=1 swift test`.
///
/// They go through the same functions as the HTTP handler (`prepareCompletion` →
/// `makeCompletionSession` → `generateCompletion`) and assert only on structure, not wording,
/// so they stay stable despite sampling. They need Apple Intelligence enabled, so they are
/// off by default and in CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AFP_INTEGRATION"] == "1"), .serialized)
struct IntegrationTests {
    private let logger = Logger(label: "integration")

    private func complete(_ json: String) async throws -> CompletionOutcome {
        guard #available(macOS 26.0, *) else { throw Abort(.notImplemented) }
        let payload = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        let prepared = try prepareCompletion(payload)
        let session = try makeCompletionSession(prepared)
        return try await generateCompletion(session, prompt: prepared.prompt, logger: logger)
    }

    private let weatherTool = #"{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}"#

    @Test func schemaOutputConformsToSchema() async throws {
        let outcome = try await complete(#"""
        {"messages":[{"role":"user","content":"Invent a fictional pet cat."}],
         "response_format":{"type":"json_schema","json_schema":{"name":"Cat","schema":{
           "type":"object",
           "properties":{
             "name":{"type":"string"},
             "age":{"type":"integer"},
             "color":{"type":"string","enum":["black","white","ginger"]},
             "toys":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}
           },
           "required":["name","age","color","toys"],
           "additionalProperties":false}}}}
        """#)
        #expect(outcome.finishReason == "stop")
        let content = try #require(outcome.content)
        let obj = try #require(parseJSONValue(content)?.objectValue)
        #expect(obj["name"]?.stringValue?.isEmpty == false)
        #expect(obj["age"]?.intValue != nil)
        #expect(["black", "white", "ginger"].contains(obj["color"]?.stringValue ?? ""))
        let toys = try #require(obj["toys"]?.arrayValue)
        #expect((1...3).contains(toys.count))
    }

    @Test func toolRoundTrip() async throws {
        let first = try await complete(#"""
        {"messages":[{"role":"user","content":"What's the weather in Paris right now?"}],
         "tools":[\#(weatherTool)],"tool_choice":"required"}
        """#)
        #expect(first.finishReason == "tool_calls")
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "get_weather")
        #expect(parseJSONValue(call.arguments)?.objectValue?["city"] != nil)

        let second = try await complete(#"""
        {"messages":[
          {"role":"user","content":"What's the weather in Paris right now?"},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":\#(String(reflecting: call.arguments))}}]},
          {"role":"tool","tool_call_id":"c1","content":"Sunny, 31C"}
         ],
         "tools":[\#(weatherTool)]}
        """#)
        #expect(second.finishReason == "stop")
        #expect(second.content?.contains("31") == true)
    }

    @Test func usageIsCountedOnSupportedOS() async throws {
        guard #available(macOS 26.4, *) else { return }
        let outcome = try await complete(#"{"messages":[{"role":"user","content":"Name three primary colors."}]}"#)
        #expect(outcome.usage.prompt_tokens > 0)
        #expect(outcome.usage.completion_tokens > 0)
        #expect(outcome.usage.total_tokens == outcome.usage.prompt_tokens + outcome.usage.completion_tokens)
    }

    @Test func contextOverflowIsA400() async throws {
        let long = String(repeating: "The quick brown fox jumps over the lazy dog near the river bank. ", count: 420)
        let json = String(decoding: try JSONEncoder().encode(["messages": [["role": "user", "content": long]]]), as: UTF8.self)
        do {
            _ = try await complete(json)
            Issue.record("expected context_length_exceeded")
        } catch let error as ProxyAPIError {
            #expect(error.status == .badRequest)
            #expect(error.code == "context_length_exceeded")
        }
    }

    @Test func budgetRejectsPromptThatCannotFitBeforeGenerating() async throws {
        guard #available(macOS 26.4, *) else { return }
        let long = String(repeating: "The quick brown fox jumps over the lazy dog near the river bank. ", count: 420)
        let json = String(decoding: try JSONEncoder().encode(["messages": [["role": "user", "content": long]]]), as: UTF8.self)
        let prepared = try prepareCompletion(JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8)))
        let session = try makeCompletionSession(prepared)
        await #expect(throws: ProxyAPIError.self) {
            _ = try await applyResponseBudget(session, prompt: prepared.prompt, requested: nil)
        }
    }

    private func completeBudgeted(_ json: String) async throws -> CompletionOutcome {
        guard #available(macOS 26.4, *) else { throw Abort(.notImplemented) }
        let prepared = try prepareCompletion(JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8)))
        let session = try await applyResponseBudget(
            try makeCompletionSession(prepared),
            prompt: prepared.prompt,
            requested: prepared.maxTokens
        )
        return try await generateCompletion(session, prompt: prepared.prompt, logger: logger)
    }

    @Test func sameSeedGivesSameReply() async throws {
        guard #available(macOS 26.4, *) else { return }
        let json = #"{"temperature":1.5,"seed":42,"max_tokens":60,"messages":[{"role":"user","content":"Invent a short poem about a strange city."}]}"#
        let first = try await completeBudgeted(json)
        let second = try await completeBudgeted(json)
        #expect(first.content == second.content)
    }

    @Test func maxTokensTruncatesWithLength() async throws {
        guard #available(macOS 26.4, *) else { return }
        let outcome = try await completeBudgeted(#"{"max_tokens":20,"messages":[{"role":"user","content":"Write a long story about a lighthouse keeper."}]}"#)
        #expect(outcome.finishReason == "length")
        #expect(outcome.usage.completion_tokens <= 20)
    }

    @Test func runawayReplyEndsWithLengthNotAnError() async throws {
        // Regression: this used to fill the window and fail as `context_length_exceeded`.
        guard #available(macOS 26.4, *) else { return }
        let prompt = String(repeating: "The quick brown fox jumps over the lazy dog near the river bank. ", count: 210)
            + "\nRepeat the text above verbatim, then continue it."
        let json = String(decoding: try JSONEncoder().encode(["messages": [["role": "user", "content": prompt]]]), as: UTF8.self)
        let outcome = try await completeBudgeted(json)
        #expect(["length", "stop"].contains(outcome.finishReason))
    }
}

#endif
