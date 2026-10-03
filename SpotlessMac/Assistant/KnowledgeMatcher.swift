import Foundation

// Article ids bound to what the snapshot shows: scanned items by short ID, memory apps and processes by name.
struct KnowledgeAnnotations: Equatable, Sendable {
    var items: [String: String] = [:]
    var apps: [String: String] = [:]
    var processes: [String: String] = [:]

    var isEmpty: Bool { items.isEmpty && apps.isEmpty && processes.isEmpty }
}

// Everything the renderer and the toolbox need from the knowledge base for one answer.
struct KnowledgeContext: Sendable {
    static let none = KnowledgeContext(base: .empty, annotations: KnowledgeAnnotations())

    let base: KnowledgeBase
    let annotations: KnowledgeAnnotations
}

// Binds snapshot entities to articles. Runs on real (unredacted) paths; only article ids leave this type.
enum KnowledgeMatcher {
    static func annotate(_ snapshot: SystemSnapshot, knowledge: KnowledgeBase, homePath: String) -> KnowledgeAnnotations {
        guard !knowledge.isEmpty else { return KnowledgeAnnotations() }
        var result = KnowledgeAnnotations()
        for item in snapshot.items {
            if let article = article(forPath: item.path, category: item.category, in: knowledge, homePath: homePath) {
                result.items[item.shortID] = article.id
            }
        }
        for app in snapshot.memory?.topApps ?? [] {
            if let article = article(forApp: app.name, bundleID: app.bundleID, in: knowledge) {
                result.apps[app.name] = article.id
            }
        }
        for process in snapshot.memory?.topProcesses ?? [] {
            if let article = article(forProcess: process.name, in: knowledge) {
                result.processes[process.name] = article.id
            }
        }
        return result
    }

    // The most specific path pattern wins; without one, the article that is the fallback for the category.
    static func article(forPath path: String, category: ScanCategory?, in knowledge: KnowledgeBase,
                        homePath: String) -> KnowledgeArticle? {
        var best: (article: KnowledgeArticle, score: Int)?
        for article in knowledge.articles {
            for pattern in article.paths {
                guard let score = specificity(of: pattern, matching: path, homePath: homePath) else { continue }
                if score > (best?.score ?? Int.min) { best = (article, score) }
            }
        }
        if let best { return best.article }
        guard let category else { return nil }
        return knowledge.articles.first { $0.categories.contains(category) }
    }

    static func article(forApp name: String, bundleID: String?, in knowledge: KnowledgeBase) -> KnowledgeArticle? {
        if let bundleID, let article = knowledge.articles.first(where: { $0.bundles.contains(bundleID) }) {
            return article
        }
        let lowered = name.lowercased()
        return knowledge.articles.first { article in
            article.kind == .app
                && (article.title.lowercased() == lowered || article.aliases.contains { $0.lowercased() == lowered })
        }
    }

    static func article(forProcess name: String, in knowledge: KnowledgeBase) -> KnowledgeArticle? {
        knowledge.articles.first { $0.processes.contains(name) }
    }

    // nil when `pattern` does not cover `path` (the path itself or anything inside it). Otherwise a score:
    // more components rank higher, then more literal components. `~` is the home folder; one `*` inside a
    // component matches any run of characters within that component.
    static func specificity(of pattern: String, matching path: String, homePath: String) -> Int? {
        let expanded = pattern == "~" ? homePath : pattern.hasPrefix("~/") ? homePath + pattern.dropFirst() : pattern
        let patternParts = expanded.split(separator: "/")
        let pathParts = path.split(separator: "/")
        guard !patternParts.isEmpty, pathParts.count >= patternParts.count else { return nil }
        var literals = 0
        for (patternPart, pathPart) in zip(patternParts, pathParts) {
            guard componentMatches(patternPart, pathPart) else { return nil }
            if !patternPart.contains("*") { literals += 1 }
        }
        return patternParts.count * 100 + literals
    }

    private static func componentMatches(_ pattern: Substring, _ component: Substring) -> Bool {
        guard pattern.contains("*") else { return pattern == component }
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return component.count >= pieces[0].count + pieces[1].count
            && component.hasPrefix(pieces[0]) && component.hasSuffix(pieces[1])
    }
}
