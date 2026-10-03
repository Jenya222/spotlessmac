import XCTest
@testable import SpotlessMac

// Retrieval quality gate: real user questions must find the expected article in the top 3.
// Each content batch adds SpotlessMacTests/Fixtures/knowledge-eval-<batch>.json.
final class KnowledgeEvalTests: XCTestCase {
    struct EvalCase: Decodable {
        let query: String
        let expected: String
    }

    static let threshold = 0.9

    private func cases() throws -> [EvalCase] {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("knowledge-eval-") && $0.hasSuffix(".json") }
            .sorted()
        var result: [EvalCase] = []
        for name in names {
            result += try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: folder.appending(path: name)))
        }
        return result
    }

    func testEvalQueriesFindTheExpectedArticleInTopThree() throws {
        let cases = try cases()
        XCTAssertFalse(cases.isEmpty)
        let (base, failures) = KnowledgeBase.build(files: try KnowledgeCorpusTests.sourceFiles)
        XCTAssertEqual(failures, [])
        var misses: [String] = []
        for test in cases {
            XCTAssertNotNil(base.article(id: test.expected), "eval expects unknown article \(test.expected)")
            let top = base.search(test.query, limit: 3).map(\.article.id)
            if !top.contains(test.expected) { misses.append("«\(test.query)» → \(test.expected), got \(top)") }
        }
        let rate = Double(cases.count - misses.count) / Double(cases.count)
        print("Knowledge eval: \(cases.count - misses.count)/\(cases.count) in top 3")
        for miss in misses { print("  miss: \(miss)") }
        XCTAssertGreaterThanOrEqual(rate, Self.threshold, misses.joined(separator: "\n"))
    }
}
