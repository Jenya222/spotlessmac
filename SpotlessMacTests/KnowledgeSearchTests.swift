import XCTest
@testable import SpotlessMac

final class KnowledgeSearchTests: XCTestCase {
    func testTokensSplitIdentifiersButKeepThemWhole() {
        XCTAssertEqual(KnowledgeSearch.tokens("mds_stores"), ["mds_stores", "mds", "stores"])
        let bundle = KnowledgeSearch.tokens("com.google.Chrome")
        XCTAssertEqual(bundle.first, "com.google.chrome")
        XCTAssertTrue(bundle.contains("google"))
        XCTAssertTrue(bundle.contains("chrome"))
    }

    func testStopWordsAreDroppedAndYoIsNormalized() {
        XCTAssertEqual(KnowledgeSearch.tokens("Что это за кэш?"), ["кэш"])
        XCTAssertEqual(KnowledgeSearch.tokens("растёт"), KnowledgeSearch.tokens("растет"))
    }

    func testStemmingMergesRussianWordForms() {
        let pairs = [("кэши", "кэш"), ("памяти", "память"), ("индексация", "индексирует"), ("данных", "данные"),
                     ("обновления", "обновлений"), ("загрузки", "загрузок"), ("файлов", "файлы")]
        for (left, right) in pairs {
            XCTAssertEqual(KnowledgeSearch.stem(left), KnowledgeSearch.stem(right), "\(left) / \(right)")
        }
        XCTAssertEqual(KnowledgeSearch.stem("chrome"), "chrome")
    }

    // The noisy body repeats the identifier whole, so plain BM25 favours it; only the exact-name boost lets the target win.
    func testExactProcessNameRanksFirst() {
        let noisy = KnowledgeFixtures.article("guide.noise", title: "Шум", body: String(repeating: "mds_stores ", count: 40))
        let target = KnowledgeFixtures.article("proc.spotlight", kind: .process, title: "Spotlight", processes: ["mds_stores"])
        let hits = KnowledgeSearch(articles: [noisy, target]).search("что за mds_stores?", limit: 3)
        XCTAssertEqual(hits.first?.article.id, "proc.spotlight")
        XCTAssertGreaterThanOrEqual(hits.first?.score ?? 0, KnowledgeSearch.exactMatchBoost)
    }

    func testExactBundleIDRanksFirst() {
        let noisy = KnowledgeFixtures.article("guide.noise", title: "Шум", body: String(repeating: "com.google.Chrome ", count: 40))
        let target = KnowledgeFixtures.article("app.browser", kind: .app, title: "Браузер", bundles: ["com.google.Chrome"])
        let hits = KnowledgeSearch(articles: [noisy, target]).search("что с com.google.Chrome", limit: 3)
        XCTAssertEqual(hits.first?.article.id, "app.browser")
        XCTAssertGreaterThanOrEqual(hits.first?.score ?? 0, KnowledgeSearch.exactMatchBoost)
    }

    func testTitleOutweighsBody() {
        let titled = KnowledgeFixtures.article("guide.swap", title: "Своп и подкачка")
        let mentioned = KnowledgeFixtures.article("guide.other", title: "Другое", body: "Тут однажды упомянут своп.")
        let hits = KnowledgeSearch(articles: [mentioned, titled]).search("своп", limit: 3)
        XCTAssertEqual(hits.map(\.article.id), ["guide.swap", "guide.other"])
    }

    func testAliasesAndStemmedFormsMatch() {
        let article = KnowledgeFixtures.article("guide.ram", title: "Давление памяти", aliases: ["оперативка"])
        let search = KnowledgeSearch(articles: [article, KnowledgeFixtures.article("guide.x", title: "Диск")])
        XCTAssertEqual(search.search("оперативка занята", limit: 1).first?.article.id, "guide.ram")
        XCTAssertEqual(search.search("не хватает памяти", limit: 1).first?.article.id, "guide.ram")
    }

    // Nothing but the id mentions "kernel" or "task": the title, summary and body are Cyrillic.
    func testArticleIsFoundByTheSegmentsOfItsID() {
        let target = KnowledgeFixtures.article("proc.kernel-task", kind: .process, title: "Ядро")
        let other = KnowledgeFixtures.article("guide.swap", title: "Своп")
        let search = KnowledgeSearch(articles: [other, target])
        XCTAssertEqual(search.search("kernel task", limit: 3).map(\.article.id), ["proc.kernel-task"])
        XCTAssertEqual(search.search("proc.kernel-task", limit: 3).first?.article.id, "proc.kernel-task")
    }

    func testNoMatchEmptyQueryAndLimit() {
        let articles = (1...5).map { KnowledgeFixtures.article("guide.a\($0)", title: "Кэш номер \($0)") }
        let search = KnowledgeSearch(articles: articles)
        XCTAssertEqual(search.search("zzzz", limit: 3), [])
        XCTAssertEqual(search.search("   ", limit: 3), [])
        XCTAssertEqual(search.search("кэш", limit: 0), [])
        XCTAssertEqual(search.search("кэш", limit: 2).count, 2)
    }

    func testEmptyIndexReturnsNothing() {
        XCTAssertEqual(KnowledgeSearch(articles: []).search("кэш", limit: 3), [])
    }
}
