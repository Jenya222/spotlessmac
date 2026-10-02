import Foundation
import Observation

@Observable
@MainActor
final class ScanViewModel {
    typealias SmartCareDelete = ([ScanItem], CleaningCancellation) -> AsyncStream<CleaningEvent>
    typealias ScanItems = (FDAStatus) async throws -> [ScanItem]
    typealias DeleteItems = ([ScanItem]) async -> [DeletionFailure]

    var items: [ScanItem] = []
    var isScanning = false
    var isDeleting = false
    var scanError: String?
    var deletionFailures: [DeletionFailure] = []
    var fdaStatus: FDAStatus = .unknown

    // Assistant staging: selection prepared by the assistant for the user's review.
    struct AssistantStaging: Equatable {
        let count: Int
        let bytes: Int64
    }
    private(set) var lastScanAt: Date?
    private(set) var assistantStaging: AssistantStaging?
    var recoveryPreviewRequested = false

    // Smart Care (dashboard one-click flow)
    var isPreparingSmartCare = false
    var isCleaning = false
    var currentCleaningItem: ScanItem?
    var bytesFreedSoFar: Int64 = 0 // Compatibility: bytes moved to Trash, not reclaimed.
    var cleanupReports: [CleanupReport] = []
    var cleanupReport: CleanupReport? { cleanupReports.first }
    var completedCategories: Set<ScanCategory> = []
    var cleaningStartedAt: Date?
    private(set) var activeSmartCareRun: SmartCareRun?
    private(set) var smartCareOutcome: SmartCareOutcome?
    private(set) var smartCareFailures: [DeletionFailure] = []
    private(set) var unprocessedSmartCareItems: [ScanItem] = []
    private(set) var processedSmartCareItemIDs: Set<UUID> = []
    private(set) var successfulSmartCareItemIDs: Set<UUID> = []
    private(set) var failedSmartCareItemIDs: Set<UUID> = []

    private let engine: ScanEngine
    private let smartCareDelete: SmartCareDelete
    private let scanItems: ScanItems
    private let deleteItems: DeleteItems
    private let sampleSpace: @Sendable (URL) async -> VolumeSample?
    private var cleaningTask: Task<Void, Never>?
    private var cleaningCancellation: CleaningCancellation?

    // Only rebuildable data participates in the one-click flow.
    private let smartCareCategories: Set<ScanCategory> = [.userCaches, .developerCaches, .logs]

    init(
        engine: ScanEngine = ScanEngine(),
        smartCareDelete: SmartCareDelete? = nil,
        scanItems: ScanItems? = nil,
        deleteItems: DeleteItems? = nil,
        sampleSpace: @escaping @Sendable (URL) async -> VolumeSample? = { try? await VolumeSpaceReader.sample(at: $0) }
    ) {
        self.engine = engine
        self.sampleSpace = sampleSpace
        self.smartCareDelete = smartCareDelete ?? { items, cancellation in
            engine.deleteWithProgress(items: items, cancellation: cancellation)
        }
        self.scanItems = scanItems ?? { fdaStatus in
            try await engine.scan(fdaStatus: fdaStatus)
        }
        self.deleteItems = deleteItems ?? { items in
            await engine.delete(items: items)
        }
    }

    var cleaningProgressFraction: Double {
        guard let count = activeSmartCareRun?.items.count, count > 0 else { return 0 }
        return min(1, Double(processedSmartCareItemCount) / Double(count))
    }

    var processedSmartCareItemCount: Int { processedSmartCareItemIDs.count }

    func smartCareCategoryState(for category: ScanCategory) -> SmartCareCategoryState {
        guard let run = activeSmartCareRun else { return .pending }
        let categoryItems = run.items.filter { $0.category == category }
        let categoryIDs = Set(categoryItems.map(\.id))
        return SmartCareCategoryState.resolve(
            isRunning: isCleaning,
            isCurrent: currentCleaningItem?.category == category,
            itemCount: categoryItems.count,
            successfulCount: categoryIDs.intersection(successfulSmartCareItemIDs).count,
            failedCount: categoryIDs.intersection(failedSmartCareItemIDs).count,
            unprocessedCount: categoryIDs.intersection(Set(unprocessedSmartCareItems.map(\.id))).count,
            outcome: smartCareOutcome
        )
    }

    var smartCareSelectedItems: [ScanItem] {
        (try? CleanupPlanBuilder.make(items: items.filter { smartCareCategories.contains($0.category) && $0.isSelected })) ?? []
    }

