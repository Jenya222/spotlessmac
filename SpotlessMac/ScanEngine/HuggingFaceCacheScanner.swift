import Foundation

struct HuggingFaceCacheScanner: Scanner {
    let category: ScanCategory = .modelCaches
    let root: URL
    init(root: URL = SafetyRules.huggingFaceRoot) { self.root = root }
    static func isRepositoryName(_ name: String) -> Bool {
        let parts = name.components(separatedBy: "--")
        return parts.count >= 2 && ["models", "datasets", "spaces"].contains(parts[0]) && parts.dropFirst().allSatisfy { !$0.isEmpty }
    }
    func scan() async throws -> [ScanItem] {
        guard let rootID = StorageFileIdentity.read(root), rootID.isDirectory else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        var items: [ScanItem] = []
        for entry in entries {
            try Task.checkCancellation()
            guard Self.isRepositoryName(entry.lastPathComponent), StorageFileIdentity.read(entry)?.isDirectory == true else { continue }
            let measurement = try await StorageAnalysisEngine(policy: PathPolicy(readRoots: [root])).measure(entry)
            guard measurement.isComplete, measurement.allocatedBytes > 0 else { continue }
            items.append(ScanItem(path: entry, size: measurement.allocatedBytes, category: category,
                modifiedAt: try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, isSelected: false,
                cleanupPolicy: .init(disposition: .redownload, reason: "Весь репозиторий вместе с blobs. Модель или датасет потребуется загрузить заново. Остановите загрузки и Python-процессы.", requiresClosedOwner: true), owner: "Hugging Face / Python"))
        }
        return items.sorted { $0.size > $1.size }
    }
}
