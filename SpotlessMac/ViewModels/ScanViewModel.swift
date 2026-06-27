import Foundation
import Observation

@Observable
@MainActor
final class ScanViewModel {
    var items: [ScanItem] = []
    var isScanning = false
    var isDeleting = false
    var scanError: String?
    var deletionFailures: [DeletionFailure] = []
    var fdaStatus: FDAStatus = .unknown

    private let engine = ScanEngine()

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
}
