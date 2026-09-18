import XCTest
@testable import SpotlessMac

@MainActor
final class StorageRecoveryTests: XCTestCase {
    func testOldInstallerScannerReturnsOnlyOldKnownPackagesUnselected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldDMG = root.appending(path: "Editor.dmg")
        let recentPKG = root.appending(path: "Current.pkg")
        let oldDocument = root.appending(path: "Notes.txt")
        let oldArchive = root.appending(path: "Backup.zip")
        try Data(repeating: 1, count: 16).write(to: oldDMG)
        try Data(repeating: 2, count: 16).write(to: recentPKG)
        try Data(repeating: 3, count: 16).write(to: oldDocument)
        try Data(repeating: 4, count: 16).write(to: oldArchive)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: oldDMG.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-86_400)],
            ofItemAtPath: recentPKG.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: oldDocument.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: oldArchive.path
        )

        let items = try await OldInstallersScanner(
            root: root,
            now: now,
            minimumAge: 7 * 86_400
        ).scan()

        XCTAssertEqual(items.map(\.path.lastPathComponent), ["Editor.dmg"])
        XCTAssertEqual(items.first?.category, .oldInstallers)
        XCTAssertEqual(items.first?.isSelected, false)
        XCTAssertNotNil(items.first?.modifiedAt)
    }

    func testDeveloperCacheScannerReturnsTopLevelEntriesSelected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }

        let projectCache = root.appending(path: "Project-abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectCache, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32).write(to: projectCache.appending(path: "build.dat"))

        let items = try await DeveloperCachesScanner(roots: [root]).scan()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path.lastPathComponent, projectCache.lastPathComponent)
        XCTAssertEqual(items.first?.size, 32)
        XCTAssertEqual(items.first?.category, .developerCaches)
        XCTAssertEqual(items.first?.isSelected, true)
    }

    func testStorageRecoveryQueryFiltersAndSortsBySize() {
        let small = ScanItem(
            path: URL(filePath: "/tmp/Archive.zip"),
            size: 10,
            category: .oldInstallers,
            isSelected: false
        )
        let large = ScanItem(
            path: URL(filePath: "/tmp/Editor.dmg"),
            size: 50,
            category: .oldInstallers,
            isSelected: false
        )
        let cache = ScanItem(
            path: URL(filePath: "/tmp/cache"),
            size: 100,
            category: .userCaches
        )

        let result = StorageRecoveryQuery.filter(
            [small, cache, large],
            searchText: ".",
            sort: .sizeDescending
        )

        XCTAssertEqual(result.map(\.id), [large.id, small.id])
    }

    func testLargeFileScannerUsesConfiguredThresholdAndKeepsResultsUnselected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }

        let small = root.appending(path: "small.bin")
        let large = root.appending(path: "large.bin")
        try Data(repeating: 0, count: 16).write(to: small)
        try Data(repeating: 0, count: 64).write(to: large)

        let items = try await LargeFilesScanner(roots: [root], threshold: 32).scan()

        XCTAssertEqual(items.map(\.path.lastPathComponent), ["large.bin"])
        XCTAssertEqual(items.first?.isSelected, false)
        XCTAssertNotNil(items.first?.modifiedAt)
    }

    func testDeduplicationPrefersSpecificInstallerRecommendation() {
        let path = URL(filePath: "/tmp/Editor.dmg")
        let large = ScanItem(path: path, size: 800, category: .largeFiles, isSelected: false)
        let installer = ScanItem(path: path, size: 800, category: .oldInstallers, isSelected: false)

        let result = ScanResultMerger.deduplicate([large, installer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, .oldInstallers)
    }

    func testCacheAndLogScannersIncludeModificationDates() async throws {
        let cacheRoot = try makeTemporaryDirectory()
        let logRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: cacheRoot, resultingItemURL: nil) }
        defer { try? FileManager.default.trashItem(at: logRoot, resultingItemURL: nil) }

        let cache = cacheRoot.appending(path: "com.example.cache")
        let log = logRoot.appending(path: "example.log")
        try Data(repeating: 0, count: 8).write(to: cache)
        try Data(repeating: 0, count: 8).write(to: log)
        let modifiedAt = Date(timeIntervalSince1970: 1_500_000)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: cache.path)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: log.path)

        let cacheItems = try await CachesScanner(root: cacheRoot).scan()
        let logItems = try await LogsScanner(fdaGranted: false, userRoot: logRoot).scan()

        XCTAssertEqual(cacheItems.first?.modifiedAt, modifiedAt)
        XCTAssertEqual(logItems.first?.modifiedAt, modifiedAt)
    }

    func testDeletionRequestsAreSerialized() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let firstItem = ScanItem(path: URL(filePath: "/tmp/cache-a"), size: 1, category: .userCaches)
        let secondItem = ScanItem(path: URL(filePath: "/tmp/cache-b"), size: 1, category: .userCaches)
        let viewModel = ScanViewModel(deleteItems: { _ in
            started.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return []
        })
        viewModel.items = [firstItem, secondItem]

        var startedIterator = started.stream.makeAsyncIterator()
        let firstRequest = Task { await viewModel.delete(items: [firstItem]) }
        _ = await startedIterator.next()

        let overlappingRequest = await viewModel.delete(items: [secondItem])
        guard case .busy = overlappingRequest else {
            return XCTFail("An overlapping destructive operation must be rejected")
        }

        release.continuation.yield()
        release.continuation.finish()
        _ = await firstRequest.value
    }

    func testManualDeletionAndSmartCareCannotOverlap() async {
        let manualStarted = AsyncStream<Void>.makeStream()
        let releaseManual = AsyncStream<Void>.makeStream()
        let manualItem = ScanItem(path: URL(filePath: "/tmp/manual"), size: 1, category: .userCaches)
        let manualViewModel = ScanViewModel(deleteItems: { _ in
            manualStarted.continuation.yield()
            var iterator = releaseManual.stream.makeAsyncIterator()
            _ = await iterator.next()
            return []
        })
        manualViewModel.items = [manualItem]

        var manualStartedIterator = manualStarted.stream.makeAsyncIterator()
        let manualRequest = Task { await manualViewModel.delete(items: [manualItem]) }
        _ = await manualStartedIterator.next()
        XCTAssertFalse(manualViewModel.startSmartCare(canClean: true) {})
        releaseManual.continuation.yield()
        releaseManual.continuation.finish()
        _ = await manualRequest.value

        let smartCareStream = AsyncStream<CleaningEvent>.makeStream()
        let smartCareItem = ScanItem(path: URL(filePath: "/tmp/smart"), size: 1, category: .userCaches)
        let smartCareViewModel = ScanViewModel(smartCareDelete: { _, _ in smartCareStream.stream })
        smartCareViewModel.items = [smartCareItem]
        XCTAssertTrue(smartCareViewModel.startSmartCare(canClean: true) {})

        let manualDuringSmartCare = await smartCareViewModel.delete(items: [smartCareItem])
        guard case .busy = manualDuringSmartCare else {
            return XCTFail("Manual deletion must be rejected while Smart Care is active")
        }
        smartCareStream.continuation.finish()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
