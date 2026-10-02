import Foundation

struct RecordingScanner: Scanner {
    let category: ScanCategory = .recordings
    let root: URL
    static let extensions: Set<String> = ["wav", "m4a", "mp3", "flac", "ogg", "webm"]
    init(root: URL = SafetyRules.recordingsRoot) { self.root = root }
    static func isStandalone(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()), StorageFileIdentity.read(url)?.isRegularFile == true else { return false }
        let stem = url.deletingPathExtension()
        return !["json", "sqlite", "db", "part", "tmp"].contains { FileManager.default.fileExists(atPath: stem.appendingPathExtension($0).path) }
    }
    func scan() async throws -> [ScanItem] {
        if root == SafetyRules.recordingsRoot && !SafetyRules.rootIsTrusted(root) { return [] }
        guard StorageFileIdentity.read(root)?.isDirectory == true else { return [] }
        var result: [ScanItem] = []
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            try Task.checkCancellation()
            guard Self.isStandalone(entry), let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) > 60 else { continue }
            let size = try await StorageAnalysisEngine(policy: PathPolicy(readRoots: [root])).measure(entry)
            guard size.isComplete else { continue }
            result.append(ScanItem(path: entry, size: size.allocatedBytes, category: category, modifiedAt: modified, isSelected: false,
                cleanupPolicy: .init(disposition: .personalData, reason: "Личная запись. Прослушайте перед удалением и закройте Wooffoow.", requiresClosedOwner: true), owner: "Wooffoow"))
        }
        return result.sorted { $0.size > $1.size }
    }
}
