import XCTest
@testable import SpotlessMac

final class PathRedactorTests: XCTestCase {
    private func redactor() -> PathRedactor { PathRedactor(homePath: "/Users/tester") }

    func testHomeBecomesTilde() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Library/Caches/x"), "~/Library/Caches/x")
        XCTAssertEqual(r.redact("/Users/tester"), "~")
        XCTAssertEqual(r.redact("/Users/tester/Projects"), "~/Projects")
    }

    func testPersonalFoldersGetStableAliases() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Projects/secret-client/node_modules"), "~/Projects/<папка-1>/node_modules")
        XCTAssertEqual(r.redact("/Users/tester/MyProjects/other/build"), "~/MyProjects/<папка-2>/build")
        XCTAssertEqual(r.redact("/Users/tester/Projects/secret-client/dist"), "~/Projects/<папка-1>/dist")
    }

    // Review focus 3: spaces and Cyrillic.
    func testSpacesAndCyrillicAreRedacted() {
        var r = redactor()
        let redacted = r.redact("/Users/tester/Documents/Мой проект/запись.m4a")
        XCTAssertEqual(redacted, "~/Documents/<папка-1>/запись.m4a")
        XCTAssertFalse(redacted.contains("Мой проект"))
        XCTAssertEqual(r.restore("Удалите <папка-1>"), "Удалите Мой проект")
    }

    func testPathsOutsideHomeAndLookalikesUntouched() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Library/Logs/x"), "/Library/Logs/x")
        XCTAssertEqual(r.redact("/Users/testerX/Projects/a"), "/Users/testerX/Projects/a")
    }

    func testRedactTextReplacesEmbeddedPaths() {
        var r = redactor()
        let text = r.redactText("посмотри /Users/tester/Projects/secret-client/build и /tmp/x")
        XCTAssertEqual(text, "посмотри ~/Projects/<папка-1>/build и /tmp/x")
        XCTAssertEqual(r.redactText("без путей"), "без путей")
    }

    func testRestoreMapsAliasesBack() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/a/x")
        _ = r.redact("/Users/tester/Projects/b/x")
        XCTAssertEqual(r.restore("<папка-1> и <папка-2>"), "a и b")
    }

    func testSnapshotHelpers() {
        let snapshot = SystemSnapshot.sample()
        XCTAssertTrue(snapshot.hasScan)
        XCTAssertEqual(snapshot.item(shortID: "c3")?.category, .userCaches)
        XCTAssertNil(snapshot.item(shortID: "c99"))
        XCTAssertEqual(CleanupDisposition.personalData.code, "personalData")
        XCTAssertEqual(snapshot.volume?.freeFraction ?? 0, 31.0 / 494.0, accuracy: 0.0001)
    }
}
