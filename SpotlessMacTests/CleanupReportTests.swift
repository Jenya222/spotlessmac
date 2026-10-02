import XCTest
@testable import SpotlessMac
final class CleanupReportTests: XCTestCase {
    func testTrashDoesNotImplyFreeSpace() {
        let before = VolumeSample(volumeID: "data", availableBytes: 100, sampledAt: .distantPast)
        let after = VolumeSample(volumeID: "data", availableBytes: 100, sampledAt: .distantFuture)
        let report = CleanupReport(trashedBytes: 800, successfulItems: 1, before: before, after: after)
        XCTAssertEqual(report.observedFreeSpaceDelta, 0)
        XCTAssertEqual(report.trashedBytes, 800)
    }
    func testIncomparableAndMissingVolumes() {
        let a = VolumeSample(volumeID: "a", availableBytes: 100, sampledAt: .distantPast)
        let b = VolumeSample(volumeID: "b", availableBytes: 200, sampledAt: .distantFuture)
        XCTAssertNil(CleanupReport(trashedBytes: 1, successfulItems: 1, before: a, after: b).observedFreeSpaceDelta)
        XCTAssertNil(CleanupReport(trashedBytes: 1, successfulItems: 1, before: nil, after: b).observedFreeSpaceDelta)
    }
    func testOtherWritesCanReduceFreeSpace() {
        let a = VolumeSample(volumeID: "a", availableBytes: 200, sampledAt: .distantPast)
        let b = VolumeSample(volumeID: "a", availableBytes: 100, sampledAt: .distantFuture)
        XCTAssertEqual(CleanupReport(trashedBytes: 50, successfulItems: 1, before: a, after: b).observedFreeSpaceDelta, -100)
    }
}
