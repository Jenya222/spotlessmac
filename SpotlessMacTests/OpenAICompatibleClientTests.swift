import XCTest
@testable import SpotlessMac

final class OpenAICompatibleClientTests: XCTestCase {
    private let base = URL(string: "https://api.openai.com")!

    private func client(_ transport: FakeTransport, key: String = "sk") -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: base, apiKey: key, timeout: 45, transport: transport)
    }

    func testRequestShape() throws {
        let call = ToolCall(id: "call_a", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)
        let req = ChatRequest(model: "gpt-4o-mini", messages: [
            WireMessage(role: .user, content: "hi"),
            WireMessage(role: .assistant, content: "", toolCalls: [call]),
            WireMessage(role: .tool, content: "r", toolCallID: "call_a", toolName: "list_items"),
        ], tools: [ToolSpec(name: "list_items", description: "d", parametersJSON: #"{"type":"object"}"#)])
        let sent = try client(FakeTransport([])).makeChatRequest(req)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk")
        XCTAssertEqual(sent.timeoutInterval, 45)
        let body = jsonBody(sent)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_a")
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"category":"logs"}"#)
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_a")
        XCTAssertNotNil(body["tools"])
    }

    func testNoAuthorizationWithoutKey() throws {
        let sent = try client(FakeTransport([]), key: "").makeChatRequest(ChatRequest(model: "m", messages: []))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testParsesSSEText() async throws {
        let transport = FakeTransport([.init(lines: [
            #"data: {"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#,
            ": keep-alive",
            #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])])
        let events = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
        XCTAssertEqual(events, [.text("Hel"), .text("lo"), .done])
    }

    func testAccumulatesChunkedToolCalls() async throws {
        let transport = FakeTransport([.init(lines: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"list_items","arguments":"{\"cate"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"gory\":\"logs\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])])
        let events = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
        XCTAssertEqual(events, [
            .toolCalls([ToolCall(id: "call_a", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)]),
            .done,
        ])
    }

    func testToolsUnsupported() async {
        let transport = FakeTransport([.init(status: 400, lines: [#"{"error":{"message":"This model does not support tools"}}"#])])
        do {
            _ = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .toolsUnsupported)
        }
    }

    func testStreamWithoutDoneIsInterrupted() async {
        let transport = FakeTransport([.init(lines: [#"data: {"choices":[{"delta":{"content":"x"}}]}"#])])
        do {
            _ = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .streamInterrupted)
        }
    }

    func testListModels() async throws {
        let transport = FakeTransport([.init(lines: [#"{"data":[{"id":"b"},{"id":"a"}]}"#])])
        let models = try await client(transport).listModels()
        XCTAssertEqual(models, ["a", "b"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.openai.com/v1/models")
    }
}
