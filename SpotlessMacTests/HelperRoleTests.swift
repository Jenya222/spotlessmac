import XCTest
@testable import SpotlessMac

final class HelperRoleTests: XCTestCase {
    private func buffer(argc: Int32, exec: String, args: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(exec.utf8) + [0, 0, 0]
        for arg in args { bytes += Array(arg.utf8) + [0] }
        bytes += Array("HOME=/Users/x".utf8) + [0] // environment must be ignored
        return bytes
    }

    func testParsesArgvAndIgnoresEnvironment() {
        let args = ["/Applications/Google Chrome.app/…/Google Chrome Helper (Renderer)", "--type=renderer", "--extension-process"]
        let parsed = ProcessArguments.parse(buffer(argc: 3, exec: "/x/Helper", args: args))
        XCTAssertEqual(parsed, args)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(ProcessArguments.parse([]))
        XCTAssertNil(ProcessArguments.parse([1, 0]))
        XCTAssertNil(ProcessArguments.parse(buffer(argc: 0, exec: "/x", args: [])))
    }

    func testClassifiesChromiumProcessTypes() {
        XCTAssertEqual(HelperRole.classify(["helper", "--type=renderer", "--renderer-client-id=5"]), .page)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=renderer", "--extension-process"]), .browserExtension)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=gpu-process"]), .gpu)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]), .network)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=utility", "--utility-sub-type=storage.mojom.StorageService"]), .storage)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"]), .audio)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=utility", "--utility-sub-type=video"]), .video)
        XCTAssertEqual(HelperRole.classify(["helper", "--type=utility", "--utility-sub-type=something.Else"]), .utility)
        XCTAssertNil(HelperRole.classify(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]))
        XCTAssertNil(HelperRole.classify(["helper", "--type=crashpad-handler"]))
    }

    func testGroupRoleTotalsAndBrowserDetection() {
        var tab = MemoryFixtures.process(1, name: "Helper (Renderer)", footprint: 300)
        tab.role = .page
        var tab2 = MemoryFixtures.process(2, name: "Helper (Renderer)", footprint: 200)
        tab2.role = .page
        var ext = MemoryFixtures.process(3, name: "Helper (Renderer)", footprint: 50)
        ext.role = .browserExtension
        let main = MemoryFixtures.process(4, name: "Google Chrome", footprint: 100)
        let group = MemoryFixtures.userGroup("/Applications/Google Chrome.app", processes: [tab, tab2, ext, main])
        XCTAssertEqual(group.roleTotals.map(\.role), [.page, .browserExtension])
        XCTAssertEqual(group.roleTotals.map(\.bytes), [500, 50])
        XCTAssertEqual(group.roleTotals.first?.count, 2)
        XCTAssertTrue(group.looksLikeBrowser)

        var electronPage = MemoryFixtures.process(5, name: "Slack Helper (Renderer)", footprint: 10)
        electronPage.role = .page
        let slack = MemoryFixtures.userGroup("/Applications/Slack.app", processes: [electronPage])
        XCTAssertFalse(slack.looksLikeBrowser)
    }
}
