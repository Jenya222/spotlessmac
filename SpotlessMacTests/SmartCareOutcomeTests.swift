import XCTest
@testable import SpotlessMac

final class SmartCareOutcomeTests: XCTestCase {
    func testClassifiesSuccessfulRun() {
        XCTAssertEqual(
            SmartCareOutcome.classify(
                successfulCount: 2,
                failedCount: 0,
                unprocessedCount: 0,
                cancellationRequested: false
            ),
            .succeeded
        )
    }

    func testClassifiesPartialAndCompleteFailures() {
        XCTAssertEqual(
            SmartCareOutcome.classify(
                successfulCount: 1,
                failedCount: 1,
                unprocessedCount: 0,
                cancellationRequested: false
            ),
            .partialFailure
        )
        XCTAssertEqual(
            SmartCareOutcome.classify(
                successfulCount: 0,
                failedCount: 2,
                unprocessedCount: 0,
                cancellationRequested: false
            ),
            .failed
        )
    }

    func testCancellationWinsOnlyWhenWorkRemains() {
        XCTAssertEqual(
            SmartCareOutcome.classify(
                successfulCount: 1,
                failedCount: 0,
                unprocessedCount: 1,
                cancellationRequested: true
            ),
            .cancelled
        )
        XCTAssertEqual(
            SmartCareOutcome.classify(
                successfulCount: 2,
                failedCount: 0,
                unprocessedCount: 0,
                cancellationRequested: true
            ),
            .succeeded,
            "A cancellation arriving after the last item must not rewrite a completed run"
        )
    }

    func testCategoryStateNeverLeavesFinishedFailureQueued() {
        XCTAssertEqual(
            SmartCareCategoryState.resolve(
                isRunning: false,
                isCurrent: false,
                itemCount: 2,
                successfulCount: 1,
                failedCount: 1,
                unprocessedCount: 0,
                outcome: .partialFailure
            ),
            .failed
        )
    }
}