    var smartCareSelectedBytes: Int64 {
        smartCareSelectedItems.reduce(0) { $0 + $1.size }
    }

    var smartCareCategoryTotals: [CategoryTotal] {
        activeSmartCareRun?.categoryTotals ?? smartCareSelectionCategoryTotals
    }

    var smartCareSelectionCategoryTotals: [CategoryTotal] {
        SmartCareRun(items: smartCareSelectedItems).categoryTotals
    }

    var smartCareTotalBytes: Int64 {
        activeSmartCareRun?.totalBytes ?? smartCareSelectedBytes
    }

    func checkFDA() {
        fdaStatus = FDAService.detect()
    }

    func scan() async {
        guard !isCleaning, !isDeleting else { return }
        checkFDA()
        isScanning = true
        scanError = nil
        deletionFailures = []
        defer { isScanning = false }
        assistantStaging = nil
        do {
            items = try await scanItems(fdaStatus)
            lastScanAt = Date()
        } catch {
            scanError = error.localizedDescription
        }
    }

    // Serializes all manual destructive operations and deletes exactly the
    // snapshot that was shown in the confirmation UI.
    func delete(items targetItems: [ScanItem]) async -> DeletionRequestResult {
        guard !isDeleting, !isCleaning else { return .busy }
        isDeleting = true
        defer { isDeleting = false }
        deletionFailures = []
        let before = await samples(for: targetItems)
        let failures = await deleteItems(targetItems)
        deletionFailures = failures
        let failedIDs = Set(failures.map(\.item.id))
        let successIDs = Set(targetItems.map(\.id)).subtracting(failedIDs)
        items.removeAll { successIDs.contains($0.id) }
        cleanupReports = await reports(for: targetItems.filter { successIDs.contains($0.id) }, before: before)
        assistantStaging = nil
        return .completed(failures)
    }

    // Per-item delete for large files. Returns failure if trashing failed.
    func deleteSingle(_ item: ScanItem) async -> DeletionFailure? {
        switch await delete(items: [item]) {
        case .completed(let failures):
            return failures.first
        case .busy:
            return DeletionFailure(item: item, reason: "Дождитесь завершения текущей очистки.")
        }
    }

    func toggleSelection(_ item: ScanItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    // Review-only findings are never selected for batch cleanup.
    func selectAll() {
        items.indices.forEach { idx in
            if items[idx].category.isBatchCleanable {
                items[idx].isSelected = true
            }
        }
    }
    func selectNone() { items.indices.forEach { items[$0].isSelected = false } }

    // Marks only existing batch-cleanable items; never deletes anything. Item IDs change on every
    // scan, so a plan that matches nothing (stale after a rescan or restart) returns nil and
    // leaves the current selection untouched.
    @discardableResult
    func stageSelection(_ ids: Set<UUID>) -> AssistantStaging? {
        guard items.contains(where: { $0.category.isBatchCleanable && ids.contains($0.id) }) else { return nil }
        var count = 0
        var bytes: Int64 = 0
        for index in items.indices where items[index].category.isBatchCleanable {
            let selected = ids.contains(items[index].id)
            items[index].isSelected = selected
            if selected {
                count += 1
                bytes += items[index].size
            }
        }
        let staging = AssistantStaging(count: count, bytes: bytes)
        assistantStaging = staging
        recoveryPreviewRequested = true
        return staging
    }

    func clearAssistantStaging() {
        assistantStaging = nil
    }

    var cleanableItems: [ScanItem] { items.filter { $0.category.isBatchCleanable } }
    var largeFileItems: [ScanItem] { items.filter { $0.category == .largeFiles } }
    var selectedItems: [ScanItem] { (try? CleanupPlanBuilder.make(items: cleanableItems.filter(\.isSelected))) ?? [] }
    var totalSelectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var hasSelection: Bool { !selectedItems.isEmpty }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }

    // MARK: - Smart Care

    // Scans, then computes per-category totals for the confirmation sheet.
    // Does NOT delete anything yet.
    func prepareSmartCare() async {
        isPreparingSmartCare = true
        defer { isPreparingSmartCare = false }
        await scan()
    }

    func makeSmartCareRun() -> SmartCareRun? {
        let selected = smartCareSelectedItems
        guard !selected.isEmpty else { return nil }
        return SmartCareRun(items: selected)
    }

