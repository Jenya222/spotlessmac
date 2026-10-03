import XCTest
@testable import SpotlessMac

final class KnowledgeParserTests: XCTestCase {
    private let front = """
    id: proc.sample
    kind: process
    title: "Sample: процесс"
    summary: Короткое описание.
    verdict: keep
    aliases: [образец, "sample one"]
    processes: [sampled, sample_helper]
    categories: [user_caches]
    macOS: 14-26
    reviewed: 2026-10-03
    sources: [https://support.apple.com/example, man:sampled]
    """

    private func file(_ front: String, body: String = KnowledgeFixtures.body) -> String {
        "---\n\(front)\n---\n\(body)"
    }

    private func assertError(_ text: String, fileName: String = "proc.sample.md", _ expected: KnowledgeParseError,
                             line: UInt = #line) {
        XCTAssertThrowsError(try KnowledgeParser.parse(text, fileName: fileName), line: line) { error in
            XCTAssertEqual(error as? KnowledgeParseError, expected, line: line)
        }
    }

    func testParsesValidArticle() throws {
        let article = try KnowledgeParser.parse(file(front), fileName: "proc.sample.md")
        XCTAssertEqual(article.id, "proc.sample")
        XCTAssertEqual(article.kind, .process)
        XCTAssertEqual(article.title, "Sample: процесс")
        XCTAssertEqual(article.summary, "Короткое описание.")
        XCTAssertEqual(article.verdict, .keep)
        XCTAssertEqual(article.aliases, ["образец", "sample one"])
        XCTAssertEqual(article.processes, ["sampled", "sample_helper"])
        XCTAssertEqual(article.categories, [.userCaches])
        XCTAssertEqual(article.macOS, "14-26")
        XCTAssertEqual(article.reviewed, "2026-10-03")
        XCTAssertEqual(article.sources, ["https://support.apple.com/example", "man:sampled"])
        XCTAssertEqual(article.keywords, [])
        XCTAssertTrue(article.body.hasPrefix("## Что это"))
    }

    func testWindowsLineEndingsAreAccepted() throws {
        let text = file(front).replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try KnowledgeParser.parse(text, fileName: "proc.sample.md").id, "proc.sample")
    }

    func testEmptyListIsAllowed() throws {
        let article = try KnowledgeParser.parse(file(front + "\nkeywords: []"), fileName: "proc.sample.md")
        XCTAssertEqual(article.keywords, [])
    }

    func testMissingFrontMatter() {
        assertError("## Что это\nтекст", .missingFrontMatter)
        assertError("---\nid: proc.sample\n## Что это", .missingFrontMatter)
    }

    func testMalformedLine() {
        assertError(file(front + "\nне ключ"), .malformedLine("не ключ"))
    }

    func testMissingRequiredField() {
        let noSummary = front.components(separatedBy: "\n").filter { !$0.hasPrefix("summary:") }.joined(separator: "\n")
        assertError(file(noSummary), .missingField("summary"))
    }

    func testUnknownKey() {
        assertError(file(front + "\ntags: [a]"), .unknownKey("tags"))
    }

    func testDuplicateKey() {
        assertError(file(front + "\nverdict: safe"), .duplicateKey("verdict"))
    }

    func testListMustUseBrackets() {
        assertError(file(front + "\nkeywords: a, b"), .invalidValue(field: "keywords", value: "a, b"))
    }

    func testUnknownEnumValues() {
        assertError(file(front.replacingOccurrences(of: "verdict: keep", with: "verdict: maybe")),
                    .invalidValue(field: "verdict", value: "maybe"))
        assertError(file(front.replacingOccurrences(of: "kind: process", with: "kind: daemon")),
                    .invalidValue(field: "kind", value: "daemon"))
        assertError(file(front.replacingOccurrences(of: "[user_caches]", with: "[caches]")),
                    .invalidValue(field: "categories", value: "caches"))
    }

    func testReviewedMustBeADate() {
        assertError(file(front.replacingOccurrences(of: "2026-10-03", with: "вчера")),
                    .invalidValue(field: "reviewed", value: "вчера"))
    }

    func testIdMustMatchFileName() {
        assertError(file(front), fileName: "proc.other.md", .idMismatch(id: "proc.sample", fileName: "proc.other.md"))
    }

    func testIdPrefixMustMatchKind() {
        let text = file(front.replacingOccurrences(of: "id: proc.sample", with: "id: app.sample"))
        assertError(text, fileName: "app.sample.md", .invalidValue(field: "id", value: "app.sample"))
    }

    func testSummaryLengthIsCapped() {
        let long = String(repeating: "а", count: 161)
        assertError(file(front.replacingOccurrences(of: "Короткое описание.", with: long)), .summaryTooLong(161))
    }

    func testRequiredSections() {
        assertError(file(front, body: "## Что это\nтекст"), .missingSection("Что делать"))
    }

    func testUnknownSection() {
        assertError(file(front, body: "## Что это\nа\n## Советы\nб\n## Что делать\nв"), .unknownSection("Советы"))
    }

    func testSectionsOutOfOrder() {
        assertError(file(front, body: "## Что делать\nа\n## Что это\nб"), .sectionsOutOfOrder)
    }
}
