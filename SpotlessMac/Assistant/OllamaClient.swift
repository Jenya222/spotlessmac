import Foundation

struct OllamaClient: LLMClient {
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval
    let transport: HTTPTransport

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.open(try makeChatRequest(request))
                    guard (200..<300).contains(response.statusCode) else {
                        throw LLMError.fromHTTP(status: response.statusCode, body: try await response.collectBody())
                    }
                    var callCount = 0
                    for try await line in response.lines {
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        guard let chunk = JSONText.object(from: line) as? [String: Any] else { throw LLMError.decodingFailed }
                        if let message = chunk["error"] as? String {
                            throw LLMError.fromHTTP(status: 500, body: message)
                        }
                        let message = chunk["message"] as? [String: Any]
                        if let content = message?["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        if let rawCalls = message?["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                            var calls: [ToolCall] = []
                            for raw in rawCalls {
                                guard let function = raw["function"] as? [String: Any],
                                      let name = function["name"] as? String else { continue }
                                callCount += 1
                                let arguments = function["arguments"] as? String
                                    ?? JSONText.string(from: function["arguments"] ?? [String: Any]())
                                calls.append(ToolCall(id: "call_\(callCount)", name: name, argumentsJSON: arguments))
                            }
                            if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                        }
                        if chunk["done"] as? Bool == true {
                            continuation.yield(.done)
                            continuation.finish()
                            return
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
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
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
                  let models = json["models"] as? [[String: Any]] else { throw LLMError.decodingFailed }
            return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }.sorted()
        } catch {
            throw LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout))
        }
    }

    func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": request.messages.map(Self.wire),
            "options": ["temperature": request.temperature],
        ]
        if !request.tools.isEmpty { body["tools"] = request.tools.map { $0.jsonObject() } }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func wire(_ message: WireMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                ["function": ["name": call.name, "arguments": JSONText.object(from: call.argumentsJSON) ?? [String: Any]()]]
            }
        }
        if message.role == .tool, let name = message.toolName { object["tool_name"] = name }
        return object
    }
}
