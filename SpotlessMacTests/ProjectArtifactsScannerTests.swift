import XCTest
@testable import SpotlessMac
final class ProjectArtifactsScannerTests: XCTestCase {
    func testMarkersAndGitProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let fm = FileManager.default
        for path in ["js/node_modules", "swift/.build", "ordinary/build", "protected/node_modules/.git", "unknown/vendor"] {
            let folder = root.appending(path: path)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appending(path: "blob"))
        }
        for path in ["js/package.json", "swift/Package.swift", "protected/package.json"] { try Data().write(to: root.appending(path: path)) }
        let items = try await ProjectArtifactsScanner(roots: [root]).scan()
        XCTAssertEqual(Set(items.map(\.path.lastPathComponent)), ["node_modules", ".build"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
    }
}
