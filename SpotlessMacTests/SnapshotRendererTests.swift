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

    // A huge scan is truncated to the character budget and points to list_items.
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

    // The reason line can embed a project folder name (ProjectArtifactsScanner), so it goes through formatPath too.
    func testItemCardRedactsFolderNameInReason() {
        let item = SnapshotItem(
            shortID: "c7", itemID: UUID(), path: "/Users/tester/Projects/secret-client/node_modules",
            bytes: 3_200_000_000, category: .projectArtifacts, disposition: .rebuildable,
            reason: "Зависимости или сборка проекта secret-client. Потребуется переустановка.",
            modifiedAt: nil, owner: nil
        )
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let card = SnapshotRenderer.itemCard(item) { s in
            s.hasPrefix(SystemSnapshot.testHome) ? redactor.redact(s) : redactor.redactText(s)
        }
        XCTAssertFalse(card.contains("secret-client"))
        let lines = card.components(separatedBy: "\n")
        XCTAssertTrue(lines.first { $0.hasPrefix("Путь:") }?.contains("<папка-1>") == true)
        XCTAssertTrue(lines.first { $0.hasPrefix("Причина:") }?.contains("<папка-1>") == true)
    }

    func testPromptVariants() {
        let fallback = AssistantPrompt.system(toolsEnabled: false)
        XCTAssertTrue(fallback.contains("```spotless-plan"))
        XCTAssertTrue(fallback.contains("не можешь ничего удалить"))
        XCTAssertTrue(fallback.contains("вкладке «Память»"))
        let tools = AssistantPrompt.system(toolsEnabled: true)
        XCTAssertTrue(tools.contains("propose_plan"))
        XCTAssertTrue(tools.contains("lookup_knowledge"))
        // The tool does not exist in tools-off mode, so no part of that prompt may name it.
        XCTAssertFalse(fallback.contains("lookup_knowledge"))
        XCTAssertTrue(fallback.contains("Справка SpotlessMac"))
        XCTAssertTrue(fallback.contains("Политика элемента в снимке"))
        XCTAssertTrue(fallback.contains("организации файлов"))
        XCTAssertFalse(tools.contains("```spotless-plan"))
        for category in ScanCategory.allCases {
            XCTAssertTrue(tools.contains(category.rawValue), category.rawValue)
        }
    }

    private func knowledgeContext() -> KnowledgeContext {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, summary: "Сборки Xcode.", verdict: .safe),
            KnowledgeFixtures.article("app.xcode", kind: .app, summary: "Xcode.", verdict: .caution),
            KnowledgeFixtures.article("proc.kernel-task", kind: .process, summary: "Ядро.", verdict: .keep),
        ])
        return KnowledgeContext(base: base, annotations: KnowledgeAnnotations(
            items: ["c1": "path.xcode-deriveddata"], apps: ["Xcode": "app.xcode"], processes: ["kernel_task": "proc.kernel-task"]))
    }

    func testItemLinesCarryTheArticleColumn() {
        let text = SnapshotRenderer.render(.sample(), knowledge: knowledgeContext()) { $0 }
        XCTAssertTrue(text.contains("(ID | путь | размер | категория | политика | изменён | владелец | справка):"))
        let c1 = text.components(separatedBy: "\n").first { $0.hasPrefix("c1 |") } ?? ""
        XCTAssertTrue(c1.hasSuffix("| path.xcode-deriveddata"), c1)
        let c2 = text.components(separatedBy: "\n").first { $0.hasPrefix("c2 |") } ?? ""
        XCTAssertTrue(c2.hasSuffix("| —"), c2)
    }

    func testMemoryLinesCarryArticleIDsAndTopProcesses() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory?.topProcesses = [MemoryProcessInfo(name: "kernel_task", bytes: 2_000_000_000),
                                         MemoryProcessInfo(name: "node", bytes: 1_000_000_000)]
        let text = SnapshotRenderer.render(snapshot, knowledge: knowledgeContext()) { $0 }
        XCTAssertTrue(text.contains("Xcode — \(SnapshotRenderer.memoryBytes(4_000_000_000)) [app.xcode]"))
        XCTAssertTrue(text.contains("Крупные процессы вне программ: kernel_task — \(SnapshotRenderer.memoryBytes(2_000_000_000)) [proc.kernel-task], node — "))
        XCTAssertTrue(text.contains("Справка SpotlessMac по найденному"))
        XCTAssertTrue(text.contains("- path.xcode-deriveddata — безопасно — Сборки Xcode."))
    }

    func testTopProcessNamesAreFormatted() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory?.topProcesses = [MemoryProcessInfo(name: "secret-client-worker", bytes: 1)]
        let text = SnapshotRenderer.render(snapshot) { $0.replacingOccurrences(of: "secret-client", with: "<папка-1>") }
        XCTAssertFalse(text.contains("secret-client"))
        XCTAssertTrue(text.contains("<папка-1>-worker"))
    }

    func testItemCardShowsTheArticle() {
        let card = SnapshotRenderer.itemCard(SystemSnapshot.sample().items[0], articleID: "path.xcode-deriveddata") { $0 }
        XCTAssertTrue(card.hasSuffix("Справка: path.xcode-deriveddata"))
        XCTAssertFalse(SnapshotRenderer.itemCard(SystemSnapshot.sample().items[0]) { $0 }.contains("Справка:"))
    }
}