    // Called after the user confirms in the sheet. Only selected eligible
    // items are cleaned (mirrors existing per-item deselect via toggleSelection).
    @discardableResult
    func startSmartCare(licenseManager: LicenseManager) -> Bool {
        startSmartCare(canClean: licenseManager.canClean) {
            if !licenseManager.isActivated {
                licenseManager.recordClean()
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSmartCareTimestamp")
        }
    }

    @discardableResult
    func startSmartCare(
        canClean: Bool,
        recordSuccessfulClean: @escaping @MainActor () -> Void
    ) -> Bool {
        guard canClean, !isCleaning, !isDeleting, cleaningTask == nil, let run = makeSmartCareRun() else {
            return false
        }
        activeSmartCareRun = run
        isCleaning = true
        bytesFreedSoFar = 0
        completedCategories = []
        deletionFailures = []
        smartCareFailures = []
        processedSmartCareItemIDs = []
        successfulSmartCareItemIDs = []
        failedSmartCareItemIDs = []
        unprocessedSmartCareItems = []
        smartCareOutcome = nil
        cleaningStartedAt = Date()
        let cancellation = CleaningCancellation()
        cleaningCancellation = cancellation
        cleaningTask = Task {
            await runSmartCare(run, cancellation: cancellation, recordSuccessfulClean: recordSuccessfulClean)
        }
        return true
    }

    func stopSmartCare() {
        cleaningCancellation?.cancel()
    }

    private func runSmartCare(
        _ run: SmartCareRun,
        cancellation: CleaningCancellation,
        recordSuccessfulClean: @escaping @MainActor () -> Void
    ) async {
        cleanupReports = []
        let before = await samples(for: run.items)
        for await event in smartCareDelete(run.items, cancellation) {
            switch event {
            case .itemProcessed(let item, let failure):
                currentCleaningItem = item
                processedSmartCareItemIDs.insert(item.id)
                if let failure {
                    deletionFailures.append(failure)
                    smartCareFailures.append(failure)
                    failedSmartCareItemIDs.insert(item.id)
                } else {
                    successfulSmartCareItemIDs.insert(item.id)
                    bytesFreedSoFar += item.size
                    items.removeAll { $0.id == item.id }
                }
                updateCompletedCategories(for: run)
            }
        }

        unprocessedSmartCareItems = run.items.filter { !processedSmartCareItemIDs.contains($0.id) }
        smartCareOutcome = SmartCareOutcome.classify(
            successfulCount: successfulSmartCareItemIDs.count,
            failedCount: smartCareFailures.count,
            unprocessedCount: unprocessedSmartCareItems.count,
            cancellationRequested: cancellation.isCancelled
        )

        if !successfulSmartCareItemIDs.isEmpty {
            recordSuccessfulClean()
        }
        cleanupReports = await reports(for: run.items.filter { successfulSmartCareItemIDs.contains($0.id) }, before: before)
        isCleaning = false
        currentCleaningItem = nil
        cleaningCancellation = nil
        cleaningTask = nil
    }

    private func samples(for candidates: [ScanItem]) async -> [String: VolumeSample] {
        var result: [String: VolumeSample] = [:]
        for parent in Set(candidates.map { $0.path.deletingLastPathComponent() }) {
            if let sample = await sampleSpace(parent) { result[sample.volumeID] = sample }
        }
        return result
    }

    private func reports(for succeeded: [ScanItem], before: [String: VolumeSample]) async -> [CleanupReport] {
        var byVolume: [String: (VolumeSample, Int64, Int)] = [:]
        var unknownBytes: Int64 = 0
        var unknownCount = 0
        for item in succeeded {
            if let after = await sampleSpace(item.path.deletingLastPathComponent()) {
                let previous = byVolume[after.volumeID]
                byVolume[after.volumeID] = (after, (previous?.1 ?? 0) + item.size, (previous?.2 ?? 0) + 1)
            } else { unknownBytes += item.size; unknownCount += 1 }
        }
        var reports = byVolume.sorted { $0.key < $1.key }.map { id, value in
            CleanupReport(trashedBytes: value.1, successfulItems: value.2, before: before[id], after: value.0)
        }
        if unknownCount > 0 { reports.append(CleanupReport(trashedBytes: unknownBytes, successfulItems: unknownCount, before: nil, after: nil)) }
        return reports
    }

    private func updateCompletedCategories(for run: SmartCareRun) {
        for total in run.categoryTotals {
            let categoryIDs = Set(run.items.filter { $0.category == total.category }.map(\.id))
            if categoryIDs.isSubset(of: successfulSmartCareItemIDs) {
                completedCategories.insert(total.category)
            }
        }
    }
}
