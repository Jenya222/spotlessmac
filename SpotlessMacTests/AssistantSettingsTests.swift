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

    // Final review, item 2: a saved token is only ever offered to the provider and host it was saved for.
    func testSavedTokenBelongsToSavedProviderAndHostOnly() {
        var saved = AssistantSettings()
        saved.switchProvider(to: .openAICompatible)
        saved.baseURL = "https://api.openai.com"
        var edited = saved
        XCTAssertTrue(edited.sharesTokenEndpoint(with: saved))
        edited.baseURL = "https://API.OpenAI.com/v1"
        XCTAssertTrue(edited.sharesTokenEndpoint(with: saved), "host comparison ignores case, path and scheme details")
        edited.baseURL = "https://evil.example.com"
        XCTAssertFalse(edited.sharesTokenEndpoint(with: saved))
        edited.baseURL = "https://api.openai.com.evil.example"
        XCTAssertFalse(edited.sharesTokenEndpoint(with: saved))
        edited.baseURL = "https://api.openai.com"
        XCTAssertTrue(edited.sharesTokenEndpoint(with: saved), "going back to the saved host restores the match")
        edited.switchProvider(to: .ollamaCloud)
        XCTAssertFalse(edited.sharesTokenEndpoint(with: saved), "another provider never shares the token")
    }

    func testSavedTokenDoesNotFollowSameProviderDefaultAddressWhenSavedHostWasCustom() {
        var saved = AssistantSettings()
        saved.switchProvider(to: .openAICompatible)
        saved.baseURL = "https://llm.internal.example"
        var edited = saved
        edited.switchProvider(to: .openAICompatible)
        XCTAssertFalse(edited.sharesTokenEndpoint(with: saved))
    }

    func testUnparsableAddressesShareTheTokenOnlyWhenIdentical() {
        var saved = AssistantSettings()
        saved.baseURL = "not a url"
        var edited = saved
        XCTAssertTrue(edited.sharesTokenEndpoint(with: saved))
        edited.baseURL = "not a url either"
        XCTAssertFalse(edited.sharesTokenEndpoint(with: saved))
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
        settings.baseURL = "http://[::1]:1234"
        XCTAssertFalse(settings.sendsDataOffDevice)
        // Local Ollama pointed at a LAN/remote host still leaves this Mac.
        settings.switchProvider(to: .ollamaLocal)
        settings.baseURL = "http://192.168.1.10:11434"
        XCTAssertTrue(settings.sendsDataOffDevice)
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
