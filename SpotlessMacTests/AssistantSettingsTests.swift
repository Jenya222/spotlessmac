import XCTest
@testable import SpotlessMac

@MainActor
final class AssistantSettingsTests: XCTestCase {
    func testDefaultsAreOllamaCloudWithGptOss() {
        let settings = AssistantSettings()
        XCTAssertEqual(settings.provider, .ollamaCloud)
        XCTAssertEqual(settings.baseURL, "https://ollama.com")
        XCTAssertEqual(settings.model, "gpt-oss:20b")
        XCTAssertEqual(settings.toolMode, .auto)
        XCTAssertEqual(settings.timeoutSeconds, 120)
    }

    func testSwitchProviderAppliesPresets() {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        XCTAssertEqual(settings.baseURL, "http://localhost:11434")
        XCTAssertEqual(settings.model, "gpt-oss:20b")
        settings.switchProvider(to: .openAICompatible)
        XCTAssertEqual(settings.baseURL, "https://api.openai.com")
        XCTAssertEqual(settings.model, "")
    }

    func testSendsDataOffDevice() {
        var settings = AssistantSettings()
        XCTAssertTrue(settings.sendsDataOffDevice)
        settings.switchProvider(to: .ollamaLocal)
        XCTAssertFalse(settings.sendsDataOffDevice)
        settings.switchProvider(to: .openAICompatible)
        XCTAssertTrue(settings.sendsDataOffDevice)
        settings.baseURL = "http://localhost:1234"
        XCTAssertFalse(settings.sendsDataOffDevice)
        settings.baseURL = "http://127.0.0.1:1234"
        XCTAssertFalse(settings.sendsDataOffDevice)
    }

    func testKeyRequirements() {
        XCTAssertTrue(AssistantProvider.ollamaCloud.requiresAPIKey)
        XCTAssertFalse(AssistantProvider.ollamaLocal.usesAPIKey)
        XCTAssertTrue(AssistantProvider.openAICompatible.usesAPIKey)
        XCTAssertFalse(AssistantProvider.openAICompatible.requiresAPIKey)
    }

    func testStoreRoundTripAndClampsTimeout() {
        let store = AssistantSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), AssistantSettings())
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        settings.model = "qwen3:8b"
        settings.timeoutSeconds = 9_999
        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.provider, .ollamaLocal)
        XCTAssertEqual(loaded.model, "qwen3:8b")
        XCTAssertEqual(loaded.timeoutSeconds, 300)
    }

    func testToolSupportCacheAndDisclosureFlag() {
        let store = AssistantSettingsStore(defaults: makeDefaults())
        let key = AssistantSettings().toolSupportKey
        XCTAssertNil(store.toolSupport(for: key))
        store.setToolSupport(false, for: key)
        XCTAssertEqual(store.toolSupport(for: key), false)
        XCTAssertFalse(store.cloudDisclosureAccepted)
        store.cloudDisclosureAccepted = true
        XCTAssertTrue(store.cloudDisclosureAccepted)
    }

    func testFakeKeyStoreTrims() {
        let keys = FakeKeyStore()
        keys.writeKey("  abc \n")
        XCTAssertEqual(keys.readKey(), "abc")
    }
}
