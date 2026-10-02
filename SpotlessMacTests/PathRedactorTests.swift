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

    // Folder names with spaces and Cyrillic letters are fully hidden from the cloud.
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

    // Assistant answers are stored after restore(_:) (real names), then sent again as history.
    func testRestoredHistoryIsRedactedAgain() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Documents/Мой проект/recording.m4a"), "~/Documents/<папка-1>/recording.m4a")
        let answer = "Удалите ~/Documents/<папка-1>/recording.m4a — папка <папка-1> личная"
        let restored = r.restore(answer)
        XCTAssertEqual(restored, "Удалите ~/Documents/Мой проект/recording.m4a — папка Мой проект личная")
        let redacted = r.redactText(restored)
        XCTAssertFalse(redacted.contains("Мой проект"))
        XCTAssertEqual(redacted.components(separatedBy: "<папка-1>").count - 1, 2)
        XCTAssertEqual(redacted, answer)
    }

    func testKnownNameWithSpacesInFreeTextPath() {
        var r = redactor()
        _ = r.redact("/Users/tester/Documents/Мой проект/recording.m4a")
        XCTAssertEqual(r.redactText("удали /Users/tester/Documents/Мой проект/recording.m4a"),
                       "удали ~/Documents/<папка-1>/recording.m4a")
    }

    func testBareHomeBeforePunctuationIsRedacted() {
        var r = redactor()
        XCTAssertEqual(r.redactText("/Users/tester, там"), "~, там")
        XCTAssertEqual(r.redactText("`/Users/tester`"), "`~`")
        XCTAssertEqual(r.redactText("(/Users/tester)."), "(~).")
        XCTAssertEqual(r.redactText("см. /Users/tester."), "см. ~.")
        XCTAssertEqual(r.redactText("/Users/testerX/a"), "/Users/testerX/a")
        XCTAssertEqual(r.redactText("/Users/tester.bak"), "/Users/tester.bak")
    }

    func testShortNamesAreNotSubstitutedInProse() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/a/x")
        XCTAssertEqual(r.redactText("a b c"), "a b c")
    }

    func testBareKnownNameMatchesWholeWordsOnly() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/secret/x")
        XCTAssertEqual(r.redactText("secret и secrets, top-secret"), "<папка-1> и secrets, top-<папка-1>")
    }

    func testNewAliasesAreNumberedInTextOrder() {
        var r = redactor()
        XCTAssertEqual(r.redactText("/Users/tester/Projects/a/x и /Users/tester/Projects/b/x"),
                       "~/Projects/<папка-1>/x и ~/Projects/<папка-2>/x")
    }

    func testFolderNamedLikeAnAliasWordIsNotCorrupted() {
        var r = redactor()
        _ = r.redact("/Users/tester/Documents/папка/x")
        XCTAssertEqual(r.redactText("в <папка-1> лежит папка"), "в <папка-1> лежит <папка-1>")
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
