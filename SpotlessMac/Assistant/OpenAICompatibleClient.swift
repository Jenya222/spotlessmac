import Foundation

struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval
    let transport: HTTPTransport

    private struct PendingCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.open(try makeChatRequest(request))
                    guard (200..<300).contains(response.statusCode) else {
                        throw LLMError.fromHTTP(status: response.statusCode, body: try await response.collectBody())
                    }
                    var pending: [Int: PendingCall] = [:]
                    for try await rawLine in response.lines {
                        let line = rawLine.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            if let calls = Self.drain(&pending) { continuation.yield(.toolCalls(calls)) }
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                        guard let chunk = JSONText.object(from: payload) as? [String: Any] else { throw LLMError.decodingFailed }
                        if chunk["error"] != nil {
                            throw LLMError.fromHTTP(status: 500, body: payload)
                        }
                        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any]
                        if let content = delta?["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        for raw in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                            let index = raw["index"] as? Int ?? 0
                            var entry = pending[index] ?? PendingCall()
                            if let id = raw["id"] as? String { entry.id = id }
                            let function = raw["function"] as? [String: Any]
                            if let name = function?["name"] as? String { entry.name += name }
                            if let arguments = function?["arguments"] as? String { entry.arguments += arguments }
                            pending[index] = entry
                        }
                        if choice["finish_reason"] as? String == "tool_calls", let calls = Self.drain(&pending) {
                            continuation.yield(.toolCalls(calls))
                        }
                    }
                    try Task.checkCancellation()
                    throw LLMError.streamInterrupted
                } catch {
                    continuation.finish(throwing: LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        authorize(&request)
        do {
            let response = try await transport.open(request)
            let body = try await response.collectBody(limit: 2_000_000)
            guard (200..<300).contains(response.statusCode) else {
                throw LLMError.fromHTTP(status: response.statusCode, body: body)
            }
            guard let json = JSONText.object(from: body) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { throw LLMError.decodingFailed }
            return models.compactMap { $0["id"] as? String }.sorted()
        } catch {
            throw LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout))
        }
    }

    func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        // No "temperature": OpenAI reasoning models reject any explicit value, so the server default applies.
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": request.messages.map(Self.wire),
        ]
        if !request.tools.isEmpty { body["tools"] = request.tools.map { $0.jsonObject() } }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func drain(_ pending: inout [Int: PendingCall]) -> [ToolCall]? {
        guard !pending.isEmpty else { return nil }
        let calls = pending.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = pending[index], !call.name.isEmpty else { return nil }
            return ToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name,
                            argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        pending = [:]
        return calls.isEmpty ? nil : calls
    }

    private static func wire(_ message: WireMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
        }
        if message.role == .tool, let id = message.toolCallID { object["tool_call_id"] = id }
        return object
    }
}
