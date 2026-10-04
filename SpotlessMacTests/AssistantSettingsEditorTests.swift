import XCTest
import SwiftUI
@testable import SpotlessMac

@MainActor
final class AssistantSettingsEditorTests: XCTestCase {
    private let success = ConnectionCheckResult(ok: true, message: "A checked", toolsSupported: true)

    func testUnsavedKeyDoesNotFollowAnotherHost() async {
        let saved = settings(host: "a.example")
        var checkedKey: String?
        var modelsKey: String?
        var savedKey: String?
        let editor = AssistantSettingsEditor(
            loadSettings: { saved }, loadAPIKey: { "key-A" },
            fetchModels: { _, key in modelsKey = key; return ["model-C"] },
            checkConnection: { _, key in checkedKey = key; return self.success },
            saveSettings: { _, key in savedKey = key }
        )
        editor.updateSettings(settings(host: "b.example"))
        editor.updateAPIKey("key-B")
        editor.updateSettings(settings(host: "c.example"))
        await editor.check()
        await editor.loadModels()
        editor.save()
        XCTAssertEqual(checkedKey, "")
        XCTAssertEqual(modelsKey, "")
        XCTAssertEqual(savedKey, "")
        editor.updateSettings(saved)
        XCTAssertEqual(editor.apiKey, "key-A")
    }

    func testURLFieldBindingClearsUnsavedCredentialBeforeSave() {
        let saved = settings(host: "a.example")
        var persistedKey: String?
        let editor = AssistantSettingsEditor(
            loadSettings: { saved }, loadAPIKey: { "key-A" },
            fetchModels: { _, _ in [] },
            checkConnection: { _, _ in self.success },
            saveSettings: { _, key in persistedKey = key }
        )
        @Bindable var bound = editor
        $bound.settings.baseURL.wrappedValue = "https://b.example"
        $bound.key.wrappedValue = "key-B"
        $bound.settings.baseURL.wrappedValue = "https://c.example"
        XCTAssertEqual(editor.apiKey, "", "the URL field clears credentials synchronously, before Save")
        editor.save()
        XCTAssertEqual(persistedKey, "")
        $bound.settings.baseURL.wrappedValue = "https://a.example"
        XCTAssertEqual(editor.apiKey, "key-A")
    }

    func testEndpointIdentityNormalizesHostAndFallsBackToTrimmedAddress() {
        let saved = settings(host: "a.example")
        let editor = makeEditor(saved: saved)
        editor.updateAPIKey("edited-key")
        var edited = saved
        edited.baseURL = " HTTP://A.EXAMPLE:8080/v1 \n"
        editor.updateSettings(edited)
        XCTAssertEqual(editor.apiKey, "edited-key")
        edited.provider = .ollamaCloud
        editor.updateSettings(edited)
        XCTAssertEqual(editor.apiKey, "")
        edited.baseURL = "not a url"
        editor.updateSettings(edited)
        editor.updateAPIKey("invalid-address-key")
        edited.baseURL = "  not a url \n"
        editor.updateSettings(edited)
        XCTAssertEqual(editor.apiKey, "invalid-address-key")
        edited.baseURL = "another invalid url"
        editor.updateSettings(edited)
        XCTAssertEqual(editor.apiKey, "")
    }

    func testEditedDraftIgnoresLateProbeResult() async {
        let probe = DeferredSettingsProbe()
        let editor = makeEditor(probe: probe)
        let modelsTask = Task { await editor.loadModels() }
        await probe.waitForModels(1)
        let checkTask = Task { await editor.check() }
        await probe.waitForChecks(1)
        var edited = settings(host: "b.example")
        edited.provider = .ollamaLocal
        edited.model = "model-B"
        editor.updateSettings(edited)
        probe.finishModels(0, with: ["model-A"])
        probe.finishCheck(0, with: success)
        await modelsTask.value
        await checkTask.value
        XCTAssertEqual(editor.draft, edited)
        XCTAssertTrue(editor.models.isEmpty)
        XCTAssertNil(editor.status)
        XCTAssertFalse(editor.isChecking)
        XCTAssertFalse(editor.isLoadingModels)
        XCTAssertEqual(probe.modelRequests[0].settings.baseURL, "https://a.example")
        XCTAssertEqual(probe.checkRequests[0].key, "key-A")
    }

    func testLatestModelRequestWinsInBothResponseOrders() async {
        for newestFirst in [false, true] {
            let probe = DeferredSettingsProbe()
            let editor = makeEditor(probe: probe)
            let first = Task { await editor.loadModels() }
            await probe.waitForModels(1)
            let second = Task { await editor.loadModels() }
            await probe.waitForModels(2)
            if newestFirst {
                probe.finishModels(1, with: ["new-model"])
                await second.value
                probe.finishModels(0, with: ["old-model"])
                await first.value
            } else {
                probe.finishModels(0, with: ["old-model"])
                await first.value
                XCTAssertTrue(editor.isLoadingModels, "old completion must not stop the current spinner")
                XCTAssertTrue(editor.models.isEmpty)
                probe.finishModels(1, with: ["new-model"])
                await second.value
            }
            XCTAssertEqual(editor.models, ["new-model"])
            XCTAssertFalse(editor.isLoadingModels)
        }
    }

