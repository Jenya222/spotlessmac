import Foundation

enum AssistantProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollamaCloud, ollamaLocal, openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollamaCloud: "Ollama Cloud"
        case .ollamaLocal: "Локальная Ollama"
        case .openAICompatible: "OpenAI-совместимый"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollamaCloud: "https://ollama.com"
        case .ollamaLocal: "http://localhost:11434"
        case .openAICompatible: "https://api.openai.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollamaCloud, .ollamaLocal: "gpt-oss:20b"
        case .openAICompatible: ""
        }
    }

    var usesAPIKey: Bool { self != .ollamaLocal }
    var requiresAPIKey: Bool { self == .ollamaCloud }
}

enum AssistantToolMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .on: "Вкл"
        case .off: "Выкл"
        }
    }
}

struct AssistantSettings: Codable, Equatable, Sendable {
    static let timeoutRange = 10...300

    var provider: AssistantProvider = .ollamaCloud
    var baseURL: String = AssistantProvider.ollamaCloud.defaultBaseURL
    var model: String = AssistantProvider.ollamaCloud.defaultModel
    var toolMode: AssistantToolMode = .auto
    var timeoutSeconds: Int = 120

    mutating func switchProvider(to newProvider: AssistantProvider) {
        provider = newProvider
        baseURL = newProvider.defaultBaseURL
        model = newProvider.defaultModel
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Anything that leaves this Mac gets redacted paths.
    var sendsDataOffDevice: Bool {
        switch provider {
        case .ollamaCloud: return true
        case .ollamaLocal: return false
        case .openAICompatible:
            let host = URL(string: baseURL)?.host()?.lowercased() ?? ""
            return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }

    var toolSupportKey: String { "\(provider.rawValue)|\(baseURL)|\(trimmedModel)" }
}

@MainActor
final class AssistantSettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "assistantSettings"
    private let toolSupportKey = "assistantToolSupport"
    private let disclosureKey = "assistantCloudDisclosureAccepted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AssistantSettings {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(AssistantSettings.self, from: data) else {
            return AssistantSettings()
        }
        let range = AssistantSettings.timeoutRange
        settings.timeoutSeconds = min(max(settings.timeoutSeconds, range.lowerBound), range.upperBound)
        return settings
    }

    func save(_ settings: AssistantSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    func toolSupport(for key: String) -> Bool? {
        (defaults.dictionary(forKey: toolSupportKey) as? [String: Bool])?[key]
    }

    func setToolSupport(_ supported: Bool, for key: String) {
        var map = (defaults.dictionary(forKey: toolSupportKey) as? [String: Bool]) ?? [:]
        map[key] = supported
        defaults.set(map, forKey: toolSupportKey)
    }

    var cloudDisclosureAccepted: Bool {
        get { defaults.bool(forKey: disclosureKey) }
        set { defaults.set(newValue, forKey: disclosureKey) }
    }
}
