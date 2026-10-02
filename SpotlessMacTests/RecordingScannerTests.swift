import XCTest
@testable import SpotlessMac
final class RecordingScannerTests: XCTestCase {
    func testOnlyFinishedStandaloneRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.wav", "two.m4a", "index.sqlite", "incomplete.wav.part"] {
            try Data(repeating: 1, count: 64).write(to: root.appending(path: name))
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: root.appending(path: name).path)
        }
        let items = try await RecordingScanner(root: root).scan()
        XCTAssertEqual(Set(items.map(\.path.lastPathComponent)), ["one.wav", "two.m4a"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected && $0.cleanupPolicy.disposition == .personalData })
    }
}
