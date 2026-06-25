import Foundation

private let largeFileThreshold: Int64 = 1_073_741_824 // 1 GiB

struct LargeFilesScanner: Scanner {
    let category: ScanCategory = .largeFiles

    func scan() async throws -> [ScanItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL] = [
            home.appending(path: "Downloads",  directoryHint: .isDirectory),
            home.appending(path: "Movies",     directoryHint: .isDirectory),
            home.appending(path: "Documents",  directoryHint: .isDirectory),
            home.appending(path: "Desktop",    directoryHint: .isDirectory),
            home.appending(path: "Music",      directoryHint: .isDirectory),
            home.appending(path: "Pictures",   directoryHint: .isDirectory),
        ]
        var results: [ScanItem] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                let rv = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard rv.isRegularFile == true else { continue }
                let size = Int64(rv.fileSize ?? 0)
                if size >= largeFileThreshold {
                    // isSelected: false — large files are never auto-selected
                    results.append(ScanItem(path: file, size: size, category: .largeFiles, isSelected: false))
                }
            }
        }
        return results.sorted { $0.size > $1.size }
    }
}
