import XCTest
@testable import SpotlessMac

@MainActor
final class AssistantStagingTests: XCTestCase {
    private func item(_ name: String, _ size: Int64, _ category: ScanCategory, selected: Bool = true) -> ScanItem {
        ScanItem(path: URL(filePath: "/Users/tester/Library/Caches/\(name)"), size: size, category: category, isSelected: selected)
    }

    private func scannedViewModel(_ items: [ScanItem]) async -> ScanViewModel {
        let vm = ScanViewModel(
            scanItems: { _ in items },
            deleteItems: { _ in XCTFail("staging must never delete"); return [] }
        )
        await vm.scan()
        return vm
    }

    func testStageSelectionOnlyTogglesBatchItemsAndNeverDeletes() async {
        let a = item("a", 100, .userCaches)
        let b = item("b", 200, .logs)
        let model = item("m", 999, .modelCaches, selected: false)
        let vm = await scannedViewModel([a, b, model])
        let staging = vm.stageSelection([b.id, model.id])
        XCTAssertEqual(staging, ScanViewModel.AssistantStaging(count: 1, bytes: 200))
        XCTAssertEqual(vm.items.first { $0.id == a.id }?.isSelected, false)
        XCTAssertEqual(vm.items.first { $0.id == b.id }?.isSelected, true)
        XCTAssertEqual(vm.items.first { $0.id == model.id }?.isSelected, false)
        XCTAssertEqual(vm.assistantStaging, staging)
        XCTAssertTrue(vm.recoveryPreviewRequested)
        XCTAssertEqual(vm.items.count, 3)
        vm.clearAssistantStaging()
        XCTAssertNil(vm.assistantStaging)
    }

    // A persisted plan outlives the scan whose IDs it references; a stale plan must not touch the selection.
    func testStageSelectionWithOnlyUnknownIDsChangesNothing() async {
        let a = item("a", 100, .userCaches)
        let b = item("b", 200, .logs, selected: false)
        let model = item("m", 999, .modelCaches, selected: false)
        let vm = await scannedViewModel([a, b, model])
        let before = vm.items.map(\.isSelected)
        XCTAssertNil(vm.stageSelection([UUID(), model.id]))
        XCTAssertEqual(vm.items.map(\.isSelected), before)
        XCTAssertNil(vm.assistantStaging)
        XCTAssertFalse(vm.recoveryPreviewRequested)
    }

    private final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    // Final review (T13): while a scan runs, `items` still holds the previous scan's list that the
    // plan was written against, and the scan is about to replace it. Staging then would mark rows that vanish.
    func testStageSelectionDuringAScanReturnsNilAndChangesNothing() async {
        let a = item("a", 100, .userCaches, selected: false)
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let scans = ScanCounter()
        let vm = ScanViewModel(
            scanItems: { _ in
                if scans.next() > 1 {
                    started.continuation.yield(())
                    for await _ in gate.stream { break }
                }
                return [a]
            },
            deleteItems: { _ in XCTFail("staging must never delete"); return [] }
        )
        await vm.scan()
        let before = vm.items.map(\.isSelected)
        let rescan = Task { await vm.scan() }
        for await _ in started.stream { break }
        XCTAssertTrue(vm.isScanning)
        XCTAssertNil(vm.stageSelection([a.id]))
        XCTAssertEqual(vm.items.map(\.isSelected), before)
        XCTAssertNil(vm.assistantStaging)
        XCTAssertFalse(vm.recoveryPreviewRequested)
        gate.continuation.yield(())
        await rescan.value
        XCTAssertFalse(vm.isScanning)
        XCTAssertNotNil(vm.stageSelection([a.id]), "staging works again once the scan is over")
    }

    func testScanRecordsTimestamp() async {
        let vm = await scannedViewModel([])
        XCTAssertNotNil(vm.lastScanAt)
    }

