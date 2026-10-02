import XCTest
@testable import SpotlessMac

final class ProcessGrouperTests: XCTestCase {
    private typealias F = MemoryFixtures

    func testOutermostAppNormalizesNestedBundles() {
        XCTAssertEqual(BundlePath.outermostApp(in: "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop"),
                       "/Applications/Docker.app")
        XCTAssertEqual(BundlePath.outermostApp(in: "/Applications/Foo.app"), "/Applications/Foo.app")
        XCTAssertNil(BundlePath.outermostApp(in: "/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"))
        XCTAssertNil(BundlePath.outermostApp(in: "/usr/libexec/trustd"))
    }

    func testDockerProcessesCollapseIntoOneGroup() {
        let docker = "/Applications/Docker.app"
        let processes = [
            F.process(3246, name: "Docker Desktop", path: docker + "/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop", footprint: 40),
            F.process(3281, ppid: 3246, name: "Docker Desktop Helper",
                      path: docker + "/Contents/MacOS/Docker Desktop.app/Contents/Frameworks/Docker Desktop Helper.app/Contents/MacOS/Docker Desktop Helper",
                      responsible: 3246),
            F.process(29234, name: "com.docker.backend", path: docker + "/Contents/MacOS/com.docker.backend"),
            F.process(29388, ppid: 29234, name: "docker-agent", path: docker + "/Contents/Resources/cli-plugins/docker-agent", responsible: 29234),
            F.process(500, name: "com.apple.Virtualization.VirtualMachine",
                      path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
                      responsible: 29234, footprint: 8000),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(3246, docker, id: "com.electron.dockerdesktop")], currentUID: F.me)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, docker)
        XCTAssertEqual(groups[0].displayName, "Docker")
        XCTAssertEqual(groups[0].kind, .userApp)
        XCTAssertEqual(groups[0].processes.count, 5)
        XCTAssertEqual(groups[0].processes.first?.pid, 500, "processes are sorted by footprint")
    }

    func testChromeCodeSignCloneResolvesThroughRunningApp() {
        let chrome = "/Applications/Google Chrome.app"
        let processes = [
            F.process(10, name: "Google Chrome", path: "/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"),
            F.process(11, ppid: 10, name: "Google Chrome Helper (Renderer)",
                      path: chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                      responsible: 10),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(10, chrome)], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), [chrome])
        XCTAssertEqual(groups[0].processes.count, 2)
    }

    func testWithoutResponsibilityParentChainFindsTheApp() {
        let processes = [
            F.process(20, name: "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo"),
            F.process(21, ppid: 20, name: "tool", path: "/usr/local/bin/tool"),
            F.process(22, ppid: 21, name: "worker", path: nil),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), ["/Applications/Foo.app"])
        XCTAssertEqual(groups[0].processes.count, 3)
    }

    func testRegularAppUnderSystemIsUserApp() {
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let processes = [F.process(30, name: "Terminal", path: terminal + "/Contents/MacOS/Terminal")]
        let groups = ProcessGrouper.group(processes, runningApps: [F.app(30, terminal, id: "com.apple.Terminal")], currentUID: F.me)
        XCTAssertEqual(groups.first?.kind, .userApp)
        XCTAssertEqual(groups.first?.displayName, "Terminal")
    }

    func testRootOtherUsersAndSystemBundlesGoToSystem() {
        let processes = [
            F.process(40, uid: 0, name: "trustd", path: "/usr/libexec/trustd"),
            F.process(41, uid: 205, name: "locationd", path: "/usr/libexec/locationd"),
            F.process(42, name: "Spotlight", path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"),
            F.process(43, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), [ProcessGrouper.systemGroupID])
        XCTAssertEqual(groups[0].kind, .system)
        XCTAssertEqual(groups[0].processes.count, 4)
    }

    func testUserCommandLineProcessesGroupByName() {
        let processes = [
            F.process(50, name: "claude", path: "/Users/u/.local/share/claude/versions/2.1.285"),
            F.process(51, name: "claude", path: "/Users/u/.local/share/claude/versions/2.1.287"),
            F.process(52, name: "node", path: "/opt/homebrew/bin/node"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(Set(groups.map(\.id)), ["other:claude", "other:node"])
        XCTAssertEqual(groups.first { $0.id == "other:claude" }?.processes.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.kind == .other })
    }

    func testParentCycleTerminates() {
        let processes = [
            F.process(60, ppid: 61, name: "loop"),
            F.process(61, ppid: 60, name: "loop"),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.id), ["other:loop"])
    }

    func testPartialProcessesAreKept() {
        let processes = [F.process(70, uid: nil, name: "secret", path: nil, footprint: 0, resident: 0, partial: true)]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].hasPartialData)
    }

    func testGroupsAreSortedAndTotalsSummed() {
        let processes = [
            F.process(80, name: "A", path: "/Applications/A.app/Contents/MacOS/A", footprint: 300, resident: 100),
            F.process(81, name: "B", path: "/Applications/B.app/Contents/MacOS/B", footprint: 500, resident: 500),
            F.process(82, ppid: 80, name: "A Helper", path: "/Applications/A.app/Contents/MacOS/A Helper", footprint: 400, resident: 100),
        ]
        let groups = ProcessGrouper.group(processes, runningApps: [], currentUID: F.me)
        XCTAssertEqual(groups.map(\.displayName), ["A", "B"])
        XCTAssertEqual(groups[0].footprint, 700)
        XCTAssertEqual(groups[0].pushedOut, 500)
        XCTAssertEqual(groups[1].pushedOut, 0)
    }
}
