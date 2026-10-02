import XCTest
@testable import SpotlessMac

final class SnapshotRendererTests: XCTestCase {
    func testRendersDiskCategoriesAndItems() {
        let text = SnapshotRenderer.render(.sample()) { $0 }
        XCTAssertTrue(text.contains("«Macintosh HD»"))
        XCTAssertTrue(text.contains("свободно"))
        XCTAssertTrue(text.contains("Полный доступ к диску: есть"))
        XCTAssertTrue(text.contains("developer_caches"))
        XCTAssertTrue(text.contains("c1 | /Users/tester/Library/Developer/Xcode/DerivedData |"))
        XCTAssertTrue(text.contains("| rebuildable |"))
        XCTAssertTrue(text.contains("Docker"))
    }

    func testFormatPathIsAppliedToEveryPath() {
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let text = SnapshotRenderer.render(.sample()) { redactor.redact($0) }
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertFalse(text.contains("secret-client"))
        XCTAssertTrue(text.contains("~/Projects/<папка-1>/node_modules"))
    }

    func testNoScanMessage() {
        let snapshot = SystemSnapshot(takenAt: SystemSnapshot.testDate)
        let text = SnapshotRenderer.render(snapshot) { $0 }
        XCTAssertTrue(text.contains("ещё не проводилось"))
        XCTAssertTrue(text.contains("данные о томе недоступны"))
    }

    // Review focus 2: huge scans stay within budget.
    func testLargeSnapshotStaysWithinBudget() {
        var snapshot = SystemSnapshot.sample()
        snapshot.items = (1...5_000).map { n in
            SnapshotItem(shortID: "c\(n)", itemID: UUID(), path: "/Users/tester/Library/Caches/" + String(repeating: "x", count: 180) + "\(n)",
                         bytes: Int64(10_000 - n), category: .userCaches, disposition: .rebuildable, reason: "r", modifiedAt: nil, owner: nil)
        }
        let text = SnapshotRenderer.render(snapshot) { $0 }
        XCTAssertLessThanOrEqual(text.count, SnapshotRenderer.maxCharacters)
        XCTAssertTrue(text.contains("из 5000"))
        XCTAssertTrue(text.contains("list_items"))
    }

    func testRendersMemory() {
        let text = SnapshotRenderer.render(.sample()) { $0 }
        XCTAssertTrue(text.contains("Память: давление нормальное"))
        XCTAssertTrue(text.contains("Xcode —"))
        var noMemory = SystemSnapshot.sample()
        noMemory.memory = nil
        XCTAssertTrue(SnapshotRenderer.render(noMemory) { $0 }.contains("Память: данные не получены"))
    }

    func testItemCard() {
        let item = SystemSnapshot.sample().items[3]
        let card = SnapshotRenderer.itemCard(item) { $0 }
        XCTAssertTrue(card.contains("ID: c4"))
        XCTAssertTrue(card.contains("Политика: personalData"))
        XCTAssertTrue(card.contains("Пакетная очистка: нет"))
    }

    func testPromptVariants() {
        let fallback = AssistantPrompt.system(toolsEnabled: false)
        XCTAssertTrue(fallback.contains("```spotless-plan"))
        XCTAssertTrue(fallback.contains("не можешь ничего удалить"))
        XCTAssertTrue(fallback.contains("вкладке «Память»"))
        let tools = AssistantPrompt.system(toolsEnabled: true)
        XCTAssertTrue(tools.contains("propose_plan"))
        XCTAssertFalse(tools.contains("```spotless-plan"))
        for category in ScanCategory.allCases {
            XCTAssertTrue(tools.contains(category.rawValue), category.rawValue)
        }
    }
}
