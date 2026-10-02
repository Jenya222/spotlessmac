import XCTest
@testable import SpotlessMac

final class LLMErrorTests: XCTestCase {
    func testHTTPStatusMapping() {
        XCTAssertEqual(LLMError.fromHTTP(status: 401, body: ""), .unauthorized)
        XCTAssertEqual(LLMError.fromHTTP(status: 403, body: ""), .unauthorized)
        XCTAssertEqual(LLMError.fromHTTP(status: 404, body: ""), .modelNotFound)
        XCTAssertEqual(LLMError.fromHTTP(status: 429, body: ""), .rateLimited)
        XCTAssertEqual(LLMError.fromHTTP(status: 500, body: "boom"), .httpStatus(code: 500, body: "boom"))
    }

    func testToolsUnsupportedDetectedFromBody() {
        XCTAssertEqual(LLMError.fromHTTP(status: 400, body: #"{"error":"registry.ollama.ai/library/gemma:2b does not support tools"}"#), .toolsUnsupported)
        XCTAssertEqual(LLMError.fromHTTP(status: 400, body: #"{"error":{"message":"This model does not support tools"}}"#), .toolsUnsupported)
    }

    func testModelNotFoundDetectedFromBody() {
        XCTAssertEqual(LLMError.fromHTTP(status: 500, body: "model 'nope' not found"), .modelNotFound)
    }

    func testBodyIsTruncated() {
        let long = String(repeating: "x", count: 1_000)
        guard case .httpStatus(_, let body) = LLMError.fromHTTP(status: 502, body: long) else { return XCTFail() }
        XCTAssertEqual(body.count, 240)
    }

    func testExtractMessageHandlesBothShapes() {
        XCTAssertEqual(LLMError.extractMessage(from: #"{"error":"plain"}"#), "plain")
        XCTAssertEqual(LLMError.extractMessage(from: #"{"error":{"message":"nested"}}"#), "nested")
        XCTAssertEqual(LLMError.extractMessage(from: "not json"), "not json")
    }

    func testTransportMapping() {
        XCTAssertEqual(LLMError.mapTransport(URLError(.cannotConnectToHost), host: "localhost:11434", timeout: 60) as? LLMError, .connectionRefused(host: "localhost:11434"))
        XCTAssertEqual(LLMError.mapTransport(URLError(.timedOut), host: "h", timeout: 60) as? LLMError, .timedOut(seconds: 60))
        XCTAssertTrue(LLMError.mapTransport(URLError(.cancelled), host: "h", timeout: 60) is CancellationError)
        XCTAssertEqual(LLMError.mapTransport(LLMError.rateLimited, host: "h", timeout: 1) as? LLMError, .rateLimited)
    }

    func testUserMessagesAndSettingsHint() {
        XCTAssertTrue(LLMError.unauthorized.userMessage.contains("Неверный токен"))
        XCTAssertTrue(LLMError.connectionRefused(host: "localhost:11434").userMessage.contains("ollama serve"))
        XCTAssertTrue(LLMError.timedOut(seconds: 30).userMessage.contains("30"))
        XCTAssertTrue(LLMError.unauthorized.opensSettings)
        XCTAssertTrue(LLMError.missingAPIKey.opensSettings)
        XCTAssertFalse(LLMError.rateLimited.opensSettings)
    }

    func testHostLabel() {
        XCTAssertEqual(URL(string: "http://localhost:11434")!.hostLabel, "localhost:11434")
        XCTAssertEqual(URL(string: "https://ollama.com")!.hostLabel, "ollama.com")
    }
}
