import Foundation

struct DiskSpaceOverview: Sendable {
    let totalBytes: Int64
    /// Free space as macOS Settings counts it, `purgeableBytes` included.
    let availableBytes: Int64
    let applicationsBytes: Int64
    let documentsBytes: Int64
    var isComplete = true
    var capacityKnown = true
    /// False while no source has been measured yet: zero bytes then mean "unknown", not "empty".
    var breakdownMeasured = true
    /// Caches and local snapshots macOS deletes on demand; Disk Utility and `df` still count them as used.
    var purgeableBytes: Int64 = 0

    var usedBytes: Int64 { totalBytes - availableBytes }
    var unclassifiedBytes: Int64 { max(0, usedBytes - applicationsBytes - documentsBytes) }
    var availableFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
    var formattedUsed: String { ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file) }
    var formattedAvailable: String { ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file) }
    var formattedTotal: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    var formattedPurgeable: String { ByteCountFormatter.string(fromByteCount: purgeableBytes, countStyle: .file) }
}

struct VolumeCapacity: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let purgeableBytes: Int64
}

enum DiskSpaceService {
    /// Capacity is read fresh on every call; the breakdown comes from already measured sources.
    /// Pass no sources for the capacity alone.
    static func overview(sourceResults: [StorageSourceResult]) async -> DiskSpaceOverview {
        let capacity = capacity()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let appRoots = SafetyRules.uninstallAppRoots
        let documentRoots = ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures", "MyProjects"].map { home.appending(path: $0) }
        var appsBytes: Int64 = 0
        var docsBytes: Int64 = 0
        var complete = !sourceResults.isEmpty
        for url in appRoots + documentRoots {
            if let value = sourceResults.first(where: { PathPolicy.canonical($0.source.url) == PathPolicy.canonical(url) }) {
                if let size = value.measurement {
                    if appRoots.contains(url) { appsBytes += size.allocatedBytes } else { docsBytes += size.allocatedBytes }
                    complete = complete && size.isComplete
                } else if FileManager.default.fileExists(atPath: url.path) { complete = false }
            } else { complete = false }
        }

        return DiskSpaceOverview(
            totalBytes: capacity?.totalBytes ?? 0, availableBytes: capacity?.availableBytes ?? 0,
            applicationsBytes: appsBytes, documentsBytes: docsBytes, isComplete: complete, capacityKnown: capacity != nil,
            breakdownMeasured: !sourceResults.isEmpty, purgeableBytes: capacity?.purgeableBytes ?? 0
        )
    }

    /// Free space as macOS Settings and Finder report it: purgeable data (caches, local snapshots)
    /// counts as free. `volumeAvailableCapacity` alone omits it and reads tens of gigabytes lower.
    static func capacity(of volume: URL = URL(filePath: "/", directoryHint: .isDirectory)) -> VolumeCapacity? {
        guard let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let unused = values.volumeAvailableCapacity else { return nil }
        let available = max(Int64(unused), values.volumeAvailableCapacityForImportantUsage ?? 0)
        return VolumeCapacity(totalBytes: Int64(total), availableBytes: available, purgeableBytes: available - Int64(unused))
    }

    static func largestHomeFolders(limit: Int = 5) async -> [FolderEntry] {
        var entries: [FolderEntry] = []
        for source in StorageSourceCatalog.sources() {
            if let size = try? await StorageAnalysisEngine().measure(source.url) {
                entries.append(FolderEntry(url: source.url, size: size.allocatedBytes, isDirectory: true))
            }
        }
        return Array(entries.sorted { $0.size > $1.size }.prefix(limit))
    }

    static var volumeDisplayName: String {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let values = try? root.resourceValues(forKeys: [.volumeNameKey])
        return values?.volumeName ?? "Macintosh HD"
    }
}
