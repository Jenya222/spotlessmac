import XCTest
@testable import SpotlessMac
final class LeftoverSelectionTests: XCTestCase {
    func testNestedCacheIsNotCountedOrDeletedTwice() {
        let parent = LeftoverItem(path: URL(filePath: "/tmp/fixture/data"), size: 100, location: "Application Support", confidence: .exact, isSelected: true)
        let child = LeftoverItem(path: URL(filePath: "/tmp/fixture/data/Cache"), size: 20, location: "Кэш приложения", confidence: .exact, isSelected: true)
        let result = LeftoverItem.nonOverlapping([parent, child, parent])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.size, 100)
    }
}
