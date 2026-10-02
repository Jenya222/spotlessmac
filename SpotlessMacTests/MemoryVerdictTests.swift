import XCTest
@testable import SpotlessMac

final class MemoryVerdictTests: XCTestCase {
    private typealias F = MemoryFixtures

    private let groups = [
        F.userGroup("/Applications/Google Chrome.app", processes: [F.process(1, footprint: 10 << 30)]),
        F.userGroup("/Applications/Slack.app", processes: [F.process(2, footprint: 2 << 30)]),
        F.userGroup("/Applications/Notes.app", processes: [F.process(3, footprint: 1 << 30)]),
    ]

    func testCalmSystem() {
        XCTAssertEqual(MemoryVerdict.text(system: F.system(), groups: groups), "Памяти достаточно.")
    }

    func testHeavySwapNamesTopTwoApps() {
        let text = MemoryVerdict.text(system: F.system(swapUsed: 9 << 30), groups: groups)
        XCTAssertTrue(text.hasPrefix("Своп "), text)
        XCTAssertTrue(text.contains("Google Chrome"), text)
        XCTAssertTrue(text.contains("Slack"), text)
        XCTAssertFalse(text.contains("Notes"), text)
    }

    func testCriticalPressureWithoutSwap() {
        let text = MemoryVerdict.text(system: F.system(pressure: .critical), groups: groups)
        XCTAssertTrue(text.hasPrefix("Своп "), text)
    }

    func testWarningPressure() {
        let text = MemoryVerdict.text(system: F.system(pressure: .warning), groups: groups)
        XCTAssertTrue(text.hasPrefix("Память под нагрузкой."), text)
    }

    func testCommandLineGroupsAreNotNamedAsHolders() {
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil,
                                   processes: [F.process(9, footprint: 20 << 30)])
        let text = MemoryVerdict.text(system: F.system(swapUsed: 9 << 30), groups: [other])
        XCTAssertFalse(text.contains("node"), text)
    }
}
