import Foundation
@testable import SpotlessMac

enum KnowledgeFixtures {
    static let body = """
    ## Что это
    Образец статьи для тестов.

    ## Что делать
    Ничего не делать.
    """

    static func article(
        _ id: String, kind: KnowledgeKind = .guide, title: String? = nil, summary: String = "Кратко.",
        verdict: KnowledgeVerdict = .info, aliases: [String] = [], keywords: [String] = [],
        processes: [String] = [], bundles: [String] = [], paths: [String] = [],
        categories: [ScanCategory] = [], related: [String] = [], body: String = body
    ) -> KnowledgeArticle {
        KnowledgeArticle(
            id: id, kind: kind, title: title ?? id, summary: summary, verdict: verdict,
            aliases: aliases, keywords: keywords, processes: processes, bundles: bundles, paths: paths,
            categories: categories, related: related, macOS: nil, reviewed: "2026-10-03", sources: [], body: body
        )
    }

    static func base(_ articles: [KnowledgeArticle]) -> KnowledgeBase {
        KnowledgeBase(articles: articles)
    }
}
