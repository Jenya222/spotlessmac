import Foundation

struct LargeFilesScanner: Scanner {
    let category: ScanCategory = .largeFiles
    let roots: [URL]
    let threshold: Int64

    init(roots: [URL]? = nil, threshold: Int64 = 524_288_000) {
        if let roots {
            self.roots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.roots = [
                home.appending(path: "Downloads", directoryHint: .isDirectory),
                home.appending(path: "Movies", directoryHint: .isDirectory),
                home.appending(path: "Documents", directoryHint: .isDirectory),
                home.appending(path: "Desktop", directoryHint: .isDirectory),
                home.appending(path: "Music", directoryHint: .isDirectory),
                home.appending(path: "Pictures", directoryHint: .isDirectory),
            ]
        }
        self.threshold = threshold
    }

    func scan() async throws -> [ScanItem] {
        var results: [ScanItem] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                if Task.isCancelled { return results.sorted { $0.size > $1.size } }
                guard let rv = try? file.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .contentModificationDateKey,
                ]) else { continue }
                guard rv.isRegularFile == true else { continue }
                let size = Int64(rv.fileSize ?? 0)
                if size >= threshold {
                    // isSelected: false — large files are never auto-selected
                    results.append(ScanItem(
                        path: file,
                        size: size,
                        category: .largeFiles,
                        modifiedAt: rv.contentModificationDate,
                        isSelected: false
                    ))
                }
            }
        }
        return results.sorted { $0.size > $1.size }
    }
}
