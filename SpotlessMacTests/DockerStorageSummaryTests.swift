import XCTest
@testable import SpotlessMac
final class DockerStorageSummaryTests: XCTestCase {
    func testOtherLocalProviderIsNotDockerDesktop() {
        XCTAssertFalse(DockerContextIdentity(name: "colima", endpoint: "unix:///tmp/colima.sock").isDockerDesktop)
        XCTAssertFalse(DockerContextIdentity(name: "desktop-linux", endpoint: "ssh://server").isDockerDesktop)
        let socket = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/run/docker.sock").path
        XCTAssertTrue(DockerContextIdentity(name: "desktop-linux", endpoint: "unix://" + socket).isDockerDesktop)
    }
    func testReclaimableComesFromTypedDockerRows() {
        let rows = #"{"Type":"Images","Reclaimable":"10.26GB (25%)"}"# + "\n" + #"{"Type":"Local Volumes","Reclaimable":"20.81GB (82%)"}"#
        XCTAssertEqual(DockerStorageSummary.parseReclaimable(rows), 31_070_000_000)
        XCTAssertNil(DockerStorageSummary.parseReclaimable("arbitrary localized table"))
        XCTAssertNil(DockerStorageSummary.parseReclaimable(#"{"Type":"Images","Reclaimable":"unknown"}"#))
    }
    func testNoSizeSumClaimsActualSavings() {
        let summary = DockerStorageSummary(virtualDiskAllocatedBytes: 200, engineReclaimableBytes: 100, report: nil)
        XCTAssertNil(summary.report)
        XCTAssertEqual(summary.engineReclaimableBytes, 100)
    }
}
