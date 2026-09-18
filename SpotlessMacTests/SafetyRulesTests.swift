import XCTest
@testable import SpotlessMac

final class SafetyRulesTests: XCTestCase {
    func testCleanerRejectsSiblingWhoseNameSharesAllowedPrefix() {
        let root = SafetyRules.allowedRoots[0]
        let sibling = root.deletingLastPathComponent()
            .appending(path: root.lastPathComponent + "-not-allowed/file")

        XCTAssertFalse(SafetyRules.isSafe(url: sibling))
    }

    func testCleanerAllowsChildrenOfDeveloperCacheRootsOnly() {
        let root = SafetyRules.developerCacheRoots[0]
        let child = root.appending(path: "Project/Build/output.o")
        let sibling = root.deletingLastPathComponent()
            .appending(path: root.lastPathComponent + "-backup/output.o")

        XCTAssertTrue(SafetyRules.isSafe(url: child))
        XCTAssertFalse(SafetyRules.isSafe(url: sibling))
    }

    func testBatchDeleteReportsUnsafePathAsFailure() async {
        let item = ScanItem(path: URL(filePath: "/System/unsafe"), size: 1, category: .userCaches)

        let failures = await ScanEngine().delete(items: [item])

        XCTAssertEqual(failures.map(\.item.id), [item.id])
    }

    func testUninstallReportsUnsafePathAsFailure() async {
        let item = LeftoverItem(
            path: URL(filePath: "/System/unsafe.app"),
            size: 1,
            location: "Программа",
            confidence: .exact,
            isSelected: true
        )

        let failures = await UninstallEngine().uninstall(items: [item])

        XCTAssertEqual(failures.map(\.item.id), [item.id])
    }
}
