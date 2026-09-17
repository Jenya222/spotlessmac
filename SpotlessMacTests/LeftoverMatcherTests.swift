import XCTest
@testable import SpotlessMac

final class LeftoverMatcherTests: XCTestCase {
    func testChromeDoesNotOwnCanaryPreferences() {
        XCTAssertFalse(LeftoverMatcher.isExact(
            component: "com.google.Chrome.canary.plist",
            bundleID: "com.google.Chrome",
            rootName: "Preferences"
        ))
    }

    func testOwnPreferencesAreExact() {
        XCTAssertTrue(LeftoverMatcher.isExact(
            component: "com.google.Chrome.plist",
            bundleID: "com.google.Chrome",
            rootName: "Preferences"
        ))
    }

    func testGroupContainerIsNeverExactByNameAlone() {
        XCTAssertFalse(LeftoverMatcher.isExact(
            component: "TEAM.com.google.Chrome",
            bundleID: "com.google.Chrome",
            rootName: "Group Containers"
        ))
    }

    func testAmbiguousBundlePrefixIsReturnedUnselectedByEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SpotlessMacTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let preferences = root.appending(path: "Preferences", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let candidate = preferences.appending(path: "com.google.Chrome.canary.plist")
        FileManager.default.createFile(atPath: candidate.path(percentEncoded: false), contents: Data())
        let app = InstalledApp(
            name: "Google Chrome",
            bundleURL: root.appending(path: "Google Chrome.app", directoryHint: .isDirectory),
            bundleID: "com.google.Chrome"
        )

        let leftovers = await UninstallEngine(leftoverRoots: [preferences]).findLeftovers(for: app)
        let matched = try XCTUnwrap(
            leftovers.first { $0.path.lastPathComponent == candidate.lastPathComponent },
            "Returned paths: \(leftovers.map { $0.path.path(percentEncoded: false) })"
        )

        guard case .nameOnly = matched.confidence else {
            return XCTFail("Ambiguous bundle prefix must remain a name-only candidate")
        }
        XCTAssertFalse(matched.isSelected)
    }
}
