import XCTest
@testable import SpotlessMac
final class KnownCacheScannerTests: XCTestCase {
    func testOnlyExactCatalogLocationsUnselected() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for path in ["Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/User", "Library/Application Support/Claude/vm_bundles"] {
            let folder = home.appending(path: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appending(path: "blob"))
        }
        let result = try await KnownCacheScanner(home: home).scan()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.path.lastPathComponent, "Cache")
        XCTAssertFalse(result.first!.isSelected)
        XCTAssertNotNil(result.first?.identity)
    }
}
