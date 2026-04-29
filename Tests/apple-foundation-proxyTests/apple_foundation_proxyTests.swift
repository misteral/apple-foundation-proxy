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
