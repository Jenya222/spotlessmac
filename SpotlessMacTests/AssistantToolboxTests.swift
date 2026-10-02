import XCTest
@testable import SpotlessMac

final class AssistantToolboxTests: XCTestCase {
    private let snapshot = SystemSnapshot.sample()

    private func run(_ name: String, _ arguments: String) -> ToolOutcome {
        AssistantToolbox.execute(ToolCall(id: "1", name: name, argumentsJSON: arguments), snapshot: snapshot) { $0 }
    }

    func testToolSetIsExactlyThreeReadOnlyTools() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan"])
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

    func testFormatPathIsUsed() {
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let outcome = AssistantToolbox.execute(ToolCall(id: "1", name: "list_items", argumentsJSON: "{}"), snapshot: snapshot) { redactor.redact($0) }
        XCTAssertFalse(outcome.resultText.contains("/Users/tester"))
    }
}
