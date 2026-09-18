import Foundation

struct OldInstallersScanner: Scanner {
    let category: ScanCategory = .oldInstallers
    let root: URL
    let now: Date
    let minimumAge: TimeInterval

    init(
        root: URL? = nil,
        now: Date = Date(),
        minimumAge: TimeInterval = 7 * 86_400
    ) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads", directoryHint: .isDirectory)
        self.now = now
        self.minimumAge = minimumAge
    }

    func scan() async throws -> [ScanItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Generic ZIP files may contain personal archives and are not reliable
        // installer candidates without inspecting their contents.
        let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
        var results: [ScanItem] = []
        for case let file as URL in enumerator {
            if Task.isCancelled { break }
            guard extensions.contains(file.pathExtension.lowercased()) else { continue }
            guard let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]), values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= minimumAge else { continue }

            results.append(ScanItem(
                path: file,
                size: Int64(values.fileSize ?? 0),
                category: .oldInstallers,
                modifiedAt: modifiedAt,
                isSelected: false
            ))
        }
        return results.sorted { $0.size > $1.size }
    }
}
