import XCTest
@testable import SpotlessMac
final class StorageRootRegistryTests: XCTestCase {
    func testOverlappingSourceRootsAreShownOnce() {
        let parent = StorageSource(url: URL(filePath: "/tmp/fixtures/projects"), title: "Projects", explanation: "")
        let child = StorageSource(url: parent.url.appending(path: "child"), title: "HF", explanation: "")
        let result = StorageSourceCatalog.nonOverlapping([child, parent, parent])
        XCTAssertEqual(result.map(\.id), [parent.id])
    }
    func testRejectsWholeDiskAndHome() {
        XCTAssertFalse(StorageRootRegistry.isAdmissible(URL(filePath: "/")))
        XCTAssertFalse(StorageRootRegistry.isAdmissible(FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertFalse(StorageRootRegistry.isAdmissible(URL(filePath: "/System/Library")))
    }
    func testCanonicalRootIsPersistedOnlyAfterExplicitRegistration() throws {
        let suite = UserDefaults(suiteName: "spotless-fixture-" + UUID().uuidString)!
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StorageRootRegistry.register(root, kind: .projects, store: suite)
        XCTAssertEqual(StorageRootRegistry.roots(kind: .projects, store: suite).map(PathPolicy.canonical), [PathPolicy.canonical(root)])
        XCTAssertTrue(StorageRootRegistry.roots(kind: .huggingFace, store: suite).isEmpty)
    }
}
