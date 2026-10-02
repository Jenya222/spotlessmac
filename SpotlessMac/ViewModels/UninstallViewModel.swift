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
    private var activeSelectionID = UUID()
    var isDeleting = false
    var failures: [UninstallFailure] = []

    var storageSummaries: [UUID: AppStorageSummary] = [:]
    var sortBySize = true
    var isSizingApps = false
    private var summaryTask: Task<Void, Never>?
    private var summaryGeneration = UUID()
    private let cleaner = ScanEngine()
    var sortedApps: [InstalledApp] {
        apps.sorted {
            guard sortBySize else { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let a = storageSummaries[$0.id], b = storageSummaries[$1.id]
            if a == nil || b == nil { return a != nil && b == nil }
            if a!.confirmedTotalBytes != b!.confirmedTotalBytes { return a!.confirmedTotalBytes > b!.confirmedTotalBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    private let engine = UninstallEngine()

    func loadApps() async {
        isLoadingApps = true
        defer { isLoadingApps = false }
        apps = await engine.listApps()
        summaryTask?.cancel()
        let generation = UUID(); summaryGeneration = generation
        storageSummaries = [:]; isSizingApps = true
        let snapshot = apps
        let service = AppStorageService()
        summaryTask = Task {
            for offset in stride(from: 0, to: snapshot.count, by: 4) {
                guard !Task.isCancelled, summaryGeneration == generation else { return }
                let batch = Array(snapshot[offset..<min(snapshot.count, offset + 4)])
                let results = await withTaskGroup(of: AppStorageSummary?.self) { group in
                    for app in batch { group.addTask { try? await service.summary(for: app) } }
                    var values: [AppStorageSummary] = []
                    for await value in group { if let value { values.append(value) } }
                    return values
                }
                guard !Task.isCancelled, summaryGeneration == generation else { return }
                for summary in results { storageSummaries[summary.appID] = summary }
            }
            if summaryGeneration == generation { isSizingApps = false }
        }
    }

    func select(_ app: InstalledApp) async {
        guard !isDeleting else { return }
        let selectionID = UUID(); activeSelectionID = selectionID
        selectedApp = app
        leftovers = []
        failures = []
        isScanningLeftovers = true
        defer { if activeSelectionID == selectionID { isScanningLeftovers = false } }
        let found = await engine.findLeftovers(for: app)
        // Guard against a stale result if the user switched apps mid-scan.
        guard selectedApp?.id == app.id, activeSelectionID == selectionID else { return }
        leftovers = found
    }

    func toggleSelection(_ item: LeftoverItem) {
        guard let idx = leftovers.firstIndex(where: { $0.id == item.id }) else { return }
        leftovers[idx].isSelected.toggle()
    }

    func selectAllExact() {
        leftovers.indices.forEach { idx in
            if leftovers[idx].confidence == .exact && (leftovers[idx].isCache || leftovers[idx].location == "Программа") {
                leftovers[idx].isSelected = true
            }
        }
    }

    func selectNone() {
        leftovers.indices.forEach { leftovers[$0].isSelected = false }
    }

    func uninstall(items snapshot: [LeftoverItem]? = nil) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        failures = []
        let toDelete = snapshot ?? selectedLeftovers
        let result = await engine.uninstall(items: toDelete)
        failures = result
        if let app = selectedApp { storageSummaries.removeValue(forKey: app.id) }
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

    var supportedCacheItems: [ScanItem] {
        leftovers.filter { item in
            KnownCacheScanner.locations(home: FileManager.default.homeDirectoryForCurrentUser).contains { PathPolicy.canonical($0.url) == PathPolicy.canonical(item.path) }
        }.map { item in
            ScanItem(path: item.path, size: item.size, category: .knownAppCaches, isSelected: false,
                cleanupPolicy: .init(disposition: .rebuildable, reason: "Кэш приложения. Закройте программу перед очисткой.", requiresClosedOwner: true), owner: selectedApp?.name)
        }
    }
    func cleanCache(_ snapshot: [ScanItem]) async -> [DeletionFailure] {
        guard !isDeleting else { return snapshot.map { DeletionFailure(item: $0, reason: "Дождитесь завершения операции.") } }
        isDeleting = true; defer { isDeleting = false }
        let failures = await cleaner.delete(items: snapshot)
        if let app = selectedApp { storageSummaries.removeValue(forKey: app.id) }
        let failed = Set(failures.map { $0.item.path })
        leftovers.removeAll { item in snapshot.contains { $0.path == item.path } && !failed.contains(item.path) }
        return failures
    }
    func cancelSizing() {
        summaryGeneration = UUID(); summaryTask?.cancel(); summaryTask = nil; isSizingApps = false
    }

    var exactItems: [LeftoverItem] { leftovers.filter { $0.confidence == .exact } }
    var nameOnlyItems: [LeftoverItem] { leftovers.filter { $0.confidence == .nameOnly } }
    var selectedLeftovers: [LeftoverItem] { LeftoverItem.nonOverlapping(leftovers.filter(\.isSelected)) }
    var hasSelection: Bool { !selectedLeftovers.isEmpty }
    var totalSelectedSize: Int64 { selectedLeftovers.reduce(0) { $0 + $1.size } }
    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }

    var totalLeftoverCount: Int { leftovers.count }
    var totalLeftoverSize: Int64 { LeftoverItem.nonOverlapping(leftovers).reduce(0) { $0 + $1.size } }
    var formattedTotalLeftoverSize: String {
        ByteCountFormatter.string(fromByteCount: totalLeftoverSize, countStyle: .file)
    }

    var leftoversByLocation: [(location: String, items: [LeftoverItem])] {
        let grouped = Dictionary(grouping: leftovers, by: \.location)
        return grouped.keys.sorted().map { key in
            (location: key, items: grouped[key]!.sorted { $0.size > $1.size })
        }
    }

    // Heuristic threshold for flagging an unusually large leftover — tunable.
    static let largeLeftoverThreshold: Int64 = 5 * 1_073_741_824

    var largeLeftoverWarning: LeftoverItem? {
        leftovers.filter { $0.size >= Self.largeLeftoverThreshold }.max { $0.size < $1.size }
    }
}
