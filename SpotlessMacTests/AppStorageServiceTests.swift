import XCTest
@testable import SpotlessMac
final class AppStorageServiceTests: XCTestCase {
    func testRedirectedInventoryRootIsNotMeasured() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let outside = root.appending(path: "outside")
        let caches = root.appending(path: "home/Caches")
        try FileManager.default.createDirectory(at: outside.appending(path: "com.example.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: outside)
        let app = InstalledApp(name: "Example", bundleURL: root.appending(path: "Example.app"), bundleID: "com.example.app")
        let service = AppStorageService(roots: [caches], rootTrust: { PathPolicy.isUnredirected($0, below: caches.deletingLastPathComponent()) }, measure: { url in
            XCTAssertEqual(url, app.bundleURL)
            return StorageMeasurement(logicalBytes: 100, allocatedBytes: 100)
        })
        let result = try await service.summary(for: app)
        XCTAssertEqual(result.cacheBytes, 0)
        XCTAssertFalse(result.isComplete)
    }
    func testExactOwnershipAndNoSharedGroupContainer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for path in ["Caches/com.example.app", "Application Support/com.example.app", "Application Support/com.example.app-other", "Group Containers/TEAM.com.example.app"] {
            try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        let app = InstalledApp(name: "Example", bundleURL: root.appending(path: "Example.app"), bundleID: "com.example.app")
        let service = AppStorageService(roots: ["Caches", "Application Support", "Group Containers"].map { root.appending(path: $0) }, measure: { _ in StorageMeasurement(logicalBytes: 100, allocatedBytes: 100) })
        let result = try await service.summary(for: app)
        XCTAssertEqual(result.bundleBytes, 100)
        XCTAssertEqual(result.cacheBytes, 100)
        XCTAssertEqual(result.dataBytes, 100)
        XCTAssertEqual(result.confirmedTotalBytes, 300)
        XCTAssertTrue(result.isComplete)
    }
    func testMeasurementFailureDoesNotBecomeKnownZero() async throws {
        let app = InstalledApp(name: "Missing", bundleURL: URL(filePath: "/tmp/missing.app"), bundleID: nil)
        let service = AppStorageService(roots: [], measure: { _ in throw CocoaError(.fileReadNoPermission) })
        let result = try await service.summary(for: app)
        XCTAssertFalse(result.isComplete)
    }
}
