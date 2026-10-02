import XCTest
@testable import SpotlessMac

final class AssistantMarkdownBlocksTests: XCTestCase {
    func testHeadingsListsAndParagraphs() {
        let blocks = AssistantMarkdownBlocks.parse("## Вердикт\nБезопасно.\n\n- кеш\n- логи\n1. шаг")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Вердикт"),
            .paragraph("Безопасно."),
            .bullet(text: "кеш", depth: 0),
            .bullet(text: "логи", depth: 0),
            .numbered(marker: "1.", text: "шаг"),
        ])
    }

    func testCodeAndTable() {
        let blocks = AssistantMarkdownBlocks.parse("```\nrm -rf\n```\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.code("rm -rf"), .table(header: ["A", "B"], rows: [["1", "2"]])])
    }
}
