import XCTest
@testable import SpotlessMac

final class AssistantToolboxTests: XCTestCase {
    private let snapshot = SystemSnapshot.sample()

    private func run(_ name: String, _ arguments: String) -> ToolOutcome {
        AssistantToolbox.execute(ToolCall(id: "1", name: name, argumentsJSON: arguments), snapshot: snapshot) { $0 }
    }

    func testToolSetIsExactlyFourReadOnlyTools() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan", "lookup_knowledge"])
        XCTAssertEqual(AssistantTool.specs.map(\.name), AssistantTool.names)
    }

    func testUnknownToolIsRefused() {
        let outcome = run("delete_file", #"{"path":"/Users/tester"}"#)
        XCTAssertTrue(outcome.resultText.contains("не существует"))
        XCTAssertTrue(outcome.resultText.contains("Удалять файлы"))
        XCTAssertNil(outcome.proposal)
        XCTAssertEqual(AssistantTool.parse(ToolCall(id: "1", name: "run_shell", argumentsJSON: "{}")), .failure(.unknownTool("run_shell")))
    }

    func testListItemsFiltersByCategory() {
        let outcome = run("list_items", #"{"category":"logs"}"#)
        XCTAssertTrue(outcome.resultText.contains("c5 |"))
        XCTAssertFalse(outcome.resultText.contains("c1 |"))
    }

    func testListItemsByAgeAndLimit() {
        let old = run("list_items", #"{"olderThanDays":60}"#)
        XCTAssertTrue(old.resultText.contains("c2 |"))
        XCTAssertTrue(old.resultText.contains("c6 |"))
        XCTAssertFalse(old.resultText.contains("c1 |"))
        let limited = run("list_items", #"{"limit":1}"#)
        XCTAssertTrue(limited.resultText.contains("показано 1"))
    }

    func testListItemsRejectsUnknownCategory() {
        XCTAssertTrue(run("list_items", #"{"category":"system"}"#).resultText.contains("Ошибка"))
    }

    func testItemDetails() {
        XCTAssertTrue(run("item_details", #"{"id":"c1"}"#).resultText.contains("Политика: rebuildable"))
        XCTAssertTrue(run("item_details", #"{"id":"c42"}"#).resultText.contains("не найден"))
        XCTAssertTrue(run("item_details", "[]").resultText.contains("Ошибка"))
    }

    func testProposePlanReturnsProposalAndDeletesNothing() {
        let outcome = run("propose_plan", #"{"items":["c1","c3"],"reason":"кеши"}"#)
        XCTAssertEqual(outcome.proposal, PlanProposal(items: ["c1", "c3"], reason: "кеши"))
        XCTAssertTrue(outcome.resultText.contains("Ничего не удалено"))
        XCTAssertTrue(outcome.resultText.contains("2 элементов"))
    }

    func testEmptyPlanIsReportedHonestly() {
        let outcome = run("propose_plan", #"{"filters":[{"category":"logs","olderThanDays":3650}],"reason":"старые логи"}"#)
        XCTAssertNil(outcome.proposal)
        XCTAssertTrue(outcome.resultText.contains("План пуст"))
        XCTAssertFalse(outcome.resultText.contains("показан пользователю"))
    }

    func testProposePlanReportsSkippedGroups() {
        let outcome = run("propose_plan", #"{"items":["c1","c4","c99"],"reason":"проверка"}"#)
        XCTAssertNotNil(outcome.proposal)
        XCTAssertTrue(outcome.resultText.contains("1 элементов"))
        XCTAssertTrue(outcome.resultText.contains("Пропущено:"))
        XCTAssertTrue(outcome.resultText.contains("личные данные — 1"))
        XCTAssertTrue(outcome.resultText.contains("неизвестные ID — 1"))
    }

    func testProposePlanReportsManualReviewCountOnly() {
        let outcome = run("propose_plan", #"{"items":["c2"],"reason":"зависимости"}"#)
        XCTAssertNotNil(outcome.proposal)
        XCTAssertTrue(outcome.resultText.contains("Удалять вручную: 1."))
        XCTAssertFalse(outcome.resultText.contains("node_modules"))
        XCTAssertFalse(outcome.resultText.contains("secret-client"))
    }

    func testCleanPlanHasNoSkippedSuffix() {
        let outcome = run("propose_plan", #"{"items":["c1","c3"],"reason":"кеши"}"#)
        XCTAssertFalse(outcome.resultText.contains("Пропущено"))
        XCTAssertFalse(outcome.resultText.contains("Удалять вручную"))
    }

    func testListItemsRejectsMistypedArguments() {
        XCTAssertTrue(run("list_items", #"{"olderThanDays":"60"}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"minBytes":"1000"}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"limit":true}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"olderThanDays":false}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"category":5}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"olderThanDays":-1}"#).resultText.contains("Ошибка"))
        XCTAssertTrue(run("list_items", #"{"minBytes":-5}"#).resultText.contains("Ошибка"))
    }

    func testListItemsParseErrorsNameTheKey() {
        let call = ToolCall(id: "1", name: "list_items", argumentsJSON: #"{"olderThanDays":"60"}"#)
        XCTAssertEqual(AssistantTool.parse(call), .failure(.invalidArguments("olderThanDays должно быть числом")))
        let category = ToolCall(id: "1", name: "list_items", argumentsJSON: #"{"category":5}"#)
        XCTAssertEqual(AssistantTool.parse(category), .failure(.invalidArguments("category должно быть строкой")))
    }

    func testListItemsAcceptsNumbersAndExplicitNull() {
        let call = ToolCall(id: "1", name: "list_items", argumentsJSON: #"{"category":null,"olderThanDays":60,"minBytes":0,"limit":5}"#)
        XCTAssertEqual(AssistantTool.parse(call), .success(.listItems(category: nil, minBytes: 0, olderThanDays: 60, limit: 5)))
    }

    func testListItemsHeaderEchoesAppliedFilters() {
        let logs = run("list_items", #"{"category":"logs"}"#).resultText
        XCTAssertTrue(logs.contains("(категория: logs)"))
        XCTAssertFalse(logs.contains("старше"))
        let all = run("list_items", #"{"category":"developer_caches","olderThanDays":30,"minBytes":1000000000}"#).resultText
        XCTAssertTrue(all.contains("категория: developer_caches; старше 30 дн.; от \(SnapshotRenderer.bytes(1_000_000_000))"))
        let unfiltered = run("list_items", "{}").resultText
        XCTAssertFalse(unfiltered.contains("категория:"))
        XCTAssertFalse(unfiltered.contains("старше"))
    }

    func testFormatPathIsUsed() {
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let outcome = AssistantToolbox.execute(ToolCall(id: "1", name: "list_items", argumentsJSON: "{}"), snapshot: snapshot) { redactor.redact($0) }
        XCTAssertFalse(outcome.resultText.contains("/Users/tester"))
    }

    private func knowledge() -> KnowledgeContext {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("guide.swap", title: "Своп и подкачка", summary: "Файл подкачки."),
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, title: "DerivedData", verdict: .safe),
        ])
        return KnowledgeContext(base: base, annotations: KnowledgeAnnotations(items: ["c1": "path.xcode-deriveddata"]))
    }

    private func lookup(_ arguments: String) -> String {
        AssistantToolbox.execute(ToolCall(id: "k", name: "lookup_knowledge", argumentsJSON: arguments),
                                 snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
    }

    func testLookupKnowledgeByID() {
        XCTAssertTrue(lookup(#"{"id":"guide.swap"}"#).hasPrefix("[guide.swap] Своп и подкачка"))
    }

    func testLookupKnowledgeByQuery() {
        XCTAssertTrue(lookup(#"{"query":"что такое своп"}"#).contains("[guide.swap]"))
    }

    func testLookupKnowledgeRejectsBadArguments() {
        XCTAssertEqual(lookup("{}"), "Ошибка в аргументах lookup_knowledge: нужен id или query.")
        XCTAssertEqual(lookup(#"{"id":"  ","query":null}"#), "Ошибка в аргументах lookup_knowledge: нужен id или query.")
        XCTAssertEqual(lookup(#"{"id":5}"#), "Ошибка в аргументах lookup_knowledge: id должно быть строкой.")
        XCTAssertEqual(lookup(#"{"query":true}"#), "Ошибка в аргументах lookup_knowledge: query должно быть строкой.")
        XCTAssertEqual(lookup("[]"), "Ошибка в аргументах lookup_knowledge: аргументы должны быть JSON-объектом.")
    }

    func testLookupKnowledgeUnknownIDAndNoHits() {
        XCTAssertTrue(lookup(#"{"id":"guide.nope"}"#).hasPrefix("Статья guide.nope не найдена."))
        XCTAssertEqual(lookup(#"{"query":"zzzz"}"#),
                       "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет.")
    }

    func testLookupKnowledgeNeverProposesAPlan() {
        let outcome = AssistantToolbox.execute(ToolCall(id: "k", name: "lookup_knowledge", argumentsJSON: #"{"query":"своп"}"#),
                                               snapshot: .sample(), knowledge: knowledge()) { $0 }
        XCTAssertNil(outcome.proposal)
    }

    func testListItemsAndDetailsShowTheArticle() {
        let list = AssistantToolbox.execute(ToolCall(id: "l", name: "list_items", argumentsJSON: #"{"category":"developer_caches"}"#),
                                            snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
        XCTAssertTrue(list.contains("Колонки: \(SnapshotRenderer.itemColumns):"))
        XCTAssertTrue(list.contains("| path.xcode-deriveddata"))
        let card = AssistantToolbox.execute(ToolCall(id: "d", name: "item_details", argumentsJSON: #"{"id":"c1"}"#),
                                            snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
        XCTAssertTrue(card.contains("Справка: path.xcode-deriveddata"))
    }

    func testUnknownToolListsAllFourTools() {
        let text = AssistantToolbox.execute(ToolCall(id: "x", name: "rm", argumentsJSON: "{}"), snapshot: .sample()) { $0 }.resultText
        XCTAssertTrue(text.contains("list_items, item_details, propose_plan и lookup_knowledge"))
    }
}