    func testSnapshotBuilderAssignsStableIDsBySize() async {
        let small = item("small", 10, .logs)
        let big = item("big", 500, .developerCaches)
        let tieA = item("a-tie", 50, .userCaches)
        let tieB = item("b-tie", 50, .userCaches)
        let vm = await scannedViewModel([small, tieB, big, tieA])
        let snapshot = AssistantSnapshotBuilder.make(scan: vm, docker: nil, uninstall: nil, memory: nil, volume: nil, now: SystemSnapshot.testDate)
        XCTAssertEqual(snapshot.items.map(\.shortID), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(snapshot.items.map(\.itemID), [big.id, tieA.id, tieB.id, small.id])
        XCTAssertEqual(snapshot.categories.first?.category, .developerCaches)
        XCTAssertNotNil(snapshot.lastScanAt)
        XCTAssertEqual(snapshot.items[0].path, "/Users/tester/Library/Caches/big")
    }

    func testMemoryInfoKeepsTopUserAppsOnly() {
        let kernel = AppMemoryGroup(id: "kernel", displayName: "kernel_task", kind: .system, bundlePath: nil,
                                    processes: [MemoryFixtures.process(0, footprint: 8 << 30)])
        let groups = [
            MemoryFixtures.userGroup("/Applications/Slack.app", processes: [MemoryFixtures.process(2, footprint: 1 << 30)]),
            kernel,
            MemoryFixtures.userGroup("/Applications/Xcode.app", processes: [MemoryFixtures.process(1, footprint: 4 << 30)]),
        ]
        let sample = MemorySample(date: SystemSnapshot.testDate,
                                  system: MemoryFixtures.system(swapUsed: 2 << 30, pressure: .warning),
                                  groups: groups, runningApps: [])
        let info = AssistantSnapshotBuilder.memoryInfo(sample)
        XCTAssertEqual(info.load, .warning)
        XCTAssertEqual(info.swapUsedBytes, 2 << 30)
        XCTAssertEqual(info.physicalBytes, 16 << 30)
        XCTAssertEqual(info.topApps.map(\.name), ["Xcode", "Slack"])
    }

    func testMemoryInfoCarriesBundleIDsAndTopProcesses() {
        let chrome = MemoryFixtures.userGroup("/Applications/Google Chrome.app",
                                              processes: [MemoryFixtures.process(10, footprint: 3 << 30)])
        let system = AppMemoryGroup(id: ProcessGrouper.systemGroupID, displayName: "Система", kind: .system, bundlePath: nil,
                                    processes: [MemoryFixtures.process(0, name: "kernel_task", footprint: 2 << 30),
                                                MemoryFixtures.process(90, name: "WindowServer", footprint: 1 << 30)])
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil,
                                   processes: [MemoryFixtures.process(300, name: "node", footprint: 3 << 29)])
        let sample = MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [chrome, system, other],
                                           runningApps: [MemoryFixtures.app(10, "/Applications/Google Chrome.app", id: "com.google.Chrome")])
        let info = AssistantSnapshotBuilder.memoryInfo(sample)
        XCTAssertEqual(info.topApps, [MemoryAppInfo(name: "Google Chrome", bytes: 3 << 30, bundleID: "com.google.Chrome")])
        XCTAssertEqual(info.topProcesses.map(\.name), ["kernel_task", "node", "WindowServer"])
        XCTAssertEqual(info.topProcesses.first?.bytes, 2 << 30)
    }

    func testTopProcessesAreCapped() {
        let processes = (1...12).map { MemoryFixtures.process(pid_t($0), name: "p\($0)", footprint: UInt64($0) << 20) }
        let system = AppMemoryGroup(id: ProcessGrouper.systemGroupID, displayName: "Система", kind: .system,
                                    bundlePath: nil, processes: processes)
        let notes = MemoryFixtures.userGroup("/Applications/Notes.app",
                                             processes: [MemoryFixtures.process(500, name: "NotesMain", footprint: 1 << 20)])
        let info = AssistantSnapshotBuilder.memoryInfo(MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [system, notes]))
        XCTAssertEqual(info.topProcesses.count, AssistantSnapshotBuilder.maxTopProcesses)
        XCTAssertEqual(info.topProcesses.first?.name, "p12")
        XCTAssertFalse(info.topProcesses.contains { $0.name == "NotesMain" })
        XCTAssertEqual(info.topApps, [MemoryAppInfo(name: "Notes", bytes: 1 << 20, bundleID: nil)])
    }

    func testBundleIDPrefersRegularAppOverNestedHelper() {
        let chrome = MemoryFixtures.userGroup("/Applications/Google Chrome.app",
                                              processes: [MemoryFixtures.process(10, footprint: 3 << 30)])
        let helper = MemoryFixtures.app(11, "/Applications/Google Chrome.app", id: "com.google.Chrome.helper", policy: .accessory)
        let main = MemoryFixtures.app(10, "/Applications/Google Chrome.app", id: "com.google.Chrome")
        let sample = MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [chrome], runningApps: [helper, main])
        XCTAssertEqual(AssistantSnapshotBuilder.memoryInfo(sample).topApps.first?.bundleID, "com.google.Chrome")
    }

    func testBundleIDFallsBackToFirstNonNilWhenNoRegularApp() {
        let agent = MemoryFixtures.userGroup("/Applications/Agent.app",
                                             processes: [MemoryFixtures.process(20, footprint: 1 << 20)])
        let unnamed = MemoryFixtures.app(21, "/Applications/Agent.app", id: nil, policy: .accessory)
        let named = MemoryFixtures.app(20, "/Applications/Agent.app", id: "com.example.agent", policy: .accessory)
        let sample = MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [agent], runningApps: [unnamed, named])
        XCTAssertEqual(AssistantSnapshotBuilder.memoryInfo(sample).topApps.first?.bundleID, "com.example.agent")
    }

    func testMemoryCacheRefreshes() async {
        let sample = MemoryFixtures.sample(at: SystemSnapshot.testDate)
        let cache = AssistantMemoryCache(sample: { sample })
        XCTAssertNil(cache.latest)
        await cache.refresh()
        XCTAssertEqual(cache.latest, sample)
    }

    func testAdvisorSuggestsMemoryUnderPressureOnly() {
        var snapshot = SystemSnapshot.sample()
        XCTAssertFalse(ImprovementAdvisor.suggestions(for: snapshot).contains { $0.id == "memory" })
        snapshot.memory = MemoryInfo(load: .normal, usedBytes: 10, physicalBytes: 20, swapUsedBytes: 3_000_000_000, topApps: [])
        XCTAssertTrue(ImprovementAdvisor.suggestions(for: snapshot).contains { $0.id == "memory" })
        snapshot.memory = MemoryInfo(load: .critical, usedBytes: 10, physicalBytes: 20, swapUsedBytes: 0, topApps: [])
        let memory = ImprovementAdvisor.suggestions(for: snapshot).first { $0.id == "memory" }
        XCTAssertEqual(memory?.title, "Критическая нехватка памяти")
        XCTAssertEqual(memory?.action, .ask("Почему не хватает памяти и какие программы стоит закрыть?"))
    }

    func testFocusForScanItem() {
        let focus = AssistantSnapshotBuilder.focus(for: item("DerivedData", 9_800_000_000, .developerCaches), ownerActivity: .running)
        XCTAssertEqual(focus.title, "DerivedData")
        XCTAssertTrue(focus.facts.contains { $0.hasPrefix("Категория:") })
    }

    func testAdvisorWithoutScanSuggestsScanning() {
        let suggestions = ImprovementAdvisor.suggestions(for: SystemSnapshot(takenAt: SystemSnapshot.testDate, fullDiskAccess: true))
        XCTAssertEqual(suggestions.map(\.action), [.scan])
    }

    func testAdvisorRanksLowSpaceFirstAndCaps() {
        var snapshot = SystemSnapshot.sample()
        snapshot.volume = VolumeInfo(name: "Macintosh HD", totalBytes: 500_000_000_000, availableBytes: 20_000_000_000)
        snapshot.fullDiskAccess = false
        let suggestions = ImprovementAdvisor.suggestions(for: snapshot)
        XCTAssertEqual(suggestions.first?.id, "low-space")
        XCTAssertTrue(suggestions.contains { $0.id == "fda" })
        XCTAssertTrue(suggestions.contains { $0.id == "category-developer_caches" })
        XCTAssertTrue(suggestions.contains { $0.id == "docker" })
        XCTAssertLessThanOrEqual(suggestions.count, 6)
    }

    func testAdvisorFlagsStaleScan() {
        var snapshot = SystemSnapshot.sample()
        snapshot.lastScanAt = SystemSnapshot.testDate.addingTimeInterval(-5 * 86_400)
        XCTAssertTrue(ImprovementAdvisor.suggestions(for: snapshot).contains { $0.id == "stale-scan" && $0.action == .scan })
    }
}
