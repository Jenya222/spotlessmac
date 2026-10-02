import XCTest
@testable import SpotlessMac

final class OllamaClientTests: XCTestCase {
    private let cloud = URL(string: "https://ollama.com")!
    private let tool = ToolSpec(name: "list_items", description: "d", parametersJSON: #"{"type":"object","properties":{}}"#)

    private func request(tools: [ToolSpec] = []) -> ChatRequest {
        ChatRequest(model: "gpt-oss:20b", messages: [WireMessage(role: .system, content: "sys"), WireMessage(role: .user, content: "hi")], tools: tools)
    }

    func testChatRequestBodyAndHeaders() async throws {
        let transport = FakeTransport([.init(lines: [#"{"message":{"role":"assistant","content":"ok"},"done":true}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "secret", timeout: 90, transport: transport)
        _ = try await collectEvents(client.stream(request(tools: [tool])))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://ollama.com/api/chat")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 90)
        let body = jsonBody(sent)
        XCTAssertEqual(body["model"] as? String, "gpt-oss:20b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }, ["system", "user"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "list_items")
    }

    func testNoAuthorizationAndNoToolsWhenEmpty() async throws {
        let transport = FakeTransport([.init(lines: [#"{"done":true}"#])])
        let client = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, apiKey: "", timeout: 30, transport: transport)
        _ = try await collectEvents(client.stream(request()))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(jsonBody(sent)["tools"])
    }

    func testToolMessagesAreEncoded() throws {
        let client = OllamaClient(baseURL: cloud, apiKey: "", timeout: 30, transport: FakeTransport([]))
        let call = ToolCall(id: "call_1", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)
        let req = ChatRequest(model: "m", messages: [
            WireMessage(role: .assistant, content: "", toolCalls: [call]),
            WireMessage(role: .tool, content: "result", toolCallID: "call_1", toolName: "list_items"),
        ])
        let messages = try XCTUnwrap(jsonBody(client.makeChatRequest(req))["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "list_items")
        XCTAssertEqual((function["arguments"] as? [String: Any])?["category"] as? String, "logs")
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_name"] as? String, "list_items")
    }

    func testParsesTextToolCallsAndDone() async throws {
        let transport = FakeTransport([.init(lines: [
            #"{"message":{"role":"assistant","content":"При"},"done":false}"#,
            "",
            #"{"message":{"role":"assistant","content":"вет"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_items","arguments":{"category":"logs"}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true}"#,
        ])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        let events = try await collectEvents(client.stream(request()))
        XCTAssertEqual(events, [
            .text("При"), .text("вет"),
            .toolCalls([ToolCall(id: "call_1", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)]),
            .done,
        ])
    }

    func testToolsUnsupportedStatus() async {
        let transport = FakeTransport([.init(status: 400, lines: [#"{"error":"registry.ollama.ai/library/gemma:2b does not support tools"}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request(tools: [tool])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .toolsUnsupported)
        }
    }

    func testErrorLineInsideStream() async {
        let transport = FakeTransport([.init(lines: [#"{"error":"model 'nope' not found"}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request()))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .modelNotFound)
        }
    }

    // Review focus 5: 200 response that ends without "done".
    func testStreamWithoutDoneIsInterrupted() async {
        let transport = FakeTransport([.init(lines: [#"{"message":{"content":"Частичный"},"done":false}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        var received: [ChatEvent] = []
        do {
            for try await event in client.stream(request()) { received.append(event) }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(received, [.text("Частичный")])
            XCTAssertEqual(error as? LLMError, .streamInterrupted)
        }
    }

    func testConnectionRefused() async {
        let transport = FakeTransport([.init(error: URLError(.cannotConnectToHost))])
        let client = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, apiKey: "", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request()))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .connectionRefused(host: "localhost:11434"))
        }
    }

    func testListModels() async throws {
        let transport = FakeTransport([.init(lines: [#"{"models":[{"name":"qwen3:8b"},{"name":"gpt-oss:20b"}]}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        let models = try await client.listModels()
        XCTAssertEqual(models, ["gpt-oss:20b", "qwen3:8b"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://ollama.com/api/tags")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }
}
