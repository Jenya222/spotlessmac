import Foundation
@testable import SpotlessMac

final class FakeKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String
    init(_ key: String = "") { self.key = key }
    func readKey() -> String { lock.withLock { key } }
    func writeKey(_ newKey: String) {
        lock.withLock { key = newKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

func makeDefaults() -> UserDefaults {
    let name = "assistant.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var lines: [String] = []
        var error: Error?
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? Reply() : replies.removeFirst()
        }
        if let error = reply.error { throw error }
        let lines = reply.lines
        return HTTPStreamResponse(statusCode: reply.status, lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

final class FakeLLMClient: LLMClient, @unchecked Sendable {
    enum Step {
        case events([ChatEvent])
        case failure(Error)
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [ChatRequest] = []
    private var hanging: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    var models: [String] = []

    init(_ steps: [Step]) { self.steps = steps }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let step: Step = lock.withLock {
            recorded.append(request)
            return steps.isEmpty ? .events([.done]) : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .hang:
                // Kept alive on purpose: the stream ends only when the consumer is cancelled.
                lock.withLock { hanging.append(continuation) }
            }
        }
    }

    func listModels() async throws -> [String] { models }
}

func jsonBody(_ request: URLRequest) -> [String: Any] {
    (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

func collectEvents(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
