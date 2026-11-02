import Foundation
import Testing
import Vapor
@testable import apple_foundation_proxy

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - systemInstructions

@Suite struct SystemInstructionsTests {
    typealias Message = ChatCompletionRequest.Message

    @Test func returnsNilWhenNoMessages() {
        #expect(systemInstructions(from: []) == nil)
    }

    @Test func returnsNilWhenNoSystemOrDeveloperRoles() {
        let result = systemInstructions(from: [
            Message(role: "user", content: "hi"),
            Message(role: "assistant", content: "hello"),
        ])
        #expect(result == nil)
    }

    @Test func returnsSingleSystemMessageVerbatim() {
        let result = systemInstructions(from: [
            Message(role: "system", content: "You are concise."),
        ])
        #expect(result == "You are concise.")
    }

    @Test func joinsMultipleSystemAndDeveloperMessagesInOrder() {
        let result = systemInstructions(from: [
            Message(role: "system", content: "You are concise."),
            Message(role: "user", content: "ignored"),
            Message(role: "developer", content: "Format as bullets."),
        ])
        #expect(result == "You are concise.\n\nFormat as bullets.")
    }

    @Test func ignoresUserAndAssistantContent() {
        let result = systemInstructions(from: [
            Message(role: "user", content: "should not appear"),
            Message(role: "system", content: "kept"),
            Message(role: "assistant", content: "should not appear either"),
        ])
        #expect(result == "kept")
    }
}

// MARK: - renderPrompt

@Suite struct RenderPromptTests {
    typealias Message = ChatCompletionRequest.Message

    @Test func returnsEmptyStringWhenNoConversation() {
        #expect(renderPrompt(from: []) == "")
        #expect(renderPrompt(from: [Message(role: "system", content: "ignored")]) == "")
    }

    @Test func singleUserMessageIsReturnedVerbatim() {
        let result = renderPrompt(from: [Message(role: "user", content: "hi")])
        #expect(result == "hi")
    }

    @Test func systemMessagesAreExcludedFromPrompt() {
        let result = renderPrompt(from: [
            Message(role: "system", content: "be concise"),
            Message(role: "developer", content: "answer in JSON"),
            Message(role: "user", content: "hi"),
        ])
        #expect(result == "hi")
    }

    @Test func multiTurnEndsWithAssistantCueWhenLastIsUser() {
        let result = renderPrompt(from: [
            Message(role: "user", content: "hi"),
            Message(role: "assistant", content: "hello"),
            Message(role: "user", content: "what's 2+2?"),
        ])
        let expected = """
        User: hi
        Assistant: hello
        User: what's 2+2?
        Assistant:
        """
        #expect(result == expected)
    }

    @Test func multiTurnDoesNotAppendCueWhenLastIsAssistant() {
        let result = renderPrompt(from: [
            Message(role: "user", content: "hi"),
            Message(role: "assistant", content: "hello"),
        ])
        let expected = """
        User: hi
        Assistant: hello
        """
        #expect(result == expected)
    }

    @Test func ignoresUnknownRoles() {
        let result = renderPrompt(from: [
            Message(role: "user", content: "hi"),
            Message(role: "tool", content: "tool result — not implemented"),
            Message(role: "assistant", content: "hello"),
        ])
        let expected = """
        User: hi
        Assistant: hello
        """
        #expect(result == expected)
    }
}

// MARK: - augmentInstructionsForJSONObject

@Suite struct AugmentInstructionsForJSONObjectTests {
    @Test func returnsBareDirectiveWhenNoBase() {
        #expect(augmentInstructionsForJSONObject(nil) == jsonObjectDirective)
        #expect(augmentInstructionsForJSONObject("") == jsonObjectDirective)
    }

    @Test func appendsDirectiveAfterBase() {
        let result = augmentInstructionsForJSONObject("Be concise.")
        #expect(result == "Be concise.\n\n" + jsonObjectDirective)
    }
}

// MARK: - JSONValue

