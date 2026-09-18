import XCTest
@testable import SpotlessMac

@MainActor
final class DockerCleanupViewModelTests: XCTestCase {
    func testScanPreservesDefaultSelectionsAndConfirmationSnapshotIsImmutable() async {
        let initial = makeSnapshot()
        let viewModel = DockerCleanupViewModel(
            scanDocker: { DockerClientScanResult(serverVersion: "29.4.1", snapshot: initial) },
            deleteDocker: { _, _ in [] }
        )

        let didScan = await viewModel.scan()
        XCTAssertTrue(didScan)
        let selection = viewModel.makeCleanupSnapshot()
        let selectedID = initial.resources[0].id
        viewModel.toggle(initial.resources[0])

        XCTAssertEqual(selection?.resources.map(\.id), [selectedID])
        XCTAssertTrue(viewModel.selectedResources.isEmpty)
        XCTAssertEqual(viewModel.availability, .ready(serverVersion: "29.4.1"))
    }

    func testVolumeDeletionRequiresSeparateAcknowledgment() async {
        let volume = DockerResource(
            id: "database-data", kind: .volume, name: "database-data", detail: "",
            size: nil, createdAt: nil, lastUsedAt: nil, risk: .dataLoss, isSelected: true
        )
        let snapshot = DockerScanSnapshot(
            resources: [volume], referencedImageIDs: [], stoppedContainerIDs: [],
            unreferencedImageIDs: [], danglingVolumeNames: [volume.id], reclaimableBuildCacheIDs: []
        )
        let deleteRecorder = DockerDeleteRecorder()
        let viewModel = DockerCleanupViewModel(
            scanDocker: { DockerClientScanResult(serverVersion: nil, snapshot: snapshot) },
            deleteDocker: { resources, evidence in
                await deleteRecorder.record(resources, snapshot: evidence)
                return []
            }
        )
        let didScan = await viewModel.scan()
        XCTAssertTrue(didScan)
        let selection = try! XCTUnwrap(viewModel.makeCleanupSnapshot())

        let result = await viewModel.deleteConfirmed(
            selection,
            volumeAcknowledged: false,
            canClean: true,
            recordSuccessfulClean: {}
        )

        guard case .volumeAcknowledgmentRequired = result else {
            return XCTFail("A selected volume must require a second explicit acknowledgment")
        }
        let deleteCallCount = await deleteRecorder.callCount()
        XCTAssertEqual(deleteCallCount, 0)
    }

    func testSuccessfulDeletionRecordsTrialAndRescans() async {
        let initial = makeSnapshot()
        let empty = DockerScanSnapshot(
            resources: [], referencedImageIDs: [], stoppedContainerIDs: [],
            unreferencedImageIDs: [], danglingVolumeNames: [], reclaimableBuildCacheIDs: []
        )
        let scanQueue = DockerScanQueue([
            DockerClientScanResult(serverVersion: "29.4.1", snapshot: initial),
            DockerClientScanResult(serverVersion: "29.4.1", snapshot: empty),
        ])
        let viewModel = DockerCleanupViewModel(
            scanDocker: { try await scanQueue.next() },
            deleteDocker: { _, _ in [] }
        )
        var recordedCleans = 0
        let didScan = await viewModel.scan()
        XCTAssertTrue(didScan)
        let selection = try! XCTUnwrap(viewModel.makeCleanupSnapshot())

        let result = await viewModel.deleteConfirmed(
            selection,
            volumeAcknowledged: true,
            canClean: true,
            recordSuccessfulClean: { recordedCleans += 1 }
        )

        guard case .completed(let successCount) = result else {
            return XCTFail("Expected a completed Docker cleanup")
        }
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(recordedCleans, 1)
        XCTAssertTrue(viewModel.resources.isEmpty)
        let remainingScans = await scanQueue.remainingCount()
        XCTAssertEqual(remainingScans, 0)
    }

