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
}
