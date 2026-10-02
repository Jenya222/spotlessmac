import XCTest
@testable import SpotlessMac
final class PathPolicyTests: XCTestCase {
    func testDirectoryHintDoesNotFollowSymlinkIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertTrue(StorageFileIdentity.read(link)?.isSymbolicLink == true)
        XCTAssertFalse(StorageFileIdentity.read(link)?.isDirectory == true)
    }
    func testComponentBoundaryAndForbiddenPaths() {
        let policy = PathPolicy(readRoots: [URL(filePath: "/tmp/fixture/allowed")])
        XCTAssertTrue(policy.canRead(URL(filePath: "/tmp/fixture/allowed/cache")))
        XCTAssertFalse(policy.canRead(URL(filePath: "/tmp/fixture/allowed-other/cache")))
        XCTAssertFalse(policy.canRead(URL(filePath: "/System")))
    }
    func testSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: URL(filePath: "/System"))
        XCTAssertFalse(PathPolicy(readRoots: [root]).canRead(root.appending(path: "link/Library")))
    }
}
