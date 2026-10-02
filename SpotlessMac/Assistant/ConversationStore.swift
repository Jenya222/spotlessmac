import Foundation

// Persists only the last conversation, as JSON, in the app's own support folder.
struct ConversationStore: Sendable {
    static let maxStoredMessages = 200

    let fileURL: URL

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "SpotlessMac", directoryHint: .isDirectory)
            .appending(path: "assistant-conversation.json")
    }

    func load() -> [AssistantMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let messages = try? JSONDecoder().decode([AssistantMessage].self, from: data) else { return [] }
        return messages.map { message in
            var copy = message
            if copy.status == .streaming { copy.status = .interrupted }
            return copy
        }
    }

    func save(_ messages: [AssistantMessage]) {
        guard let data = try? JSONEncoder().encode(Array(messages.suffix(Self.maxStoredMessages))) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
