import XCTest
@testable import SpotlessMac

@MainActor
final class SmartCareLifecycleTests: XCTestCase {
    func testSuccessfulRunRecordsTrialWithoutProgressView() async {
        let item = makeItem(size: 10)
        let viewModel = ScanViewModel(smartCareDelete: immediateFactory { .itemProcessed(item: $0, failure: nil) })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(viewModel.smartCareOutcome, .succeeded)
    }

    func testDeniedAndEmptyRunsDoNotStart() {
        let item = makeItem(size: 10)
        let viewModel = ScanViewModel(smartCareDelete: immediateFactory { .itemProcessed(item: $0, failure: nil) })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertFalse(viewModel.startSmartCare(canClean: false) { recorded += 1 })
        viewModel.items[0].isSelected = false
        XCTAssertFalse(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        XCTAssertFalse(viewModel.isCleaning)
        XCTAssertEqual(recorded, 0)
    }

    func testSecondRunCannotStartWhileFirstIsActive() async {
        let item = makeItem(size: 10)
        let pair = AsyncStream<CleaningEvent>.makeStream()
        let viewModel = ScanViewModel(smartCareDelete: { _, _ in pair.stream })
        viewModel.items = [item]

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) {})
        XCTAssertFalse(viewModel.startSmartCare(canClean: true) {})
        pair.continuation.finish()
        await waitUntilFinished(viewModel)
    }

    func testCompleteFailureDoesNotRecordTrial() async {
        let item = makeItem(size: 10)
        let failure = DeletionFailure(item: item, reason: "denied")
        let viewModel = ScanViewModel(smartCareDelete: immediateFactory { .itemProcessed(item: $0, failure: failure) })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 0)
        XCTAssertEqual(viewModel.smartCareOutcome, .failed)
    }

    func testZeroByteSuccessRecordsTrial() async {
        let item = makeItem(size: 0)
        let viewModel = ScanViewModel(smartCareDelete: immediateFactory { .itemProcessed(item: $0, failure: nil) })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 1)
    }

    func testCancellationAfterSuccessRecordsOnceAndKeepsRemainingItem() async {
        let first = makeItem(size: 10)
        let second = makeItem(size: 20, category: .logs)
        let pair = AsyncStream<CleaningEvent>.makeStream()
        let viewModel = ScanViewModel(smartCareDelete: { _, _ in pair.stream })
        viewModel.items = [first, second]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        pair.continuation.yield(.itemProcessed(item: first, failure: nil))
        await waitUntilProcessed(viewModel, count: 1)
        viewModel.stopSmartCare()
        pair.continuation.finish()
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(viewModel.smartCareOutcome, .cancelled)
        XCTAssertEqual(viewModel.unprocessedSmartCareItems.map(\.id), [second.id])
    }

    private func makeItem(size: Int64, category: ScanCategory = .userCaches) -> ScanItem {
        ScanItem(path: URL(filePath: "/tmp/\(UUID().uuidString)"), size: size, category: category)
    }

    private func immediateFactory(
        event: @escaping (ScanItem) -> CleaningEvent
    ) -> ScanViewModel.SmartCareDelete {
        { items, _ in
            AsyncStream { continuation in
                items.forEach { continuation.yield(event($0)) }
                continuation.finish()
            }
        }
    }

    private func waitUntilProcessed(_ viewModel: ScanViewModel, count: Int) async {
        for _ in 0..<1_000 {
            if viewModel.processedSmartCareItemCount == count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for processed items")
    }

    private func waitUntilFinished(_ viewModel: ScanViewModel) async {
        for _ in 0..<1_000 {
            if !viewModel.isCleaning { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for Smart Care to finish")
    }
}
