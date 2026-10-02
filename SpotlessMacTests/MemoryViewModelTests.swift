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

/// Models a small process table: `running` shrinks when an app obeys a terminate request.
@MainActor
private final class TerminatorSpy {
    var running: Set<pid_t>
    var terminated: [pid_t] = []
    var forced: [pid_t] = []
    /// The app ignores the polite quit request.
    var ignoresTerminate = false
    /// The app survives even a force quit.
    var survivesForce = false

    init(running: Set<pid_t> = [42]) {
        self.running = running
    }

    var terminator: AppTerminator {
        AppTerminator(
            terminate: { pids in
                self.terminated += pids
                if !self.ignoresTerminate { self.running.subtract(pids) }
            },
            forceTerminate: { pids in
                self.forced += pids
                if !self.survivesForce { self.running.subtract(pids) }
            },
            isAnyRunning: { pids in pids.contains { self.running.contains($0) } }
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

    func testLoopEndsWhenViewModelIsFreedWithoutStop() async {
        let source = SampleSource()
        weak var weakViewModel: MemoryViewModel?
        do {
            let viewModel = MemoryViewModel(sample: { await source.next() }, interval: .milliseconds(1))
            weakViewModel = viewModel
            viewModel.start()
            await waitUntil { await source.calls >= 3 }
            let sampled = await source.calls
            XCTAssertGreaterThanOrEqual(sampled, 3)
            // Last reference dropped here; `stop()` is deliberately never called.
        }
        XCTAssertNil(weakViewModel, "the polling loop must not keep the view model alive")

        // Settle: at most one in-flight sample may still finish after the release.
        try? await Task.sleep(for: .milliseconds(300))
        let settled = await source.calls
        try? await Task.sleep(for: .milliseconds(300))
        let later = await source.calls
        XCTAssertEqual(settled, later, "the loop must end once the view model is gone")
    }

    func testOffersQuitOnlyForGroupsWithARunningApplication() {
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) })
        let withApp = F.userGroup(slackPath, processes: [F.process(42)])
        let servicesOnly = F.userGroup("/Applications/Xcode.app", processes: [F.process(7, name: "SourceKitService")])
        let system = AppMemoryGroup(id: "system", displayName: "Система", kind: .system, bundlePath: nil,
                                    processes: [F.process(1)])
        XCTAssertFalse(viewModel.hasRunningApplication(in: withApp), "no sample yet")

