import XCTest
@testable import SpotlessMac
final class StorageAnalysisEngineTests: XCTestCase {
    func testHiddenFilesHardLinksAndSymlinkEscape() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root.appending(path: ".hidden"), withIntermediateDirectories: true)
        let blob = root.appending(path: ".hidden/blob")
        try Data(repeating: 1, count: 8192).write(to: blob)
        try fm.linkItem(at: blob, to: root.appending(path: "hard-link"))
        try fm.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: URL(filePath: "/System"))
        let engine = StorageAnalysisEngine(policy: PathPolicy(readRoots: [root]))
        let result = try await engine.measure(root)
        XCTAssertEqual(result.logicalBytes, 8192)
        XCTAssertTrue(result.isComplete)
        let children = try await engine.children(of: root)
        XCTAssertTrue(children.contains { $0.url.lastPathComponent == ".hidden" })
        XCTAssertFalse(children.contains { $0.url.lastPathComponent == "escape" })
    }
    func testMissingIsNotEmpty() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = StorageAnalysisEngine(policy: PathPolicy(readRoots: [root]))
        do { _ = try await engine.children(of: root); XCTFail("Expected missing-path error") }
        catch { }
    }
    func testSparseFileUsesPhysicalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "sparse")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16 * 1024 * 1024)
        try handle.close()
        let size = try await StorageAnalysisEngine(policy: PathPolicy(readRoots: [root])).measure(root)
        XCTAssertEqual(size.logicalBytes, 16 * 1024 * 1024)
        XCTAssertLessThan(size.allocatedBytes, size.logicalBytes)
    }
}
