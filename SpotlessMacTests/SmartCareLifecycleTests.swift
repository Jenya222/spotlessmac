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
        XCTAssertEqual(viewModel.smartCareFailures.map(\.item.id), [item.id])

        viewModel.deletionFailures = []
        XCTAssertEqual(
            viewModel.smartCareFailures.map(\.item.id),
            [item.id],
            "Scan state must not erase the retained Smart Care result"
        )
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

    func testCancellationBeforeFirstItemDoesNotRecordTrial() async {
        let item = makeItem(size: 10)
        let pair = AsyncStream<CleaningEvent>.makeStream()
        let viewModel = ScanViewModel(smartCareDelete: { _, _ in pair.stream })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        viewModel.stopSmartCare()
        pair.continuation.finish()
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 0)
        XCTAssertEqual(viewModel.smartCareOutcome, .cancelled)
        XCTAssertEqual(viewModel.unprocessedSmartCareItems.map(\.id), [item.id])
    }

    func testCancellationAfterFinalItemKeepsSucceededOutcome() async {
        let item = makeItem(size: 10)
        let pair = AsyncStream<CleaningEvent>.makeStream()
        let viewModel = ScanViewModel(smartCareDelete: { _, _ in pair.stream })
        viewModel.items = [item]
        var recorded = 0

        XCTAssertTrue(viewModel.startSmartCare(canClean: true) { recorded += 1 })
        pair.continuation.yield(.itemProcessed(item: item, failure: nil))
        await waitUntilProcessed(viewModel, count: 1)
        viewModel.stopSmartCare()
        pair.continuation.finish()
        await waitUntilFinished(viewModel)

        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(viewModel.smartCareOutcome, .succeeded)
        XCTAssertTrue(viewModel.unprocessedSmartCareItems.isEmpty)
    }

    func testTrialPolicyRejectsSequentialRunAfterFirstSuccess() async {
        let first = makeItem(size: 10)
        let viewModel = ScanViewModel(smartCareDelete: immediateFactory { .itemProcessed(item: $0, failure: nil) })
        viewModel.items = [first]
        var state = LicenseManager.LicenseState.trial(usedCleans: 0, allowed: 1)

        XCTAssertTrue(viewModel.startSmartCare(canClean: LicenseManager.isCleaningAllowed(state: state)) {
            state = .trial(usedCleans: 1, allowed: 1)
        })
        await waitUntilFinished(viewModel)

        viewModel.items = [makeItem(size: 20)]
        XCTAssertFalse(viewModel.startSmartCare(canClean: LicenseManager.isCleaningAllowed(state: state)) {})
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
