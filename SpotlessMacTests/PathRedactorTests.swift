import XCTest
@testable import SpotlessMac

final class PathRedactorTests: XCTestCase {
    private func redactor() -> PathRedactor { PathRedactor(homePath: "/Users/tester") }

    private func redactor(extraRoots: [String]) -> PathRedactor {
        PathRedactor(homePath: "/Users/tester", extraRoots: extraRoots)
    }

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
        XCTAssertEqual(redacted, "~/Documents/<папка-1>/<папка-2>")
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
        XCTAssertEqual(r.redact("/Users/tester/Documents/Мой проект/recording.m4a"), "~/Documents/<папка-1>/<папка-2>")
        let answer = "Удалите ~/Documents/<папка-1>/<папка-2> — папка <папка-1> личная"
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
                       "удали ~/Documents/<папка-1>/<папка-2>")
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
                       "~/Projects/<папка-1>/<папка-2> и ~/Projects/<папка-3>/<папка-4>")
    }

    func testFolderNamedLikeAnAliasWordIsNotCorrupted() {
        var r = redactor()
        _ = r.redact("/Users/tester/Documents/папка/x")
        XCTAssertEqual(r.redactText("в <папка-1> лежит папка"), "в <папка-1> лежит <папка-1>")
    }

    // Punctuation right after a restored known name must survive and must not create a new alias.
    func testKnownAliasesStayStableAcrossPunctuation() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Downloads/big.iso"), "~/Downloads/<папка-1>")
        XCTAssertEqual(r.redact("/Users/tester/Documents/Мой проект/a"), "~/Documents/<папка-2>/<папка-3>")
        let answers = [
            "Удалите ~/Downloads/<папка-1>. Это безопасно.",
            "~/Documents/<папка-2>: 0.9 ГБ",
            "Папка **~/Documents/<папка-2>** большая",
            "(~/Downloads/<папка-1>), затем ~/Documents/<папка-2>!",
        ]
        for answer in answers {
            let restored = r.restore(answer)
            XCTAssertFalse(restored.contains("<папка-"), restored)
            XCTAssertEqual(r.redactText(restored), answer)
            XCTAssertEqual(r.restore(r.redactText(restored)), restored)
        }
        // No alias was created along the way: the next new folder gets number 4.
        XCTAssertEqual(r.redact("/Users/tester/Projects/new/x"), "~/Projects/<папка-4>/<папка-5>")
    }

    func testKnownNameMustMatchWholeComponent() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/shop/x")
        XCTAssertEqual(r.redactText("~/Projects/shop-admin/x"), "~/Projects/<папка-3>/<папка-4>")
        XCTAssertEqual(r.restore("<папка-3>"), "shop-admin")
        XCTAssertEqual(r.redactText("~/Projects/shop.old/x"), "~/Projects/<папка-5>/<папка-6>")
        XCTAssertEqual(r.redactText("~/Projects/shop/x"), "~/Projects/<папка-1>/<папка-2>")
    }

    func testHomeInsideLongerPathStillAliasesPersonalFolder() {
        var r = redactor()
        let redacted = r.redactText("/System/Volumes/Data/Users/tester/Documents/Секрет/x")
        XCTAssertFalse(redacted.contains("Секрет"))
        XCTAssertFalse(redacted.contains("tester"))
        XCTAssertTrue(redacted.contains("<папка-1>"))
    }

    func testRestoreMapsAliasesBack() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/a/x")
        _ = r.redact("/Users/tester/Projects/b/x")
        XCTAssertEqual(r.restore("<папка-1> и <папка-3>"), "a и b")
        XCTAssertEqual(r.restore("<папка-2> и <папка-4>"), "x и x")
    }

    // MARK: Nested folders and registered project roots

    func testNestedProjectNamesAreAliasedAndArtifactDirectoriesStayVisible() {
        var r = redactor()
        let redacted = r.redact("/Users/tester/MyProjects/clients/acme-bank/node_modules")
        XCTAssertEqual(redacted, "~/MyProjects/<папка-1>/<папка-2>/node_modules")
        XCTAssertFalse(redacted.contains("clients"))
        XCTAssertFalse(redacted.contains("acme-bank"))
        XCTAssertEqual(r.restore(redacted), "~/MyProjects/clients/acme-bank/node_modules")
    }

    func testWellKnownArtifactDirectoriesAreNeverAliased() {
        var r = redactor()
        for name in ["node_modules", ".build", "build", "dist", "target", ".venv", "venv", "Pods", "DerivedData",
                     ".gradle", "__pycache__", ".next", ".nuxt", ".cache", "vendor"] {
            XCTAssertEqual(r.redact("/Users/tester/code/\(name)"), "~/code/\(name)", name)
        }
        XCTAssertEqual(r.redact("/Users/tester/Developer/app/.build/checkouts"), "~/Developer/<папка-1>/.build/<папка-2>")
    }

    func testSameFolderAlwaysGetsTheSameAliasAndDifferentFoldersDoNot() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Projects/a/src"), "~/Projects/<папка-1>/<папка-2>")
        XCTAssertEqual(r.redact("/Users/tester/Projects/a/src/deep"), "~/Projects/<папка-1>/<папка-2>/<папка-3>")
        XCTAssertEqual(r.redact("/Users/tester/Projects/b/src"), "~/Projects/<папка-4>/<папка-5>")
        XCTAssertEqual(r.redact("/Users/tester/Projects/a/src"), "~/Projects/<папка-1>/<папка-2>")
        XCTAssertEqual(r.restore("<папка-3> <папка-5>"), "deep src")
    }

    func testReasonNamingANestedProjectIsRedactedOnceItsPathIsRegistered() {
        var r = redactor()
        _ = r.redact("/Users/tester/MyProjects/clients/acme-bank/node_modules")
        let reason = r.redactText("Зависимости или сборка проекта acme-bank.")
        XCTAssertFalse(reason.contains("acme-bank"))
        XCTAssertEqual(reason, "Зависимости или сборка проекта <папка-2>.")
        XCTAssertEqual(r.restore(reason), "Зависимости или сборка проекта acme-bank.")
    }

    func testRedactTextAliasesEveryComponentAndKeepsTrailingPunctuation() {
        var r = redactor()
        XCTAssertEqual(r.redactText("удали /Users/tester/Projects/shop/api/node_modules."),
                       "удали ~/Projects/<папка-1>/<папка-2>/node_modules.")
        XCTAssertEqual(r.redactText("**~/Projects/shop/api**"), "**~/Projects/<папка-1>/<папка-2>**")
        XCTAssertEqual(r.redactText("(~/Projects/shop/api), затем ~/Projects/shop!"),
                       "(~/Projects/<папка-1>/<папка-2>), затем ~/Projects/<папка-1>!")
    }

    func testRedactAndRedactTextAgreeOnAliases() {
        var r = redactor()
        let viaPath = r.redact("/Users/tester/Documents/Клиенты/Альфа/отчёт.pdf")
        XCTAssertEqual(viaPath, "~/Documents/<папка-1>/<папка-2>/<папка-3>")
        XCTAssertEqual(r.redactText("/Users/tester/Documents/Клиенты/Альфа/отчёт.pdf"), viaPath)
        XCTAssertEqual(r.restore(viaPath), "~/Documents/Клиенты/Альфа/отчёт.pdf")
    }

    func testRegisteredRootIsReplacedByAProjectsAlias() {
        var r = redactor(extraRoots: ["/Volumes/Ext/clients"])
        let redacted = r.redact("/Volumes/Ext/clients/acme/x")
        XCTAssertTrue(redacted.hasPrefix("<проекты-1>/"))
        XCTAssertEqual(redacted, "<проекты-1>/<папка-1>/<папка-2>")
        for leak in ["Ext", "clients", "acme"] { XCTAssertFalse(redacted.contains(leak), leak) }
        XCTAssertEqual(r.restore(redacted), "/Volumes/Ext/clients/acme/x")
        XCTAssertEqual(r.redact("/Volumes/Ext/clients"), "<проекты-1>")
        XCTAssertEqual(r.redact("/Volumes/Ext/clients/acme/node_modules"), "<проекты-1>/<папка-1>/node_modules")
    }

    func testRootsThatOnlyLookLikeARegisteredRootAreUntouched() {
        var r = redactor(extraRoots: ["/Volumes/Ext/clients/"])
        XCTAssertEqual(r.redact("/Volumes/Ext/clients2/a"), "/Volumes/Ext/clients2/a")
        XCTAssertEqual(r.redact("/Volumes/Ext/other"), "/Volumes/Ext/other")
        XCTAssertEqual(r.redactText("/Volumes/Ext/clients2/a и /Volumes/Ext/clients-old/a"),
                       "/Volumes/Ext/clients2/a и /Volumes/Ext/clients-old/a")
    }

    func testRegisteredRootsAreNumberedInOrderOfFirstUse() {
        var r = redactor(extraRoots: ["/Volumes/A/one", "/Volumes/B/two"])
        XCTAssertEqual(r.redact("/Volumes/B/two/x/build"), "<проекты-1>/<папка-1>/build")
        XCTAssertEqual(r.redact("/Volumes/A/one/y"), "<проекты-2>/<папка-2>")
        XCTAssertEqual(r.redact("/Volumes/B/two/z"), "<проекты-1>/<папка-3>")
        XCTAssertEqual(r.restore("<проекты-2> и <проекты-1>"), "/Volumes/A/one и /Volumes/B/two")
    }

    func testRedactTextHandlesRegisteredRootsLikeRedact() {
        var r = redactor(extraRoots: ["/Volumes/Ext/clients"])
        let text = r.redactText("посмотри /Volumes/Ext/clients/acme/node_modules. Это и /Volumes/Ext/clients/acme/x, ok")
        XCTAssertEqual(text, "посмотри <проекты-1>/<папка-1>/node_modules. Это и <проекты-1>/<папка-1>/<папка-2>, ok")
        for leak in ["Ext", "clients", "acme"] { XCTAssertFalse(text.contains(leak), leak) }
        XCTAssertEqual(r.restore(text),
                       "посмотри /Volumes/Ext/clients/acme/node_modules. Это и /Volumes/Ext/clients/acme/x, ok")
    }

    func testBareProjectNameUnderARegisteredRootIsHiddenInReasons() {
        var r = redactor(extraRoots: ["/Volumes/Ext/clients"])
        _ = r.redact("/Volumes/Ext/clients/acme-bank/node_modules")
        let reason = r.redactText("Зависимости или сборка проекта acme-bank.")
        XCTAssertFalse(reason.contains("acme-bank"))
        XCTAssertEqual(r.restore(reason), "Зависимости или сборка проекта acme-bank.")
    }

    func testRegisteredRootInsideHomeIsHiddenInBothSpellings() {
        var r = redactor(extraRoots: ["/Users/tester/work"])
        XCTAssertEqual(r.redact("/Users/tester/work/acme/x"), "<проекты-1>/<папка-1>/<папка-2>")
        XCTAssertEqual(r.redactText("/Users/tester/work/acme/x и ~/work/acme/x"),
                       "<проекты-1>/<папка-1>/<папка-2> и <проекты-1>/<папка-1>/<папка-2>")
        XCTAssertEqual(r.redactText("/Users/tester/workshop/a"), "~/workshop/a")
    }

    // Answers are stored restored (real names) and sent again as history.
    func testRestoredHistoryWithRegisteredRootIsRedactedAgain() {
        var r = redactor(extraRoots: ["/Volumes/Ext/clients"])
        _ = r.redact("/Volumes/Ext/clients/Мой клиент/x")
        let answer = "Удалите <проекты-1>/<папка-1>/<папка-2> — клиент <папка-1> давно не используется"
        let restored = r.restore(answer)
        XCTAssertEqual(restored, "Удалите /Volumes/Ext/clients/Мой клиент/x — клиент Мой клиент давно не используется")
        XCTAssertEqual(r.redactText(restored), answer)
    }

    func testAliasTokensAreNotCorruptedByAFolderNamedLikeAToken() {
        var r = redactor(extraRoots: ["/Volumes/Ext/проекты"])
        _ = r.redact("/Volumes/Ext/проекты/проекты/x")
        XCTAssertEqual(r.redactText("в <проекты-1> лежит проекты и <папка-1>"), "в <проекты-1> лежит <папка-1> и <папка-1>")
    }

    func testFolderNamedLikeAPersonalRootDoesNotBreakTheRootInProse() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/app/src")
        XCTAssertEqual(r.redactText("~/Documents/src"), "~/Documents/<папка-3>")
        XCTAssertEqual(r.redactText("~/src/a"), "~/src/<папка-4>")
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
