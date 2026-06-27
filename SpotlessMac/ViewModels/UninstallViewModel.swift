import Foundation
import Observation

@Observable
@MainActor
final class UninstallViewModel {
    var apps: [InstalledApp] = []
    var selectedApp: InstalledApp?
    var leftovers: [LeftoverItem] = []
    var isLoadingApps = false
    var isScanningLeftovers = false
    var isDeleting = false
    var failures: [UninstallFailure] = []

    private let engine = UninstallEngine()

    func loadApps() async {
        isLoadingApps = true
        defer { isLoadingApps = false }
        apps = await engine.listApps()
    }

    func select(_ app: InstalledApp) async {
        selectedApp = app
        leftovers = []
        failures = []
        isScanningLeftovers = true
        defer { isScanningLeftovers = false }
        let found = await engine.findLeftovers(for: app)
        // Guard against a stale result if the user switched apps mid-scan.
        guard selectedApp?.id == app.id else { return }
        leftovers = found
    }

    func toggleSelection(_ item: LeftoverItem) {
        guard let idx = leftovers.firstIndex(where: { $0.id == item.id }) else { return }
        leftovers[idx].isSelected.toggle()
    }

    func selectAllExact() {
        leftovers.indices.forEach { idx in
            if leftovers[idx].confidence == .exact {
                leftovers[idx].isSelected = true
            }
        }
    }

    func selectNone() {
        leftovers.indices.forEach { leftovers[$0].isSelected = false }
    }

    func uninstall() async {
        isDeleting = true
        defer { isDeleting = false }
        failures = []
        let toDelete = selectedLeftovers
        let result = await engine.uninstall(items: toDelete)
        failures = result
        let failedIDs = Set(result.map(\.item.id))
        let successIDs = Set(toDelete.map(\.id)).subtracting(failedIDs)
        leftovers.removeAll { successIDs.contains($0.id) }
        // If the app bundle itself was removed, drop it from the app list.
        if let app = selectedApp, !leftovers.contains(where: { $0.path == app.bundleURL }),
           successIDs.contains(where: { id in toDelete.first(where: { $0.id == id })?.path == app.bundleURL }) {
            apps.removeAll { $0.id == app.id }
            if leftovers.isEmpty { selectedApp = nil }
        }
    }

    var exactItems: [LeftoverItem] { leftovers.filter { $0.confidence == .exact } }
    var nameOnlyItems: [LeftoverItem] { leftovers.filter { $0.confidence == .nameOnly } }
    var selectedLeftovers: [LeftoverItem] { leftovers.filter(\.isSelected) }
    var hasSelection: Bool { !selectedLeftovers.isEmpty }
    var totalSelectedSize: Int64 { selectedLeftovers.reduce(0) { $0 + $1.size } }
    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }
}
