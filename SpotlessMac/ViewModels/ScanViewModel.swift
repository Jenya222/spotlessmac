import Foundation
import Observation

@Observable
@MainActor
final class ScanViewModel {
    typealias SmartCareDelete = ([ScanItem], CleaningCancellation) -> AsyncStream<CleaningEvent>

    var items: [ScanItem] = []
    var isScanning = false
    var isDeleting = false
    var scanError: String?
    var deletionFailures: [DeletionFailure] = []
    var fdaStatus: FDAStatus = .unknown

    // Smart Care (dashboard one-click flow)
    var isPreparingSmartCare = false
    var isCleaning = false
    var currentCleaningItem: ScanItem?
    var bytesFreedSoFar: Int64 = 0
    var completedCategories: Set<ScanCategory> = []
    var cleaningStartedAt: Date?
    private(set) var activeSmartCareRun: SmartCareRun?
    private(set) var smartCareOutcome: SmartCareOutcome?
    private(set) var unprocessedSmartCareItems: [ScanItem] = []
    private(set) var processedSmartCareItemIDs: Set<UUID> = []
    private(set) var successfulSmartCareItemIDs: Set<UUID> = []
    private(set) var failedSmartCareItemIDs: Set<UUID> = []

    private let engine: ScanEngine
    private let smartCareDelete: SmartCareDelete
    private var cleaningTask: Task<Void, Never>?
    private var cleaningCancellation: CleaningCancellation?

    // Real categories eligible for the one-click flow. .largeFiles never
    // participates in batch delete (existing invariant, see delete() below).
    private let smartCareCategories: Set<ScanCategory> = [.userCaches, .logs]

    init(engine: ScanEngine = ScanEngine(), smartCareDelete: SmartCareDelete? = nil) {
        self.engine = engine
        self.smartCareDelete = smartCareDelete ?? { items, cancellation in
            engine.deleteWithProgress(items: items, cancellation: cancellation)
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
        items.filter { smartCareCategories.contains($0.category) && $0.isSelected }
    }

    var smartCareSelectedBytes: Int64 {
        smartCareSelectedItems.reduce(0) { $0 + $1.size }
    }

    var smartCareCategoryTotals: [CategoryTotal] {
        activeSmartCareRun?.categoryTotals ?? SmartCareRun(items: smartCareSelectedItems).categoryTotals
    }

    var smartCareTotalBytes: Int64 {
        activeSmartCareRun?.totalBytes ?? smartCareSelectedBytes
    }

    func checkFDA() {
        fdaStatus = FDAService.detect()
    }

    func scan() async {
        guard !isCleaning else { return }
        checkFDA()
        isScanning = true
        scanError = nil
        deletionFailures = []
        defer { isScanning = false }
        do {
            items = try await engine.scan(fdaStatus: fdaStatus)
        } catch {
            scanError = error.localizedDescription
        }
    }

    // Batch delete — never touches .largeFiles (defense in depth).
    func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        deletionFailures = []
        let toDelete = selectedItems.filter { $0.category != .largeFiles }
        let failures = await engine.delete(items: toDelete)
        deletionFailures = failures
        let failedIDs = Set(failures.map(\.item.id))
        let successIDs = Set(toDelete.map(\.id)).subtracting(failedIDs)
        items.removeAll { successIDs.contains($0.id) }
    }

    // Per-item delete for large files. Returns failure if trashing failed.
    func deleteSingle(_ item: ScanItem) async -> DeletionFailure? {
        let failures = await engine.delete(items: [item])
        if let failure = failures.first {
            return failure
        }
        items.removeAll { $0.id == item.id }
        return nil
    }

    func toggleSelection(_ item: ScanItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    // Never selects .largeFiles items.
    func selectAll() {
        items.indices.forEach { idx in
            if items[idx].category != .largeFiles {
                items[idx].isSelected = true
            }
        }
    }
    func selectNone() { items.indices.forEach { items[$0].isSelected = false } }

    var cleanableItems: [ScanItem] { items.filter { $0.category != .largeFiles } }
    var largeFileItems: [ScanItem] { items.filter { $0.category == .largeFiles } }
    var selectedItems: [ScanItem] { cleanableItems.filter(\.isSelected) }
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
        guard canClean, !isCleaning, cleaningTask == nil, let run = makeSmartCareRun() else {
            return false
        }
        activeSmartCareRun = run
        isCleaning = true
        bytesFreedSoFar = 0
        completedCategories = []
        deletionFailures = []
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
        for await event in smartCareDelete(run.items, cancellation) {
            switch event {
            case .itemProcessed(let item, let failure):
                currentCleaningItem = item
                processedSmartCareItemIDs.insert(item.id)
                if let failure {
                    deletionFailures.append(failure)
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
            failedCount: deletionFailures.count,
            unprocessedCount: unprocessedSmartCareItems.count,
            cancellationRequested: cancellation.isCancelled
        )

        if !successfulSmartCareItemIDs.isEmpty {
            recordSuccessfulClean()
        }
        isCleaning = false
        currentCleaningItem = nil
        cleaningCancellation = nil
        cleaningTask = nil
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
