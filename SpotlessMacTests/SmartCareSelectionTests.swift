import XCTest
@testable import SpotlessMac

@MainActor
final class SmartCareSelectionTests: XCTestCase {
    func testSelectionDrivesTotalsAndRunSnapshot() {
        let selected = ScanItem(path: URL(filePath: "/tmp/cache-a"), size: 100, category: .userCaches)
        let deselected = ScanItem(path: URL(filePath: "/tmp/cache-b"), size: 200, category: .logs, isSelected: false)
        let large = ScanItem(path: URL(filePath: "/tmp/archive.zip"), size: 400, category: .largeFiles)
        let viewModel = ScanViewModel()
        viewModel.items = [selected, deselected, large]

        XCTAssertEqual(viewModel.smartCareSelectedItems.map(\.id), [selected.id])
        XCTAssertEqual(viewModel.smartCareSelectedBytes, 100)

        let run = viewModel.makeSmartCareRun()
        XCTAssertEqual(run?.items.map(\.id), [selected.id])
        XCTAssertEqual(run?.totalBytes, 100)

        viewModel.items[0].isSelected = false
        XCTAssertEqual(run?.items.map(\.id), [selected.id], "The confirmed work set must be immutable")
    }

    func testEmptySelectionDoesNotCreateRun() {
        let viewModel = ScanViewModel()
        viewModel.items = [
            ScanItem(path: URL(filePath: "/tmp/cache"), size: 100, category: .userCaches, isSelected: false),
            ScanItem(path: URL(filePath: "/tmp/large"), size: 200, category: .largeFiles),
        ]

        XCTAssertNil(viewModel.makeSmartCareRun())
    }

    func testSmartCareIncludesDeveloperCachesButExcludesReviewOnlyFiles() {
        let developerCache = ScanItem(
            path: URL(filePath: "/tmp/DerivedData"),
            size: 120,
            category: .developerCaches
        )
        let installer = ScanItem(
            path: URL(filePath: "/tmp/Installer.dmg"),
            size: 500,
            category: .oldInstallers,
            isSelected: true
        )
        let viewModel = ScanViewModel()
        viewModel.items = [developerCache, installer]

        XCTAssertEqual(viewModel.smartCareSelectedItems.map(\.id), [developerCache.id])
        XCTAssertEqual(viewModel.selectedItems.map(\.id), [developerCache.id])
    }

    func testConfirmationTotalsIgnorePreviousRunSnapshot() async {
        let old = ScanItem(path: URL(filePath: "/tmp/old"), size: 100, category: .userCaches)
        let pair = AsyncStream<CleaningEvent>.makeStream()
        let viewModel = ScanViewModel(smartCareDelete: { _, _ in pair.stream })
        viewModel.items = [old]

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) {})
        viewModel.items = [
            ScanItem(path: URL(filePath: "/tmp/new"), size: 350, category: .logs),
        ]

        XCTAssertEqual(viewModel.smartCareSelectionCategoryTotals.map(\.totalBytes), [350])
        pair.continuation.finish()
        for _ in 0..<1_000 {
            if !viewModel.isCleaning { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the retained run to finish")
    }
}
