import XCTest
@testable import SpotlessMac
final class HuggingFaceCacheScannerTests: XCTestCase {
    func testWholeRepositoriesOnlyAndNoSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "models--org--name/blobs")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: repo.appending(path: "blob"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "models--bad--link"), withDestinationURL: URL(filePath: "/System"))
        let items = try await HuggingFaceCacheScanner(root: root).scan()
        XCTAssertEqual(items.map(\.path.lastPathComponent), ["models--org--name"])
        XCTAssertFalse(items.first!.isSelected)
        XCTAssertEqual(items.first?.cleanupPolicy.disposition, .redownload)
    }
}
