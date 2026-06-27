import Foundation

struct DeletionFailure: Sendable {
    let item: ScanItem
    let reason: String
}

actor ScanEngine {
    func scan(fdaStatus: FDAStatus) async throws -> [ScanItem] {
        let scanners: [any Scanner] = [
            CachesScanner(),
            LogsScanner(fdaGranted: fdaStatus == .granted),
            LargeFilesScanner(),
        ]
        var results: [ScanItem] = []
        for scanner in scanners {
            let items = try await scanner.scan()
            results.append(contentsOf: items)
        }
        return results
    }

    // Non-throwing: per-item failures collected and returned.
    // Only FileManager.trashItem is used — never removeItem.
    // Large files (.largeFiles category) must never reach this method via batch delete;
    // use deleteSingle() in ScanViewModel for them.
    func delete(items: [ScanItem]) async -> [DeletionFailure] {
        var failures: [DeletionFailure] = []
        let fm = FileManager.default
        for item in items where SafetyRules.isSafe(url: item.path) {
            do {
                try fm.trashItem(at: item.path, resultingItemURL: nil)
            } catch {
                failures.append(DeletionFailure(item: item, reason: error.localizedDescription))
            }
        }
        return failures
    }
}
