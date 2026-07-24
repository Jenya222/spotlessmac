import Foundation
import Observation

struct CategoryTotal: Identifiable, Sendable {
    let category: ScanCategory
    let totalBytes: Int64
    var id: String { category.rawValue }
}

@Observable
@MainActor
final class ScanViewModel {
    var items: [ScanItem] = []
    var isScanning = false
    var isDeleting = false
    var scanError: String?
    var deletionFailures: [DeletionFailure] = []
    var fdaStatus: FDAStatus = .unknown

    // Smart Care (dashboard one-click flow)
    var isPreparingSmartCare = false
    var smartCareCategoryTotals: [CategoryTotal] = []
    var smartCareTotalBytes: Int64 = 0
    var isCleaning = false
    var currentCleaningItem: ScanItem?
    var bytesFreedSoFar: Int64 = 0
    var completedCategories: Set<ScanCategory> = []
    var cleaningStartedAt: Date?

    private let engine = ScanEngine()
    private var cleaningTask: Task<Void, Never>?

    // Real categories eligible for the one-click flow. .largeFiles never
    // participates in batch delete (existing invariant, see delete() below).
    private let smartCareCategories: Set<ScanCategory> = [.userCaches, .logs]

    var cleaningProgressFraction: Double {
        smartCareTotalBytes > 0 ? min(1, Double(bytesFreedSoFar) / Double(smartCareTotalBytes)) : 0
    }

    func checkFDA() {
        fdaStatus = FDAService.detect()
    }

    func scan() async {
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
        let eligible = items.filter { smartCareCategories.contains($0.category) }
        let grouped = Dictionary(grouping: eligible, by: \.category)
        smartCareCategoryTotals = grouped
            .map { CategoryTotal(category: $0.key, totalBytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.totalBytes > $1.totalBytes }
        smartCareTotalBytes = smartCareCategoryTotals.reduce(0) { $0 + $1.totalBytes }
    }

    // Called after the user confirms in the sheet. Only selected eligible
    // items are cleaned (mirrors existing per-item deselect via toggleSelection).
    func startSmartCare() {
        cleaningTask = Task { await runSmartCare() }
    }

    func stopSmartCare() {
        cleaningTask?.cancel()
    }

    private func runSmartCare() async {
        let toClean = items.filter { smartCareCategories.contains($0.category) && $0.isSelected }
        isCleaning = true
        bytesFreedSoFar = 0
        completedCategories = []
        deletionFailures = []
        cleaningStartedAt = Date()
        defer { isCleaning = false; currentCleaningItem = nil }

        for await event in engine.deleteWithProgress(items: toClean) {
            if Task.isCancelled { break }
            switch event {
            case .itemProcessed(let item, let failure):
                currentCleaningItem = item
                if let failure {
                    deletionFailures.append(failure)
                } else {
                    bytesFreedSoFar += item.size
                    items.removeAll { $0.id == item.id }
                    let categoryRemaining = items.contains {
                        $0.category == item.category && smartCareCategories.contains($0.category)
                    }
                    if !categoryRemaining { completedCategories.insert(item.category) }
                }
            }
        }
    }
}
