import XCTest
@testable import SpotlessMac

final class ProcessSafetyRulesTests: XCTestCase {
    private typealias F = MemoryFixtures
    private let own = "/Applications/SpotlessMac.app"

    private func decide(_ group: AppMemoryGroup, _ apps: [RunningAppInfo]) -> QuitDecision {
        ProcessSafetyRules.canQuit(group, runningApps: apps, currentUID: F.me, ownBundlePath: own, ownPID: 9999)
    }

    func testRegularUserAppIsAllowed() {
        let group = F.userGroup("/Applications/Slack.app", processes: [F.process(1, name: "Slack")])
        XCTAssertEqual(decide(group, [F.app(1, "/Applications/Slack.app")]), .allowed)
    }

    func testSystemAndCommandLineGroupsAreDeniedWithDifferentReasons() {
        let system = AppMemoryGroup(id: "system", displayName: "Система", kind: .system, bundlePath: nil, processes: [])
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil, processes: [])
        guard case .denied(let systemReason) = decide(system, []),
              case .denied(let otherReason) = decide(other, []) else { return XCTFail("must deny") }
        XCTAssertNotEqual(systemReason, otherReason)
    }

    func testRegularAppUnderSystemIsAllowed() {
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let group = F.userGroup(terminal, processes: [F.process(11, name: "Terminal")])
        XCTAssertEqual(decide(group, [F.app(11, terminal, id: "com.apple.Terminal")]), .allowed)
    }

    func testSpotlessMacItselfIsDenied() {
        let byPath = F.userGroup(own, processes: [F.process(2)])
        XCTAssertNotEqual(decide(byPath, [F.app(2, own)]), .allowed)
        let byPID = F.userGroup("/Applications/X.app", processes: [F.process(9999)])
        XCTAssertNotEqual(decide(byPID, [F.app(9999, "/Applications/X.app")]), .allowed)
    }

    func testForeignUIDIsDenied() {
        let group = F.userGroup("/Applications/X.app", processes: [F.process(3), F.process(4, uid: 0)])
        XCTAssertNotEqual(decide(group, [F.app(3, "/Applications/X.app")]), .allowed)
    }

    func testProtectedComponentsAreDenied() {
        let finder = "/System/Library/CoreServices/Finder.app"
        let byID = F.userGroup(finder, processes: [F.process(5, name: "Finder")])
        XCTAssertNotEqual(decide(byID, [F.app(5, finder, id: "com.apple.finder")]), .allowed)
        let byName = F.userGroup("/Applications/Weird.app", processes: [F.process(6, name: "WindowServer")])
        XCTAssertNotEqual(decide(byName, [F.app(6, "/Applications/Weird.app")]), .allowed)
    }

    func testProtectedBundleIDAloneDeniesQuit() {
        // Neutral process name and a path outside /System, so only the bundle-id rule can decide.
        let path = "/Applications/Weird.app"
        let group = F.userGroup(path, processes: [F.process(12, name: "Helper")])
        XCTAssertEqual(decide(group, [F.app(12, path, id: "com.apple.controlcenter")]),
                       .denied("Это системный компонент macOS."))
        XCTAssertEqual(decide(group, [F.app(12, path, id: "com.example.weird")]), .allowed,
                       "same group with an ordinary bundle id is quittable")
    }

    func testAppWithoutRunningApplicationIsDenied() {
        let group = F.userGroup("/Applications/Xcode.app", processes: [F.process(7, name: "SourceKitService")])
        XCTAssertNotEqual(decide(group, []), .allowed)
    }

    func testActivationPolicyRules() {
        let menuBar = F.userGroup("/Applications/Menu.app", processes: [F.process(8)])
        XCTAssertEqual(decide(menuBar, [F.app(8, "/Applications/Menu.app", policy: .accessory)]), .allowed)

        let systemAgent = F.userGroup("/System/Library/CoreServices/Agent.app", processes: [F.process(9)])
        XCTAssertNotEqual(decide(systemAgent, [F.app(9, "/System/Library/CoreServices/Agent.app", policy: .accessory)]), .allowed)

        let background = F.userGroup("/Applications/Daemon.app", processes: [F.process(10)])
        XCTAssertNotEqual(decide(background, [F.app(10, "/Applications/Daemon.app", policy: .prohibited)]), .allowed)
    }
}
