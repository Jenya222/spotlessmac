import Foundation

struct FolderEntry: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let size: Int64
    let isDirectory: Bool
    var name: String { url.lastPathComponent }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    init(url: URL, size: Int64, isDirectory: Bool) {
        self.id = UUID()
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
    }
}

enum FolderSizeCalculator {
    static func children(of dir: URL, cache: [String: Int64]) async -> [FolderEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return await withTaskGroup(of: FolderEntry?.self) { group in
            for url in urls {
                group.addTask(priority: .utility) {
                    if Task.isCancelled { return nil }
                    let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDir = rv?.isDirectory ?? false
                    let size: Int64
                    if isDir {
                        let key = url.standardizedFileURL.path(percentEncoded: false)
                        size = cache[key] ?? recursiveSize(url)
                    } else {
                        size = Int64(rv?.fileSize ?? 0)
                    }
                    return FolderEntry(url: url, size: size, isDirectory: isDir)
                }
            }
            var result: [FolderEntry] = []
            for await entry in group {
                if let entry { result.append(entry) }
            }
            return result
        }
    }

    static func recursiveSize(_ url: URL) -> Int64 {
        // Legacy callers display logical bytes; the analysis UI displays allocated bytes.
        (try? StorageAnalysisEngine.measureNow(url, policy: PathPolicy(readRoots: [url])).logicalBytes) ?? 0
    }
}
