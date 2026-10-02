import Foundation

struct HTTPStreamResponse: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>

    func collectBody(limit: Int = 4_000) async throws -> String {
        var body = ""
        for try await line in lines {
            body += body.isEmpty ? line : "\n" + line
            if body.count >= limit { break }
        }
        return body
    }
}

protocol HTTPTransport: Sendable {
    func open(_ request: URLRequest) async throws -> HTTPStreamResponse
}

struct URLSessionTransport: HTTPTransport {
    func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: status, lines: lines)
    }
}
