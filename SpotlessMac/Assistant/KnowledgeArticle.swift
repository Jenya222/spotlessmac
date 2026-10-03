import Foundation

enum KnowledgeKind: String, Sendable, CaseIterable {
    case process, app, path, guide

    var idPrefix: String {
        switch self {
        case .process: "proc."
        case .app: "app."
        case .path: "path."
        case .guide: "guide."
        }
    }
}

enum KnowledgeVerdict: String, Sendable, CaseIterable {
    case safe, caution, keep, info

    var label: String {
        switch self {
        case .safe: "безопасно"
        case .caution: "осторожно"
        case .keep: "не трогать"
        case .info: "справка"
        }
    }
}

// One reviewed article of the bundled knowledge base. Read-only data: it only ever becomes prompt text.
struct KnowledgeArticle: Equatable, Sendable, Identifiable {
    let id: String
    let kind: KnowledgeKind
    let title: String
    let summary: String
    let verdict: KnowledgeVerdict
    var aliases: [String] = []
    var keywords: [String] = []
    var processes: [String] = []
    var bundles: [String] = []
    var paths: [String] = []
    var categories: [ScanCategory] = []
    var related: [String] = []
    var macOS: String?
    var reviewed: String = ""
    var sources: [String] = []
    var body: String = ""
}