@Suite struct JSONValueTests {
    @Test func decodesPrimitives() throws {
        let decoder = JSONDecoder()
        try #expect(decoder.decode(JSONValue.self, from: Data("null".utf8)) == .null)
        try #expect(decoder.decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
        try #expect(decoder.decode(JSONValue.self, from: Data("42".utf8)) == .int(42))
        try #expect(decoder.decode(JSONValue.self, from: Data("3.14".utf8)) == .double(3.14))
        try #expect(decoder.decode(JSONValue.self, from: Data("\"hi\"".utf8)) == .string("hi"))
    }

    @Test func decodesArrayAndObject() throws {
        let decoder = JSONDecoder()
        let arr = try decoder.decode(JSONValue.self, from: Data("[1,\"two\",true]".utf8))
        #expect(arr == .array([.int(1), .string("two"), .bool(true)]))

        let obj = try decoder.decode(JSONValue.self, from: Data("{\"k\":1}".utf8))
        #expect(obj == .object(["k": .int(1)]))
    }

    @Test func roundTripsThroughEncoder() throws {
        let value: JSONValue = .object([
            "name": .string("Alex"),
            "age": .int(30),
            "scores": .array([.double(1.5), .double(2.5)]),
            "active": .bool(true),
            "missing": .null,
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func accessorsReturnNilForMismatchedKinds() {
        #expect(JSONValue.string("x").intValue == nil)
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.bool(true).arrayValue == nil)
        #expect(JSONValue.null.objectValue == nil)
    }

    @Test func intValueAcceptsExactDoubles() {
        #expect(JSONValue.double(5).intValue == 5)
        #expect(JSONValue.double(5.5).intValue == nil)
    }
}

// MARK: - response_format decoding (Vapor Content path)

@Suite struct ResponseFormatDecodingTests {
    @Test func decodesRequestWithoutResponseFormat() throws {
        let json = """
        {"model":"m","messages":[{"role":"user","content":"hi"}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.response_format == nil)
    }

    @Test func decodesJsonObjectFormat() throws {
        let json = """
        {"model":"m","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_object"}}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.response_format?.type == "json_object")
        #expect(req.response_format?.json_schema == nil)
    }

