import XCTest
@testable import SpotlessMac
@MainActor
final class StorageAnalysisViewModelTests: XCTestCase {
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
