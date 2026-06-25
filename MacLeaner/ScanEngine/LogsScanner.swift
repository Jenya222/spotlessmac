import Foundation

struct LogsScanner: Scanner {
    let fdaGranted: Bool
    let category: ScanCategory = .logs

    func scan() async throws -> [ScanItem] {
        var results: [ScanItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLogs = home.appending(path: "Library/Logs", directoryHint: .isDirectory)
        results += try scanDir(userLogs)
        if fdaGranted {
            let systemLogs = URL(filePath: "/Library/Logs", directoryHint: .isDirectory)
            results += try scanDir(systemLogs)
        }
        return results.sorted { $0.size > $1.size }
    }

    private func scanDir(_ url: URL) throws -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var items: [ScanItem] = []
        for entry in entries {
            let size = try recursiveSize(entry)
            if size > 0 {
                items.append(ScanItem(path: entry, size: size, category: .logs))
            }
        }
        return items
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