    @Test func decodesJsonSchemaFormat() throws {
        let json = #"""
        {
          "model":"m",
          "messages":[{"role":"user","content":"hi"}],
          "response_format":{
            "type":"json_schema",
            "json_schema":{
              "name":"Person",
              "description":"a person",
              "schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
              "strict":true
            }
          }
        }
        """#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        let spec = try #require(req.response_format?.json_schema)
        #expect(spec.name == "Person")
        #expect(spec.description == "a person")
        #expect(spec.strict == true)
        let schemaObj = try #require(spec.schema?.objectValue)
        #expect(schemaObj["type"] == .string("object"))
    }
}

// MARK: - Schema bridge (FoundationModels-gated)

#if canImport(FoundationModels)

/// `buildGenerationSchema` is `@available(macOS 26.0, *)`, but Swift Testing's
/// `@Test`/`@Suite` macros don't accept `@available` annotations on the type or function.
/// Each test guards the call site with `if #available` and returns early on older runtimes.
@Suite struct BuildGenerationSchemaTests {
    typealias Spec = ChatCompletionRequest.JSONSchemaSpec

    private func spec(_ schema: JSONValue, name: String = "Root", description: String? = nil) -> Spec {
        Spec(name: name, description: description, schema: schema, strict: nil)
    }

    @Test func buildsObjectSchemaWithRequiredAndOptionalProperties() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("full name")]),
                "age": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("name")]),
        ])
        // Smoke test: must construct without throwing. The resulting schema's internal
        // shape is the framework's contract to honor.
        _ = try buildGenerationSchema(from: spec(schema))
    }

    @Test func buildsStringEnumViaAnyOf() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("string"),
            "enum": .array([.string("red"), .string("green"), .string("blue")]),
        ])
        _ = try buildGenerationSchema(from: spec(schema, name: "Color"))
    }

    @Test func buildsArrayWithBounds() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "minItems": .int(1),
            "maxItems": .int(5),
        ])
        _ = try buildGenerationSchema(from: spec(schema, name: "Tags"))
    }

    @Test func buildsScalarRoots() throws {
        guard #available(macOS 26.0, *) else { return }
        for type in ["string", "integer", "number", "boolean"] {
            let schema: JSONValue = .object(["type": .string(type)])
            _ = try buildGenerationSchema(from: spec(schema, name: "Val_\(type)"))
        }
    }

    @Test func rejectsMissingSchema() throws {
        guard #available(macOS 26.0, *) else { return }
        let s = Spec(name: "X", description: nil, schema: nil, strict: nil)
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: s)
        }
    }

    @Test func rejectsNonObjectSchemaFragment() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .string("not an object")
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: spec(schema))
        }
    }

    @Test func rejectsUnsupportedConstructs() throws {
        guard #available(macOS 26.0, *) else { return }
        for unsupported in ["oneOf", "anyOf", "allOf", "$ref", "pattern", "format"] {
            let schema: JSONValue = .object([
                "type": .string("object"),
                unsupported: .array([]),
            ])
            #expect(throws: Abort.self, "should reject \(unsupported)") {
                try buildGenerationSchema(from: spec(schema, name: "Bad_\(unsupported)"))
            }
        }
    }

    @Test func acceptsAdditionalPropertiesFalse() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
        // Strict-mode OpenAI schemas always include this; it must build cleanly.
        _ = try buildGenerationSchema(from: spec(schema, name: "Strict"))
    }

    @Test func rejectsAdditionalPropertiesTrue() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
        ])
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: spec(schema, name: "Open"))
        }
    }

    @Test func rejectsAdditionalPropertiesAsObject() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .object(["type": .string("string")]),
        ])
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: spec(schema, name: "Typed"))
        }
    }

    @Test func rejectsArrayWithoutItems() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object(["type": .string("array")])
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: spec(schema))
        }
    }

    @Test func rejectsUnknownType() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema: JSONValue = .object(["type": .string("date")])
        #expect(throws: Abort.self) {
            try buildGenerationSchema(from: spec(schema))
        }
    }
}

#endif

// MARK: - Tool calls: request decoding

@Suite struct ToolRequestDecodingTests {
    @Test func decodesToolsToolChoiceAndToolMessages() throws {
        let json = #"""
        {
          "model":"m",
          "messages":[
            {"role":"user","content":"weather?"},
            {"role":"assistant","content":null,"tool_calls":[
              {"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}
            ]},
            {"role":"tool","tool_call_id":"call_1","content":"18C"}
          ],
          "tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather",
            "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
          "tool_choice":"auto"
        }
        """#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.tools?.first?.function.name == "get_weather")
        #expect(req.tool_choice == .string("auto"))
        #expect(req.messages[1].content == nil)
        #expect(req.messages[1].tool_calls?.first?.function.arguments == #"{"city":"Paris"}"#)
        #expect(req.messages[2].tool_call_id == "call_1")
    }

    @Test func responseMessageEncodesNullContentAndToolCalls() throws {
        let msg = ChatCompletionResponse.Choice.Message(
            role: "assistant",
            content: nil,
            tool_calls: [.init(id: "call_1", type: "function", function: .init(name: "f", arguments: "{}"))]
        )
        let data = try JSONEncoder().encode(msg)
        let obj = try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        #expect(obj["content"] == .null)
        #expect(obj["tool_calls"]?.arrayValue?.count == 1)
    }

    @Test func responseMessageOmitsToolCallsWhenAbsent() throws {
        let data = try JSONEncoder().encode(ChatCompletionResponse.Choice.Message(role: "assistant", content: "hi"))
        let obj = try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        #expect(obj["content"] == .string("hi"))
        #expect(obj["tool_calls"] == nil)
    }
}

// MARK: - Tool calls: tool_choice / selection

@Suite struct ToolChoiceTests {
    typealias Def = ChatCompletionRequest.ToolDefinition

    private func tool(_ name: String, type: String = "function") -> Def {
        Def(type: type, function: .init(name: name, description: nil, parameters: nil, strict: nil))
    }

    @Test func parsesAllForms() throws {
        #expect(try parseToolChoice(nil) == .auto)
        #expect(try parseToolChoice(.null) == .auto)
        #expect(try parseToolChoice(.string("auto")) == .auto)
        #expect(try parseToolChoice(.string("none")) == .none)
        #expect(try parseToolChoice(.string("required")) == .required)
        let named: JSONValue = .object([
            "type": .string("function"),
            "function": .object(["name": .string("f")]),
        ])
        #expect(try parseToolChoice(named) == .function("f"))
    }

    @Test func rejectsInvalidChoice() {
        #expect(throws: Abort.self) { try parseToolChoice(.string("sometimes")) }
        #expect(throws: Abort.self) { try parseToolChoice(.object(["type": .string("function")])) }
    }

    @Test func directiveOnlyForForcingChoices() {
        #expect(toolChoiceDirective(.auto) == nil)
        #expect(toolChoiceDirective(.none) == nil)
        #expect(toolChoiceDirective(.required) != nil)
        #expect(toolChoiceDirective(.function("f"))?.contains("'f'") == true)
    }

    @Test func selectToolsAppliesChoice() throws {
        let tools = [tool("a"), tool("b")]
        #expect(try selectTools(tools, choice: .auto).map(\.function.name) == ["a", "b"])
        #expect(try selectTools(tools, choice: .none).isEmpty)
        #expect(try selectTools(tools, choice: .function("b")).map(\.function.name) == ["b"])
    }

    @Test func requiredChoiceWithoutToolsIsRejected() throws {
        #expect(throws: Abort.self) { try selectTools([], choice: .required) }
        #expect(try selectTools([], choice: .auto).isEmpty)
        #expect(try selectTools([], choice: .none).isEmpty)
    }

    @Test func toolPipelineIsUsedForToolHistoryEvenWithoutTools() {
        typealias Message = ChatCompletionRequest.Message
        let plain = [Message(role: "user", content: "hi")]
        #expect(!needsToolPipeline(tools: [], messages: plain))
        #expect(needsToolPipeline(tools: [tool("a")], messages: plain))
        #expect(needsToolPipeline(tools: [], messages: plain + [Message(role: "tool", content: "r", tool_call_id: "c1")]))
        #expect(needsToolPipeline(tools: [], messages: [Message(role: "assistant", content: nil, tool_calls: [
            .init(id: "c1", type: "function", function: .init(name: "f", arguments: "{}")),
        ])]))
        #expect(!needsToolPipeline(tools: [], messages: [Message(role: "assistant", content: "x", tool_calls: [])]))
    }

    @Test func selectToolsRejectsBadDefinitions() {
        #expect(throws: Abort.self) { try selectTools([tool("a"), tool("a")], choice: .auto) }
        #expect(throws: Abort.self) { try selectTools([tool("a", type: "retrieval")], choice: .auto) }
        #expect(throws: Abort.self) { try selectTools([tool("")], choice: .auto) }
        #expect(throws: Abort.self) { try selectTools([tool("a")], choice: .function("zzz")) }
    }
}

// MARK: - Tool calls: conversation split & replay

@Suite struct ToolConversationTests {
    typealias Message = ChatCompletionRequest.Message
    typealias Call = ChatCompletionRequest.ToolCall

    private func call(_ id: String, _ name: String, _ args: String) -> Call {
        Call(id: id, type: "function", function: .init(name: name, arguments: args))
    }

    @Test func plainConversationHasNoPendingResults() throws {
        let conv = try splitToolConversation([
            Message(role: "system", content: "sys"),
            Message(role: "user", content: "hi"),
            Message(role: "assistant", content: "hello"),
            Message(role: "user", content: "again"),
        ])
        #expect(conv.prompt == "again")
        #expect(conv.history.count == 3)
        #expect(conv.pendingResults.isEmpty)
    }

    @Test func trailingToolRoundTripsBecomePendingResults() throws {
        let conv = try splitToolConversation([
            Message(role: "user", content: "weather in Paris and Rome?"),
            Message(role: "assistant", content: nil, tool_calls: [
                call("c1", "get_weather", #"{"city":"Paris"}"#),
                call("c2", "get_weather", #"{"city":"Rome"}"#),
            ]),
            Message(role: "tool", content: "18C", tool_call_id: "c1"),
            Message(role: "tool", content: "25C", tool_call_id: "c2"),
        ])
        #expect(conv.prompt == "weather in Paris and Rome?")
        #expect(conv.history.isEmpty)
        #expect(conv.pendingResults == [
            .init(id: "c1", name: "get_weather", arguments: #"{"city":"Paris"}"#, output: "18C"),
            .init(id: "c2", name: "get_weather", arguments: #"{"city":"Rome"}"#, output: "25C"),
        ])
    }

    @Test func toolRoundTripsBeforeLastUserStayInHistory() throws {
        let conv = try splitToolConversation([
            Message(role: "user", content: "q1"),
            Message(role: "assistant", content: nil, tool_calls: [call("c1", "f", "{}")]),
            Message(role: "tool", content: "r1", tool_call_id: "c1"),
            Message(role: "assistant", content: "a1"),
            Message(role: "user", content: "q2"),
        ])
        #expect(conv.prompt == "q2")
        #expect(conv.history.count == 4)
        #expect(conv.pendingResults.isEmpty)
    }

    @Test func rejectsMissingUserAndDanglingToolResults() {
        #expect(throws: Abort.self) {
            try splitToolConversation([Message(role: "system", content: "s")])
        }
        #expect(throws: Abort.self) {
            try splitToolConversation([
                Message(role: "user", content: "q"),
                Message(role: "tool", content: "r", tool_call_id: "nope"),
            ])
        }
        #expect(throws: Abort.self) {
            try splitToolConversation([
                Message(role: "user", content: "q"),
                Message(role: "tool", content: "r"),
            ])
        }
    }

    @Test func appendToolResultsRendersEachResult() {
        #expect(appendToolResultsToPrompt("q", results: []) == "q")
        let out = appendToolResultsToPrompt("q", results: [
            .init(id: "c1", name: "f", arguments: #"{"x":1}"#, output: "ok"),
        ])
        #expect(out == "q\n\nTool results:\n- f({\"x\":1}): ok")
    }
}

@Suite struct ToolReplayCacheTests {
    @Test func exactArgumentMatchIsOrderInsensitiveAndReusable() {
        let cache = ToolReplayCache([
            .init(id: "c1", name: "f", arguments: #"{"a":1,"b":2}"#, output: "r1"),
        ])
        #expect(cache.result(name: "f", arguments: #"{"b":2,"a":1}"#) == "r1")
        #expect(cache.result(name: "f", arguments: #"{"a":1,"b":2}"#) == "r1")
    }

    @Test func matchesNormalizedArguments() {
        let cache = ToolReplayCache([
            .init(id: "c1", name: "f", arguments: #"{"city":"Paris"}"#, output: "r1"),
            .init(id: "c2", name: "f", arguments: #"{"city":"New  York","n":2.0}"#, output: "r2"),
        ])
        #expect(cache.result(name: "f", arguments: #"{"city":" paris "}"#) == "r1")
        #expect(cache.result(name: "f", arguments: #"{"n":2,"city":"new york"}"#) == "r2")
    }

    @Test func neverHandsOneCallsResultToADifferentCall() {
        // Regression: a name-only fallback used to return Paris's result for London.
        let cache = ToolReplayCache([
            .init(id: "c1", name: "get_weather", arguments: #"{"city":"Paris"}"#, output: "Sunny 31C"),
        ])
        #expect(cache.result(name: "get_weather", arguments: #"{"city":"London"}"#) == nil)
        #expect(cache.result(name: "get_weather", arguments: #"{"city":"Paris"}"#) == "Sunny 31C")
    }

    @Test func nonJSONArgumentsMatchOnlyVerbatim() {
        let cache = ToolReplayCache([.init(id: "c1", name: "f", arguments: "raw", output: "r")])
        #expect(cache.result(name: "f", arguments: "raw") == "r")
        #expect(cache.result(name: "f", arguments: "RAW") == nil)
    }

    @Test func unknownToolMisses() {
        let cache = ToolReplayCache([.init(id: "c1", name: "f", arguments: "{}", output: "r")])
        #expect(cache.result(name: "g", arguments: "{}") == nil)
    }

    @Test func recorderKeepsInvocationsInOrder() {
        let recorder = ToolInvocationRecorder()
        recorder.record(name: "a", arguments: "{}")
        recorder.record(name: "b", arguments: #"{"x":1}"#)
        #expect(recorder.invocations == [.init(name: "a", arguments: "{}"), .init(name: "b", arguments: #"{"x":1}"#)])
    }
}

// MARK: - Streaming

@Suite struct StreamingTests {
    private let factory = ChunkFactory(id: "chatcmpl-1", created: 42, model: "m")

    private func decode(_ chunk: ChatCompletionChunk) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(chunk)
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    @Test func deltaIsSuffixWhenSnapshotExtendsPrevious() {
        #expect(streamDelta(previous: "", current: "Hello") == "Hello")
        #expect(streamDelta(previous: "Hello", current: "Hello, world") == ", world")
        #expect(streamDelta(previous: "Hello", current: "Hello") == "")
    }

    @Test func deltaFallsBackToCommonPrefixOnDivergence() {
        #expect(streamDelta(previous: "Hello wor", current: "Hello there") == "there")
    }

    @Test func deltaHandlesMultiByteCharacters() {
        #expect(streamDelta(previous: "Привет", current: "Привет, мир 👋") == ", мир 👋")
    }

    /// Replays a snapshot sequence the way a client would: by concatenating deltas.
    private func streamed(_ snapshots: [String]) -> String {
        var previous = ""
        var out = ""
        for snap in snapshots {
            out += streamDelta(previous: previous, current: snap)
            previous = snap
        }
        return out
    }

    @Test func snapshotsSplitMidGraphemeDoNotDuplicate() {
        // Regression: Character-based diffing re-sent the base of a grapheme completed by
        // the next snapshot ("cafee\u{301}!", "🇺🇺🇸").
        #expect(streamed(["cafe", "cafe\u{301}", "cafe\u{301}!"]).unicodeScalars.elementsEqual("cafe\u{301}!".unicodeScalars))
        #expect(streamed(["🇺", "🇺🇸"]).unicodeScalars.elementsEqual("🇺🇸".unicodeScalars))
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(streamed(["👨", "👨\u{200D}", family]).unicodeScalars.elementsEqual(family.unicodeScalars))
    }

    @Test func requestDecodesStreamFields() throws {
        let json = #"{"messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{"include_usage":true}}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.stream == true)
        #expect(req.stream_options?.include_usage == true)
    }

    @Test func sseEventFraming() throws {
        let event = try sseEvent(factory.content("hi"))
        #expect(event.hasPrefix("data: {"))
        #expect(event.hasSuffix("}\n\n"))
        #expect(sseDone == "data: [DONE]\n\n")
    }

    @Test func contentChunkKeepsNullFinishReasonAndOmitsUnsetDeltaFields() throws {
        let obj = try decode(factory.content("hi"))
        #expect(obj["object"] == .string("chat.completion.chunk"))
        #expect(obj["id"] == .string("chatcmpl-1"))
        #expect(obj["usage"] == nil)
        let choice = try #require(obj["choices"]?.arrayValue?.first?.objectValue)
        #expect(choice["finish_reason"] == .null)
        #expect(choice["delta"] == .object(["content": .string("hi")]))
    }

    @Test func roleAndFinishChunks() throws {
        let role = try #require(try decode(factory.role())["choices"]?.arrayValue?.first?.objectValue)
        #expect(role["delta"] == .object(["role": .string("assistant"), "content": .string("")]))
        let finish = try #require(try decode(factory.finish("stop"))["choices"]?.arrayValue?.first?.objectValue)
        #expect(finish["delta"] == .object([:]))
        #expect(finish["finish_reason"] == .string("stop"))
    }

    @Test func toolCallsChunkIndexesEachCall() throws {
        let chunk = factory.toolCalls([.init(name: "a", arguments: "{}"), .init(name: "b", arguments: #"{"x":1}"#)])
        let calls = try #require(chunk.choices.first?.delta.tool_calls)
        #expect(calls.map(\.index) == [0, 1])
        #expect(calls.map(\.function.name) == ["a", "b"])
        #expect(calls.allSatisfy { $0.type == "function" && $0.id.hasPrefix("call_") })
    }

    @Test func usageChunkHasEmptyChoices() throws {
        let obj = try decode(factory.usage())
        #expect(obj["choices"] == .array([]))
        #expect(obj["usage"]?.objectValue?["total_tokens"] == .int(0))
    }
}

#if canImport(FoundationModels)

@Suite struct ToolBridgeTests {
    typealias Def = ChatCompletionRequest.ToolDefinition
    typealias Message = ChatCompletionRequest.Message

    private let weather = Def(type: "function", function: .init(
        name: "get_weather",
        description: "Get weather",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]),
            "additionalProperties": .bool(false),
        ]),
        strict: true
    ))

    @Test func buildsProxyToolsIncludingParameterlessTools() throws {
        guard #available(macOS 26.0, *) else { return }
        let noParams = Def(type: "function", function: .init(name: "now", description: nil, parameters: nil, strict: nil))
        let tools = try buildProxyTools(
            [weather, noParams],
            replay: ToolReplayCache([]),
            recorder: ToolInvocationRecorder()
        )
        #expect(tools.map(\.name) == ["get_weather", "now"])
        #expect(tools[0].description == "Get weather")
    }

    @Test func rejectsUnsupportedParameterSchema() throws {
        guard #available(macOS 26.0, *) else { return }
        let bad = Def(type: "function", function: .init(
            name: "f", description: nil,
            parameters: .object(["type": .string("object"), "oneOf": .array([])]),
            strict: nil
        ))
        #expect(throws: Abort.self) {
            try buildProxyTools([bad], replay: ToolReplayCache([]), recorder: ToolInvocationRecorder())
        }
    }

    @Test func proxyToolReplaysCachedResultOrRecordsAndThrows() async throws {
        guard #available(macOS 26.0, *) else { return }
        let recorder = ToolInvocationRecorder()
        let replay = ToolReplayCache([.init(id: "c1", name: "get_weather", arguments: #"{"city":"Paris"}"#, output: "18C")])
        let tool = try #require(try buildProxyTools([weather], replay: replay, recorder: recorder).first)

        let cached = try await tool.call(arguments: GeneratedContent(json: #"{"city":"Paris"}"#))
        #expect(cached == "18C")
        #expect(recorder.invocations.isEmpty)

        await #expect(throws: ProxyToolInvocation.self) {
            _ = try await tool.call(arguments: GeneratedContent(json: #"{"city":"Rome"}"#))
        }
        #expect(recorder.invocations.map(\.name) == ["get_weather"])
        #expect(parseJSONValue(recorder.invocations[0].arguments) == .object(["city": .string("Rome")]))
    }

    @Test func transcriptContainsNativeToolEntries() throws {
        guard #available(macOS 26.0, *) else { return }
        let tools = try buildProxyTools([weather], replay: ToolReplayCache([]), recorder: ToolInvocationRecorder())
        let transcript = try buildTranscript(instructions: "be brief", tools: tools, history: [
            Message(role: "system", content: "be brief"),
            Message(role: "user", content: "weather?"),
            Message(role: "assistant", content: nil, tool_calls: [
                .init(id: "c1", type: "function", function: .init(name: "get_weather", arguments: #"{"city":"Paris"}"#)),
            ]),
            Message(role: "tool", content: "18C", tool_call_id: "c1"),
            Message(role: "assistant", content: "It's 18C."),
        ])
        let kinds: [String] = transcript.map { entry in
            switch entry {
            case .instructions(let i): return "instructions(\(i.toolDefinitions.count))"
            case .prompt: return "prompt"
            case .toolCalls(let c): return "toolCalls(\(c.count))"
            case .toolOutput(let o): return "toolOutput(\(o.toolName))"
            case .response: return "response"
            @unknown default: return "unknown"
            }
        }
        #expect(kinds == ["instructions(1)", "prompt", "toolCalls(1)", "toolOutput(get_weather)", "response"])
    }

    @Test func transcriptRejectsInvalidToolCallArguments() throws {
        guard #available(macOS 26.0, *) else { return }
        #expect(throws: Abort.self) {
            try buildTranscript(instructions: nil, tools: [], history: [
                Message(role: "assistant", content: nil, tool_calls: [
                    .init(id: "c1", type: "function", function: .init(name: "f", arguments: "not json")),
                ]),
            ])
        }
    }
}

#endif
