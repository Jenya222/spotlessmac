import XCTest
@testable import SpotlessMac
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
@MainActor
final class StorageAnalysisViewModelTests: XCTestCase {
    private func sources(_ names: [String]) -> [StorageSource] {
        names.map { StorageSource(url: URL(filePath: "/tmp/\($0)"), title: $0, explanation: "") }
    }
    private func sizes(_ vm: StorageAnalysisViewModel) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: vm.sourceResults.map { ($0.source.title, $0.measurement?.allocatedBytes ?? -1) })
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
    func testSlowSourceDoesNotHoldBackTheRest() async throws {
        let all = sources(["slow", "a", "b", "c", "d"])
        let vm = StorageAnalysisViewModel(sources: { all }, measureSource: { url in
            if url.lastPathComponent == "slow" { try await Task.sleep(for: .seconds(5)) }
            return StorageMeasurement(allocatedBytes: 1)
        })
        let scan = Task { await vm.scanSources() }
        try await waitUntil { vm.sourceResults.count == 4 }
        XCTAssertEqual(Set(sizes(vm).keys), ["a", "b", "c", "d"])
        vm.cancel()
        await scan.value
    }
    func testRefreshKeepsPreviousSizesUntilRemeasured() async throws {
        let refreshing = Flag()
        let vm = StorageAnalysisViewModel(sources: { [all = sources(["fast", "slow"])] in all }, measureSource: { url in
            guard refreshing.isSet else { return StorageMeasurement(allocatedBytes: 10) }
            if url.lastPathComponent == "slow" { try await Task.sleep(for: .seconds(5)) }
            return StorageMeasurement(allocatedBytes: 20)
        })
        await vm.scanSources()
        refreshing.set()
        let refresh = Task { await vm.scanSources() }
        try await waitUntil { sizes(vm)["fast"] == 20 }
        XCTAssertEqual(sizes(vm), ["fast": 20, "slow": 10])
        XCTAssertEqual(vm.breakdownSources.count, 2)
        vm.cancel()
        await refresh.value
    }
    func testFirstPassShowsNoBreakdownUntilEverySourceIsMeasured() async throws {
        let vm = StorageAnalysisViewModel(sources: { [all = sources(["fast", "slow"])] in all }, measureSource: { url in
            if url.lastPathComponent == "slow" { try await Task.sleep(for: .seconds(5)) }
            return StorageMeasurement(allocatedBytes: 10)
        })
        let scan = Task { await vm.scanSources() }
        try await waitUntil { vm.sourceResults.count == 1 }
        XCTAssertEqual(vm.sourceResults.count, 1)
        XCTAssertTrue(vm.breakdownSources.isEmpty)
        // A stopped pass shows what it measured; the overview marks it incomplete.
        vm.cancel()
        await scan.value
        XCTAssertEqual(vm.breakdownSources.count, 1)
    }
    func testDeniedIsReportedInsteadOfEmpty() async {
        let vm = StorageAnalysisViewModel(loadChildren: { _ in throw CocoaError(.fileReadNoPermission) })
        await vm.scan(root: URL(filePath: "/tmp/fixture"))
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }
    func testOldScanCannotOverwriteNewScan() async {
        let vm = StorageAnalysisViewModel(loadChildren: { url in
            if url.lastPathComponent == "old" { try? await Task.sleep(for: .milliseconds(80)) }
            return [StorageNode(url: url, measurement: StorageMeasurement(), isDirectory: true, isPackage: false)]
        })
        let old = Task { await vm.scan(root: URL(filePath: "/tmp/old")) }
        await Task.yield()
        await vm.scan(root: URL(filePath: "/tmp/new"))
        await old.value
        XCTAssertEqual(vm.nodes.first?.url.lastPathComponent, "new")
        XCTAssertFalse(vm.isLoading)
    }
    func testCancelKeepsPreviousSnapshotMarkedStale() async {
        let vm = StorageAnalysisViewModel(loadChildren: { url in
            if url.lastPathComponent == "slow" { try await Task.sleep(for: .seconds(1)) }
            return [StorageNode(url: url, measurement: StorageMeasurement(), isDirectory: true, isPackage: false)]
        })
        await vm.scan(root: URL(filePath: "/tmp/first"))
        let next = Task { await vm.scan(root: URL(filePath: "/tmp/slow")) }
        await Task.yield()
        vm.cancel()
        await next.value
        XCTAssertEqual(vm.nodes.first?.url.lastPathComponent, "first")
        XCTAssertTrue(vm.isStale)
    }
    func testOnlyDeletableNodesBecomeTrashCandidates() async {
        let vm = StorageAnalysisViewModel(
            loadChildren: { root in
                ["keep", "trash"].map {
                    StorageNode(url: root.appending(path: $0), measurement: StorageMeasurement(logicalBytes: 10, allocatedBytes: 4096), isDirectory: false, isPackage: false)
                }
            },
            isDeletable: { $0.lastPathComponent == "trash" }
        )
        await vm.scan(root: URL(filePath: "/tmp/fixture"))
        XCTAssertEqual(vm.deletableNodeIDs, ["/tmp/fixture/trash"])

        let items = vm.deletionItems(for: Set(vm.nodes.map(\.id)))
        XCTAssertEqual(items.map(\.path.lastPathComponent), ["trash"])
        XCTAssertEqual(items.first?.size, 4096)
        XCTAssertEqual(items.first?.isSelected, true)
        XCTAssertEqual(items.first?.cleanupPolicy.canDelete, true)
        XCTAssertEqual(items.first?.cleanupPolicy.requiresClosedOwner, false)
    }
    func testNodeFocusDescribesSourceAndDeletability() {
        let source = StorageSource(url: URL(filePath: "/tmp/models"), title: "Модели Ollama", explanation: "Только просмотр.")
        let node = StorageNode(url: URL(filePath: "/tmp/models/blobs/sha256-abc"), measurement: StorageMeasurement(logicalBytes: 42, allocatedBytes: 4096), isDirectory: false, isPackage: false)

        let focus = AssistantSnapshotBuilder.focus(for: node, deletable: false, sources: [source])

        XCTAssertEqual(focus.title, "sha256-abc")
        XCTAssertTrue(focus.facts.contains("Тип: файл"))
        XCTAssertTrue(focus.facts.contains { $0.contains("Модели Ollama") && $0.contains("Только просмотр.") })
        XCTAssertTrue(focus.facts.contains { $0.hasPrefix("SpotlessMac не удаляет") })
    }
}
