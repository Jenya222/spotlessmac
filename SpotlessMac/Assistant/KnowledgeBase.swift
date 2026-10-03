import Foundation
import os

// The bundled, read-only knowledge base. Loaded once at launch and handed to the assistant as a value.
struct KnowledgeBase: Sendable {
    static let empty = KnowledgeBase(articles: [])
    static let resourceFolder = "Knowledge"
    private static let logger = Logger(subsystem: "com.spotlessmac.app", category: "knowledge")

    let articles: [KnowledgeArticle]
    private let byID: [String: KnowledgeArticle]
    private let index: KnowledgeSearch

    init(articles: [KnowledgeArticle]) {
        let sorted = articles.sorted { $0.id < $1.id }
        self.articles = sorted
        byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        index = KnowledgeSearch(articles: sorted)
    }

    var isEmpty: Bool { articles.isEmpty }

    func article(id: String) -> KnowledgeArticle? { byID[id] }

    func search(_ query: String, limit: Int) -> [KnowledgeHit] { index.search(query, limit: limit) }

    // Parses every file. A file that fails (or repeats an id) is reported and skipped; the rest still load.
    static func build(files: [(name: String, text: String)]) -> (base: KnowledgeBase, failures: [String]) {
        var articles: [KnowledgeArticle] = []
        var seen = Set<String>()
        var failures: [String] = []
        for file in files.sorted(by: { $0.name < $1.name }) {
            do {
                let article = try KnowledgeParser.parse(file.text, fileName: file.name)
                guard seen.insert(article.id).inserted else {
                    failures.append("\(file.name): duplicate id \(article.id)")
                    continue
                }
                articles.append(article)
            } catch {
                failures.append("\(file.name): \(error)")
            }
        }
        return (KnowledgeBase(articles: articles), failures)
    }

    static func loadBundled(from bundle: Bundle) -> KnowledgeBase {
        let urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: resourceFolder) ?? []
        // An unreadable file is passed on as empty text, so it is reported as a parse failure below.
        let files = urls.map { url in (name: url.lastPathComponent, text: (try? String(contentsOf: url, encoding: .utf8)) ?? "") }
        let (base, failures) = build(files: files)
        if base.isEmpty { logger.error("Knowledge base is empty: no articles in the bundle") }
        for failure in failures { logger.error("Knowledge article skipped: \(failure, privacy: .public)") }
        assert(failures.isEmpty, "Broken knowledge articles: \(failures)")
        return base
    }
}
