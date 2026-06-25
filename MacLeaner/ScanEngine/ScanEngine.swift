import Foundation

struct DeletionFailure: Sendable {
    let item: ScanItem
    let reason: String
}

actor ScanEngine {
    private let scanners: [any Scanner] = [CachesScanner()]

    func scan() async throws -> [ScanItem] {
        var results: [ScanItem] = []
        for scanner in scanners {
            let items = try await scanner.scan()
            results.append(contentsOf: items)
        }
        return results
    }

    // Non-throwing: per-item failures are collected and returned, not propagated.
    // Only FileManager.trashItem is used — never removeItem.
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
