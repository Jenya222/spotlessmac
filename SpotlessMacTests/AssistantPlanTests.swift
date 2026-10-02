import XCTest
@testable import SpotlessMac

final class AssistantPlanTests: XCTestCase {
    private let snapshot = SystemSnapshot.sample()
    private func id(_ shortID: String) -> UUID { snapshot.item(shortID: shortID)!.itemID }

    func testResolvesIDsAndCountsUnknown() {
        let plan = PlanResolver.resolve(PlanProposal(items: ["c1", "c3", "c99", "c1"], reason: " кеши "), in: snapshot)
        XCTAssertEqual(plan.itemIDs, [id("c1"), id("c3")])
        XCTAssertEqual(plan.totalBytes, 9_800_000_000 + 1_500_000_000)
        XCTAssertEqual(plan.reason, "кеши")
        XCTAssertEqual(plan.skipped, [SkippedGroup(label: "неизвестные ID", count: 1)])
    }

    func testSkipsPersonalInspectOnlyAndListsManualItems() {
        let plan = PlanResolver.resolve(PlanProposal(items: ["c2", "c4", "c6"]), in: snapshot)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.isMeaningful)
        XCTAssertEqual(plan.skipped, [
            SkippedGroup(label: "личные данные", count: 1),
            SkippedGroup(label: "только просмотр", count: 1),
            SkippedGroup(label: "удаляются вручную по одному", count: 1),
        ])
        XCTAssertEqual(plan.manualReview.count, 1)
        XCTAssertTrue(plan.manualReview[0].hasPrefix("node_modules"))
    }

    func testFiltersByCategoryAgeAndSize() {
        let older = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "developer_caches", olderThanDays: 30)]), in: snapshot)
        XCTAssertEqual(older.itemIDs, [id("c1")])
        let recent = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "user_caches", olderThanDays: 30)]), in: snapshot)
        XCTAssertTrue(recent.itemIDs.isEmpty)
        let big = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "logs", minBytes: 1_000_000_000)]), in: snapshot)
        XCTAssertTrue(big.itemIDs.isEmpty)
    }

    func testFilterWithoutCategoryMatchesNothing() {
        let plan = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(olderThanDays: 1)]), in: snapshot)
        XCTAssertTrue(plan.itemIDs.isEmpty)
        XCTAssertFalse(plan.isMeaningful)
    }

    func testProposalDecodingIsLenient() {
        XCTAssertEqual(PlanProposal.decode(json: #"{"items":["c1"]}"#), PlanProposal(items: ["c1"]))
        XCTAssertNil(PlanProposal.decode(json: "nope"))
    }

    func testParserExtractsAndStripsBlock() {
        let text = "Можно почистить кеши.\n\n```spotless-plan\n{\"items\":[\"c1\"],\"reason\":\"r\"}\n```\n"
        let result = PlanParser.extract(from: text)
        XCTAssertEqual(result.text, "Можно почистить кеши.")
        XCTAssertEqual(result.proposal, PlanProposal(items: ["c1"], reason: "r"))
        XCTAssertFalse(result.malformed)
    }

    func testParserFlagsMalformedBlock() {
        let result = PlanParser.extract(from: "Текст\n```spotless-plan\n{broken\n```")
        XCTAssertEqual(result.text, "Текст")
        XCTAssertNil(result.proposal)
        XCTAssertTrue(result.malformed)
    }

    func testParserWithoutBlockAndUnclosedBlock() {
        XCTAssertEqual(PlanParser.extract(from: "просто текст"), .init(text: "просто текст", proposal: nil, malformed: false))
        let unclosed = PlanParser.extract(from: "A\n```spotless-plan\n{\"items\":[\"c3\"]}")
        XCTAssertEqual(unclosed.proposal, PlanProposal(items: ["c3"]))
        XCTAssertEqual(unclosed.text, "A")
    }

    func testVisibleWhileStreamingHidesPartialBlock() {
        XCTAssertEqual(PlanParser.visibleWhileStreaming("Ответ\n```spotless-plan\n{\"ite"), "Ответ")
        XCTAssertEqual(PlanParser.visibleWhileStreaming("Ответ"), "Ответ")
    }
}
