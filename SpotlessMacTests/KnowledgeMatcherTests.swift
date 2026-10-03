import XCTest
@testable import SpotlessMac

final class KnowledgeMatcherTests: XCTestCase {
    private let home = SystemSnapshot.testHome

    private func base() -> KnowledgeBase {
        KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.user-caches", kind: .path, verdict: .safe, paths: ["~/Library/Caches"],
                                      categories: [.userCaches]),
            KnowledgeFixtures.article("path.package-caches", kind: .path, verdict: .safe, paths: ["~/Library/Caches/Homebrew"],
                                      categories: [.developerCaches]),
            KnowledgeFixtures.article("path.containers", kind: .path, verdict: .caution, paths: ["~/Library/Containers/*/Data"]),
            KnowledgeFixtures.article("path.docker-raw", kind: .path, verdict: .caution,
                                      paths: ["~/Library/Containers/com.docker.docker/Data"]),
            KnowledgeFixtures.article("path.photos-library", kind: .path, verdict: .keep, paths: ["~/Pictures/*.photoslibrary"]),
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, verdict: .safe,
                                      paths: ["~/Library/Developer/Xcode/DerivedData"]),
            KnowledgeFixtures.article("app.xcode", kind: .app, verdict: .caution, aliases: ["Xcode"], bundles: ["com.apple.dt.Xcode"]),
            KnowledgeFixtures.article("app.chrome", kind: .app, verdict: .safe, aliases: ["Google Chrome"], bundles: ["com.google.Chrome"]),
            KnowledgeFixtures.article("guide.chrome-tips", aliases: ["Chrome Tips"]),
            KnowledgeFixtures.article("proc.kernel-task", kind: .process, verdict: .keep, processes: ["kernel_task"]),
        ])
    }

    func testPatternCoversThePathAndItsContentsOnly() {
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/Caches", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/Caches/x/y", homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library", homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/CachesX", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "/private/var/vm", matching: "/private/var/vm/swapfile0", homePath: home))
    }

    func testWildcardMatchesInsideOneComponent() {
        let library = home + "/Pictures/Photos Library.photoslibrary/originals"
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Pictures/*.photoslibrary", matching: library, homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Pictures/*.photoslibrary", matching: home + "/Pictures/a.jpg", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Containers/*/Data",
                                                     matching: home + "/Library/Containers/com.x/Data/y", homePath: home))
    }

    func testMostSpecificPatternWins() {
        let article = KnowledgeMatcher.article(forPath: home + "/Library/Caches/Homebrew/downloads", category: .userCaches,
                                               in: base(), homePath: home)
        XCTAssertEqual(article?.id, "path.package-caches")
    }

    func testLiteralBeatsWildcard() {
        let article = KnowledgeMatcher.article(forPath: home + "/Library/Containers/com.docker.docker/Data/vms",
                                               category: nil, in: base(), homePath: home)
        XCTAssertEqual(article?.id, "path.docker-raw")
    }

    func testCategoryFallbackAndNoMatch() {
        XCTAssertEqual(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: .developerCaches,
                                                in: base(), homePath: home)?.id, "path.package-caches")
        XCTAssertNil(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: .trash, in: base(), homePath: home))
        XCTAssertNil(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: nil, in: base(), homePath: home))
    }

    func testAppsMatchByBundleThenByAppAlias() {
        XCTAssertEqual(KnowledgeMatcher.article(forApp: "Хром", bundleID: "com.google.Chrome", in: base())?.id, "app.chrome")
        XCTAssertEqual(KnowledgeMatcher.article(forApp: "google chrome", bundleID: nil, in: base())?.id, "app.chrome")
        XCTAssertNil(KnowledgeMatcher.article(forApp: "Chrome Tips", bundleID: nil, in: base()), "guides never bind to apps")
        XCTAssertNil(KnowledgeMatcher.article(forApp: "Slack", bundleID: "com.tinyspeck.slackmacgap", in: base()))
    }

    func testProcessesMatchByExactName() {
        XCTAssertEqual(KnowledgeMatcher.article(forProcess: "kernel_task", in: base())?.id, "proc.kernel-task")
        XCTAssertNil(KnowledgeMatcher.article(forProcess: "kernel", in: base()))
    }

    func testAnnotateSnapshot() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory = MemoryInfo(load: .normal, usedBytes: 1, physicalBytes: 2, swapUsedBytes: 0,
                                     topApps: [MemoryAppInfo(name: "Xcode", bytes: 4, bundleID: "com.apple.dt.Xcode"),
                                               MemoryAppInfo(name: "Telegram", bytes: 1)],
                                     topProcesses: [MemoryProcessInfo(name: "kernel_task", bytes: 3),
                                                    MemoryProcessInfo(name: "node", bytes: 2)])
        let annotations = KnowledgeMatcher.annotate(snapshot, knowledge: base(), homePath: home)
        XCTAssertEqual(annotations.items["c1"], "path.xcode-deriveddata")
        XCTAssertEqual(annotations.items["c3"], "path.user-caches")
        XCTAssertNil(annotations.items["c2"])
        XCTAssertEqual(annotations.apps, ["Xcode": "app.xcode"])
        XCTAssertEqual(annotations.processes, ["kernel_task": "proc.kernel-task"])
    }

    func testEmptyBaseAnnotatesNothing() {
        XCTAssertTrue(KnowledgeMatcher.annotate(.sample(), knowledge: .empty, homePath: home).isEmpty)
    }
}
