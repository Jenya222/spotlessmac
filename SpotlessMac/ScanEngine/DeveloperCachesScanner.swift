import Foundation

struct DeveloperCachesScanner: Scanner {
    let category: ScanCategory = .developerCaches
    let roots: [URL]

    init(roots: [URL]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            self.roots = SafetyRules.developerCacheRoots
        }
    }

    func scan() async throws -> [ScanItem] {
        let fm = FileManager.default
        var results: [ScanItem] = []

        for root in roots {
            guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            let entries = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                if Task.isCancelled { return results.sorted { $0.size > $1.size } }
                let size = FolderSizeCalculator.recursiveSize(entry)
                guard size > 0 else { continue }
                let modifiedAt = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                results.append(ScanItem(
                    path: entry,
                    size: size,
                    category: .developerCaches,
                    modifiedAt: modifiedAt
                ))
            }
        }

        return results.sorted { $0.size > $1.size }
    }
}
