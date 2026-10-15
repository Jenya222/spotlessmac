import Foundation

enum AgentStorageKind: String, Sendable {
    case workspace, temporary, cache, logs, sessions
    var title: String {
        switch self {
        case .workspace: "Рабочая папка"
        case .temporary: "Временные данные"
        case .cache: "Кэш"
        case .logs: "Диагностические логи"
        case .sessions: "История сессий"
        }
    }
}

enum AgentStorageStatus: String, CaseIterable, Identifiable, Sendable {
    case cleanable, recent, protected, review
    var id: Self { self }
    var title: String {
        switch self {
        case .cleanable: "Можно очистить"
        case .recent: "Недавно использовалось"
        case .protected: "Защищено"
        case .review: "Нужна проверка"
        }
    }
}

struct AgentStorageSource: Sendable {
    let url: URL
    let agent: String
    let kind: AgentStorageKind
}

struct AgentStorageItem: Identifiable, Sendable {
    let path: URL
    let agent: String
    let kind: AgentStorageKind
    let bytes: Int64
    let modifiedAt: Date?
    let isComplete: Bool
    let hasGit: Bool
    let status: AgentStorageStatus
    let reason: String
    let recommendation: String
    let scanItem: ScanItem
    var id: String { path.standardizedFileURL.path(percentEncoded: false) }
}

struct AgentStorageTotal: Identifiable, Sendable {
    let agent: String
    let bytes: Int64
    let count: Int
    var id: String { agent }
}

struct AgentStorageReport: Sendable {
    var items: [AgentStorageItem] = []
    var warnings: [String] = []
    var scannedAt: Date = Date()
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var cleanableBytes: Int64 { items.filter { $0.status == .cleanable }.reduce(0) { $0 + $1.bytes } }
    var totals: [AgentStorageTotal] {
        Dictionary(grouping: items, by: \.agent).map { agent, items in
            AgentStorageTotal(agent: agent, bytes: items.reduce(0) { $0 + $1.bytes }, count: items.count)
        }.sorted { $0.bytes == $1.bytes ? $0.agent < $1.agent : $0.bytes > $1.bytes }
    }
}

struct AgentStorageSelection: Identifiable, Sendable {
    let id = UUID()
    let generation: UUID
    let items: [AgentStorageItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}
