import XCTest
@testable import SpotlessMac

@MainActor
final class LicenseManagerTests: XCTestCase {
    func testProductionPolicyAllowsOnlyActivatedOrUnusedTrial() {
        XCTAssertTrue(LicenseManager.isCleaningAllowed(state: .activated(email: "user@example.com")))
        XCTAssertTrue(LicenseManager.isCleaningAllowed(state: .trial(usedCleans: 0, allowed: 1)))
        XCTAssertFalse(LicenseManager.isCleaningAllowed(state: .trial(usedCleans: 1, allowed: 1)))
        XCTAssertFalse(LicenseManager.isCleaningAllowed(state: .trial(usedCleans: 2, allowed: 1)))
    }
}
