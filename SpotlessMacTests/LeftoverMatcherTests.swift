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
}
