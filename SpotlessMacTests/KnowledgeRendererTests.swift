import XCTest
@testable import SpotlessMac

final class KnowledgeRendererTests: XCTestCase {
    private let swap = KnowledgeFixtures.article("guide.swap", title: "Своп", summary: "Файл подкачки.",
                                                 related: ["guide.memory"])
    private let memory = KnowledgeFixtures.article("guide.memory", title: "Давление памяти", summary: "Как читать.")

    func testArticleText() {
        let text = KnowledgeRenderer.article(swap)
        XCTAssertTrue(text.hasPrefix("[guide.swap] Своп\nВердикт: справка\nКратко: Файл подкачки.\n## Что это"))
        XCTAssertTrue(text.hasSuffix("См. также: guide.memory"))
    }

    func testArticleIsTruncated() {
        let long = KnowledgeFixtures.article("guide.long", body: String(repeating: "а", count: 5_000))
        let text = KnowledgeRenderer.article(long)
        XCTAssertEqual(text.count, KnowledgeRenderer.articleLimit)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testLookupByIDAndQuery() {
        let base = KnowledgeFixtures.base([swap, memory])
        XCTAssertTrue(KnowledgeRenderer.lookup(id: "guide.swap", query: nil, in: base).hasPrefix("[guide.swap]"))
        let byQuery = KnowledgeRenderer.lookup(id: nil, query: "давление памяти", in: base)
        XCTAssertTrue(byQuery.hasPrefix("Найдено в справке: "))
        XCTAssertTrue(byQuery.contains("[guide.memory]"))
    }

    func testLookupUnknownIDSuggestsSimilar() {
        let base = KnowledgeFixtures.base([swap, memory])
        let text = KnowledgeRenderer.lookup(id: "guide.memory-pressure", query: nil, in: base)
        XCTAssertTrue(text.hasPrefix("Статья guide.memory-pressure не найдена. Похожие статьи: guide.memory — Давление памяти"))
    }

    func testLookupWithNothingFound() {
        let text = KnowledgeRenderer.lookup(id: nil, query: "zzzz", in: KnowledgeFixtures.base([swap]))
        XCTAssertEqual(text, "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет.")
    }

    func testLookupResultIsCapped() {
        let big = (1...3).map { KnowledgeFixtures.article("guide.big\($0)", title: "Кэш \($0)", body: String(repeating: "кэш ", count: 900)) }
        let text = KnowledgeRenderer.lookup(id: nil, query: "кэш", in: KnowledgeFixtures.base(big))
        XCTAssertLessThanOrEqual(text.count, KnowledgeRenderer.lookupLimit)
        XCTAssertTrue(text.contains("[guide.big1]"))
        // The header counts the articles that fit under the cap, not every hit.
        let included = text.components(separatedBy: "[guide.big").count - 1
        let header = text.dropFirst("Найдено в справке: ".count).prefix { $0.isNumber }
        XCTAssertLessThan(included, big.count)
        XCTAssertEqual(Int(header), included)
    }

    func testInjectedReference() {
        let base = KnowledgeFixtures.base([swap, memory])
        let text = KnowledgeRenderer.injected(for: "что такое своп", in: base)
        XCTAssertTrue(text?.hasPrefix("Справка SpotlessMac по вопросу:\n\n[guide.swap]") == true)
        XCTAssertNil(KnowledgeRenderer.injected(for: "zzzz", in: base))
        XCTAssertLessThanOrEqual(text?.count ?? 0, KnowledgeRenderer.injectedLimit)
    }

    func testSectionOrdersByCoveredBytesAndDeduplicates() {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.derived", kind: .path, summary: "Сборки.", verdict: .safe),
            KnowledgeFixtures.article("path.caches", kind: .path, summary: "Кэши.", verdict: .safe),
        ])
        let annotations = KnowledgeAnnotations(items: ["c1": "path.derived", "c3": "path.caches", "c5": "path.caches"])
        let text = KnowledgeRenderer.section(.sample(), context: KnowledgeContext(base: base, annotations: annotations))
        XCTAssertEqual(text, """
        Справка SpotlessMac по найденному (id — вердикт — кратко):
        - path.derived — безопасно — Сборки.
        - path.caches — безопасно — Кэши.
        """)
    }

    func testSectionIsCappedAndEmptyWithoutMatches() {
        XCTAssertNil(KnowledgeRenderer.section(.sample(), context: .none))
        let articles = (1...20).map {
            KnowledgeFixtures.article("guide.n\($0)", summary: String(repeating: "с", count: 150))
        }
        var items: [String: String] = [:]
        var snapshot = SystemSnapshot.sample()
        snapshot.items = (1...20).map { n in
            SnapshotItem(shortID: "c\(n)", itemID: UUID(), path: "/x/\(n)", bytes: Int64(100 - n), category: .userCaches,
                         disposition: .rebuildable, reason: "r", modifiedAt: nil, owner: nil)
        }
        for n in 1...20 { items["c\(n)"] = "guide.n\(n)" }
        let text = KnowledgeRenderer.section(snapshot, context: KnowledgeContext(base: KnowledgeFixtures.base(articles),
                                                                                  annotations: KnowledgeAnnotations(items: items)))
        let lines = text?.components(separatedBy: "\n") ?? []
        XCTAssertLessThanOrEqual(lines.count - 1, KnowledgeRenderer.sectionEntries)
        XCTAssertLessThanOrEqual(text?.count ?? 0, KnowledgeRenderer.sectionLimit)
    }
}
