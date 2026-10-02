import XCTest
@testable import SpotlessMac

final class LLMClientFactoryTests: XCTestCase {
    func testCloudWithoutKeyThrows() {
        XCTAssertThrowsError(try LLMClientFactory.make(settings: AssistantSettings(), apiKey: " ")) { error in
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
    }

    func testLocalOllamaDropsKey() throws {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        let client = try XCTUnwrap(try LLMClientFactory.make(settings: settings, apiKey: "leftover") as? OllamaClient)
        XCTAssertEqual(client.apiKey, "")
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(client.timeout, 120)
    }

    func testOpenAICompatibleStripsV1Suffix() throws {
        var settings = AssistantSettings()
        settings.switchProvider(to: .openAICompatible)
        settings.baseURL = "http://localhost:1234/v1/"
        let client = try XCTUnwrap(try LLMClientFactory.make(settings: settings, apiKey: "") as? OpenAICompatibleClient)
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:1234")
    }

    func testOllamaStripsApiSuffix() {
        XCTAssertEqual(LLMClientFactory.normalizedBaseURL("https://ollama.com/api", provider: .ollamaCloud)?.absoluteString, "https://ollama.com")
    }

    func testInvalidURLThrows() {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        for bad in ["", "not a url", "ftp://host"] {
            settings.baseURL = bad
            XCTAssertThrowsError(try LLMClientFactory.make(settings: settings, apiKey: "")) { error in
                XCTAssertEqual(error as? LLMError, .invalidURL, bad)
            }
        }
    }

    func testTesterReportsToolSupport() async {
        let client = FakeLLMClient([.events([.text("готово"), .done])])
        let result = await AssistantConnectionTester.check(client: client, model: "gpt-oss:20b")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.toolsSupported, true)
        XCTAssertTrue(result.message.contains("gpt-oss:20b"))
        XCTAssertFalse(client.requests[0].tools.isEmpty)
    }

    func testTesterFallsBackWhenToolsUnsupported() async {
        let client = FakeLLMClient([.failure(LLMError.toolsUnsupported), .events([.text("ok"), .done])])
        let result = await AssistantConnectionTester.check(client: client, model: "gemma:2b")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.toolsSupported, false)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[1].tools.isEmpty)
    }

    func testTesterReportsFailure() async {
        let client = FakeLLMClient([.failure(LLMError.unauthorized)])
        let result = await AssistantConnectionTester.check(client: client, model: "m")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, LLMError.unauthorized.userMessage)
        XCTAssertNil(result.toolsSupported)
    }
}
