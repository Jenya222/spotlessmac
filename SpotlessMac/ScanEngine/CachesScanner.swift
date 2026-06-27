import Foundation

struct CachesScanner: Scanner {
    let category: ScanCategory = .userCaches

    func scan() async throws -> [ScanItem] {
        let cachesURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: cachesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var results: [ScanItem] = []
        for url in entries {
            let size = try recursiveSize(url)
            if size > 0 {
                results.append(ScanItem(path: url, size: size, category: .userCaches))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    private func recursiveSize(_ url: URL) throws -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let rv = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let rv = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv.isRegularFile == true {
                total += Int64(rv.fileSize ?? 0)
            }
        }
        return total
    }
}
