import Foundation

struct ProjectArtifactsScanner: Scanner {
    let category: ScanCategory = .projectArtifacts
    let roots: [URL]
    init(roots: [URL] = SafetyRules.projectRoots.filter(SafetyRules.rootIsTrusted)) { self.roots = roots }
    static func hasMarker(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        let marker: URL
        switch url.lastPathComponent {
        case "node_modules": marker = parent.appending(path: "package.json")
        case ".build": marker = parent.appending(path: "Package.swift")
        case "build": marker = url.appending(path: "CMakeCache.txt")
        default: return false
        }
        return StorageFileIdentity.read(marker)?.isRegularFile == true
    }
    static func containsGitMetadata(_ url: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in false }) else { return true }
        for case let child as URL in walker {
            if child.lastPathComponent == ".git" { return true }
            if StorageFileIdentity.read(child)?.isSymbolicLink == true { walker.skipDescendants() }
            if Task.isCancelled { return true }
        }
        return false
    }
    func scan() async throws -> [ScanItem] {
        var result: [ScanItem] = []
        for root in roots {
            guard StorageFileIdentity.read(root)?.isDirectory == true else { continue }
            let policy = PathPolicy(readRoots: [root])
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { continue }
            for case let entry as URL in walker {
                try Task.checkCancellation()
                guard policy.canRead(entry), StorageFileIdentity.read(entry)?.isDirectory == true else { walker.skipDescendants(); continue }
                if [".git", "vendor", ".env"].contains(entry.lastPathComponent) { walker.skipDescendants(); continue }
                if Self.hasMarker(entry) {
                    walker.skipDescendants()
                    guard !Self.containsGitMetadata(entry) else { continue }
                    let size = try await StorageAnalysisEngine(policy: policy).measure(entry)
                    guard size.isComplete, size.allocatedBytes > 0 else { continue }
                    result.append(ScanItem(path: entry, size: size.allocatedBytes, category: category, isSelected: false,
                        cleanupPolicy: .init(disposition: .redownload, reason: "Зависимости или сборка проекта \(entry.deletingLastPathComponent().lastPathComponent). Потребуется переустановка или пересборка. Остановите сборки.", requiresClosedOwner: true), owner: "Инструменты сборки"))
                } else if ["node_modules", ".build", "build"].contains(entry.lastPathComponent) { walker.skipDescendants() }
            }
        }
        return result.sorted { $0.size > $1.size }
    }
}
