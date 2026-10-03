import XCTest
@testable import SpotlessMac

final class KnowledgeBaseTests: XCTestCase {
    private func text(_ id: String, kind: String = "guide", verdict: String = "info") -> String {
        "---\nid: \(id)\nkind: \(kind)\ntitle: \(id)\nsummary: Кратко.\nverdict: \(verdict)\nreviewed: 2026-10-03\n---\n"
            + KnowledgeFixtures.body
    }

    func testBuildSortsByIDAndLooksUp() {
        let (base, failures) = KnowledgeBase.build(files: [("guide.b.md", text("guide.b")), ("guide.a.md", text("guide.a"))])
        XCTAssertEqual(failures, [])
        XCTAssertEqual(base.articles.map(\.id), ["guide.a", "guide.b"])
        XCTAssertEqual(base.article(id: "guide.b")?.id, "guide.b")
        XCTAssertNil(base.article(id: "guide.c"))
        XCTAssertFalse(base.isEmpty)
    }

    func testBuildSkipsBrokenFilesAndKeepsTheRest() {
        let (base, failures) = KnowledgeBase.build(files: [
            ("guide.a.md", text("guide.a")),
            ("guide.broken.md", "no front matter"),
            ("guide.dup.md", text("guide.a")),
        ])
        XCTAssertEqual(base.articles.map(\.id), ["guide.a"])
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.contains { $0.hasPrefix("guide.broken.md:") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("guide.dup.md:") })
    }

    func testEmptyBase() {
        XCTAssertTrue(KnowledgeBase.empty.isEmpty)
        XCTAssertEqual(KnowledgeBase.empty.search("кэш", limit: 3), [])
    }

    func testSearchGoesThroughTheIndex() {
        let base = KnowledgeFixtures.base([KnowledgeFixtures.article("guide.swap", title: "Своп")])
        XCTAssertEqual(base.search("своп", limit: 3).map(\.article.id), ["guide.swap"])
    }
}
