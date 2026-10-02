import Foundation

enum LLMError: Error, Equatable, Sendable {
    case missingAPIKey
    case unauthorized
    case modelNotFound
    case rateLimited
    case toolsUnsupported
    case connectionRefused(host: String)
    case timedOut(seconds: Int)
    case httpStatus(code: Int, body: String)
    case decodingFailed
    case invalidURL
    case streamInterrupted

    var userMessage: String {
        switch self {
        case .missingAPIKey: "Не указан токен. Добавьте его в Настройки → Ассистент."
        case .unauthorized: "Неверный токен. Проверьте его в Настройки → Ассистент."
        case .modelNotFound: "Модель не найдена. Выберите другую в настройках."
        case .rateLimited: "Превышен лимит запросов. Попробуйте позже."
        case .toolsUnsupported: "Модель не поддерживает инструменты. Выключите их в настройках."
        case .connectionRefused(let host):
            "Не удалось подключиться к \(host). Если это локальная Ollama — запустите приложение Ollama или `ollama serve`."
        case .timedOut(let seconds): "Модель не ответила за \(seconds) с. Увеличьте тайм-аут в настройках."
        case .httpStatus(let code, let body): body.isEmpty ? "Сервер вернул ошибку \(code)." : "Сервер вернул ошибку \(code): \(body)"
        case .decodingFailed: "Не удалось разобрать ответ сервера."
        case .invalidURL: "Некорректный адрес сервера. Проверьте URL в настройках."
        case .streamInterrupted: "Ответ прерван: соединение закрылось раньше времени."
        }
    }

    var opensSettings: Bool {
        switch self {
        case .missingAPIKey, .unauthorized, .modelNotFound, .invalidURL, .toolsUnsupported: true
        default: false
        }
    }

    static func fromHTTP(status: Int, body: String) -> LLMError {
        let message = extractMessage(from: body)
        let lower = message.lowercased()
        if lower.contains("tool"), lower.contains("support") { return .toolsUnsupported }
        if lower.contains("model"), lower.contains("not found") { return .modelNotFound }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .modelNotFound
        case 429: return .rateLimited
        default: return .httpStatus(code: status, body: String(message.prefix(240)))
        }
    }

    // Ollama: {"error":"…"}; OpenAI-compatible: {"error":{"message":"…"}}.
    static func extractMessage(from body: String) -> String {
        guard let json = JSONText.object(from: body) as? [String: Any] else { return body }
        if let text = json["error"] as? String { return text }
        if let nested = json["error"] as? [String: Any], let text = nested["message"] as? String { return text }
        return body
    }

    static func mapTransport(_ error: Error, host: String, timeout: Int) -> Error {
        if error is LLMError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet: return LLMError.connectionRefused(host: host)
        case .timedOut: return LLMError.timedOut(seconds: timeout)
        case .networkConnectionLost: return LLMError.streamInterrupted
        default: return LLMError.httpStatus(code: urlError.errorCode, body: urlError.localizedDescription)
        }
    }
}

extension URL {
    var hostLabel: String {
        let host = host() ?? absoluteString
        return port.map { "\(host):\($0)" } ?? host
    }
}
