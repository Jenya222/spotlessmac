import Foundation

struct DiskSpaceOverview: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let applicationsBytes: Int64
    let documentsBytes: Int64

    var usedBytes: Int64 { totalBytes - availableBytes }
    var systemBytes: Int64 { max(0, usedBytes - applicationsBytes - documentsBytes) }
    var availableFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
    var formattedUsed: String { ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file) }
    var formattedAvailable: String { ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file) }
    var formattedTotal: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
}

enum DiskSpaceService {
    static func overview() async -> DiskSpaceOverview {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)

        let home = FileManager.default.homeDirectoryForCurrentUser
        async let apps = FolderSizeCalculator.recursiveSize(URL(filePath: "/Applications", directoryHint: .isDirectory))
        async let docs = FolderSizeCalculator.recursiveSize(home.appending(path: "Documents", directoryHint: .isDirectory))
        let (appsBytes, docsBytes) = await (apps, docs)

        return DiskSpaceOverview(
            totalBytes: total, availableBytes: available,
            applicationsBytes: appsBytes, documentsBytes: docsBytes
        )
    }

    static func largestHomeFolders(limit: Int = 5) async -> [FolderEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries = await FolderSizeCalculator.children(of: home, cache: [:])
        return Array(entries.filter(\.isDirectory).sorted { $0.size > $1.size }.prefix(limit))
    }

    static var volumeDisplayName: String {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let values = try? root.resourceValues(forKeys: [.volumeNameKey])
        return values?.volumeName ?? "Macintosh HD"
    }
}
