import Foundation
import Observation

/// Owns the unsaved settings and credentials. Requests are immutable snapshots;
/// only the most recent operation for the unchanged draft may update the editor.
@Observable @MainActor
final class AssistantSettingsEditor {
    private(set) var draft: AssistantSettings
    private(set) var apiKey: String
    private(set) var models: [String] = []
    private(set) var isLoadingModels = false
    private(set) var isChecking = false
    private(set) var status: ConnectionCheckResult?

    private let loadSettings: @MainActor () -> AssistantSettings
    private let loadAPIKey: @MainActor () -> String
    private let fetchModels: @MainActor (AssistantSettings, String) async throws -> [String]
    private let checkConnection: @MainActor (AssistantSettings, String) async -> ConnectionCheckResult
    private let saveSettings: @MainActor (AssistantSettings, String) -> Void
    private var generation: UInt64 = 0

    // Writable projections let SwiftUI field bindings invalidate probes synchronously.
    var settings: AssistantSettings {
        get { draft }
        set { updateSettings(newValue) }
    }

    var key: String {
        get { apiKey }
        set { updateAPIKey(newValue) }
    }

    init(
        loadSettings: @escaping @MainActor () -> AssistantSettings,
        loadAPIKey: @escaping @MainActor () -> String,
        fetchModels: @escaping @MainActor (AssistantSettings, String) async throws -> [String],
        checkConnection: @escaping @MainActor (AssistantSettings, String) async -> ConnectionCheckResult,
        saveSettings: @escaping @MainActor (AssistantSettings, String) -> Void
    ) {
        self.loadSettings = loadSettings
        self.loadAPIKey = loadAPIKey
        self.fetchModels = fetchModels
        self.checkConnection = checkConnection
        self.saveSettings = saveSettings
        draft = loadSettings()
        apiKey = loadAPIKey()
    }

    func updateSettings(_ settings: AssistantSettings) {
        guard settings != draft else { return }
        let identityChanged = AssistantEndpointIdentity(settings: settings) != AssistantEndpointIdentity(settings: draft)
        let addressChanged = settings.provider != draft.provider || settings.baseURL != draft.baseURL
        draft = settings
        if identityChanged {
            apiKey = settings.sharesTokenEndpoint(with: loadSettings()) ? loadAPIKey() : ""
        }
        if addressChanged { models = [] }
        invalidateProbes()
    }

    func updateAPIKey(_ key: String) {
        guard apiKey != key else { return }
        apiKey = key
        models = []
        invalidateProbes()
    }

    func reset() {
        invalidateProbes()
        draft = loadSettings()
        apiKey = loadAPIKey()
        models = []
    }

    func loadModels() async {
        let request = beginProbe()
        isLoadingModels = true
        do {
            let fetched = try await fetchModels(request.settings, request.key)
            guard isCurrent(request) else { return }
            models = fetched
            // This is part of the accepted response, rather than a user edit.
            if draft.trimmedModel.isEmpty, let first = fetched.first { draft.model = first }
            status = ConnectionCheckResult(ok: true, message: "Найдено моделей: \(fetched.count)", toolsSupported: nil)
        } catch {
            guard isCurrent(request) else { return }
            status = .failure(error)
        }
        isLoadingModels = false
    }

    func check() async {
        let request = beginProbe()
        isChecking = true
        let result = await checkConnection(request.settings, request.key)
        guard isCurrent(request) else { return }
        status = result
        isChecking = false
    }

    func save() {
        invalidateProbes()
        saveSettings(draft, apiKey)
        status = ConnectionCheckResult(ok: true, message: "Сохранено", toolsSupported: nil)
    }

    private struct Probe {
        let generation: UInt64
        let settings: AssistantSettings
        let key: String
    }

    private func beginProbe() -> Probe {
        invalidateProbes()
        return Probe(generation: generation, settings: draft, key: apiKey)
    }

    private func isCurrent(_ request: Probe) -> Bool {
        generation == request.generation && draft == request.settings && apiKey == request.key
    }

    private func invalidateProbes() {
        generation &+= 1
        status = nil
        isLoadingModels = false
        isChecking = false
    }
}
