import Foundation

// Turns articles into the text the model reads: full articles, lookup results, the
// «Справка по найденному» section and the tools-off reference. All limits are in characters.
enum KnowledgeRenderer {
    static let articleLimit = 3_000
    static let lookupLimit = 6_000
    static let sectionLimit = 2_500
    static let sectionEntries = 12
    static let injectedLimit = 4_000

    static func article(_ article: KnowledgeArticle, limit: Int = articleLimit) -> String {
        var lines = [
            "[\(article.id)] \(article.title)",
            "Вердикт: \(article.verdict.label)",
            "Кратко: \(article.summary)",
            article.body,
        ]
        if !article.related.isEmpty { lines.append("См. также: " + article.related.joined(separator: ", ")) }
        return truncated(lines.joined(separator: "\n"), to: limit)
    }

    // `id` wins when it exists. An unknown id falls back to `query`, or, without a query, to similar titles.
    static func lookup(id: String?, query: String?, in base: KnowledgeBase) -> String {
        if let id, let found = base.article(id: id) { return article(found) }
        let prefix = id.map { "Статья \($0) не найдена. " } ?? ""
        let text = query ?? id.map { $0.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ") } ?? ""
        let hits = base.search(text, limit: 3)
        guard !hits.isEmpty else {
            return prefix + "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет."
        }
        if query == nil {
            return prefix + "Похожие статьи: "
                + hits.map { "\($0.article.id) — \($0.article.title)" }.joined(separator: "; ") + "."
        }
        return prefix + joined(hits.map(\.article), header: "Найдено в справке: \(hits.count).", limit: lookupLimit)
    }

    // Tools-off mode: the best articles for the user's question, sent as one more system message.
    static func injected(for question: String, in base: KnowledgeBase) -> String? {
        let hits = base.search(question, limit: 2)
        guard !hits.isEmpty else { return nil }
        return joined(hits.map(\.article), header: "Справка SpotlessMac по вопросу:", limit: injectedLimit)
    }

    // Each matched article once, the one covering the most bytes first.
    static func section(_ snapshot: SystemSnapshot, context: KnowledgeContext) -> String? {
        var weight: [String: Int64] = [:]
        for item in snapshot.items {
            if let id = context.annotations.items[item.shortID] { weight[id, default: 0] += item.bytes }
        }
        for app in snapshot.memory?.topApps ?? [] {
            if let id = context.annotations.apps[app.name] { weight[id, default: 0] += app.bytes }
        }
        for process in snapshot.memory?.topProcesses ?? [] {
            if let id = context.annotations.processes[process.name] { weight[id, default: 0] += process.bytes }
        }
        let ordered = weight
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { context.base.article(id: $0.key) }
        var lines = ["Справка SpotlessMac по найденному (id — вердикт — кратко):"]
        var used = lines[0].count
        for article in ordered.prefix(sectionEntries) {
            let line = "- \(article.id) — \(article.verdict.label) — \(article.summary)"
            guard used + 1 + line.count <= sectionLimit else { break }
            lines.append(line)
            used += 1 + line.count
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    private static func joined(_ articles: [KnowledgeArticle], header: String, limit: Int) -> String {
        var text = header
        for item in articles {
            let block = "\n\n" + article(item)
            guard text.count + block.count <= limit else { break }
            text += block
        }
        return text
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
