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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if Task.isCancelled { return total }
            let rv = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv?.isRegularFile == true {
                total += Int64(rv?.fileSize ?? 0)
            }
        }
        return total
    }
}
