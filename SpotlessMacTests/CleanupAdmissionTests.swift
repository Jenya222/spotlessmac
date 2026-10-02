import XCTest
@testable import SpotlessMac
private final class TrashSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
final class CleanupAdmissionTests: XCTestCase {
    func testInspectOnlyRequestReturnsFailure() async {
        let spy = TrashSpy()
        let item = ScanItem(path: URL(filePath: "/tmp/fixture"), size: 1, category: .knownAppCaches,
            cleanupPolicy: .init(disposition: .inspectOnly, reason: "Read only", requiresClosedOwner: false))
        let engine = ScanEngine(validate: { _ in nil }, trash: { _ in spy.record() })
        let failures = await engine.delete(items: [item])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(spy.count, 0)
    }
    func testUninstallerBlocksKnownCacheAndContainingDirectoryForActiveOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = root.appending(path: "Cursor/Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for path in [cache, cache.deletingLastPathComponent()] {
            for activity in [OwnerActivity.running, .unknown] {
                let spy = TrashSpy()
                let engine = UninstallEngine(cacheLocations: [.init(url: cache, owner: "Cursor")],
                    activity: { _ in activity }, validate: { _ in nil }, trash: { _ in spy.record() })
                let item = LeftoverItem(path: path, size: 1, location: "Caches", confidence: .exact, isSelected: true)
                let failures = await engine.uninstall(items: [item])
                XCTAssertEqual(failures.count, 1)
                XCTAssertEqual(spy.count, 0)
            }
        }
    }

    func testOverlappingCandidatesCallTrashOnce() async {
        let spy = TrashSpy()
        let parent = ScanItem(path: URL(filePath: "/tmp/fixture/parent"), size: 100, category: .userCaches)
        let child = ScanItem(path: URL(filePath: "/tmp/fixture/parent/child"), size: 20, category: .userCaches)
        let engine = ScanEngine(validate: { _ in nil }, trash: { _ in spy.record() })
        let failures = await engine.delete(items: [parent, child])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(spy.count, 1)
    }

    func testUnknownOrRunningOwnerBlocksTrash() async {
        for activity in [OwnerActivity.unknown, .running] {
            let spy = TrashSpy()
            let item = ScanItem(path: URL(filePath: "/tmp/fixture"), size: 1, category: .modelCaches,
                cleanupPolicy: .init(disposition: .redownload, reason: "Model", requiresClosedOwner: true))
            let engine = ScanEngine(activity: { _ in activity }, validate: { _ in nil }, trash: { _ in spy.record() })
            let failures = await engine.delete(items: [item])
            XCTAssertEqual(failures.count, 1); XCTAssertEqual(spy.count, 0)
        }
    }
    func testChangedObjectAndSymlinkBlockTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "blob")
        try Data([1]).write(to: file)
        let item = ScanItem(path: file, size: 1, category: .knownAppCaches,
            cleanupPolicy: .init(disposition: .rebuildable, reason: "Cache", requiresClosedOwner: true))
        try FileManager.default.moveItem(at: file, to: root.appending(path: "original"))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(filePath: "/System"))
        let spy = TrashSpy()
        let policy = PathPolicy(readRoots: [root])
        let engine = ScanEngine(activity: { _ in .closed }, validate: { CleanupPlanBuilder.validationFailure(for: $0, allowsPath: policy.canRead) }, trash: { _ in spy.record() })
        let failures = await engine.delete(items: [item])
        XCTAssertEqual(failures.count, 1); XCTAssertEqual(spy.count, 0)
    }
    func testConfirmedClosedOwnerCallsOnlyFakeTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "blob"); try Data([1]).write(to: file)
        let item = ScanItem(path: file, size: 1, category: .knownAppCaches,
            cleanupPolicy: .init(disposition: .rebuildable, reason: "Cache", requiresClosedOwner: true))
        let spy = TrashSpy(); let policy = PathPolicy(readRoots: [root])
        let engine = ScanEngine(activity: { _ in .closed }, validate: { CleanupPlanBuilder.validationFailure(for: $0, allowsPath: policy.canRead) }, trash: { _ in spy.record() })
        let failures = await engine.delete(items: [item])
        XCTAssertTrue(failures.isEmpty); XCTAssertEqual(spy.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
