import XCTest
@testable import SpotlessMac

final class SafetyRulesTests: XCTestCase {
    func testRedirectedAppParentAfterPreviewIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let apps = home.appending(path: "Applications")
        let app = apps.appending(path: "Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let before = StorageFileIdentity.read(app)
        let moved = home.appending(path: "Moved")
        try FileManager.default.moveItem(at: apps, to: moved)
        try FileManager.default.createSymbolicLink(at: apps, withDestinationURL: moved)
        XCTAssertEqual(before, StorageFileIdentity.read(app))
        XCTAssertFalse(SafetyRules.isSafeToUninstall(url: app, appRoots: [apps], rootTrust: { PathPolicy.isUnredirected($0, below: home) }))
    }
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
