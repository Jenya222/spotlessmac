import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct WireMessage: Equatable, Sendable {
    let role: ChatRole
    let content: String
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var toolName: String?
}

struct ToolSpec: Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String

    // Same function-tool shape for Ollama /api/chat and OpenAI /v1/chat/completions.
    func jsonObject() -> [String: Any] {
        let parameters = JSONText.object(from: parametersJSON) ?? ["type": "object", "properties": [String: Any]()]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

struct ChatRequest: Sendable {
    var model: String
    var messages: [WireMessage]
    var tools: [ToolSpec] = []
    var temperature: Double = 0.2
}

enum ChatEvent: Equatable, Sendable {
    case text(String)
    case toolCalls([ToolCall])
    case done
}

protocol LLMClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
}

enum JSONText {
    static func string(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(from text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
