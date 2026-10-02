import Foundation

struct DiskSpaceOverview: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let applicationsBytes: Int64
    let documentsBytes: Int64
    var isComplete = true
    var capacityKnown = true

    var usedBytes: Int64 { totalBytes - availableBytes }
    var unclassifiedBytes: Int64 { max(0, usedBytes - applicationsBytes - documentsBytes) }
    var availableFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
    var formattedUsed: String { ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file) }
    var formattedAvailable: String { ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file) }
    var formattedTotal: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
}

enum DiskSpaceService {
    static func overview(sourceResults: [StorageSourceResult]? = nil) async -> DiskSpaceOverview {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let appRoots = SafetyRules.uninstallAppRoots
        let documentRoots = ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures", "MyProjects"].map { home.appending(path: $0) }
        let engine = StorageAnalysisEngine()
        var appsBytes: Int64 = 0
        var docsBytes: Int64 = 0
        var complete = true
        if let sourceResults {
            complete = !sourceResults.isEmpty
            for url in appRoots + documentRoots {
                if let value = sourceResults.first(where: { PathPolicy.canonical($0.source.url) == PathPolicy.canonical(url) }) {
                    if let size = value.measurement {
                        if appRoots.contains(url) { appsBytes += size.allocatedBytes } else { docsBytes += size.allocatedBytes }
                        complete = complete && size.isComplete
                    } else if FileManager.default.fileExists(atPath: url.path) { complete = false }
                } else { complete = false }
            }
        } else {
            for url in appRoots + documentRoots {
                do {
                    let size = try await engine.measure(url)
                    if appRoots.contains(url) { appsBytes += size.allocatedBytes } else { docsBytes += size.allocatedBytes }
                    complete = complete && size.isComplete
                } catch { if FileManager.default.fileExists(atPath: url.path) { complete = false } }
            }
        }

        return DiskSpaceOverview(
            totalBytes: total, availableBytes: available,
            applicationsBytes: appsBytes, documentsBytes: docsBytes, isComplete: complete, capacityKnown: values?.volumeTotalCapacity != nil && values?.volumeAvailableCapacity != nil
        )
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
