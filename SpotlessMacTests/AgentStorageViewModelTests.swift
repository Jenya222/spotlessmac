import XCTest
@testable import SpotlessMac

@MainActor
final class AgentStorageViewModelTests: XCTestCase {
    private func item() throws -> AgentStorageItem {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: root.path)
        return try AgentStorageScanner.inspect(root, source: .init(url: root, agent: "Claude", kind: .cache))
    }

    func testNoDefaultSelectionAndStalePreviewIsRejected() async throws {
        let entry = try item()
        let vm = AgentStorageViewModel(scan: { AgentStorageReport(items: [entry]) }, delete: { _ in
            XCTFail("Stale preview must never reach deletion"); return []
        })
        await vm.scan()
        XCTAssertNil(vm.makeSelection())
        vm.toggle(entry)
        let selection = try XCTUnwrap(vm.makeSelection())
        await vm.scan()
        let result = await vm.deleteConfirmed(selection, canClean: true, recordSuccessfulClean: {})
        XCTAssertEqual(result, .staleSelection)
    }

    func testLicenseAndFailurePreserveItems() async throws {
        let entry = try item()
        let vm = AgentStorageViewModel(scan: { AgentStorageReport(items: [entry]) }, delete: { items in
            items.map { DeletionFailure(item: $0, reason: "Владелец работает") }
        })
        await vm.scan(); vm.toggle(entry)
        let selection = try XCTUnwrap(vm.makeSelection())
        let blocked = await vm.deleteConfirmed(selection, canClean: false, recordSuccessfulClean: { XCTFail() })
        XCTAssertEqual(blocked, .licenseRequired)
        let result = await vm.deleteConfirmed(selection, canClean: true, recordSuccessfulClean: { XCTFail() })
        XCTAssertEqual(result, .completed(0))
        XCTAssertEqual(vm.failures.count, 1)
        XCTAssertEqual(vm.report.items.count, 1)
        XCTAssertTrue(vm.selectedIDs.isEmpty)
    }

    func testSuccessfulCleanupRecordsOnceAndRemovesSuccessfulRows() async throws {
        let entry = try item()
        let vm = AgentStorageViewModel(scan: { AgentStorageReport(items: [entry]) }, delete: { _ in [] })
        await vm.scan(); vm.toggle(entry)
        let selection = try XCTUnwrap(vm.makeSelection())
        var recordings = 0
        let result = await vm.deleteConfirmed(selection, canClean: true, recordSuccessfulClean: { recordings += 1 })
        XCTAssertEqual(result, .completed(1))
        XCTAssertEqual(recordings, 1)
        XCTAssertTrue(vm.report.items.isEmpty)
        let retry = await vm.deleteConfirmed(selection, canClean: true, recordSuccessfulClean: { recordings += 1 })
        XCTAssertEqual(retry, .staleSelection)
        XCTAssertEqual(recordings, 1)
    }

    func testCancellationDoesNotPublishPartialResults() async {
        let vm = AgentStorageViewModel(scan: {
            try await Task.sleep(for: .seconds(30)); return AgentStorageReport()
        })
        vm.startScan()
        await Task.yield()
        vm.cancelScan()
        while vm.isScanning { await Task.yield() }
        XCTAssertFalse(vm.hasScanned)
        XCTAssertNil(vm.makeSelection())
    }
}
