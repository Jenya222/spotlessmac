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
        for item in items {
            guard SafetyRules.isSafe(url: item.path) else {
                failures.append(DeletionFailure(
                    item: item,
                    reason: "Путь не разрешён правилами безопасности."
                ))
                continue
            }
            do {
                try fm.trashItem(at: item.path, resultingItemURL: nil)
            } catch {
                failures.append(DeletionFailure(item: item, reason: error.localizedDescription))
            }
        }
        return failures
    }
}

enum CleaningEvent: Sendable {
    case itemProcessed(item: ScanItem, failure: DeletionFailure?)
}

extension ScanEngine {
    // Streams one event per item as it's trashed, so the UI can show a live
    // ring/current-file/per-category checklist. Every item is still gated
    // through SafetyRules.isSafe — same guarantee as delete(items:) above.
    nonisolated func deleteWithProgress(
        items: [ScanItem],
        cancellation: CleaningCancellation
    ) -> AsyncStream<CleaningEvent> {
        AsyncStream { continuation in
            let task = Task {
                let fm = FileManager.default
                for item in items {
                    if Task.isCancelled || cancellation.isCancelled { break }
                    guard SafetyRules.isSafe(url: item.path) else {
                        continuation.yield(.itemProcessed(
                            item: item,
                            failure: DeletionFailure(
                                item: item,
                                reason: "Путь не разрешён правилами безопасности."
                            )
                        ))
                        continue
                    }
                    do {
                        try fm.trashItem(at: item.path, resultingItemURL: nil)
                        continuation.yield(.itemProcessed(item: item, failure: nil))
                    } catch {
                        let failure = DeletionFailure(item: item, reason: error.localizedDescription)
                        continuation.yield(.itemProcessed(item: item, failure: failure))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