    func testLatestCheckWinsInBothResponseOrders() async {
        for newestFirst in [false, true] {
            let probe = DeferredSettingsProbe()
            let editor = makeEditor(probe: probe)
            let first = Task { await editor.check() }
            await probe.waitForChecks(1)
            let second = Task { await editor.check() }
            await probe.waitForChecks(2)
            let newest = ConnectionCheckResult(ok: false, message: "new check", toolsSupported: false)
            if newestFirst {
                probe.finishCheck(1, with: newest)
                await second.value
                probe.finishCheck(0, with: success)
                await first.value
            } else {
                probe.finishCheck(0, with: success)
                await first.value
                XCTAssertTrue(editor.isChecking)
                XCTAssertNil(editor.status)
                probe.finishCheck(1, with: newest)
                await second.value
            }
            XCTAssertEqual(editor.status, newest)
            XCTAssertFalse(editor.isChecking)
        }
    }

    func testResetInvalidatesInFlightResultsEvenForSameDraft() async {
        let probe = DeferredSettingsProbe()
        let editor = makeEditor(probe: probe)
        let models = Task { await editor.loadModels() }
        await probe.waitForModels(1)
        let check = Task { await editor.check() }
        await probe.waitForChecks(1)
        editor.reset()
        probe.finishModels(0, with: ["old-model"])
        probe.finishCheck(0, with: success)
        await models.value
        await check.value
        XCTAssertEqual(editor.apiKey, "key-A")
        XCTAssertTrue(editor.models.isEmpty)
        XCTAssertNil(editor.status)
        XCTAssertFalse(editor.isLoadingModels)
        XCTAssertFalse(editor.isChecking)
    }

    func testEverySettingsFieldAndKeyEditInvalidateStatusAndInFlightProbe() async {
        for field in ["model", "toolMode", "timeout", "key"] {
            let probe = DeferredSettingsProbe()
            let editor = makeEditor(probe: probe)
            let initial = Task { await editor.check() }
            await probe.waitForChecks(1)
            probe.finishCheck(0, with: success)
            await initial.value
            XCTAssertTrue(editor.status?.ok == true)
            let pending = Task { await editor.check() }
            await probe.waitForChecks(2)
            var edited = editor.draft
            switch field {
            case "model": edited.model = "another-model"
            case "toolMode": edited.toolMode = .off
            case "timeout": edited.timeoutSeconds = 200
            default: break
            }
            if field == "key" { editor.updateAPIKey("another-key") }
            else { editor.updateSettings(edited) }
            XCTAssertNil(editor.status, field)
            probe.finishCheck(1, with: success)
            await pending.value
            XCTAssertNil(editor.status, field)
        }
    }

    func testModelsCanFillEmptyModelAndSaveInvalidatesPendingProbe() async {
        let probe = DeferredSettingsProbe()
        var saved = settings(host: "a.example")
        saved.model = ""
        var persisted: AssistantSettings?
        let editor = AssistantSettingsEditor(
            loadSettings: { saved }, loadAPIKey: { "key-A" },
            fetchModels: probe.models, checkConnection: probe.check,
            saveSettings: { settings, _ in persisted = settings }
        )
        let models = Task { await editor.loadModels() }
        await probe.waitForModels(1)
        probe.finishModels(0, with: ["selected-model"])
        await models.value
        XCTAssertEqual(editor.draft.model, "selected-model")
        XCTAssertEqual(editor.models, ["selected-model"])
        let check = Task { await editor.check() }
        await probe.waitForChecks(1)
        editor.save()
        probe.finishCheck(0, with: success)
        await check.value
        XCTAssertEqual(persisted?.model, "selected-model")
        XCTAssertEqual(editor.status?.message, "Сохранено")
    }

    private func settings(host: String) -> AssistantSettings {
        AssistantSettings(provider: .openAICompatible, baseURL: "https://\(host)", model: "model-A")
    }

    private func makeEditor(saved: AssistantSettings? = nil, probe: DeferredSettingsProbe? = nil) -> AssistantSettingsEditor {
        let saved = saved ?? settings(host: "a.example")
        return AssistantSettingsEditor(
            loadSettings: { saved }, loadAPIKey: { "key-A" },
            fetchModels: { settings, key in
                if let probe { return try await probe.models(settings, key) }
                return []
            },
            checkConnection: { settings, key in
                if let probe { return await probe.check(settings, key) }
                return self.success
            },
            saveSettings: { _, _ in }
        )
    }
}

@MainActor
private final class DeferredSettingsProbe {
    struct Request { let settings: AssistantSettings; let key: String }
    private(set) var modelRequests: [Request] = []
    private(set) var checkRequests: [Request] = []
    private var modelContinuations: [CheckedContinuation<[String], any Error>] = []
    private var checkContinuations: [CheckedContinuation<ConnectionCheckResult, Never>] = []

    func models(_ settings: AssistantSettings, _ key: String) async throws -> [String] {
        try await withCheckedThrowingContinuation {
            modelRequests.append(Request(settings: settings, key: key))
            modelContinuations.append($0)
        }
    }

    func check(_ settings: AssistantSettings, _ key: String) async -> ConnectionCheckResult {
        await withCheckedContinuation {
            checkRequests.append(Request(settings: settings, key: key))
            checkContinuations.append($0)
        }
    }

    func waitForModels(_ count: Int) async {
        for _ in 0..<1_000 {
            if modelRequests.count >= count { return }
            await Task.yield()
        }
        XCTFail("Model request did not start")
    }

    func waitForChecks(_ count: Int) async {
        for _ in 0..<1_000 {
            if checkRequests.count >= count { return }
            await Task.yield()
        }
        XCTFail("Connection check did not start")
    }

    func finishModels(_ index: Int, with models: [String]) { modelContinuations[index].resume(returning: models) }
    func finishCheck(_ index: Int, with result: ConnectionCheckResult) { checkContinuations[index].resume(returning: result) }
}
