import Foundation

struct ConnectionCheckResult: Equatable, Sendable {
    let ok: Bool
    let message: String
    let toolsSupported: Bool?

    static func failure(_ error: Error) -> ConnectionCheckResult {
        ConnectionCheckResult(ok: false, message: (error as? LLMError)?.userMessage ?? error.localizedDescription, toolsSupported: nil)
    }
}

enum AssistantConnectionTester {
    static let probeTool = ToolSpec(
        name: "item_details",
        description: "Подробности об элементе по ID",
        parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
    )

    // Sends a real short request: first with a tool, then without if tools are unsupported.
    static func check(client: any LLMClient, model: String) async -> ConnectionCheckResult {
        let messages = [WireMessage(role: .user, content: "Ответь одним словом: готово")]
        do {
            try await drain(client.stream(ChatRequest(model: model, messages: messages, tools: [probeTool])))
            return ConnectionCheckResult(ok: true, message: "Ответила \(model) · инструменты поддерживаются", toolsSupported: true)
        } catch LLMError.toolsUnsupported {
            do {
                try await drain(client.stream(ChatRequest(model: model, messages: messages)))
                return ConnectionCheckResult(ok: true, message: "Ответила \(model) · инструменты не поддерживаются, план будет текстовым", toolsSupported: false)
            } catch {
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    private static func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws {
        for try await _ in stream {}
    }
}
