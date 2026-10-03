import Foundation

enum KnowledgeParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontMatter
    case malformedLine(String)
    case unknownKey(String)
    case duplicateKey(String)
    case missingField(String)
    case invalidValue(field: String, value: String)
    case idMismatch(id: String, fileName: String)
    case summaryTooLong(Int)
    case unknownSection(String)
    case missingSection(String)
    case sectionsOutOfOrder

    var description: String {
        switch self {
        case .missingFrontMatter: "no front matter between --- lines"
        case .malformedLine(let line): "malformed front matter line: \(line)"
        case .unknownKey(let key): "unknown key: \(key)"
        case .duplicateKey(let key): "duplicate key: \(key)"
        case .missingField(let key): "missing required field: \(key)"
        case .invalidValue(let field, let value): "invalid \(field): \(value)"
        case .idMismatch(let id, let fileName): "id \(id) does not match file \(fileName)"
        case .summaryTooLong(let count): "summary is \(count) characters, max \(KnowledgeParser.maxSummaryLength)"
        case .unknownSection(let title): "unknown section: \(title)"
        case .missingSection(let title): "missing section: \(title)"
        case .sectionsOutOfOrder: "sections out of order"
        }
    }
}

// Parses one article file: a flat front matter between `---` lines, then the Markdown body.
// Front matter is a strict YAML subset: `key: value` per line, lists only as inline `[a, b]`
// (items cannot contain commas), optional double quotes, no nesting. Unknown keys are errors.
enum KnowledgeParser {
    static let maxSummaryLength = 160
    static let sectionOrder = ["Что это", "Норма", "Почему растёт", "Что делать", "Чего не делать"]
    static let requiredSections = ["Что это", "Что делать"]
    private static let scalarKeys: Set<String> = ["id", "kind", "title", "summary", "verdict", "macOS", "reviewed"]
    private static let listKeys: Set<String> = [
        "aliases", "keywords", "processes", "bundles", "paths", "categories", "related", "sources",
    ]

    static func parse(_ text: String, fileName: String) throws(KnowledgeParseError) -> KnowledgeArticle {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw .missingFrontMatter }

        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for line in lines[1..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformedLine(line) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard scalars[key] == nil, lists[key] == nil else { throw .duplicateKey(key) }
            if scalarKeys.contains(key) {
                scalars[key] = unquoted(value)
            } else if listKeys.contains(key) {
                guard value.hasPrefix("["), value.hasSuffix("]") else { throw .invalidValue(field: key, value: value) }
                let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                lists[key] = inner.isEmpty ? [] : inner.split(separator: ",").map {
                    unquoted($0.trimmingCharacters(in: .whitespaces))
                }
            } else {
                throw .unknownKey(key)
            }
        }

        func required(_ key: String) throws(KnowledgeParseError) -> String {
            guard let value = scalars[key], !value.isEmpty else { throw .missingField(key) }
            return value
        }
        let id = try required("id")
        let kindValue = try required("kind")
        guard let kind = KnowledgeKind(rawValue: kindValue) else { throw .invalidValue(field: "kind", value: kindValue) }
        let idCharacters = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        guard id.hasPrefix(kind.idPrefix), idCharacters else { throw .invalidValue(field: "id", value: id) }
        let baseName = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        guard baseName == id else { throw .idMismatch(id: id, fileName: fileName) }
        let title = try required("title")
        let summary = try required("summary")
        guard summary.count <= maxSummaryLength else { throw .summaryTooLong(summary.count) }
        let verdictValue = try required("verdict")
        guard let verdict = KnowledgeVerdict(rawValue: verdictValue) else {
            throw .invalidValue(field: "verdict", value: verdictValue)
        }
        let reviewed = try required("reviewed")
        guard reviewed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw .invalidValue(field: "reviewed", value: reviewed)
        }
        var categories: [ScanCategory] = []
        for value in lists["categories"] ?? [] {
            guard let category = ScanCategory(rawValue: value) else { throw .invalidValue(field: "categories", value: value) }
            categories.append(category)
        }

        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        try checkSections(body)

        return KnowledgeArticle(
            id: id, kind: kind, title: title, summary: summary, verdict: verdict,
            aliases: lists["aliases"] ?? [], keywords: lists["keywords"] ?? [],
            processes: lists["processes"] ?? [], bundles: lists["bundles"] ?? [], paths: lists["paths"] ?? [],
            categories: categories, related: lists["related"] ?? [], macOS: scalars["macOS"],
            reviewed: reviewed, sources: lists["sources"] ?? [], body: body
        )
    }

    private static func checkSections(_ body: String) throws(KnowledgeParseError) {
        let titles = body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("## ") }
            .map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        var last = -1
        for title in titles {
            guard let index = sectionOrder.firstIndex(of: title) else { throw .unknownSection(title) }
            guard index > last else { throw .sectionsOutOfOrder }
            last = index
        }
        for title in requiredSections where !titles.contains(title) { throw .missingSection(title) }
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
