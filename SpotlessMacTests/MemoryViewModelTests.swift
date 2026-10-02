import XCTest
@testable import SpotlessMac

private actor SampleSource {
    private(set) var calls = 0
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    func next() async -> MemorySample {
        calls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        try? await Task.sleep(for: .milliseconds(5))
        inFlight -= 1
        return MemoryFixtures.sample(at: Date())
    }
}

@MainActor
private final class TerminatorSpy {
    var terminated: [pid_t] = []
    var forced: [pid_t] = []
    var stillRunning = false

    var terminator: AppTerminator {
        AppTerminator(
            terminate: { self.terminated += $0 },
            forceTerminate: { self.forced += $0 },
            isAnyRunning: { _ in self.stillRunning }
        )
    }
}

@MainActor
final class MemoryViewModelTests: XCTestCase {
    private typealias F = MemoryFixtures
    private let slackPath = "/Applications/Slack.app"

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testHistoryIsCapped() {
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) })
        let start = Date()
        for index in 0..<160 {
            viewModel.apply(F.sample(at: start.addingTimeInterval(Double(index)), swapUsed: UInt64(index)))
        }
        XCTAssertEqual(viewModel.history.count, MemoryViewModel.historyLimit)
        XCTAssertEqual(viewModel.history.first?.swapUsed, 10)
        XCTAssertEqual(viewModel.history.last?.swapUsed, 159)
    }

    func testOrderKeepsPreviousPositionsUntilResort() {
        let a = F.userGroup("/Applications/A.app", processes: [F.process(1, footprint: 100)])
        let b = F.userGroup("/Applications/B.app", processes: [F.process(2, footprint: 200)])
        let c = F.userGroup("/Applications/C.app", processes: [F.process(3, footprint: 50)])

        let kept = MemoryViewModel.order([b, c], previous: [a, c, b], resort: false)
        XCTAssertEqual(kept.map(\.id), [c.id, b.id], "known groups keep order, vanished ones drop")

        let appended = MemoryViewModel.order([b, a, c], previous: [a, b], resort: false)
        XCTAssertEqual(appended.map(\.id), [a.id, b.id, c.id], "new groups are appended")

        XCTAssertEqual(MemoryViewModel.order([b, a], previous: [a, b], resort: true).map(\.id), [b.id, a.id])
    }

    func testApplyResortsAtMostEveryTenSeconds() {
        let small = F.userGroup("/Applications/A.app", processes: [F.process(1, footprint: 100)])
        let big = F.userGroup("/Applications/B.app", processes: [F.process(2, footprint: 200)])
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) })
        let start = Date()

        viewModel.apply(F.sample(at: start, groups: [small, big]))
        viewModel.apply(F.sample(at: start.addingTimeInterval(2), groups: [big, small]))
        XCTAssertEqual(viewModel.displayedGroups.map(\.id), [small.id, big.id])

        viewModel.apply(F.sample(at: start.addingTimeInterval(11), groups: [big, small]))
        XCTAssertEqual(viewModel.displayedGroups.map(\.id), [big.id, small.id])
    }

    func testStartSamplesAndStopHalts() async {
        let source = SampleSource()
        let viewModel = MemoryViewModel(sample: { await source.next() }, interval: .milliseconds(10))
        viewModel.start()
        await waitUntil { await source.calls >= 3 }
        viewModel.stop()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertNotNil(viewModel.latest)

        try? await Task.sleep(for: .milliseconds(30))
        let afterStop = await source.calls
        try? await Task.sleep(for: .milliseconds(60))
        let later = await source.calls
        XCTAssertEqual(afterStop, later)
    }

    func testRestartDoesNotRunTwoLoops() async {
        let source = SampleSource()
        let viewModel = MemoryViewModel(sample: { await source.next() }, interval: .milliseconds(1))
        viewModel.start()
        viewModel.start()
        viewModel.start()
        await waitUntil { await source.calls >= 10 }
        viewModel.stop()
        let maxInFlight = await source.maxInFlight
        XCTAssertEqual(maxInFlight, 1)
    }

    func testAllowedQuitTerminatesAndFinishes() async {
        let spy = TerminatorSpy()
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator,
                                        quitGracePeriod: .milliseconds(100), ownBundlePath: "/nowhere")
        let slack = F.userGroup(slackPath, processes: [F.process(42, uid: getuid())])
        viewModel.apply(F.sample(at: Date(), groups: [slack], runningApps: [F.app(42, slackPath)]))

        viewModel.requestQuit(slack)
        XCTAssertEqual(viewModel.quitState, .confirm(slack, .allowed))
        await viewModel.confirmQuit()
        XCTAssertEqual(spy.terminated, [42])
        guard case .finished = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
    }

    func testUnresponsiveAppOffersForceQuit() async {
        let spy = TerminatorSpy()
        spy.stillRunning = true
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator,
                                        quitGracePeriod: .milliseconds(100), ownBundlePath: "/nowhere")
        let slack = F.userGroup(slackPath, processes: [F.process(42, uid: getuid())])
        viewModel.apply(F.sample(at: Date(), groups: [slack], runningApps: [F.app(42, slackPath)]))

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))
        XCTAssertTrue(spy.forced.isEmpty)

        viewModel.confirmForceQuit()
        XCTAssertEqual(spy.forced, [42])
        guard case .finished = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
    }

    func testDeniedQuitNeverTerminates() async {
        let spy = TerminatorSpy()
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator, ownBundlePath: "/nowhere")
        let system = AppMemoryGroup(id: "system", displayName: "Система", kind: .system, bundlePath: nil,
                                    processes: [F.process(1, uid: 0)])
        viewModel.apply(F.sample(at: Date(), groups: [system]))

        viewModel.requestQuit(system)
        guard case .confirm(_, .denied) = viewModel.quitState else { return XCTFail("\(viewModel.quitState)") }
        await viewModel.confirmQuit()
        XCTAssertTrue(spy.terminated.isEmpty)
        viewModel.dismissQuit()
        XCTAssertEqual(viewModel.quitState, .idle)
    }
}