        viewModel.apply(F.sample(at: Date(), groups: [withApp, servicesOnly, system],
                                 runningApps: [F.app(42, slackPath)]))
        XCTAssertTrue(viewModel.hasRunningApplication(in: withApp))
        XCTAssertFalse(viewModel.hasRunningApplication(in: servicesOnly), "background services only")
        XCTAssertFalse(viewModel.hasRunningApplication(in: system))
    }

    func testFinishedHintAppliesOnlyToRealQuits() async {
        // Polite quit succeeds.
        let spy = TerminatorSpy()
        var (viewModel, slack) = makeSlack(spy: spy)
        viewModel.requestQuit(slack)
        XCTAssertFalse(viewModel.quitState.finishedWithQuit)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .finished("Slack завершено."))
        XCTAssertTrue(viewModel.quitState.finishedWithQuit)

        // Already closed.
        let closedSpy = TerminatorSpy(running: [])
        (viewModel, slack) = makeSlack(spy: closedSpy)
        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .finished("Приложение уже закрыто."))
        XCTAssertFalse(viewModel.quitState.finishedWithQuit)

        // Force quit succeeds.
        let forceSpy = TerminatorSpy()
        forceSpy.ignoresTerminate = true
        (viewModel, slack) = makeSlack(spy: forceSpy)
        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        viewModel.confirmForceQuit()
        await waitUntil { isFinished(viewModel) }
        XCTAssertEqual(viewModel.quitState, .finished("Slack завершено принудительно."))
        XCTAssertTrue(viewModel.quitState.finishedWithQuit)

        // Force quit fails.
        let stuckSpy = TerminatorSpy()
        stuckSpy.ignoresTerminate = true
        stuckSpy.survivesForce = true
        (viewModel, slack) = makeSlack(spy: stuckSpy)
        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        viewModel.confirmForceQuit()
        await waitUntil { isFinished(viewModel) }
        XCTAssertEqual(viewModel.quitState, .finished("Slack не удалось завершить."))
        XCTAssertFalse(viewModel.quitState.finishedWithQuit)

        XCTAssertFalse(QuitState.idle.finishedWithQuit)
        XCTAssertEqual(QuitState.quitMessage(for: "Slack"), "Slack завершено.")
        XCTAssertEqual(QuitState.quitMessage(for: "Slack", forced: true), "Slack завершено принудительно.")
    }

    private func isFinished(_ viewModel: MemoryViewModel) -> Bool {
        if case .finished = viewModel.quitState { return true }
        return false
    }

    private func makeSlack(
        spy: TerminatorSpy, grace: Duration = .milliseconds(100)
    ) -> (viewModel: MemoryViewModel, slack: AppMemoryGroup) {
        let viewModel = MemoryViewModel(sample: { F.sample(at: Date()) }, terminator: spy.terminator,
                                        quitGracePeriod: grace, ownBundlePath: "/nowhere")
        let slack = F.userGroup(slackPath, processes: [F.process(42, uid: getuid())])
        viewModel.apply(F.sample(at: Date(), groups: [slack], runningApps: [F.app(42, slackPath)]))
        return (viewModel, slack)
    }

    func testAllowedQuitTerminatesAndFinishes() async {
        let spy = TerminatorSpy()
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        XCTAssertEqual(viewModel.quitState, .confirm(slack, .allowed))
        await viewModel.confirmQuit()
        XCTAssertEqual(spy.terminated, [42])
        XCTAssertEqual(viewModel.quitState, .finished("Slack завершено."))
    }

    func testUnresponsiveAppOffersForceQuit() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))
        XCTAssertTrue(spy.forced.isEmpty)

        viewModel.confirmForceQuit()
        XCTAssertEqual(spy.forced, [42])
        await waitUntil { isFinished(viewModel) }
        XCTAssertEqual(viewModel.quitState, .finished("Slack завершено принудительно."))
    }

    func testQuitOfAlreadyClosedAppDoesNotTerminate() async {
        let spy = TerminatorSpy(running: [])
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertTrue(spy.terminated.isEmpty)
        XCTAssertEqual(viewModel.quitState, .finished("Приложение уже закрыто."))
    }

    func testQuitOfAppThatVanishedFromLatestDoesNotClaimSuccess() async {
        let spy = TerminatorSpy(running: [])
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        // The next poll no longer lists the app.
        viewModel.apply(F.sample(at: Date().addingTimeInterval(2), groups: [], runningApps: []))
        await viewModel.confirmQuit()
        XCTAssertTrue(spy.terminated.isEmpty)
        XCTAssertEqual(viewModel.quitState, .finished("Приложение уже закрыто."))
    }

    func testForceQuitOfAppThatClosedMeanwhileDoesNotForceTerminate() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))

        spy.running = []
        viewModel.confirmForceQuit()
        XCTAssertTrue(spy.forced.isEmpty)
        XCTAssertEqual(viewModel.quitState, .finished("Приложение уже закрыто."))
    }

    func testQuitUsesPIDsVettedAtRequestEvenIfLatestChanges() async {
        let spy = TerminatorSpy(running: [42, 77])
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        // The app relaunched under a PID nobody vetted.
        viewModel.apply(F.sample(at: Date().addingTimeInterval(2), groups: [slack],
                                 runningApps: [F.app(77, slackPath)]))
        await viewModel.confirmQuit()
        XCTAssertEqual(spy.terminated, [42])
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))

        viewModel.confirmForceQuit()
        await waitUntil { isFinished(viewModel) }
        XCTAssertEqual(spy.forced, [42])
        XCTAssertTrue(spy.running.contains(77), "the unvetted instance must stay untouched")
    }

    func testForceQuitReportsFailureWhenAppSurvives() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        spy.survivesForce = true
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        await viewModel.confirmQuit()
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))

        viewModel.confirmForceQuit()
        XCTAssertEqual(viewModel.quitState, .quitting(slack), "the outcome is not claimed before it is checked")
        await waitUntil { isFinished(viewModel) }
        XCTAssertEqual(spy.forced, [42])
        XCTAssertEqual(viewModel.quitState, .finished("Slack не удалось завершить."))
    }

    func testDismissDuringQuittingIsNotOverwrittenByTheWaitLoop() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy)

        viewModel.requestQuit(slack)
        let quit = Task { await viewModel.confirmQuit() }
        await waitUntil { viewModel.quitState == .quitting(slack) }
        XCTAssertEqual(viewModel.quitState, .quitting(slack))

        viewModel.dismissQuit()
        await quit.value
        XCTAssertEqual(viewModel.quitState, .idle)
    }

    func testRequestQuitIsIgnoredWhileQuitting() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy)
        let other = F.userGroup("/Applications/Other.app", processes: [F.process(7, uid: getuid())])

        viewModel.requestQuit(slack)
        let quit = Task { await viewModel.confirmQuit() }
        await waitUntil { viewModel.quitState == .quitting(slack) }

        viewModel.requestQuit(other)
        XCTAssertEqual(viewModel.quitState, .quitting(slack))
        await quit.value
        XCTAssertEqual(viewModel.quitState, .stillRunning(slack))
    }

    func testCancelledCallerDoesNotEscalateToForceQuit() async {
        let spy = TerminatorSpy()
        spy.ignoresTerminate = true
        let (viewModel, slack) = makeSlack(spy: spy, grace: .seconds(5))

        viewModel.requestQuit(slack)
        let quit = Task { await viewModel.confirmQuit() }
        await waitUntil { viewModel.quitState == .quitting(slack) }

        quit.cancel()
        await quit.value
        XCTAssertEqual(viewModel.quitState, .confirm(slack, .allowed), "must not offer force quit before the grace period")
        XCTAssertTrue(spy.forced.isEmpty)
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
