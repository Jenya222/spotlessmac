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

    private let engine = ScanEngine()

    func scan() async {
        isScanning = true
        scanError = nil
        deletionFailures = []
        defer { isScanning = false }
        do {
            items = try await engine.scan()
        } catch {
            scanError = error.localizedDescription
        }
    }

    func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        deletionFailures = []
        let toDelete = selectedItems
        let failures = await engine.delete(items: toDelete)
        deletionFailures = failures
        let failedIDs = Set(failures.map(\.item.id))
        let successIDs = Set(toDelete.map(\.id)).subtracting(failedIDs)
        items.removeAll { successIDs.contains($0.id) }
    }

    func toggleSelection(_ item: ScanItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    func selectAll()  { items.indices.forEach { items[$0].isSelected = true } }
    func selectNone() { items.indices.forEach { items[$0].isSelected = false } }

    var selectedItems: [ScanItem] { items.filter(\.isSelected) }
    var totalSelectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var hasSelection: Bool { !selectedItems.isEmpty }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }
}
