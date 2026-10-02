import Foundation

enum LLMClientFactory {
    static func make(
        settings: AssistantSettings,
        apiKey: String,
        transport: HTTPTransport = URLSessionTransport()
    ) throws -> any LLMClient {
        guard let url = normalizedBaseURL(settings.baseURL, provider: settings.provider) else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.provider.requiresAPIKey && key.isEmpty { throw LLMError.missingAPIKey }
        let timeout = TimeInterval(settings.timeoutSeconds)
        switch settings.provider {
        case .ollamaCloud, .ollamaLocal:
            return OllamaClient(baseURL: url, apiKey: settings.provider.usesAPIKey ? key : "", timeout: timeout, transport: transport)
        case .openAICompatible:
            return OpenAICompatibleClient(baseURL: url, apiKey: key, timeout: timeout, transport: transport)
        }
    }

    // Users often paste ".../v1" or ".../api"; the clients append those themselves.
    static func normalizedBaseURL(_ text: String, provider: AssistantProvider) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        let suffix = provider == .openAICompatible ? "/v1" : "/api"
        if value.lowercased().hasSuffix(suffix) { value.removeLast(suffix.count) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }
}