    func testResourceRetainedAfterSuccessfulCommandIsReportedAsFailure() async {
        let initial = makeSnapshot()
        let scanQueue = DockerScanQueue([
            DockerClientScanResult(serverVersion: "29.4.1", snapshot: initial),
            DockerClientScanResult(serverVersion: "29.4.1", snapshot: initial),
        ])
        let viewModel = DockerCleanupViewModel(
            scanDocker: { try await scanQueue.next() },
            deleteDocker: { _, _ in [] }
        )
        var recordedCleans = 0
        let didScan = await viewModel.scan()
        XCTAssertTrue(didScan)
        let selection = try! XCTUnwrap(viewModel.makeCleanupSnapshot())

        let result = await viewModel.deleteConfirmed(
            selection,
            volumeAcknowledged: true,
            canClean: true,
            recordSuccessfulClean: { recordedCleans += 1 }
        )

        guard case .completed(let successCount) = result else {
            return XCTFail("Expected a completed Docker cleanup")
        }
        XCTAssertEqual(successCount, 0)
        XCTAssertEqual(recordedCleans, 0)
        XCTAssertEqual(viewModel.failures.count, 1)
        guard let failure = viewModel.failures.first else {
            return XCTFail("A retained resource must be reported")
        }
        XCTAssertTrue(failure.reason.contains("сохранил"))
    }

    func testCleanupRejectsLicenseAndConcurrentRequestAtAdmission() async {
        let initial = makeSnapshot()
        let deletionStarted = AsyncStream<Void>.makeStream()
        let releaseDeletion = AsyncStream<Void>.makeStream()
        let viewModel = DockerCleanupViewModel(
            scanDocker: { DockerClientScanResult(serverVersion: nil, snapshot: initial) },
            deleteDocker: { _, _ in
                deletionStarted.continuation.yield()
                var iterator = releaseDeletion.stream.makeAsyncIterator()
                _ = await iterator.next()
                return []
            }
        )
        let didScan = await viewModel.scan()
        XCTAssertTrue(didScan)
        let selection = try! XCTUnwrap(viewModel.makeCleanupSnapshot())

        let denied = await viewModel.deleteConfirmed(
            selection, volumeAcknowledged: true, canClean: false, recordSuccessfulClean: {}
        )
        guard case .licenseRequired = denied else { return XCTFail("License must gate admission") }

        var startedIterator = deletionStarted.stream.makeAsyncIterator()
        let first = Task {
            await viewModel.deleteConfirmed(
                selection, volumeAcknowledged: true, canClean: true, recordSuccessfulClean: {}
            )
        }
        _ = await startedIterator.next()
        let overlapping = await viewModel.deleteConfirmed(
            selection, volumeAcknowledged: true, canClean: true, recordSuccessfulClean: {}
        )
        guard case .busy = overlapping else { return XCTFail("Overlapping cleanup must be rejected") }
        releaseDeletion.continuation.yield()
        releaseDeletion.continuation.finish()
        _ = await first.value
    }

    func testExecutableAndDaemonErrorsMapToActionableAvailability() async {
        let missing = DockerCleanupViewModel(
            scanDocker: { throw DockerCommandError.executableNotFound },
            deleteDocker: { _, _ in [] }
        )
        let missingScanAdmitted = await missing.scan()
        XCTAssertTrue(missingScanAdmitted)
        XCTAssertEqual(missing.availability, .cliMissing)

        let stopped = DockerCleanupViewModel(
            scanDocker: {
                throw DockerCommandError.failed(
                    arguments: ["version"], stderr: "Cannot connect to the Docker daemon", exitCode: 1
                )
            },
            deleteDocker: { _, _ in [] }
        )
        let stoppedScanAdmitted = await stopped.scan()
        XCTAssertTrue(stoppedScanAdmitted)
        guard case .daemonUnavailable(let message) = stopped.availability else {
            return XCTFail("Daemon failures need their own UI state")
        }
        XCTAssertTrue(message.contains("Cannot connect"))
    }

    private func makeSnapshot() -> DockerScanSnapshot {
        let cache = DockerResource(
            id: "cache-id", kind: .buildCache, name: "cache", detail: "",
            size: 100, createdAt: nil, lastUsedAt: nil, risk: .rebuildable, isSelected: true
        )
        return DockerScanSnapshot(
            resources: [cache], referencedImageIDs: [], stoppedContainerIDs: [],
            unreferencedImageIDs: [], danglingVolumeNames: [], reclaimableBuildCacheIDs: [cache.id]
        )
    }
}

private actor DockerDeleteRecorder {
    private var calls = 0

    func record(_ resources: [DockerResource], snapshot: DockerScanSnapshot) {
        calls += 1
    }

    func callCount() -> Int { calls }
}

private actor DockerScanQueue {
    private var results: [DockerClientScanResult]

    init(_ results: [DockerClientScanResult]) {
        self.results = results
    }

    func next() throws -> DockerClientScanResult {
        guard !results.isEmpty else {
            throw DockerCommandError.failed(arguments: [], stderr: "No queued scan", exitCode: 1)
        }
        return results.removeFirst()
    }

    func remainingCount() -> Int { results.count }
}
