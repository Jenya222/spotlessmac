import Foundation

struct KnowledgeHit: Equatable, Sendable {
    let article: KnowledgeArticle
    let score: Double
}

// BM25 over the bundled articles, in memory. A few hundred short articles need no database:
// the index is built once and each query scores every document.
struct KnowledgeSearch: Sendable {
    static let k1 = 1.2
    static let b = 0.75
    // Added when a query word equals one of the article's process names or bundle IDs.
    static let exactMatchBoost = 5.0
    static let stopWords: Set<String> = [
        "и", "в", "во", "на", "с", "со", "за", "по", "к", "ко", "о", "об", "а", "но", "не", "ни", "что", "это",
        "как", "ли", "же", "у", "из", "от", "до", "для", "мой", "моя", "мне", "меня", "я", "ты", "он", "она",
        "оно", "они", "мы", "вы", "так", "там", "тут", "есть", "или", "можно",
        "the", "a", "an", "of", "to", "is", "what", "and", "or",
    ]
    // Two-letter adjective/plural endings stripped before the vowel pass (only if ≥ 4 letters remain).
    private static let pairEndings = ["ых", "их", "ой", "ей", "ий", "ый", "ая", "яя", "ое", "ее", "ые", "ие", "ую", "юю", "ах", "ях", "ов", "ев"]
    private static let vowelEndings = Set("аеиоуыэюяьй")
    private static let stemLength = 5

    private struct Document: Sendable {
        let article: KnowledgeArticle
        let frequencies: [String: Double]
        let length: Double
        let exactNames: Set<String>
    }

    private let documents: [Document]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    init(articles: [KnowledgeArticle]) {
        documents = articles.map(Self.document)
        var frequency: [String: Int] = [:]
        for document in documents {
            for term in document.frequencies.keys { frequency[term, default: 0] += 1 }
        }
        documentFrequency = frequency
        let total = documents.reduce(0) { $0 + $1.length }
        averageLength = documents.isEmpty ? 1 : max(total / Double(documents.count), 1)
    }

    func search(_ query: String, limit: Int) -> [KnowledgeHit] {
        guard limit > 0, !documents.isEmpty else { return [] }
        let terms = Set(Self.tokens(query))
        let words = Set(query.lowercased()
            .split { $0.isWhitespace || "?!,;:«»\"()".contains($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let count = Double(documents.count)
        var hits: [KnowledgeHit] = []
        for document in documents {
            var score = 0.0
            for term in terms {
                guard let tf = document.frequencies[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let norm = tf + Self.k1 * (1 - Self.b + Self.b * document.length / averageLength)
                score += idf * tf * (Self.k1 + 1) / norm
            }
            if !document.exactNames.isDisjoint(with: words) { score += Self.exactMatchBoost }
            if score > 0 { hits.append(KnowledgeHit(article: document.article, score: score)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.article.id < $1.article.id }
        return Array(hits.prefix(limit))
    }

    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        var result: [String] = []
        for raw in lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
            guard !word.isEmpty else { continue }
            let parts = word.split(whereSeparator: { $0 == "_" || $0 == "." }).map(String.init)
            if parts.count > 1 { result.append(word) }
            for part in parts where !stopWords.contains(part) { result.append(stem(part)) }
        }
        return result
    }

    // Light Russian stemming: drop one two-letter ending, then trailing vowels, then cut to five letters.
    // Latin words are left whole. Tuned against the eval set (KnowledgeEvalTests), not linguistically exact.
    static func stem(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else { return word }
        var characters = Array(word)
        if characters.count >= 6, pairEndings.contains(String(characters.suffix(2))) { characters.removeLast(2) }
        while characters.count > 3, let last = characters.last, vowelEndings.contains(last) { characters.removeLast() }
        return String(characters.prefix(stemLength))
    }

    private static func document(_ article: KnowledgeArticle) -> Document {
        var frequencies: [String: Double] = [:]
        var length = 0.0
        func add(_ text: String, weight: Double) {
            for token in tokens(text) {
                frequencies[token, default: 0] += weight
                length += weight
            }
        }
        add(article.title, weight: 3)
        for value in article.aliases + article.keywords + article.processes + article.bundles { add(value, weight: 2) }
        add(article.summary, weight: 1.5)
        add(article.body, weight: 1)
        let names = Set((article.processes + article.bundles).map { $0.lowercased() })
        return Document(article: article, frequencies: frequencies, length: length, exactNames: names)
    }
}
